import AttachmentsPlugin
import AVFoundation
import ImageIO
import PluginKitUI
import PluginKitUITesting
import UniformTypeIdentifiers
import XCTest
@testable import AttachmentsUI

/// The plugin in the UI harness with a recording editor and the real attachments service: drops go into the vault,
/// and media files become embeds.
@MainActor
final class AttachmentsUITests: XCTestCase {
    private var outside: URL!

    override func setUp() async throws {
        outside = FileManager.default.temporaryDirectory.appendingPathComponent("attachments-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: outside)
    }

    private func harness(_ editor: RecordingEditor, service: Bool = true) throws -> UIPluginHarness {
        let harness = try UIPluginHarness(
            logicPlugins: service ? [AttachmentsPlugin.self] : [],
            uiPlugins: [AttachmentsUIPlugin.self],
            files: ["Inbox/Trip.md": "# Trip\n"],
            editor: editor
        )
        XCTAssertTrue(harness.host.isActive("attachments-ui"), "\(harness.report)")
        addTeardownBlock { @MainActor in harness.close() }
        return harness
    }

    // MARK: Registration

    func testWithAnEditorItTakesDropsAndShowsMedia() throws {
        let editor = RecordingEditor()
        let harness = try harness(editor)
        XCTAssertEqual(editor.fileDropHandlers.map(\.id), ["attachments.import"])
        XCTAssertEqual(editor.embedRenderers.map(\.id), ["attachments.image", "attachments.video", "attachments.audio", "attachments.pdf"])
        XCTAssertEqual(Set(editor.embedRenderers.flatMap(\.extensions)), Set(
            AttachmentsUIPlugin.images + AttachmentsUIPlugin.videos + AttachmentsUIPlugin.sounds + ["pdf"]
        ))
        harness.close()
        XCTAssertTrue(editor.fileDropHandlers.isEmpty)
        XCTAssertTrue(editor.embedRenderers.isEmpty)
    }

    func testWithoutTheServiceNotesStillShowTheirMediaButTakeNoFiles() throws {
        let editor = RecordingEditor()
        _ = try harness(editor, service: false)
        XCTAssertTrue(editor.fileDropHandlers.isEmpty)
        XCTAssertEqual(editor.embedRenderers.count, 4)
    }

    func testWithoutAnEditorItDoesNothing() throws {
        let harness = try UIPluginHarness(logicPlugins: [AttachmentsPlugin.self], uiPlugins: [AttachmentsUIPlugin.self])
        defer { harness.close() }
        XCTAssertTrue(harness.host.isActive("attachments-ui"), "\(harness.report)")
    }

    // MARK: Drops

    func testDroppedFilesAreCopiedIntoTheFolderAndLinkedOnePerLine() async throws {
        let editor = RecordingEditor()
        let harness = try harness(editor)
        let photo = outside.appendingPathComponent("beach photo.jpg")
        try Data("jpeg".utf8).write(to: photo)
        let report = outside.appendingPathComponent("report.zip")
        try Data("zip".utf8).write(to: report)
        let markdown = await editor.drop([.file(photo), .file(report), .file(outside)], on: "Inbox/Trip.md")
        XCTAssertEqual(markdown, "![](Attachments/beach%20photo.jpg)\n[report.zip](Attachments/report.zip)", "the folder is left out")
        XCTAssertEqual(try Data(contentsOf: harness.vault.url("Attachments/beach photo.jpg")), Data("jpeg".utf8))
        XCTAssertTrue(harness.vault.exists("Attachments/report.zip"))
    }

    func testAPastedPictureGetsANameFromTheMoment() async throws {
        let editor = RecordingEditor()
        let harness = try harness(editor)
        let attachments = try XCTUnwrap(harness.kernel.services.service(.attachments))
        let date = Date(timeIntervalSince1970: 1_792_492_325)
        let markdown = await AttachmentsUIPlugin.importDropped(
            DroppedFiles(items: [.data(Data([1, 2]), pathExtension: "png")], notePath: "Inbox/Trip.md"),
            into: attachments, vault: harness.vault.rootURL, now: date
        )
        let name = AttachmentNames.pasted(extension: "png", at: date)
        XCTAssertEqual(markdown, "![](Attachments/\(name.replacingOccurrences(of: " ", with: "%20")))")
        XCTAssertEqual(try Data(contentsOf: harness.vault.url("Attachments/" + name)), Data([1, 2]))
    }

    func testAFileAlreadyInTheVaultIsLinkedWhereItIs() async throws {
        let editor = RecordingEditor()
        let harness = try harness(editor)
        try harness.vault.writeData("Photos/old.png", Data([1]))
        let markdown = await editor.drop([.file(harness.vault.url("Photos/old.png"))], on: "Inbox/Trip.md")
        XCTAssertEqual(markdown, "![](Photos/old.png)")
        XCTAssertFalse(harness.vault.exists("Attachments/old.png"), "not copied again")
    }

    func testNothingImportedInsertsNothing() async throws {
        let editor = RecordingEditor()
        _ = try harness(editor)
        let missing = await editor.drop([.file(outside.appendingPathComponent("gone.png"))], on: "Inbox/Trip.md")
        XCTAssertNil(missing)
    }

    // MARK: Embeds

    private func request(_ url: URL) -> EmbedRequest {
        EmbedRequest(destination: url.lastPathComponent, alt: "", path: "Attachments/" + url.lastPathComponent, file: url, notePath: "N.md")
    }

    /// A picture of `frames` frames, `width` by `height` pixels at `dpi`.
    private func picture(_ name: String, type: UTType, width: Int, height: Int, dpi: Double = 72, frames: Int = 1) throws -> URL {
        let url = outside.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, frames, nil))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        for frame in 0..<frames {
            context.setFillColor(red: CGFloat(frame), green: 0.5, blue: 0.2, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let properties: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), properties as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    func testAStillPictureIsDrawnAtItsSizeInPoints() async throws {
        let url = try picture("shot.png", type: .png, width: 600, height: 300, dpi: 144)
        let rendered = await AttachmentsUIPlugin.picture(request(url))
        let embed = try XCTUnwrap(rendered)
        guard case .image(let image) = embed.content else { return XCTFail("not drawn") }
        XCTAssertEqual(image.width, 600)
        XCTAssertEqual(embed.size, CGSize(width: 300, height: 150), "a Retina screenshot at its size on screen")
        XCTAssertFalse(embed.isInteractive)
    }

    func testABigPhotoIsDecodedSmallerButKeepsItsSize() async throws {
        let url = try picture("big.jpg", type: .jpeg, width: 4000, height: 3000)
        let loaded = try XCTUnwrap(MediaLoader.picture(at: url, maxPixels: 1000))
        XCTAssertEqual(loaded.image.width, 1000)
        XCTAssertEqual(loaded.size, CGSize(width: 4000, height: 3000))
    }

    func testAnAnimatedGIFPlaysInAView() async throws {
        let url = try picture("anim.gif", type: .gif, width: 40, height: 20, frames: 3)
        let rendered = await AttachmentsUIPlugin.picture(request(url))
        let embed = try XCTUnwrap(rendered)
        guard case .view = embed.content else { return XCTFail("not a view") }
        XCTAssertEqual(embed.size, CGSize(width: 40, height: 20))
        XCTAssertFalse(embed.isInteractive, "a click puts the caret on its line")
    }

    func testAPDFShowsAsACardWithItsFirstPage() async throws {
        let url = outside.appendingPathComponent("Report.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 50, y: 50, width: 200, height: 200))
        context.endPDFPage()
        context.closePDF()
        let rendered = await AttachmentsUIPlugin.pdf(request(url))
        let embed = try XCTUnwrap(rendered)
        XCTAssertEqual(embed.size, PDFCard.size)
        XCTAssertTrue(embed.keepsHeight)
        XCTAssertFalse(embed.isInteractive, "a double click opens it")
        XCTAssertNotNil(MediaLoader.pdfThumbnail(at: url, maxSize: CGSize(width: 128, height: 108)))
    }

    func testASoundShowsAsAPlayerCard() async throws {
        let url = outside.appendingPathComponent("tone.caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000))
        buffer.frameLength = 8000
        try file.write(from: buffer)
        let rendered = await AttachmentsUIPlugin.sound(request(url))
        let embed = try XCTUnwrap(rendered)
        XCTAssertTrue(embed.keepsHeight)
        XCTAssertTrue(embed.isInteractive)
        XCTAssertEqual(embed.size.height, AudioCard.height)
        XCTAssertEqual(AudioCard.clock(65.4), "1:05")
    }

    func testFilesThatAreNotWhatTheirNameSaysStayLinks() async throws {
        for name in ["fake.png", "fake.mp4", "fake.mp3", "fake.pdf"] {
            let url = outside.appendingPathComponent(name)
            try Data("not really".utf8).write(to: url)
            let request = request(url)
            let embed: RenderedEmbed? = switch (name as NSString).pathExtension {
            case "png": await AttachmentsUIPlugin.picture(request)
            case "mp4": await AttachmentsUIPlugin.video(request)
            case "mp3": await AttachmentsUIPlugin.sound(request)
            default: await AttachmentsUIPlugin.pdf(request)
            }
            XCTAssertNil(embed, name)
        }
    }
}
