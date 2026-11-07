import XCTest
import PluginKit
@testable import LoamCore

/// A host service the fakes write to, so a test sees each activation without global state.
private final class Journal {
    var lines: [String] = []
}

private struct Marker {}

private extension ServiceKey where Service == Journal {
    static var journal: ServiceKey<Journal> { ServiceKey<Journal>("test.journal") }
}

private extension ServiceKey where Service == Marker {
    static var x: ServiceKey<Marker> { ServiceKey<Marker>("x") }
    static var y: ServiceKey<Marker> { ServiceKey<Marker>("y") }
    static var host: ServiceKey<Marker> { ServiceKey<Marker>("host.thing") }
}

private func log(_ context: PluginContext, _ line: String) {
    context.service(.journal)?.lines.append(line)
}

/// Provides x.
private final class ProviderA: Plugin {
    static var manifest: PluginManifest {
        PluginManifest(id: "a", name: "A", version: "1.0.0", provides: ["x"])
    }
    required init() {}
    func activate(context: PluginContext) throws {
        log(context, "a")
        try context.provide(.x, Marker())
        try context.registerCommand(Command(id: "a.run", title: "A", summary: "A") { _ in "a" })
    }
}

/// Requires x, provides y.
private final class MiddleB: Plugin {
    static var manifest: PluginManifest {
        PluginManifest(id: "b", name: "B", version: "1.0.0", provides: ["y"], requires: ["x"])
    }
    required init() {}
    func activate(context: PluginContext) throws {
        log(context, "b")
        try context.provide(.y, Marker())
        try context.registerCommand(Command(id: "b.run", title: "B", summary: "B") { _ in "b" })
    }
}

/// Requires y.
private final class LeafC: Plugin {
    static var manifest: PluginManifest {
        PluginManifest(id: "c", name: "C", version: "1.0.0", requires: ["y"])
    }
    required init() {}
    func activate(context: PluginContext) throws {
        log(context, "c")
        try context.registerCommand(Command(id: "c.run", title: "C", summary: "C") { _ in "c" })
    }
}

/// Uses x when it exists: registers `opt.extra` only then.
private final class OptionalUser: Plugin {
    static var manifest: PluginManifest {
        PluginManifest(id: "opt", name: "Optional", version: "1.0.0", optionalRequires: ["x"])
    }
    required init() {}
    func activate(context: PluginContext) throws {
        let hasX = context.service(.x) != nil
        log(context, hasX ? "opt+x" : "opt")
        if hasX {
            try context.registerCommand(Command(id: "opt.extra", title: "Extra", summary: "Extra") { _ in "" })
        }
    }
}

/// Requires a service only the host provides.
private final class HostUser: Plugin {
    static var manifest: PluginManifest {
        PluginManifest(id: "host-user", name: "Host user", version: "1.0.0", requires: ["host.thing"])
    }
    required init() {}
    func activate(context: PluginContext) throws {}
}

private struct Boom: Error {}

/// Promises x but throws.
private final class BrokenA: Plugin {
    static var manifest: PluginManifest {
        PluginManifest(id: "broken", name: "Broken", version: "1.0.0", provides: ["x"])
    }
    required init() {}
    func activate(context: PluginContext) throws {
        try context.registerCommand(Command(id: "broken.run", title: "Broken", summary: "Broken") { _ in "" })
        throw Boom()
    }
}

/// Unrelated to everything else.
private final class Loner: Plugin {
    static var manifest: PluginManifest {
        PluginManifest(id: "loner", name: "Loner", version: "1.0.0")
    }
    required init() {}
    func activate(context: PluginContext) throws {}
}

/// Optionally uses y and provides x: with B (requires x, provides y) this is a cycle through an optional edge.
private final class OptionalCycle: Plugin {
    static var manifest: PluginManifest {
        PluginManifest(id: "cyc", name: "Cycle", version: "1.0.0", provides: ["x"], optionalRequires: ["y"])
    }
    required init() {}
    func activate(context: PluginContext) throws {
        try context.provide(.x, Marker())
    }
}

