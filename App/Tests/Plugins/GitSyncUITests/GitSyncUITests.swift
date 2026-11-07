import GitSyncPlugin
import PluginKit
import PluginKitUI
import PluginKitUITesting
import SwiftUI
import XCTest
@testable import GitSyncUI

/// A sync that does nothing, whose status the test sets.
final class StubSync: GitSyncService, @unchecked Sendable {
    var status = SyncStatus.off
    var handlers: [UUID: @Sendable (SyncStatus) -> Void] = [:]
    var foreground: [Bool] = []
    var requests = 0
    var bridge: SyncEditorBridge?

    func observe(_ handler: @escaping @Sendable (SyncStatus) -> Void) -> () -> Void {
        let id = UUID()
        handlers[id] = handler
        return { [weak self] in self?.handlers[id] = nil }
    }

    func syncNow() async -> SyncStatus { status }
    func requestSync() { requests += 1 }
    func setForeground(_ isForeground: Bool) { foreground.append(isForeground) }
    func setEditorBridge(_ bridge: SyncEditorBridge?) { self.bridge = bridge }

    var account: String?
    var setUpEncrypt: [Bool] = []
    func gitHubAccount() async -> String? { account }
    func setUpWithGitHub(encrypt: Bool) async throws -> SyncStatus {
        setUpEncrypt.append(encrypt)
        status.remoteURL = "https://github.com/me/loam-vault.git"
        return status
    }

    func send(_ status: SyncStatus) {
        self.status = status
        for handler in handlers.values { handler(status) }
    }
}

/// Provides the stub as the `git-sync` service, as the logic plugin would.
final class StubSyncPlugin: Plugin {
    static let manifest = PluginManifest(id: "git-sync", name: "Stub sync", version: "1", provides: ["git-sync"])
    nonisolated(unsafe) static var current = StubSync()
    init() {}

    func activate(context: PluginContext) throws {
        try context.provide(.gitSync, Self.current as GitSyncService)
    }
}

@MainActor
final class GitSyncUITests: XCTestCase {
    private var harness: UIPluginHarness!
    private var stub: StubSync!
    private var editor: RecordingEditor!

    override func setUp() async throws {
        stub = StubSync()
        StubSyncPlugin.current = stub
        editor = RecordingEditor()
        harness = try UIPluginHarness(logicPlugins: [StubSyncPlugin.self], uiPlugins: [GitSyncUIPlugin.self],
                                      files: ["Note.md": "saved\n"], editor: editor)
        XCTAssertEqual(harness.report.failed.count, 0, "\(harness.report)")
    }

    override func tearDown() async throws {
        harness.close()
    }

    private var statusPanels: [Panel] { harness.panels.panels(in: .statusBar) }

    func testTheItemAlwaysShowsSoSyncCanBeFound() throws {
        XCTAssertEqual(statusPanels.map(\.id), [GitSyncUIPlugin.panelID], "Sync off leads to setting it up")
        XCTAssertEqual(stub.foreground.count, 1, "activation tells the sync whether the app is in front")
        XCTAssertNotNil(stub.bridge)

        stub.send(SyncStatus(state: .synced))
        XCTAssertEqual(statusPanels.map(\.id), [GitSyncUIPlugin.panelID])
        let view = harness.render(statusPanels[0].makeView(), size: CGSize(width: 200, height: 22))
        XCTAssertGreaterThan(view.fittingSize.width, 0)

        stub.send(SyncStatus(state: .off))
        XCTAssertEqual(statusPanels.count, 1)
    }

    func testTheSettingsPageHasTheSyncSection() throws {
        let sections = harness.settingsSections.sections(for: GitSyncUIPlugin.settingsPageID)
        XCTAssertEqual(sections.map(\.id), ["git-sync.setup"])
        let view = harness.render(sections[0].makeView(), size: CGSize(width: 560, height: 500))
        XCTAssertGreaterThan(view.fittingSize.height, 0)
    }

    func testAnAddressIsNeededToSetUp() {
        XCTAssertTrue(SyncSettingsModel.looksLikeAddress("https://github.com/me/notes.git"))
        XCTAssertTrue(SyncSettingsModel.looksLikeAddress(" git@github.com:me/notes.git "))
        XCTAssertFalse(SyncSettingsModel.looksLikeAddress("notes"))
        XCTAssertFalse(SyncSettingsModel.looksLikeAddress(""))
    }

