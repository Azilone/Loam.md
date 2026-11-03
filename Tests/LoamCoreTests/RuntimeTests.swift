import XCTest
import PluginKit
import LoamCore

private struct Marker {}

private extension ServiceKey where Service == Marker {
    static var graph: ServiceKey<Marker> { ServiceKey<Marker>("graph") }
    static var links: ServiceKey<Marker> { ServiceKey<Marker>("links") }
    static var hostUI: ServiceKey<Marker> { ServiceKey<Marker>("host.ui") }
}

/// Stands for note-graph: provides `graph`.
private final class Graph: Plugin {
    static var manifest: PluginManifest {
        PluginManifest(id: "graph", name: "Graph", version: "1.0.0", provides: ["graph"])
    }
    required init() {}
    func activate(context: PluginContext) throws {
        try context.provide(.graph, Marker())
        try context.registerCommand(Command(id: "graph.run", title: "Graph", summary: "Graph command") { _ in "" })
    }
}

/// Requires `graph`, provides `links`.
private final class Links: Plugin {
    static var manifest: PluginManifest {
        PluginManifest(id: "links", name: "Links", version: "1.0.0", provides: ["links"], requires: ["graph"])
    }
    required init() {}
    func activate(context: PluginContext) throws {
        try context.provide(.links, Marker())
    }
}

/// Requires `links`, so `graph` transitively.
private final class Panel: Plugin {
    static var manifest: PluginManifest {
        PluginManifest(id: "panel", name: "Panel", version: "1.0.0", requires: ["links"])
    }
    required init() {}
    func activate(context: PluginContext) throws {}
}

/// Unrelated to the others.
private final class Loner: Plugin {
    static var manifest: PluginManifest {
        PluginManifest(id: "loner", name: "Loner", version: "1.0.0", description: "Stands alone.", icon: "person")
    }
    required init() {}
    func activate(context: PluginContext) throws {
        try context.registerCommand(Command(id: "loner.run", title: "Loner", summary: "Loner command") { _ in "" })
    }
}

/// Requires a service only the host provides.
private final class NeedsHost: Plugin {
    static var manifest: PluginManifest {
        PluginManifest(id: "needs-host", name: "Needs host", version: "1.0.0", requires: ["host.ui"])
    }
    required init() {}
    func activate(context: PluginContext) throws {}
}

private let allFakes: [Plugin.Type] = [Graph.self, Links.self, Panel.self, Loner.self, NeedsHost.self]

/// Reads its settings in `activate` and follows their changes; describes one of them.
private final class Configurable: Plugin {
    struct Settings: Codable, Equatable {
        var folder = "Daily"
        var showRecent = false
    }

    static var manifest: PluginManifest {
        PluginManifest(id: "configurable", name: "Configurable", version: "1.0.0", settings: [
            SettingDescription("showRecent", title: "Show recent notes", help: "Above the folders."),
        ])
    }
    static var seen: [Settings] = []
    required init() {}
    func activate(context: PluginContext) throws {
        Self.seen = [context.settings.value(default: Settings())]
        context.on(PluginSettingsChanged.self) { [weak context] event in
            guard event.pluginID == "configurable", let context else { return }
            Self.seen.append(context.settings.value(default: Settings()))
        }
    }
}

/// Reads settings of several types, two of them described with their defaults.
private final class Typed: Plugin {
    struct Settings: Codable, Equatable {
        var folder = "Daily"
        var template = ".loam/templates/daily.md"
        var days = 30
        var ratio = 1.0
        var showRecent = false
    }

    static var manifest: PluginManifest {
        PluginManifest(id: "typed", name: "Typed", version: "1.0.0", settings: [
            SettingDescription("folder", title: "Folder", default: .string("Daily")),
            SettingDescription("days", title: "Keep for", default: .number(30)),
        ])
    }
    static var seen: Settings?
    required init() {}
    func activate(context: PluginContext) throws {
        Self.seen = context.settings.value(default: Settings())
        context.on(PluginSettingsChanged.self) { [weak context] _ in
            Self.seen = context?.settings.value(default: Settings())
        }
    }
}

