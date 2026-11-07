import AppKit
import BuiltinPlugins
import ExcalidrawPlugin
import PluginKit
import PluginKitUI
import PluginKitUITesting
import XCTest
@testable import ExcalidrawUI

@MainActor
final class ExcalidrawUITests: XCTestCase {
    private let logicPlugins = builtinPlugins.filter { $0.manifest.id == "excalidraw" }

    private let drawing = """
    ---
    excalidraw-plugin: parsed
    ---

    # Excalidraw Data

    ## Text Elements
    Plan ^txt00001

    %%
    ## Drawing
    ```json
    {"type":"excalidraw","version":2,"elements":[{"id":"rect0001","type":"rectangle","x":0,"y":0,"width":200,"height":100,"angle":0,"strokeColor":"#1e1e1e","backgroundColor":"transparent","fillStyle":"solid","strokeWidth":2,"strokeStyle":"solid","roughness":1,"opacity":100,"groupIds":[],"frameId":null,"roundness":null,"seed":1,"version":1,"versionNonce":1,"isDeleted":false,"boundElements":null,"updated":1,"link":null,"locked":false},{"id":"txt00001","type":"text","x":20,"y":30,"width":60,"height":25,"angle":0,"strokeColor":"#1e1e1e","backgroundColor":"transparent","fillStyle":"solid","strokeWidth":2,"strokeStyle":"solid","roughness":1,"opacity":100,"groupIds":[],"frameId":null,"roundness":null,"seed":2,"version":1,"versionNonce":2,"isDeleted":false,"boundElements":null,"updated":1,"link":null,"locked":false,"text":"Plan","fontSize":20,"fontFamily":5,"textAlign":"left","verticalAlign":"top","containerId":null,"originalText":"Plan","autoResize":true,"lineHeight":1.25}],"appState":{"viewBackgroundColor":"#ffffff"},"files":{}}
    ```
    %%
    """

    private func harness() throws -> UIPluginHarness {
        try UIPluginHarness(logicPlugins: logicPlugins, uiPlugins: [ExcalidrawUIPlugin.self], files: [
            "Ideas/Plan.excalidraw.md": drawing, "Ideas/Note.md": "# Note\n", "Old.excalidraw": "{}",
        ])
    }

    func testOpensDrawingsAndUnloadsCleanly() async throws {
        let harness = try harness()
        defer { harness.close() }
        XCTAssertTrue(harness.host.isActive("excalidraw-ui"), "\(harness.report)")
        let drawing = Resource.file("Ideas/Plan.excalidraw.md")
        XCTAssertEqual(harness.views.viewTypes(for: drawing).first?.id, "excalidraw.drawing")
        XCTAssertTrue(harness.views.viewTypes(for: drawing).first?.prefers(drawing) ?? false)
        XCTAssertEqual(harness.views.viewTypes(for: .file("Old.excalidraw")).map(\.id), ["excalidraw.drawing"])
        XCTAssertFalse(harness.views.viewTypes(for: .file("Ideas/Note.md")).contains { $0.id == "excalidraw.drawing" })

        let path = try await harness.run("excalidraw.new-drawing", ["folder": "Ideas", "title": "Sketch"])
        XCTAssertEqual(path, "Ideas/Sketch.excalidraw.md")
        XCTAssertEqual(harness.workspace.opened.last?.resource, .file("Ideas/Sketch.excalidraw.md"))

        harness.host.deactivateAll()
        XCTAssertTrue(harness.views.all.isEmpty)
        XCTAssertNil(harness.kernel.commands.command(id: "excalidraw.new-drawing"))
    }

    func testAnOpenDrawingFollowsItsRename() throws {
        let harness = try harness()
        defer { harness.close() }
        let store = try XCTUnwrap(harness.kernel.services.service(ExcalidrawUIPlugin.storeKey))
        let editor = DrawingEditor(path: "Ideas/Plan.excalidraw.md", store: store)
        harness.kernel.events.emit(NotesMoved(moves: ["Ideas/Plan.excalidraw.md": "Ideas/Road map.excalidraw.md"]))
        XCTAssertEqual(editor.path, "Ideas/Road map.excalidraw.md", "its last save goes to the new name, not the old one")
    }