final class PluginLifecycleTests: XCTestCase {
    private var kernel: Kernel!
    private var journal: Journal!

    override func setUpWithError() throws {
        kernel = Kernel(vault: Vault(rootURL: FileManager.default.temporaryDirectory))
        journal = Journal()
        _ = try kernel.services.provide(.journal, journal)
    }

    private func makeHost(_ types: [Plugin.Type]) throws -> PluginHost {
        let host = PluginHost(kernel: kernel)
        for type in types { try host.register(type) }
        return host
    }

    // MARK: - Cascade

    func testDeactivatingAProviderCascadesDeepestFirst() throws {
        let host = try makeHost([LeafC.self, MiddleB.self, ProviderA.self, Loner.self])
        try host.activateAll()
        XCTAssertEqual(host.dependents(of: "a"), ["c", "b"])
        XCTAssertEqual(host.dependents(of: "c"), [])

        XCTAssertEqual(host.deactivate("a"), ["c", "b", "a"])
        XCTAssertEqual(host.activeIDs, ["loner"])
        for id in ["a.run", "b.run", "c.run"] { XCTAssertNil(kernel.commands.command(id: id), id) }
        XCTAssertNil(kernel.services.service(.x))
        XCTAssertNil(kernel.services.service(.y))
        XCTAssertEqual(host.deactivate("a"), [])
    }

    func testDeactivatingALeafLeavesItsProvidersActive() throws {
        let host = try makeHost([LeafC.self, MiddleB.self, ProviderA.self])
        try host.activateAll()
        XCTAssertEqual(host.deactivate("c"), ["c"])
        XCTAssertEqual(host.activeIDs, ["a", "b"])
    }

    // MARK: - Optional requirements

    func testOptionalUserStaysActiveWithoutProviderAndRestartsWhenItReturns() throws {
        let host = try makeHost([ProviderA.self, OptionalUser.self])
        XCTAssertEqual(try host.resolveOrder().map(\.id), ["a", "opt"])

        var report = host.apply(enabled: nil)
        XCTAssertEqual(report.activated, ["a", "opt"])
        XCTAssertNotNil(kernel.commands.command(id: "opt.extra"))

        report = host.apply(enabled: ["opt"])
        XCTAssertEqual(report, ActivationReport(deactivated: ["a"]))
        XCTAssertTrue(host.isActive("opt"))
        XCTAssertNil(kernel.services.service(.x))

        report = host.apply(enabled: ["a", "opt"])
        XCTAssertEqual(report.activated, ["a", "opt"])
        XCTAssertEqual(report.deactivated, [])
        XCTAssertNotNil(kernel.commands.command(id: "opt.extra"))
        XCTAssertEqual(journal.lines, ["a", "opt+x", "a", "opt+x"])
    }

    func testOptionalUserStartedAloneIsRestartedWhenProviderIsEnabled() throws {
        let host = try makeHost([ProviderA.self, OptionalUser.self])
        host.apply(enabled: ["opt"])
        XCTAssertNil(kernel.commands.command(id: "opt.extra"))
        let report = host.apply(enabled: nil)
        XCTAssertEqual(report.activated, ["a", "opt"])
        XCTAssertNotNil(kernel.commands.command(id: "opt.extra"))
        XCTAssertEqual(journal.lines, ["opt", "a", "opt+x"])
    }

    func testMissingOptionalProviderIsFine() throws {
        let host = try makeHost([OptionalUser.self])
        XCTAssertEqual(try host.resolveOrder().map(\.id), ["opt"])
        try host.activateAll()
        XCTAssertEqual(host.activeIDs, ["opt"])
    }

    func testCycleThroughAnOptionalEdgeIsNotAnError() throws {
        let host = try makeHost([OptionalCycle.self, MiddleB.self])
        XCTAssertEqual(try host.resolveOrder().map(\.id), ["cyc", "b"])
        try host.activateAll()
        XCTAssertEqual(host.activeIDs, ["cyc", "b"])
    }

    // MARK: - Host services

