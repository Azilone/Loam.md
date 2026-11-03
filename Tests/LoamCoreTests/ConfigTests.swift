import XCTest
import PluginKit
import LoamCore

final class ConfigTests: XCTestCase {
    private var root: URL!
    private var vault: Vault!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        vault = Vault(rootURL: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var configURL: URL { root.appendingPathComponent(".loam/config.json") }

    private func writeConfig(_ text: String) throws {
        try vault.write(ConfigStore.path, text)
    }

    private func readConfigObject() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as! [String: Any]
    }

    func testAMissingFileIsAnEmptyConfigAndIsOnlyCreatedByTheFirstWrite() throws {
        let store = try ConfigStore(vault: vault)
        XCTAssertTrue(store.config.isEnabled("anything"))
        XCTAssertEqual(store.config.shortcuts, [:])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".loam").path))

        try store.mutate { _ in }
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURL.path), "a no-op change writes nothing")

        try store.mutate { $0.setEnabled(false, "truffle-search") }
        let object = try readConfigObject()
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual((object["plugins"] as? [String: [String: Bool]])?["truffle-search"], ["enabled": false])
    }

    func testReadsEnabledSettingsAndShortcuts() throws {
        try writeConfig("""
            { "version": 1,
              "plugins": { "truffle-search": { "enabled": false }, "daily-notes": { "settings": { "folder": "Journal" } } },
              "shortcuts": { "switcher.open": "cmd+o", "notes.reindex": "" } }
            """)
        let config = try ConfigStore(vault: vault).config
        XCTAssertFalse(config.isEnabled("truffle-search"))
        XCTAssertTrue(config.isEnabled("daily-notes"), "an entry without enabled is enabled")
        XCTAssertTrue(config.isEnabled("missing"))
        XCTAssertEqual(config.settings(for: "daily-notes"), .map(["folder": .string("Journal")]))
        XCTAssertNil(config.settings(for: "truffle-search"))
        XCTAssertEqual(config.shortcuts, ["switcher.open": "cmd+o", "notes.reindex": ""])
    }

    func testUnknownKeysSurviveAWrite() throws {
        try writeConfig("""
            { "version": 1, "theme": "dusk",
              "plugins": { "daily-notes": { "enabled": true, "pinned": 3 } },
              "shortcuts": { "switcher.open": "cmd+o" } }
            """)
        let store = try ConfigStore(vault: vault)
        try store.mutate {
            $0.setEnabled(false, "daily-notes")
            $0.shortcuts["notes.reindex"] = ""
        }
        let object = try readConfigObject()
        XCTAssertEqual(object["theme"] as? String, "dusk")
        let entry = (object["plugins"] as? [String: [String: Any]])?["daily-notes"]
        XCTAssertEqual(entry?["pinned"] as? Int, 3)
        XCTAssertEqual(entry?["enabled"] as? Bool, false)
        XCTAssertEqual(object["shortcuts"] as? [String: String], ["switcher.open": "cmd+o", "notes.reindex": ""])
    }

    func testTheFileIsPrettyWithSortedKeys() throws {
        let store = try ConfigStore(vault: vault)
        try store.mutate {
            $0.setEnabled(false, "b")
            $0.setEnabled(false, "a")
        }
        let text = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(text.contains("\n  \"plugins\""), text)
        XCTAssertLessThan(text.range(of: "\"a\"")!.lowerBound, text.range(of: "\"b\"")!.lowerBound)
        XCTAssertTrue(text.hasSuffix("}\n"))
    }

    func testACorruptFileThrowsAndIsNeverOverwritten() throws {
        for text in ["{ not json", "[1, 2]", "{ \"plugins\": 3 }", "{ \"plugins\": { \"a\": { \"enabled\": \"no\" } } }"] {
            try writeConfig(text)
            XCTAssertThrowsError(try ConfigStore(vault: vault), text) { error in
                guard case ConfigError.corrupt(let path, _) = error else { return XCTFail("\(error)") }
                XCTAssertEqual(path, ".loam/config.json")
            }
            XCTAssertEqual(try vault.read(ConfigStore.path), text)
        }
    }

    func testAChangeKeepsEditsMadeOnDiskAndRefusesACorruptedFile() throws {
        let store = try ConfigStore(vault: vault)
        try store.mutate { $0.setEnabled(false, "a") }

        try writeConfig(#"{ "plugins": { "a": { "enabled": false }, "b": { "enabled": false } } }"#)
        XCTAssertTrue(try store.reload())
        XCTAssertFalse(try store.reload(), "nothing changed since the last reload")
        try store.mutate { $0.setEnabled(true, "a") }
        XCTAssertTrue(store.config.isEnabled("a"))
        XCTAssertFalse(store.config.isEnabled("b"), "the edit made on disk is kept")

        try writeConfig("{ broken")
        XCTAssertThrowsError(try store.mutate { $0.setEnabled(false, "c") })
        XCTAssertEqual(try vault.read(ConfigStore.path), "{ broken")
    }
}

