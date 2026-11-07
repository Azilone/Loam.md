import AppKit
import Foundation
import PluginKit
import LoamCore
import SwiftUI
import XCTest
@testable import NotebookApp

/// A built-in plugin next to the vault's own in the tests below.
private final class WriterPlugin: Plugin {
    static let manifest = PluginManifest(
        id: "test.writer", name: "Writer", version: "1.0", permissions: ["vault.read", "vault.write"]
    )
    required init() {}
    func activate(context: PluginContext) throws {}
}

/// Records the calls to the fake `plugins.build`, `plugins.install` and `plugins.remove` commands.
private final class CommandLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(String, [String: String])] = []

    func append(_ id: String, _ arguments: [String: String]) {
        lock.lock()
        defer { lock.unlock() }
        entries.append((id, arguments))
    }

    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries.map { id, arguments in
            id + arguments.keys.sorted().map { " \($0)=\(arguments[$0]!)" }.joined()
        }
    }
}

/// The plugin manager's vault section: permissions, consent before enabling, and the build, install and remove
/// commands (WP41) called by id. Fake commands stand in for them; the real ones are tested where they live.
@MainActor
final class PluginManagerVaultTests: ShellTestCase {
    private let log = CommandLog()

    override func setUp() async throws {
        try await super.setUp()
        try write(".loam/plugins/hello/plugin.json", """
        {"id": "hello", "name": "Hello", "version": "0.1.0", "library": "HelloPlugin",
         "permissions": ["vault.read", "network", "mind-reading"]}
        """)
    }

    private func makeSession(safeMode: Bool = false) throws -> ShellSession {
        let session = try ShellSession(
            rootURL: root,
            configuration: ShellConfiguration(logicPlugins: [WriterPlugin.self], uiPlugins: [], thirdPartyPlugins: true, pluginTrust: .everything),
            machineID: machineID,
            layoutSaveDelay: .seconds(60),
            safeMode: safeMode
        )
        addTeardownBlock { @MainActor in session.close() }
        return session
    }

    /// Replaces whatever the runtime registered under `id` (WP41's real command, once merged) with a fake.
    private func fake(_ session: ShellSession, _ id: String, reply: @escaping @Sendable ([String: String]) throws -> String) throws {
        let commands = session.runtime.kernel.commands
        commands.unregister(id: id)
        let log = log
        try commands.register(Command(id: id, title: id, summary: "Fake \(id) for the plugin manager tests.") { arguments in
            log.append(id, arguments)
            return try reply(arguments)
        }, owner: "test")
    }

    private func withoutVaultCommands(_ session: ShellSession) {
        for command in VaultCommand.allCases { session.runtime.kernel.commands.unregister(id: command.rawValue) }
    }

    private func model(_ session: ShellSession) async -> PluginManagerModel {
        let model = PluginManagerModel(session: session)
        await model.refresh()
        return model
    }

    // MARK: Sections and permissions

    func testBuiltinAndVaultPluginsAreListedApart() async throws {
        let model = await model(try makeSession())
        XCTAssertEqual(model.builtinRows.map(\.id), ["test.writer"])
        XCTAssertEqual(model.vaultRows.map(\.id), ["hello"])
        XCTAssertEqual(model.folderPath(of: "hello"), ".loam/plugins/hello")
        XCTAssertEqual(model.folderURL(of: "hello").path, root.appendingPathComponent(".loam/plugins/hello").path)
        XCTAssertEqual(model.permissions(of: "hello"), [.known(.network), .unknown("mind-reading"), .known(.vaultRead)])
        XCTAssertEqual(model.permissions(of: "test.writer"), [.known(.vaultWrite), .known(.vaultRead)])
    }

    func testALoadErrorIsShownWithWhatToDo() async throws {
        let model = await model(try makeSession())
        let row = try XCTUnwrap(model.vaultRows.first)
        guard case .notLoaded(let reason) = row.state else { return XCTFail("\(row.state)") }
        XCTAssertTrue(reason.hasPrefix("not built"), reason)
        XCTAssertEqual(row.state.label, "Not built yet. Build it to use it.")
        XCTAssertTrue(model.isNotBuilt(row))
        XCTAssertEqual(
            PluginManagerModel.describeLoadError("built for another version of the app (runtime a, this app runs b): rebuild"),
            "Built for another version of the app. Rebuild it."
        )
        XCTAssertEqual(
            PluginManagerModel.describeLoadError("the library changed after it was loaded; relaunch the app to use the new build"),
            "Rebuilt. Relaunch to load the new build."
        )
    }

    // MARK: Enabling asks first

