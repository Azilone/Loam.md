import PluginKitTesting
import PluginKitUI
import PluginKitUITesting
import LoamCore
import XCTest

@MainActor
final class UIPluginTests: XCTestCase {
    func testAViewAPanelAndACommandAppearAndUnloadingRemovesAllThree() throws {
        let harness = try UIPluginHarness(uiPlugins: [SampleUIPlugin.self])
        defer { harness.close() }
        XCTAssertEqual(harness.report.activated, ["test.ui"])
        XCTAssertEqual(harness.views.viewTypes(for: .virtual("test:one")).map(\.id), ["test.view"])
        XCTAssertEqual(harness.views.viewTypes(for: .file("note.md")).map(\.id), [])
        XCTAssertEqual(harness.panels.panels(in: .trailing).map(\.id), ["test.panel"])
        XCTAssertNotNil(harness.kernel.commands.command(id: "test.hello"))

        let before = SampleUIPlugin.deactivations
        XCTAssertEqual(harness.host.deactivate("test.ui"), ["test.ui"])
        XCTAssertEqual(SampleUIPlugin.deactivations, before + 1)
        XCTAssertTrue(harness.views.all.isEmpty)
        XCTAssertTrue(harness.panels.all.isEmpty)
        XCTAssertNil(harness.kernel.commands.command(id: "test.hello"))
    }

    func testCommandsOfAUIPluginRun() async throws {
        let harness = try UIPluginHarness(uiPlugins: [SampleUIPlugin.self])
        defer { harness.close() }
        let output = try await harness.run("test.hello")
        XCTAssertEqual(output, "hello")
    }

    func testDeactivatingTheProviderRemovesTheDependentsView() throws {
        let harness = try UIPluginHarness(logicPlugins: [GreeterPlugin.self], uiPlugins: [GreetingViewPlugin.self])
        defer { harness.close() }
        XCTAssertEqual(harness.views.viewTypes(for: .virtual("greeting:")).map(\.id), ["test.greeting"])

        XCTAssertEqual(harness.host.deactivate("test.greeter-provider"), ["test.greeting-view", "test.greeter-provider"])
        XCTAssertTrue(harness.views.all.isEmpty)
    }

    func testWithoutTheHostServicesRegisteringAViewThrows() throws {
        let vault = try TemporaryVault()
        let host = PluginHost(kernel: Kernel(vault: vault))
        try host.register(SampleUIPlugin.self)
        XCTAssertThrowsError(try host.activateAll()) { error in
            XCTAssertEqual(error as? UIContractError, .registryMissing("ui.views"))
        }
        XCTAssertEqual(host.activeIDs, [])
    }

    func testWithoutAnEditorAddingASlashItemDoesNothing() throws {
        let harness = try UIPluginHarness(uiPlugins: [SampleUIPlugin.self])
        defer { harness.close() }
        XCTAssertEqual(harness.report.failed, [:])
        XCTAssertTrue(harness.host.isActive("test.ui"))
    }

    func testSlashItemsReachTheEditorAndLeaveOnUnload() throws {
        let editor = RecordingEditor()
        let harness = try UIPluginHarness(uiPlugins: [SampleUIPlugin.self], editor: editor)
        defer { harness.close() }
        XCTAssertEqual(editor.slashItems.map(\.id), ["test.slash"])

        let change = editor.slashItems[0].makeChange("a /st", NSRange(location: 2, length: 3))
        XCTAssertEqual(change.applied(to: "a /st"), "a stamp")
        XCTAssertEqual(change.selection, NSRange(location: 7, length: 0))

        harness.host.deactivate("test.ui")
        XCTAssertTrue(editor.slashItems.isEmpty)
    }

    func testCodeBlockViewsReachTheEditorAndLeaveOnUnload() throws {
        let editor = RecordingEditor()
        let harness = try UIPluginHarness(uiPlugins: [SampleUIPlugin.self], editor: editor)
        defer { harness.close() }
        XCTAssertEqual(editor.codeBlockViews.map(\.id), ["test.live"])
        XCTAssertEqual(editor.codeBlockViews.first?.languages, ["live"], "lowercased")
        harness.host.deactivate("test.ui")
        XCTAssertTrue(editor.codeBlockViews.isEmpty)
    }

    func testACodeBlockContextFollowsTheEditorAndSendsItsEdits() {
        var replaced: [String] = []
        var edits = 0
        let context = CodeBlockContext(
            notePath: "A.md", language: "base", code: "views: []",
            replaceCode: { replaced.append($0) }, editCode: { edits += 1 }
        )
        context.replaceCode("views: [table]")
        context.editCode()
        XCTAssertEqual(replaced, ["views: [table]"])
        XCTAssertEqual(edits, 1)
        XCTAssertEqual(context.code, "views: []", "the code changes when the editor says so")
        context.update(code: "views: [table]", isEditingCode: true)
        XCTAssertEqual(context.code, "views: [table]")
        XCTAssertTrue(context.isEditingCode)
    }

    func testPluginsReachTheWorkspace() throws {
        let harness = try UIPluginHarness(uiPlugins: [OpenerPlugin.self])
        defer { harness.close() }
        XCTAssertEqual(harness.workspace.opened.map(\.resource), [.virtual("test:welcome")])
        XCTAssertEqual(harness.workspace.opened.map(\.placement), [.beside])
        XCTAssertEqual(harness.workspace.activeResource, .virtual("test:welcome"))
    }

    func testCloseRemovesTheHostServices() throws {
        let harness = try UIPluginHarness(uiPlugins: [SampleUIPlugin.self])
        harness.close()
        XCTAssertEqual(harness.host.activeIDs, [])
        for id in ["ui.views", "ui.panels", "ui.workspace", "ui.quick-pick"] {
            XCTAssertFalse(harness.kernel.services.isProvided(id: id), id)
        }
    }

    func testRegisteredViewsAndPanelsRenderOffscreen() throws {
        let harness = try UIPluginHarness(uiPlugins: [SampleUIPlugin.self])
        defer { harness.close() }
        let type = try XCTUnwrap(harness.views.viewTypes(for: .virtual("test:one")).first)
        let view = harness.render(type.makeView(ViewContext(resource: .virtual("test:one"))))
        XCTAssertEqual(view.frame.size, CGSize(width: 400, height: 300))
        let panel = try XCTUnwrap(harness.panels.panels(in: .trailing).first)
        XCTAssertEqual(harness.render(panel.makeView(), size: CGSize(width: 200, height: 100)).frame.size.width, 200)
    }
}
