import AppKit
import Foundation
import PluginKitUI
import SwiftUI
import XCTest
@testable import NotebookApp

/// Stands in for real plugins in the shell tests: a view type for `test:` pages, a leading panel and a command.
final class ShellTestPlugin: UIPlugin {
    static let manifest = PluginManifest(id: "test.shell", name: "Shell test", version: "1.0")

    init() {}

    @MainActor func activateUI(context: PluginContext) throws {
        try context.registerView(ViewType(
            id: "test.page",
            title: "Test page",
            canOpen: { $0.kind == .virtual && $0.path.hasPrefix("test:") },
            makeView: { context in AnyView(Text(context.resource.name)) }
        ))
        try context.registerPanel(Panel(id: "test.panel", title: "Test", symbol: "star", slot: .leading) {
            AnyView(Text("Panel"))
        })
        try context.registerCommand(Command(
            id: "test.hello",
            title: "Hello",
            summary: "Says hello, to check that commands reach the command center."
        ) { _ in "hello" })
    }
}

/// A temporary vault folder, removed by `tearDown`.
@MainActor
class ShellTestCase: XCTestCase {
    var root: URL!
    let machineID = "test-machine"
    private var sessions: [ShellSession] = []

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("NotebookAppTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for session in sessions { session.close() }
        sessions = []
        try? FileManager.default.removeItem(at: root)
    }

    func write(_ path: String, _ text: String, modified: Date? = nil) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
    }

    func read(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// A session on the temporary vault, closed by `tearDown` unless the test closes it first.
    func openSession(
        logic: [Plugin.Type] = [],
        ui: [Plugin.Type] = [ShellTestPlugin.self],
        saveDelay: Duration = .seconds(60)
    ) throws -> ShellSession {
        let session = try ShellSession(
            rootURL: root,
            configuration: ShellConfiguration(logicPlugins: logic, uiPlugins: ui),
            machineID: machineID,
            layoutSaveDelay: saveDelay
        )
        sessions.append(session)
        return session
    }

    /// Waits until `condition` holds, polling, so tests on debounced work do not sleep longer than needed.
    func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            guard clock.now < deadline else { return XCTFail("timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
