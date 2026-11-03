import AppKit
import MarkdownEditor
import PluginKitUI
import PluginKitUITesting
import SwiftUI
import XCTest
@testable import MarkdownEditorUI

/// The `editor` service's file drops and embeds: plugins' handlers and renderers as the engine's, on vault files.
@MainActor
final class EditorEmbedsServiceTests: XCTestCase {
    private var harness: UIPluginHarness!
    private var service: MarkdownEditorService!

    override func setUp() async throws {
        harness = try UIPluginHarness(uiPlugins: [], files: [
            "Inbox/Note.md": "# Note\n",
            "assets/a b.png": "png",
            "assets/doc.pdf": "pdf",
        ])
        service = MarkdownEditorService(documents: DocumentStore(vault: harness.vault), workspace: { nil })
    }

    override func tearDown() async throws {
        harness.close()
    }

    private static let picture: CGImage = {
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }()

    func testImageLinksResolveFromTheNoteThenFromTheVaultsRoot() {
        let vault = harness.vault
        XCTAssertEqual(NoteLinks.embeddedFile("../assets/a%20b.png", from: "Inbox/Note.md", vault: vault), "assets/a b.png")
        XCTAssertEqual(NoteLinks.embeddedFile("assets/a b.png", from: "Inbox/Note.md", vault: vault), "assets/a b.png", "from the root")
        XCTAssertEqual(NoteLinks.embeddedFile("../assets/a%20b.png#page=2", from: "Inbox/Note.md", vault: vault), "assets/a b.png")
        XCTAssertNil(NoteLinks.embeddedFile("https://example.com/a.png", from: "Inbox/Note.md", vault: vault))
        XCTAssertNil(NoteLinks.embeddedFile("../assets/missing.png", from: "Inbox/Note.md", vault: vault))
        XCTAssertNil(NoteLinks.embeddedFile("../../../etc/hosts", from: "Inbox/Note.md", vault: vault))
        XCTAssertNil(NoteLinks.embeddedFile("", from: "Inbox/Note.md", vault: vault))
    }

    func testEmbedsComeFromTheRenderersOfTheFilesExtension() async throws {
        XCTAssertNil(service.embedProvider(for: "Inbox/Note.md"), "no renderer, no embeds")
        var requests: [EmbedRequest] = []
        let remove = service.addEmbedRenderer(EmbedRenderer(id: "test.png", extensions: ["PNG"]) { request in
            requests.append(request)
            return RenderedEmbed(image: Self.picture, size: CGSize(width: 40, height: 20))
        })
        let provider = try XCTUnwrap(service.embedProvider(for: "Inbox/Note.md"))
        let link = EmbedLink(destination: "../assets/a%20b.png", alt: "A caption")
        let key = try XCTUnwrap(provider.identify(link))
        XCTAssertTrue(key.hasPrefix("assets/a b.png|"), key)
        XCTAssertNil(provider.identify(EmbedLink(destination: "../assets/doc.pdf", alt: "")), "no renderer for PDFs")

        let rendered = await provider.render(link)
        let embed = try XCTUnwrap(rendered)
        guard case .image(let image) = embed.content else { return XCTFail("not a picture") }
        XCTAssertEqual(image.size, NSSize(width: 40, height: 20))
        XCTAssertEqual(embed.size, NSSize(width: 40, height: 20))
        XCTAssertEqual(requests, [EmbedRequest(
            destination: "../assets/a%20b.png", alt: "A caption", path: "assets/a b.png",
            file: harness.vault.rootURL.appendingPathComponent("assets/a b.png"), notePath: "Inbox/Note.md"
        )])

        // A file replaced on disk gets another key, so it is shown again.
        try Data("bigger png".utf8).write(to: harness.vault.rootURL.appendingPathComponent("assets/a b.png"))
        XCTAssertNotEqual(provider.identify(link), key)

        remove()
        XCTAssertNil(service.embedProvider(for: "Inbox/Note.md"))
    }

    func testAViewEmbedIsHostedAsIs() throws {
        let embed = MarkdownEditorService.embed(RenderedEmbed(size: CGSize(width: 10_000, height: 96), keepsHeight: true, isInteractive: true) {
            AnyView(Text("Player"))
        })
        XCTAssertTrue(embed.keepsHeight)
        XCTAssertTrue(embed.isInteractive)
        guard case .view(let make) = embed.content else { return XCTFail("not a view") }
        XCTAssertTrue(make() is NSHostingView<AnyView>)
    }

    func testDropHandlersAreAskedInTurnUntilOneAnswers() async throws {
        XCTAssertNil(service.fileDrop(for: "Inbox/Note.md"), "no handler: the editor takes no files")
        var asked: [String] = []
        _ = service.addFileDropHandler(FileDropHandler(id: "test.none") { drop in
            asked.append("none \(drop.notePath)")
            return nil
        })
        _ = service.addFileDropHandler(FileDropHandler(id: "test.link") { drop in
            asked.append("link \(drop.items)")
            return "![](../assets/x.png)"
        })
        let drop = try XCTUnwrap(service.fileDrop(for: "Inbox/Note.md"))
        let file = URL(fileURLWithPath: "/tmp/x.png")
        let markdown = await drop([.file(file), .data(Data([1]), pathExtension: "png")])
        XCTAssertEqual(markdown, "![](../assets/x.png)")
        XCTAssertEqual(asked, [
            "none Inbox/Note.md",
            "link \([DroppedFiles.Item.file(file), .data(Data([1]), pathExtension: "png")])",
        ])
    }
}