/// `context.settings`, through a kernel with and without a config file.
final class PluginSettingsTests: XCTestCase {
    private struct Settings: Codable, Equatable {
        var folder = "Daily"
        var count = 3
        var tags: [String] = []
    }

    /// Hands its context to the test.
    private final class Probe: Plugin {
        static var manifest: PluginManifest { PluginManifest(id: "probe", name: "Probe", version: "1.0.0") }
        static var context: PluginContext?
        required init() {}
        func activate(context: PluginContext) throws { Probe.context = context }
    }

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        Probe.context = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func activate(config: ConfigStore?) throws -> (PluginContext, Kernel) {
        let kernel = Kernel(vault: Vault(rootURL: root), config: config)
        let host = PluginHost(kernel: kernel)
        try host.register(Probe.self)
        try host.activateAll()
        return (Probe.context!, kernel)
    }

    func testDefaultsAreMergedOverPartialJSON() throws {
        let vault = Vault(rootURL: root)
        try vault.write(ConfigStore.path, #"{ "plugins": { "probe": { "settings": { "folder": "Journal", "extra": 1 } } } }"#)
        let (context, _) = try activate(config: try ConfigStore(vault: vault))
        XCTAssertEqual(context.pluginID, "probe")
        XCTAssertEqual(context.settings.value(default: Settings()), Settings(folder: "Journal", count: 3, tags: []))
    }

    func testAStoredValueThatDoesNotDecodeGivesTheDefault() throws {
        let vault = Vault(rootURL: root)
        try vault.write(ConfigStore.path, #"{ "plugins": { "probe": { "settings": { "count": "many" } } } }"#)
        let (context, _) = try activate(config: try ConfigStore(vault: vault))
        XCTAssertEqual(context.settings.value(default: Settings()), Settings())
    }

    func testUpdateWritesTheConfigAndSendsAnEvent() throws {
        let vault = Vault(rootURL: root)
        let config = try ConfigStore(vault: vault)
        let (context, kernel) = try activate(config: config)
        var changed: [String] = []
        _ = kernel.events.on(PluginSettingsChanged.self) { changed.append($0.pluginID) }

        let custom = Settings(folder: "Log", count: 7, tags: ["a"])
        try context.settings.update(custom)
        XCTAssertEqual(context.settings.value(default: Settings()), custom)
        XCTAssertEqual(changed, ["probe"])

        let reread = try ConfigStore(vault: vault)
        XCTAssertEqual(reread.config.settings(for: "probe")?.asMap?["folder"], .string("Log"))
        XCTAssertTrue(reread.config.isEnabled("probe"))
    }

    func testTheKernelLearnsTheDefaultsAPluginReadsItsSettingsWith() throws {
        let (context, kernel) = try activate(config: nil)
        XCTAssertNil(kernel.settingsDefault(for: "probe"), "nothing is known before the plugin reads its settings")
        _ = context.settings.value(default: Settings())
        XCTAssertEqual(kernel.settingsDefault(for: "probe"), .map([
            "folder": .string("Daily"), "count": .number(3), "tags": .list([]),
        ]))
        // A plugin that reads a second settings type gets both sets of keys.
        struct More: Codable, Equatable { var on = true }
        _ = context.settings.value(default: More())
        XCTAssertEqual(kernel.settingsDefault(for: "probe")?.asMap?.keys.sorted(), ["count", "folder", "on", "tags"])
        XCTAssertNil(kernel.settingsDefault(for: "other"))
    }

    func testWithoutAConfigSettingsStayInMemory() throws {
        let (context, _) = try activate(config: nil)
        XCTAssertEqual(context.settings.value(default: Settings()), Settings())
        try context.settings.update(Settings(folder: "Mem"))
        XCTAssertEqual(context.settings.value(default: Settings()).folder, "Mem")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".loam").path))
    }
}

private extension JSONValue {
    var asMap: [String: JSONValue]? {
        if case .map(let map) = self { return map }
        return nil
    }
}