    func testHostServiceSatisfiesARequirement() throws {
        let host = try makeHost([HostUser.self])
        XCTAssertThrowsError(try host.resolveOrder())
        let remove = try kernel.services.provide(.host, Marker())
        defer { remove() }
        XCTAssertEqual(try host.resolveOrder().map(\.id), ["host-user"])
        try host.activateAll()
        XCTAssertEqual(host.activeIDs, ["host-user"])
    }

    func testHostServiceSatisfiesARequirementInApply() throws {
        let host = try makeHost([HostUser.self])
        XCTAssertEqual(host.apply(enabled: nil).skipped.keys.sorted(), ["host-user"])
        let remove = try kernel.services.provide(.host, Marker())
        defer { remove() }
        XCTAssertEqual(host.apply(enabled: nil).activated, ["host-user"])
    }

    // MARK: - apply

    func testApplyingTheSameSetTwiceIsANoOp() throws {
        let host = try makeHost([LeafC.self, MiddleB.self, ProviderA.self, OptionalUser.self])
        let first = host.apply(enabled: nil)
        XCTAssertEqual(first.activated, ["a", "b", "c", "opt"])
        XCTAssertEqual(host.apply(enabled: nil), ActivationReport())
        XCTAssertEqual(host.apply(enabled: ["a", "b", "c", "opt"]), ActivationReport())
    }

    func testApplyDisablingAProviderCascades() throws {
        let host = try makeHost([LeafC.self, MiddleB.self, ProviderA.self, Loner.self])
        host.apply(enabled: nil)
        let report = host.apply(enabled: ["b", "c", "loner"])
        XCTAssertEqual(report.deactivated, ["c", "b", "a"])
        XCTAssertEqual(report.skipped["b"], "requires service 'x', which no enabled plugin provides")
        XCTAssertNotNil(report.skipped["c"])
        XCTAssertEqual(host.activeIDs, ["loner"])
    }

    func testFailingPluginIsReportedAndOnlyItsDependentsAreSkipped() throws {
        let host = try makeHost([BrokenA.self, MiddleB.self, LeafC.self, Loner.self, OptionalUser.self])
        let report = host.apply(enabled: nil)
        XCTAssertEqual(Array(report.failed.keys), ["broken"])
        XCTAssertEqual(report.skipped["b"], "requires service 'x', whose provider 'broken' is not active")
        XCTAssertEqual(report.skipped["c"], "requires service 'y', whose provider 'b' is not active")
        XCTAssertEqual(report.activated, ["loner", "opt"])
        XCTAssertEqual(host.activeIDs, ["loner", "opt"])
        XCTAssertNil(kernel.commands.command(id: "broken.run"))
    }

    func testPromisedServiceMissingFailsInApply() throws {
        let host = try makeHost([Forgetful.self, Loner.self])
        let report = host.apply(enabled: nil)
        XCTAssertEqual(
            report.failed["forgetful"],
            String(describing: PluginError.providedServiceMissing(plugin: "forgetful", service: "x"))
        )
        XCTAssertEqual(host.activeIDs, ["loner"])
    }

    // MARK: - activateAll and queries

    func testActivateAllIsIdempotent() throws {
        let host = try makeHost([ProviderA.self, MiddleB.self])
        try host.activateAll(enabled: ["a"])
        try host.activateAll()
        try host.activateAll()
        XCTAssertEqual(host.activeIDs, ["a", "b"])
        XCTAssertEqual(journal.lines, ["a", "b"])
    }

    func testActivateAllRollsBackOnlyWhatItStarted() throws {
        let host = try makeHost([Loner.self, BrokenA.self])
        try host.activateAll(enabled: ["loner"])
        XCTAssertThrowsError(try host.activateAll())
        XCTAssertEqual(host.activeIDs, ["loner"])
    }

    func testManifestsAndIsActive() throws {
        let host = try makeHost([MiddleB.self, ProviderA.self, Loner.self])
        XCTAssertEqual(host.manifests.map(\.id), ["a", "b", "loner"])
        try host.activateAll(enabled: ["loner"])
        XCTAssertTrue(host.isActive("loner"))
        XCTAssertFalse(host.isActive("a"))
        XCTAssertFalse(host.isActive("unknown"))
    }

