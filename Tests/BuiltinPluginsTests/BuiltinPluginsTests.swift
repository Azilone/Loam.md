import XCTest
import PluginKit
import LoamCore
@testable import BuiltinPlugins

final class BuiltinPluginsTests: XCTestCase {
    private func makeKernel() throws -> (Kernel, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("builtin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (Kernel(vault: Vault(rootURL: root)), root)
    }

    func testEveryBuiltinPluginActivatesTogetherWithoutConflicts() throws {
        let (kernel, root) = try makeKernel()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = PluginHost(kernel: kernel)
        for plugin in builtinPlugins { try host.register(plugin) }
        try host.activateAll()
        XCTAssertEqual(Set(host.activeIDs), Set(builtinPlugins.map { $0.manifest.id }))
    }

    func testEveryCommandHasATitleAndAnAgentFriendlySummary() throws {
        let (kernel, root) = try makeKernel()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = PluginHost(kernel: kernel)
        for plugin in builtinPlugins { try host.register(plugin) }
        try host.activateAll()
        XCTAssertFalse(kernel.commands.all.isEmpty)
        for command in kernel.commands.all {
            XCTAssertFalse(command.title.isEmpty, command.id)
            XCTAssertGreaterThan(command.summary.count, 20, "\(command.id) needs a summary an agent can act on")
            XCTAssertTrue(command.id.contains("."), "\(command.id) should look like area.action")
        }
    }

    func testUnloadingEverythingLeavesNothingBehind() throws {
        let (kernel, root) = try makeKernel()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = PluginHost(kernel: kernel)
        for plugin in builtinPlugins { try host.register(plugin) }
        try host.activateAll()
        host.deactivateAll()
        XCTAssertEqual(kernel.commands.all.count, 0)
        XCTAssertEqual(host.activeIDs, [])
    }

    /// Alone, or with only the plugins providing what it `requires`.
    func testEachPluginAlsoActivatesAlone() throws {
        for plugin in builtinPlugins {
            let (kernel, root) = try makeKernel()
            defer { try? FileManager.default.removeItem(at: root) }
            let host = PluginHost(kernel: kernel)
            let providers = Self.providers(of: plugin)
            for needed in providers + [plugin] { try host.register(needed) }
            try host.activateAll()
            XCTAssertEqual(Set(host.activeIDs), Set((providers + [plugin]).map { $0.manifest.id }))
        }
    }

    /// The plugins providing what `plugin` requires, and what they require in turn.
    private static func providers(of plugin: Plugin.Type) -> [Plugin.Type] {
        var needed = Set(plugin.manifest.requires)
        var found: [Plugin.Type] = []
        while let provider = builtinPlugins.first(where: { candidate in
            candidate != plugin && !found.contains { $0 == candidate }
                && !Set(candidate.manifest.provides).isDisjoint(with: needed)
        }) {
            found.append(provider)
            needed.formUnion(provider.manifest.requires)
        }
        return found
    }

    func testADisabledPluginLeavesNoCommandsThroughTheRuntime() throws {
        let (_, root) = try makeKernel()
        defer { try? FileManager.default.removeItem(at: root) }
        try Vault(rootURL: root).write(ConfigStore.path, #"{ "plugins": { "truffle-search": { "enabled": false } } }"#)
        let runtime = try Runtime(rootURL: root, plugins: builtinPlugins)
        defer { runtime.close() }
        let ids = runtime.kernel.commands.all.map(\.id)
        XCTAssertFalse(ids.contains { $0.hasPrefix("search.") }, "\(ids)")
        XCTAssertTrue(ids.contains("plugins.list"))
        XCTAssertEqual(runtime.lastReport.failed, [:])
        XCTAssertEqual(Set(runtime.host.activeIDs), Set(builtinPlugins.map { $0.manifest.id }).subtracting(["truffle-search"]))
    }

    func testDisablingNoteGraphThroughTheRuntimeListsWhatStops() async throws {
        let (_, root) = try makeKernel()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try Runtime(rootURL: root, plugins: builtinPlugins)
        defer { runtime.close() }
        let expected = runtime.host.dependents(of: "note-graph")
        let output = try await runtime.kernel.commands.command(id: "plugins.disable")!.handler(["id": "note-graph"])
        let result = try JSONSerialization.jsonObject(with: Data(output.utf8)) as! [String: Any]
        XCTAssertEqual(result["disabled"] as? String, "note-graph")
        XCTAssertEqual(result["alsoDeactivated"] as? [String], expected)
        XCTAssertFalse(runtime.host.isActive("note-graph"))
        for id in expected { XCTAssertFalse(runtime.host.isActive(id), id) }
    }

    /// The plugins whose commands or services write notes. Add a plugin here when it starts writing.
    private let writers: Set<String> = [
        "note-graph", "daily-notes", "habit-tracker", "obsidian-import", "files", "note-query", "tasks", "canvas", "git-sync",
        "collections", "trash", "attachments", "squeeze", "meetings", "excalidraw", "assistant", "projects", "notes-import",
    ]

    /// Built-in plugins declare what they do, with the vocabulary only (docs/PERMISSIONS.md), honestly: every
    /// plugin with a command saying it writes is in `writers`, and every writer declares `vault.write`.
    func testEveryBuiltinPluginDeclaresItsPermissions() throws {
        for plugin in builtinPlugins {
            let manifest = plugin.manifest
            XCTAssertFalse(manifest.permissions.isEmpty, "\(manifest.id) declares no permissions")
            for permission in manifest.declaredPermissions {
                guard case .known = permission else { return XCTFail("\(manifest.id): unknown \(permission.rawValue)") }
            }
            XCTAssertEqual(manifest.permissions.contains("vault.write"), writers.contains(manifest.id), manifest.id)
        }
        XCTAssertTrue(try XCTUnwrap(builtinPlugins.first { $0.manifest.id == "truffle-search" })
            .manifest.permissions.contains("local-service"))

        for plugin in builtinPlugins {
            let providers = Self.providers(of: plugin)
            let own = try commandIDs(providers + [plugin]).subtracting(try commandIDs(providers))
            let summaries = try commands(providers + [plugin])
            for id in own {
                let summary = try XCTUnwrap(summaries[id])
                if summary.range(of: "writes", options: .caseInsensitive) != nil {
                    XCTAssertTrue(writers.contains(plugin.manifest.id), "\(id) writes: add \(plugin.manifest.id) to writers")
                }
            }
        }
    }

    /// The commands the plugins register, id to summary, activated together.
    private func commands(_ plugins: [Plugin.Type]) throws -> [String: String] {
        let (kernel, root) = try makeKernel()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = PluginHost(kernel: kernel)
        for plugin in plugins { try host.register(plugin) }
        try host.activateAll()
        defer { host.deactivateAll() }
        return Dictionary(uniqueKeysWithValues: kernel.commands.all.map { ($0.id, $0.summary) })
    }

    private func commandIDs(_ plugins: [Plugin.Type]) throws -> Set<String> {
        Set(try commands(plugins).keys)
    }
}