    func testEnablingAVaultPluginShowsItsPermissionsBeforeAnythingChanges() async throws {
        let session = try makeSession()
        let model = await model(session)
        await model.setEnabled(true, id: "hello")
        let confirmation = try XCTUnwrap(model.enableConfirmation)
        XCTAssertEqual(confirmation.pluginName, "Hello")
        XCTAssertFalse(confirmation.justInstalled)
        XCTAssertEqual(confirmation.permissions.map(\.rawValue), ["network", "mind-reading", "vault.read"])
        XCTAssertEqual(confirmation.highRisk.map(\.rawValue), ["network", "mind-reading"])
        XCTAssertEqual(confirmation.permissions.map(\.summary), [
            "Talk to servers on the internet", "Unknown permission: mind-reading", "Read your notes",
        ])
        XCTAssertFalse(session.runtime.config.config.isExplicitlyEnabled("hello"), "nothing changes before consent")

        model.cancelEnable()
        XCTAssertNil(model.enableConfirmation)
        XCTAssertFalse(session.runtime.config.config.isExplicitlyEnabled("hello"))

        await model.setEnabled(true, id: "hello")
        await model.confirmEnable(try XCTUnwrap(model.enableConfirmation))
        XCTAssertNil(model.enableConfirmation)
        XCTAssertTrue(session.runtime.config.config.isExplicitlyEnabled("hello"))
        XCTAssertTrue(try XCTUnwrap(model.vaultRows.first).enabled)
        // Not built, so it did not start, and the model says so.
        XCTAssertTrue(model.notice?.contains("Hello did not start") == true, model.notice ?? "")
    }

    func testEnablingABuiltinPluginDoesNotAsk() async throws {
        let session = try makeSession()
        let model = await model(session)
        await model.setEnabled(false, id: "test.writer")
        await model.setEnabled(true, id: "test.writer")
        XCTAssertNil(model.enableConfirmation)
        XCTAssertTrue(session.runtime.host.isActive("test.writer"))
    }

    // MARK: Commands by id

    func testWithoutTheCommandsTheActionsAreDisabled() async throws {
        let session = try makeSession()
        withoutVaultCommands(session)
        let model = await model(session)
        for command in VaultCommand.allCases {
            XCTAssertFalse(model.isAvailable(command))
            XCTAssertEqual(model.unavailableHelp(command), "This version of the app has no \(command.rawValue) command.")
        }
        await model.rebuild("hello")
        model.installURL = "https://example.com/plugin.git"
        await model.install()
        XCTAssertNil(model.busy["hello"])
        XCTAssertNil(model.enableConfirmation)
        XCTAssertEqual(model.installURL, "https://example.com/plugin.git", "nothing ran")
    }

    func testRebuildRunsPluginsBuildAndShowsTheEndOfTheLogOnFailure() async throws {
        let session = try makeSession()
        let lines = (1...30).map { "line \($0)" }.joined(separator: "\n") + "\nerror: boom\n"
        try fake(session, "plugins.build") { arguments in
            #"{"id": "\#(arguments["id"]!)", "ok": false, "log": \#(try JSON.string(lines))}"#
        }
        let model = await model(session)
        XCTAssertTrue(model.isAvailable(.build))
        await model.rebuild("hello")
        XCTAssertEqual(log.calls, ["plugins.build id=hello"])
        let failure = try XCTUnwrap(model.buildFailures["hello"])
        XCTAssertTrue(failure.hasSuffix("line 30\nerror: boom"), failure)
        XCTAssertFalse(failure.contains("line 19\n"), "only the last lines")
        XCTAssertEqual(model.notice, "Hello could not be built.")
        XCTAssertNil(model.busy["hello"])
    }