    func testLinksOpenNotesOfTheVault() throws {
        let harness = try harness()
        defer { harness.close() }
        let vault = harness.vault
        XCTAssertEqual(ExcalidrawStore.resolve("[[Note]]", from: "Ideas/Plan.excalidraw.md", vault: vault), "Ideas/Note.md")
        XCTAssertEqual(ExcalidrawStore.resolve("[[Note|the note]]", from: "Plan.excalidraw.md", vault: vault), "Ideas/Note.md")
        XCTAssertEqual(ExcalidrawStore.resolve("Ideas/Note.md#Top", from: "Plan.excalidraw.md", vault: vault), "Ideas/Note.md")
        XCTAssertNil(ExcalidrawStore.resolve("[[Missing]]", from: "Plan.excalidraw.md", vault: vault))
    }

    /// The real editor in a web view: it loads the drawing, gives it back, and draws its picture.
    func testTheEditorLoadsAndSavesTheDrawing() async throws {
        try XCTSkipIf(ExcalidrawBundle.root == nil, "built without the Excalidraw bundle")
        let harness = try harness()
        defer { harness.close() }
        let store = try XCTUnwrap(harness.kernel.services.service(ExcalidrawUIPlugin.storeKey))

        let editor = DrawingEditor(path: "Ideas/Plan.excalidraw.md", store: store)
        // In a window, as in a tab: WebKit draws, and React renders, only for a page on screen.
        let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 1000, height: 700),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor.webView
        window.orderBack(nil)
        defer { window.close() }
        var scene: [String: Any]?
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(100))
            if let text = try? await editor.webView.callAsyncJavaScript("return loam.flush()", contentWorld: .page) as? String {
                scene = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
                if (scene?["elements"] as? [Any])?.count == 2 { break }
            }
        }
        XCTAssertEqual((scene?["elements"] as? [[String: Any]])?.compactMap { $0["id"] as? String }.sorted(),
                       ["rect0001", "txt00001"])

        await editor.flush()
        let after = try harness.vault.read("Ideas/Plan.excalidraw.md")
        XCTAssertTrue(after.contains("Plan ^txt00001"), after)
        XCTAssertTrue(after.contains("\"rect0001\""))

        let picture = await store.previews.picture(of: "Ideas/Plan.excalidraw.md", dark: false)
        XCTAssertNotNil(picture)
        XCTAssertGreaterThan(picture?.size.width ?? 0, 100)
        // The preview's offscreen window is never ordered onto the screen, or Mission Control shows a white box and
        // AppKit thinks a window is still visible after the main window closes.
        window.close()
        XCTAssertFalse(NSApp.windows.contains { $0.isVisible && $0.frame.origin.x <= -5_000 })

        // A library added from the catalogue is merged into the shared one, kept in the vault's `.loam`.
        editor.addLibrary(#"""
        {"type":"excalidrawlib","version":2,"source":"https://libraries.excalidraw.com","libraryItems":[{"id":"box00001","status":"published","created":1,"name":"Box","elements":[{"id":"libRect01","type":"rectangle","x":0,"y":0,"width":40,"height":40,"angle":0,"strokeColor":"#1e1e1e","backgroundColor":"transparent","fillStyle":"solid","strokeWidth":2,"strokeStyle":"solid","roughness":1,"opacity":100,"groupIds":[],"frameId":null,"roundness":null,"seed":3,"version":1,"versionNonce":3,"isDeleted":false,"boundElements":null,"updated":1,"link":null,"locked":false}]}]}
        """#)
        var saved: String?
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(100))
            saved = try? String(contentsOf: store.libraryURL, encoding: .utf8)
            if saved != nil { break }
        }
        XCTAssertTrue(saved?.contains("box00001") ?? false, saved ?? "no library file")
        XCTAssertEqual(store.libraryText, saved)
    }

    func testTheCataloguesReturnAddressNamesTheLibrary() throws {
        let back = try XCTUnwrap(URL(string: "loam-excalidraw://app/index.html#addLibrary=https%3A%2F%2Flibraries.excalidraw.com%2Flibraries%2Fyouritjang%2Fsoftware-architecture.excalidrawlib&token=abc"))
        XCTAssertEqual(LibraryBrowser.libraryURL(in: back)?.absoluteString,
                       "https://libraries.excalidraw.com/libraries/youritjang/software-architecture.excalidrawlib")
        let elsewhere = try XCTUnwrap(URL(string: "loam-excalidraw://app/index.html#addLibrary=https%3A%2F%2Fevil.example%2Fx.excalidrawlib"))
        XCTAssertNil(LibraryBrowser.libraryURL(in: elsewhere), "only libraries from the catalogue")
        XCTAssertTrue(LibraryBrowser.isCatalogue(try XCTUnwrap(URL(string: "https://libraries.excalidraw.com/?theme=dark"))))
    }
}