    // MARK: - Manifest

    func testManifestDecodesWithoutOptionalLists() throws {
        let json = #"{"id": "p", "name": "P", "version": "1.0.0", "requires": ["x"]}"#
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        XCTAssertEqual(manifest, PluginManifest(id: "p", name: "P", version: "1.0.0", requires: ["x"]))
        XCTAssertEqual(manifest.optionalRequires, [])

        let full = PluginManifest(id: "q", name: "Q", version: "2.0.0", provides: ["a"], optionalRequires: ["b"])
        let decoded = try JSONDecoder().decode(PluginManifest.self, from: JSONEncoder().encode(full))
        XCTAssertEqual(decoded, full)
    }

    // MARK: - KeyShortcut

    func testShortcutFormatsInCanonicalOrderAndRoundTrips() {
        let all = KeyShortcut("K", Set(KeyShortcut.Modifier.allCases))
        XCTAssertEqual(all.key, "k")
        XCTAssertEqual(all.description, "ctrl+opt+shift+cmd+k")
        XCTAssertEqual(KeyShortcut(parsing: all.description), all)
        XCTAssertEqual(KeyShortcut("o", [.command, .shift]).description, "shift+cmd+o")
        XCTAssertEqual(KeyShortcut("return").description, "return")
        for text in ["cmd+k", "shift+cmd+o", "ctrl+left", "opt+return", "cmd++", "+", "cmd+,"] {
            XCTAssertEqual(KeyShortcut(parsing: text)?.description, text, text)
        }
    }

    func testShortcutParsingAcceptsAliasesAndAnyCase() {
        let expected = KeyShortcut("k", [.command, .shift, .option, .control])
        XCTAssertEqual(KeyShortcut(parsing: "cmd+shift+opt+ctrl+k"), expected)
        XCTAssertEqual(KeyShortcut(parsing: "Command+Shift+Option+Control+K"), expected)
        XCTAssertEqual(KeyShortcut(parsing: "CTRL + alt + shift + cmd + k"), expected)
        XCTAssertEqual(KeyShortcut(parsing: "cmd++")?.key, "+")
        XCTAssertEqual(KeyShortcut(parsing: "cmd++")?.modifiers, [.command])
    }

    func testShortcutParsingRejectsInvalidInput() {
        for text in ["", "cmd+", "cmd+shift", "hyper+k", "+k", "cmd++k", "  "] {
            XCTAssertNil(KeyShortcut(parsing: text), text)
        }
    }

    func testShortcutIsCodableAsItsText() throws {
        struct Config: Codable, Equatable { var shortcut: KeyShortcut }
        let config = Config(shortcut: KeyShortcut("p", [.command, .shift]))
        let data = try JSONEncoder().encode(config)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"shortcut":"shift+cmd+p"}"#)
        XCTAssertEqual(try JSONDecoder().decode(Config.self, from: Data(#"{"shortcut":"CMD+Shift+P"}"#.utf8)), config)
        XCTAssertThrowsError(try JSONDecoder().decode(Config.self, from: Data(#"{"shortcut":"cmd+"}"#.utf8)))
    }

    func testCommandShortcutDefaultsToNil() {
        XCTAssertNil(Command(id: "t.a", title: "A", summary: "A") { _ in "" }.shortcut)
        let command = Command(id: "t.b", title: "B", summary: "B", shortcut: KeyShortcut(parsing: "cmd+b")) { _ in "" }
        XCTAssertEqual(command.shortcut, KeyShortcut("b", [.command]))
    }
}

/// Promises x and forgets to provide it.
private final class Forgetful: Plugin {
    static var manifest: PluginManifest {
        PluginManifest(id: "forgetful", name: "Forgetful", version: "1.0.0", provides: ["x"])
    }
    required init() {}
    func activate(context: PluginContext) throws {}
}