final class RuntimeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeConfig(_ text: String) throws {
        try Vault(rootURL: root).write(ConfigStore.path, text)
    }

    private func run(_ runtime: Runtime, _ id: String, _ arguments: [String: String] = [:]) async throws -> [String: Any] {
        let output = try await runtime.kernel.commands.command(id: id)!.handler(arguments)
        return try JSONSerialization.jsonObject(with: Data(output.utf8)) as! [String: Any]
    }

    func testEverythingStartsWithoutAConfigAndNoFileIsCreated() throws {
        let runtime = try Runtime(rootURL: root, plugins: [Graph.self, Links.self, Panel.self, Loner.self])
        defer { runtime.close() }
        XCTAssertEqual(Set(runtime.host.activeIDs), ["graph", "links", "panel", "loner"])
        XCTAssertNotNil(runtime.kernel.commands.command(id: "plugins.list"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".loam").path))
    }

    func testADisabledPluginAndItsCommandsStayOff() throws {
        try writeConfig(#"{ "plugins": { "loner": { "enabled": false } } }"#)
        let runtime = try Runtime(rootURL: root, plugins: [Graph.self, Loner.self])
        defer { runtime.close() }
        XCTAssertEqual(runtime.host.activeIDs, ["graph"])
        XCTAssertNil(runtime.kernel.commands.command(id: "loner.run"))
    }

    func testAHostServiceSatisfiesARequirementAndCloseRemovesEverything() throws {
        var removed: [String] = []
        let runtime = try Runtime(rootURL: root, plugins: [NeedsHost.self, Loner.self]) { kernel in
            let remove = try kernel.services.provide(.hostUI, Marker())
            return [remove, { removed.append("second") }]
        }
        XCTAssertTrue(runtime.host.isActive("needs-host"))
        XCTAssertEqual(runtime.lastReport.skipped, [:])

        runtime.close()
        XCTAssertEqual(runtime.host.activeIDs, [])
        XCTAssertEqual(runtime.kernel.commands.all.map(\.id), [])
        XCTAssertFalse(runtime.kernel.services.isProvided(id: "host.ui"))
        XCTAssertEqual(removed, ["second"])
    }

    func testWithoutTheHostServiceThePluginIsSkippedWithAReason() throws {
        let runtime = try Runtime(rootURL: root, plugins: [NeedsHost.self])
        defer { runtime.close() }
        XCTAssertFalse(runtime.host.isActive("needs-host"))
        XCTAssertNotNil(runtime.lastReport.skipped["needs-host"])
    }

    func testDisableReportsDependentsAndOnlyWritesThePluginItself() async throws {
        let runtime = try Runtime(rootURL: root, plugins: allFakes)
        defer { runtime.close() }
        let result = try await run(runtime, "plugins.disable", ["id": "graph"])
        XCTAssertEqual(result["disabled"] as? String, "graph")
        XCTAssertEqual(result["alsoDeactivated"] as? [String], ["panel", "links"])
        XCTAssertEqual(runtime.host.activeIDs, ["loner"])
        XCTAssertNil(runtime.kernel.commands.command(id: "graph.run"))

        let config = try ConfigStore(vault: Vault(rootURL: root)).config
        XCTAssertFalse(config.isEnabled("graph"))
        XCTAssertTrue(config.isEnabled("links"), "dependents stay enabled; they stop only at runtime")
        XCTAssertTrue(config.isEnabled("panel"))
    }

    func testEnableStartsThePluginAndItsDependentsAgain() async throws {
        try writeConfig(#"{ "plugins": { "graph": { "enabled": false } } }"#)
        let runtime = try Runtime(rootURL: root, plugins: allFakes)
        defer { runtime.close() }
        XCTAssertEqual(runtime.host.activeIDs, ["loner"])
        XCTAssertNotNil(runtime.lastReport.skipped["links"])

        let result = try await run(runtime, "plugins.enable", ["id": "graph"])
        XCTAssertEqual(result["enabled"] as? String, "graph")
        XCTAssertEqual(result["active"] as? Bool, true)
        XCTAssertEqual(Set(runtime.host.activeIDs), ["graph", "links", "panel", "loner"])
        XCTAssertTrue(try ConfigStore(vault: Vault(rootURL: root)).config.isEnabled("graph"))
    }

    func testUnknownPluginIDsAreErrors() async throws {
        let runtime = try Runtime(rootURL: root, plugins: [Loner.self])
        defer { runtime.close() }
        for command in ["plugins.enable", "plugins.disable"] {
            do {
                _ = try await runtime.kernel.commands.command(id: command)!.handler(["id": "nope"])
                XCTFail("\(command) accepted an unknown id")
            } catch {
                XCTAssertEqual(error as? RuntimeError, .unknownPlugin(id: "nope"))
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".loam").path))
    }

    func testListShowsStateAndReasons() async throws {
        try writeConfig(#"{ "plugins": { "graph": { "enabled": false } } }"#)
        let runtime = try Runtime(rootURL: root, plugins: allFakes)
        defer { runtime.close() }
        let output = try await runtime.kernel.commands.command(id: "plugins.list")!.handler([:])
        let rows = try JSONSerialization.jsonObject(with: Data(output.utf8)) as! [[String: Any]]
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0["id"] as! String, $0) })
        XCTAssertEqual(rows.map { $0["id"] as! String }, ["graph", "links", "loner", "needs-host", "panel"])
        XCTAssertEqual(byID["graph"]?["enabled"] as? Bool, false)
        XCTAssertEqual(byID["graph"]?["active"] as? Bool, false)
        XCTAssertEqual(byID["links"]?["enabled"] as? Bool, true)
        XCTAssertEqual(byID["links"]?["requires"] as? [String], ["graph"])
        XCTAssertNotNil(byID["links"]?["skipped"] as? String)
        XCTAssertEqual(byID["loner"]?["active"] as? Bool, true)
        XCTAssertNil(byID["loner"]?["skipped"])
        XCTAssertEqual(byID["graph"]?["provides"] as? [String], ["graph"])
        XCTAssertEqual(byID["graph"]?["name"] as? String, "Graph")
        XCTAssertEqual(byID["graph"]?["version"] as? String, "1.0.0")
        XCTAssertEqual(byID["loner"]?["description"] as? String, "Stands alone.")
        XCTAssertEqual(byID["loner"]?["icon"] as? String, "person")
        XCTAssertEqual(byID["graph"]?["description"] as? String, "")
        XCTAssertNil(byID["graph"]?["icon"])
    }

    func testSafeModeRunsTheAllowlistAndWhatItRequires() throws {
        let runtime = try Runtime(rootURL: root, plugins: allFakes, safeMode: ["panel"])
        defer { runtime.close() }
        XCTAssertEqual(Set(runtime.host.activeIDs), ["graph", "links", "panel"])
        XCTAssertFalse(runtime.host.isActive("loner"))
    }

    func testSafeModeStillHonoursTheConfig() throws {
        try writeConfig(#"{ "plugins": { "links": { "enabled": false } } }"#)
        let runtime = try Runtime(rootURL: root, plugins: allFakes, safeMode: ["panel"])
        defer { runtime.close() }
        XCTAssertEqual(runtime.host.activeIDs, ["graph"])
    }

    func testApplyConfigFollowsEditsMadeOnDisk() throws {
        let runtime = try Runtime(rootURL: root, plugins: [Graph.self, Loner.self])
        defer { runtime.close() }
        try writeConfig(#"{ "plugins": { "loner": { "enabled": false } } }"#)
        let report = runtime.applyConfig()
        XCTAssertEqual(report.deactivated, ["loner"])
        XCTAssertEqual(runtime.host.activeIDs, ["graph"])
    }

    func testACorruptConfigStopsTheRuntimeFromOpening() throws {
        try writeConfig("{ nope")
        XCTAssertThrowsError(try Runtime(rootURL: root, plugins: [Loner.self])) { error in
            guard case ConfigError.corrupt = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try Vault(rootURL: root).read(ConfigStore.path), "{ nope")
    }

    func testPluginSettingsCanBeListedAndChangedByCommand() async throws {
        let runtime = try Runtime(rootURL: root, plugins: [Configurable.self, Loner.self])
        defer { runtime.close() }
        let list = try XCTUnwrap(runtime.kernel.commands.command(id: "plugins.settings"))
        let fields = try JSONDecoder().decode([SettingField].self, from: Data(try await list.handler(["id": "configurable"]).utf8))
        XCTAssertEqual(fields, [
            SettingField(key: "showRecent", value: .bool(false), defaultValue: .bool(false), title: "Show recent notes",
                         help: "Above the folders.", isDefault: true),
            SettingField(key: "folder", value: .string("Daily"), defaultValue: .string("Daily"), isDefault: true),
        ])
        let none = try JSONDecoder().decode([SettingField].self, from: Data(try await list.handler(["id": "loner"]).utf8))
        XCTAssertEqual(none, [], "a plugin that never reads settings has none")

        let set = try XCTUnwrap(runtime.kernel.commands.command(id: "plugins.set-setting"))
        let changed = try JSONDecoder().decode(SettingField.self, from: Data(
            try await set.handler(["id": "configurable", "key": "showRecent", "value": "true"]).utf8
        ))
        XCTAssertEqual(changed.value, .bool(true))
        XCTAssertFalse(changed.isDefault)
        _ = try await set.handler(["id": "configurable", "key": "folder", "value": "Journal/2026"])
        XCTAssertEqual(Configurable.seen.last, Configurable.Settings(folder: "Journal/2026", showRecent: true),
                       "the plugin is told and reads the new values")
        XCTAssertEqual(try ConfigStore(vault: Vault(rootURL: root)).config.settings(for: "configurable"), .map([
            "showRecent": .bool(true), "folder": .string("Journal/2026"),
        ]))
        do {
            _ = try await set.handler(["id": "nope", "key": "a", "value": "1"])
            XCTFail("accepted an unknown plugin")
        } catch {
            XCTAssertEqual(error as? RuntimeError, .unknownPlugin(id: "nope"))
        }
    }

    func testSetSettingKeepsTextAsTypedAndRefusesWhatThePluginCannotRead() async throws {
        let runtime = try Runtime(rootURL: root, plugins: [Typed.self])
        defer { runtime.close() }
        let set = try XCTUnwrap(runtime.kernel.commands.command(id: "plugins.set-setting"))
        func stored() throws -> JSONValue? { try ConfigStore(vault: Vault(rootURL: root)).config.settings(for: "typed") }

        // A folder named 2026 and a template named true are text, as their defaults are.
        _ = try await set.handler(["id": "typed", "key": "folder", "value": "2026"])
        _ = try await set.handler(["id": "typed", "key": "template", "value": "true"])
        _ = try await set.handler(["id": "typed", "key": "days", "value": "7"])
        XCTAssertEqual(try stored(), .map(["folder": .string("2026"), "template": .string("true"), "days": .number(7)]))
        XCTAssertEqual(Typed.seen, Typed.Settings(folder: "2026", template: "true", days: 7))
        _ = try await set.handler(["id": "typed", "key": "folder", "value": #""Journal""#])
        XCTAssertEqual(Typed.seen?.folder, "Journal", "a JSON string loses its quotes")

        // Refused, writing nothing: the plugin reads days as an integer, showRecent as a bool, ratio as a number.
        let refused: [(key: String, value: String, expected: String)] = [
            ("days", "7.5", "a whole number"), ("days", "soon", "a number"), ("showRecent", "yes", "true or false"),
            ("ratio", "\"wide\"", "a number"),
        ]
        let before = try stored()
        for (key, value, expected) in refused {
            do {
                _ = try await set.handler(["id": "typed", "key": key, "value": value])
                XCTFail("accepted \(key)=\(value)")
            } catch {
                XCTAssertEqual(error as? RuntimeError, .invalidSetting(id: "typed", key: key, expected: expected))
            }
        }
        XCTAssertThrowsError(try runtime.setSetting("folder", to: .number(2026), for: "typed")) { error in
            XCTAssertEqual(error as? RuntimeError, .invalidSetting(id: "typed", key: "folder", expected: "text"))
        }
        XCTAssertEqual(try stored(), before)
        _ = try await set.handler(["id": "typed", "key": "ratio", "value": "1.5"])
        XCTAssertEqual(Typed.seen?.ratio, 1.5, "a fraction is fine where the plugin reads a Double")

        let fields = runtime.settingFields(for: "typed")
        XCTAssertEqual(fields.first { $0.key == "days" }?.isWholeNumber, true)
        XCTAssertEqual(fields.first { $0.key == "ratio" }?.isWholeNumber, false)
        XCTAssertEqual(fields.first { $0.key == "folder" }?.defaultValue, .string("Daily"))
    }

    func testAStoredValueOfTheWrongTypeFollowsTheDefaultAndKeepsTheOtherSettings() throws {
        // Written by hand: the folder as a number, the days as a fraction.
        try writeConfig(#"""
        { "plugins": { "typed": { "settings": { "folder": 2026, "template": "Templates/Day.md", "days": 7.5 } } } }
        """#)
        let runtime = try Runtime(rootURL: root, plugins: [Typed.self])
        defer { runtime.close() }
        XCTAssertEqual(Typed.seen, Typed.Settings(template: "Templates/Day.md"), "only the unreadable keys reset")

        // The page shows what is in effect, with the control of the default's type.
        let fields = Dictionary(uniqueKeysWithValues: runtime.settingFields(for: "typed").map { ($0.key, $0) })
        XCTAssertEqual(fields["folder"]?.value, .string("Daily"))
        XCTAssertEqual(fields["folder"]?.isDefault, true)
        XCTAssertEqual(fields["folder"]?.kind, .string("Daily"))
        XCTAssertEqual(fields["days"]?.value, .number(30))
        XCTAssertEqual(fields["template"]?.value, .string("Templates/Day.md"))
        XCTAssertEqual(fields["template"]?.isDefault, false)
    }

    func testSetSettingRefusesAKeyThePluginNeverReads() throws {
        let runtime = try Runtime(rootURL: root, plugins: [Typed.self, Loner.self])
        defer { runtime.close() }
        XCTAssertThrowsError(try runtime.setSetting("foldr", to: .string("Journal"), for: "typed")) { error in
            guard case .unknownSetting(let id, let key, let known)? = error as? RuntimeError else { return XCTFail("\(error)") }
            XCTAssertEqual([id, key], ["typed", "foldr"])
            XCTAssertTrue(known.contains("folder"))
        }
        XCTAssertThrowsError(try runtime.setSetting("trashDays", to: .number(30), for: "loner")) { error in
            XCTAssertEqual(error as? RuntimeError, .unknownSetting(id: "loner", key: "trashDays", known: []))
        }
        XCTAssertNil(try ConfigStore(vault: Vault(rootURL: root)).config.settings(for: "typed"))
        XCTAssertEqual(runtime.settingFields(for: "loner"), [])
    }

    func testAStoredKeyThePluginDoesNotReadIsNotShownAsASetting() throws {
        try writeConfig(#"{ "plugins": { "typed": { "settings": { "unknownKey": 3, "days": 7 } } } }"#)
        let runtime = try Runtime(rootURL: root, plugins: [Typed.self])
        defer { runtime.close() }
        XCTAssertFalse(runtime.settingFields(for: "typed").map(\.key).contains("unknownKey"))
        XCTAssertEqual(runtime.settingFields(for: "typed").first { $0.key == "days" }?.value, .number(7))
    }

    func testSettingsEditedOutsideTheProcessAreAnnouncedToThePlugins() throws {
        let runtime = try Runtime(rootURL: root, plugins: [Typed.self])
        defer { runtime.close() }
        nonisolated(unsafe) var announced: [String] = []
        let remove = runtime.kernel.events.on(PluginSettingsChanged.self) { announced.append($0.pluginID) }
        defer { remove() }
        let before = runtime.config.config
        try writeConfig(#"{ "plugins": { "typed": { "settings": { "folder": "Journal" } } } }"#)
        XCTAssertTrue(try runtime.config.reload())
        runtime.applyConfig()
        runtime.announceSettingChanges(since: before)
        XCTAssertEqual(announced, ["typed"])
        XCTAssertEqual(Typed.seen?.folder, "Journal", "the plugin read the new value")
        // Nothing changed since: nothing is announced.
        runtime.announceSettingChanges(since: runtime.config.config)
        XCTAssertEqual(announced, ["typed"])
    }

    func testAPluginThatHasNotRunShowsTheSettingsItsManifestDescribes() throws {
        try writeConfig(#"{ "plugins": { "typed": { "enabled": false, "settings": { "days": 7 } } } }"#)
        let runtime = try Runtime(rootURL: root, plugins: [Typed.self])
        defer { runtime.close() }
        XCTAssertFalse(runtime.host.isActive("typed"))
        let fields = runtime.settingFields(for: "typed")
        XCTAssertEqual(fields.map(\.key), ["folder", "days"], "the described keys only, until it runs")
        XCTAssertEqual(fields.map(\.value), [.string("Daily"), .number(7)])
        XCTAssertEqual(fields.map(\.isDefault), [true, false])
        // Its descriptions still check the type of what is typed.
        XCTAssertThrowsError(try runtime.setSetting("days", to: .string("soon"), for: "typed"))
        XCTAssertNoThrow(try runtime.setSetting("folder", to: .string("Journal"), for: "typed"))
    }

    func testCoreCommandsHaveUsefulSummariesAndWritingOnesSaySo() throws {
        let runtime = try Runtime(rootURL: root, plugins: [])
        defer { runtime.close() }
        let core = runtime.kernel.commands.all
        XCTAssertEqual(core.map(\.id), [
            "plugins.disable", "plugins.enable", "plugins.list", "plugins.set-setting", "plugins.settings",
            "tools.check", "tools.install", "tools.list",
        ])
        for command in core {
            XCTAssertGreaterThan(command.summary.count, 20, command.id)
        }
        for id in ["plugins.enable", "plugins.disable", "plugins.set-setting"] {
            XCTAssertTrue(runtime.kernel.commands.command(id: id)!.summary.contains("writes .loam/config.json"), id)
        }
    }
}