    func testTheWizardSetsUpWithGitHubInThreeScreens() async throws {
        stub.account = "me"
        let model = SyncSettingsModel(service: stub, root: URL(fileURLWithPath: "/tmp/vault"))
        model.refresh()
        for _ in 0..<100 where model.account == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.step, .idle)
        model.connectGitHub()
        XCTAssertEqual(model.step, .protect, "signed in already: straight to the encryption choice")
        XCTAssertTrue(model.encrypt)
        model.encrypt = false
        model.startSyncing()
        for _ in 0..<100 where model.step != .done { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.step, .done)
        XCTAssertEqual(stub.setUpEncrypt, [false])
        model.go(.idle)
        for _ in 0..<100 where !model.isSetUp { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(model.isSetUp)
    }

    func testUnloadingRemovesTheItemAndTheBridge() {
        stub.send(SyncStatus(state: .offline))
        XCTAssertEqual(statusPanels.count, 1)
        harness.host.deactivateAll()
        XCTAssertEqual(statusPanels.count, 0)
        XCTAssertNil(stub.bridge)
        XCTAssertTrue(stub.handlers.isEmpty)
    }

    func testSymbolsAndMenu() throws {
        let model = try XCTUnwrap(harness.kernel.services.service(GitSyncUIPlugin.modelKey))
        stub.send(SyncStatus(state: .synced, conflicts: ["Ideas/Plan (conflict A 2026-10-20).md"]))
        XCTAssertEqual(model.symbol, "doc.on.doc")
        XCTAssertEqual(model.status.label, "1 conflict")
        model.showMenu()
        let items = harness.quickPick.query("")
        XCTAssertEqual(items.map(\.title), ["Sync now", "Open Plan (conflict A 2026-10-20).md", "Sync settings…"])
        XCTAssertTrue(harness.quickPick.choose(id: items[1].id))
        XCTAssertEqual(harness.workspace.opened.last?.resource, .file("Ideas/Plan (conflict A 2026-10-20).md"))
        model.showMenu()
        XCTAssertTrue(harness.quickPick.choose(id: "sync"))
        XCTAssertEqual(stub.requests, 1)

        stub.send(SyncStatus(state: .offline))
        XCTAssertEqual(model.symbol, "wifi.slash")
        stub.send(SyncStatus(state: .attention, message: "The remote refused the credentials."))
        XCTAssertTrue(model.details.contains("refused"))
    }

    func testTheBridgeSeesTypingAndUnsavedText() throws {
        let bridge = try XCTUnwrap(stub.bridge as? EditorSyncBridge)
        XCTAssertEqual(bridge.busyPaths(["Note.md"], quiet: 5), [], "not open")
        editor.texts["Note.md"] = "saved\n"
        XCTAssertEqual(bridge.busyPaths(["Note.md"], quiet: 5), [], "open, same as disk, not typed in")
        bridge.typed("Note.md")
        XCTAssertEqual(bridge.busyPaths(["Note.md"], quiet: 5), ["Note.md"], "typed in just now")
        bridge.typed("Note.md", at: Date().addingTimeInterval(-60))
        editor.texts["Note.md"] = "unsaved typing\n"
        XCTAssertEqual(bridge.busyPaths(["Note.md"], quiet: 5), ["Note.md"], "holds unsaved text")
        XCTAssertEqual(bridge.reload(["Note.md"]), ["Note.md"], "the editor kept text that differs from the merge")
        editor.texts["Note.md"] = "saved\n"
        XCTAssertEqual(bridge.reload(["Note.md"]), [])
    }

    func testTheMenuSaysWhichAgentChangedWhat() throws {
        let model = try XCTUnwrap(harness.kernel.services.service(GitSyncUIPlugin.modelKey))
        var status = SyncStatus(state: .synced)
        status.incoming = [SyncStatus.DeviceChanges(device: "agent-research", files: ["Plan.md", "Ideas/New.md"])]
        stub.send(status)
        stub.send(SyncStatus(state: .synced))
        XCTAssertEqual(model.recent.map(\.summary), ["agent-research changed 2 notes"], "kept after a quiet sync")
        XCTAssertTrue(model.details.contains("agent-research changed 2 notes"))
    }
}