    func testASuccessfulRebuildOfAnEnabledPluginNeedsNoRelaunchWhenItWasNotLoaded() async throws {
        try write(".loam/config.json", #"{"plugins": {"hello": {"enabled": true}}}"#)
        let session = try makeSession()
        try fake(session, "plugins.build") { arguments in #"{"id": "\#(arguments["id"]!)", "ok": true, "log": ""}"# }
        let model = await model(session)
        await model.rebuild("hello")
        XCTAssertEqual(log.calls, ["plugins.build id=hello"])
        XCTAssertNil(model.buildFailures["hello"])
        XCTAssertTrue(model.needsRelaunch.isEmpty, "its code was never loaded, so no relaunch")
    }

    func testInstallRunsPluginsInstallThenAsksToEnable() async throws {
        let session = try makeSession()
        let root = root!
        try fake(session, "plugins.install") { _ in
            let folder = root.appendingPathComponent(".loam/plugins/clock")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try #"{"id": "clock", "name": "Clock", "version": "1.2.0", "library": "Clock", "permissions": ["ui", "shell"]}"#
                .write(to: folder.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
            return #"{"id": "clock", "path": ".loam/plugins/clock", "permissions": ["ui", "shell"], "built": true}"#
        }
        let model = await model(session)
        model.installURL = "  https://example.com/clock.git "
        await model.install()
        XCTAssertEqual(log.calls, ["plugins.install url=https://example.com/clock.git"])
        XCTAssertEqual(model.installURL, "")
        XCTAssertEqual(model.vaultRows.map(\.id), ["clock", "hello"])
        let confirmation = try XCTUnwrap(model.enableConfirmation)
        XCTAssertTrue(confirmation.justInstalled)
        XCTAssertTrue(confirmation.canEnable)
        XCTAssertEqual(confirmation.pluginName, "Clock")
        XCTAssertEqual(confirmation.permissions, [.known(.shell), .known(.ui)])
        XCTAssertFalse(session.runtime.config.config.isExplicitlyEnabled("clock"), "installing never enables")
    }

    func testAnInstallThatDidNotBuildCannotBeEnabledYet() async throws {
        let session = try makeSession()
        try fake(session, "plugins.install") { _ in
            #"{"id": "hello", "path": ".loam/plugins/hello", "permissions": [], "built": false, "log": "error: no Package.swift"}"#
        }
        let model = await model(session)
        model.installURL = "https://example.com/hello.git"
        await model.install()
        let confirmation = try XCTUnwrap(model.enableConfirmation)
        XCTAssertFalse(confirmation.canEnable)
        XCTAssertEqual(confirmation.buildLog, "error: no Package.swift")
        await model.confirmEnable(confirmation)
        XCTAssertFalse(session.runtime.config.config.isExplicitlyEnabled("hello"))
    }

    func testRemoveAsksThenRunsPluginsRemove() async throws {
        let session = try makeSession()
        let root = root!
        try fake(session, "plugins.remove") { arguments in
            try FileManager.default.removeItem(at: root.appendingPathComponent(".loam/plugins/\(arguments["id"]!)"))
            return #"{"id": "\#(arguments["id"]!)", "trashedTo": "/tmp/Trash/hello"}"#
        }
        let model = await model(session)
        model.requestRemove("hello")
        let confirmation = try XCTUnwrap(model.removeConfirmation)
        XCTAssertEqual(confirmation.pluginName, "Hello")
        XCTAssertTrue(log.calls.isEmpty, "nothing runs before the confirmation")

        model.cancelRemove()
        XCTAssertNil(model.removeConfirmation)
        model.requestRemove("hello")
        await model.confirmRemove(try XCTUnwrap(model.removeConfirmation))
        XCTAssertEqual(log.calls, ["plugins.remove id=hello"])
        XCTAssertEqual(model.notice, "Hello was moved to the Trash.")
        XCTAssertTrue(model.vaultRows.isEmpty)
    }

    func testSafeModeSaysVaultPluginsAreOff() async throws {
        try write(".loam/config.json", #"{"plugins": {"hello": {"enabled": true}}}"#)
        let model = await model(try makeSession(safeMode: true))
        XCTAssertTrue(model.isSafeMode)
        guard case .skipped(let reason) = try XCTUnwrap(model.vaultRows.first).state else { return XCTFail("not skipped") }
        XCTAssertTrue(reason.contains("plugins from the vault are not loaded"), reason)
    }

    // MARK: Rendering

    /// The list with a vault plugin row, and its page with a failed build and every action, rendered offscreen. Set
    /// `LOAM_SNAPSHOT_DIR` to keep the image.
    func testThePluginsTabRendersAVaultPlugin() async throws {
        let session = try makeSession()
        try fake(session, "plugins.build") { _ in #"{"id": "hello", "ok": false, "log": "error: cannot find 'Foo' in scope"}"# }
        let model = await model(session)
        await model.rebuild("hello")
        let size = CGSize(width: 640, height: 1440)
        let hosting = NSHostingView(rootView: VStack(spacing: 0) {
            PluginList(model: model) { _ in }
            PluginPage(model: model, id: "hello", back: {}, open: { _ in })
        }
        .frame(width: size.width, height: size.height))
        hosting.frame = CGRect(origin: .zero, size: size)
        // A List is a table view: it fills its rows only in a window, after a turn of the run loop.
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        if let dir = ProcessInfo.processInfo.environment["LOAM_SNAPSHOT_DIR"] {
            try bitmap.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("plugins-tab.png"))
        }
    }
}
