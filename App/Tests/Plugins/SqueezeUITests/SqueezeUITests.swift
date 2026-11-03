import AppKit
import AttachmentsPlugin
import NoteGraphPlugin
import PDFKit
import PluginKit
import PluginKitUI
import PluginKitUITesting
import SqueezePlugin
import XCTest
@testable import SqueezeUI

/// The PDF rasterizer on a real PDF, the toasts, the two palette commands on a fake compressor, and the whole path
/// of a PDF dropped into a note.
@MainActor
final class SqueezeUITests: XCTestCase {
    private var work: URL!

    override func setUp() async throws {
        work = FileManager.default.temporaryDirectory.appendingPathComponent("squeeze-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: work)
    }

    /// A two-page PDF with text and a smooth picture on each page, the picture stored losslessly (so it is big).
    private func samplePDF(pages: Int = 2) throws -> URL {
        let url = work.appendingPathComponent("sample.pdf")
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        let side = 1400
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side {
                let i = (y * side + x) * 4
                pixels[i] = UInt8((x * 255) / side)
                pixels[i + 1] = UInt8((y * 255) / side)
                pixels[i + 2] = UInt8(((x + y) * 255) / (2 * side))
                pixels[i + 3] = 255
            }
        }
        let image = try XCTUnwrap(CGContext(
            data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )?.makeImage())
        for number in 1...pages {
            context.beginPDFPage(nil)
            context.draw(image, in: CGRect(x: 40, y: 200, width: 500, height: 500))
            let graphics = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            NSAttributedString(string: "Page \(number) selectable text", attributes: [.font: NSFont.systemFont(ofSize: 24)])
                .draw(at: CGPoint(x: 40, y: 760))
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    // MARK: The rasterizer

    func testAPdfBecomesPictureOnlyPagesOfTheSameSizeAndMuchSmaller() async throws {
        let input = try samplePDF()
        let output = work.appendingPathComponent("out.pdf")
        let original = try XCTUnwrap(PDFDocument(url: input))
        XCTAssertTrue(original.string?.contains("selectable text") == true)

        try await PDFKitRasterizer().rasterize(input, to: output, dpi: 130, jpegQuality: 70)

        let result = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(result.pageCount, 2)
        XCTAssertEqual(result.page(at: 0)?.bounds(for: .mediaBox).size, CGSize(width: 595, height: 842))
        XCTAssertFalse(result.string?.contains("selectable text") == true, "the text is gone, as the setting says")
        let before = try MediaSize.of(input)
        let after = try MediaSize.of(output)
        XCTAssertLessThan(after, before / 3, "\(before) -> \(after)")
        XCTAssertGreaterThan(after, 5_000)
    }

    func testAnUnreadablePdfThrowsAndLeavesNothing() async throws {
        let input = work.appendingPathComponent("broken.pdf")
        try Data("not a pdf".utf8).write(to: input)
        let output = work.appendingPathComponent("out.pdf")
        do {
            try await PDFKitRasterizer().rasterize(input, to: output, dpi: 130, jpegQuality: 70)
            XCTFail("should throw")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
    }

    // MARK: Registration and toasts

    private func harness(_ logic: [Plugin.Type] = []) throws -> UIPluginHarness {
        let harness = try UIPluginHarness(logicPlugins: logic, uiPlugins: [SqueezeUIPlugin.self], files: ["Inbox/Note.md": "# Note\n"])
        XCTAssertTrue(harness.host.isActive("squeeze-ui"), "\(harness.report)")
        addTeardownBlock { @MainActor in harness.close() }
        return harness
    }

    func testItProvidesTheRasterizerAndTheTwoCommands() throws {
        let harness = try harness()
        XCTAssertNotNil(harness.kernel.services.service(.pdfRasterizer))
        XCTAssertEqual(Set(harness.kernel.commands.all.map(\.id)), ["squeeze.pick", "squeeze.optimize-all"])
        harness.host.deactivateAll()
        XCTAssertNil(harness.kernel.services.service(.pdfRasterizer))
        XCTAssertEqual(harness.kernel.commands.all.count, 0)
    }

    func testWhatTheCompressorDoesIsSaidInToasts() throws {
        let harness = try harness()
        harness.kernel.events.emit(MediaOptimized(path: "Attachments/shot.webp", before: 2_400_000, after: 180_000))
        harness.kernel.events.emit(MediaOptimizationStarted(path: "Attachments/clip.mov"))
        harness.kernel.events.emit(MediaBatchProgress(done: 2, total: 5, current: "a/movie.mov"))
        harness.kernel.events.emit(MediaBatchProgress(done: 5, total: 5, current: nil))
        harness.kernel.events.emit(MediaOptimizationFailed(path: "Attachments/a.png", message: "cwebp was not found.", tool: "cwebp"))
        harness.kernel.events.emit(MediaOptimizationFailed(path: "Attachments/b.mp4", message: "ffmpeg failed: oops"))
        let messages = harness.toasts.messages
        XCTAssertEqual(messages.count, 5, "the end of a batch is said by its command")
        XCTAssertTrue(messages[0].text.hasPrefix("Optimized shot.webp: "), messages[0].text)
        XCTAssertEqual(messages[0].kind, .success, "a file made smaller shows a green mark")
        XCTAssertEqual(messages[1], .init(text: "Optimizing clip.mov in the background", kind: .info))
        XCTAssertEqual(messages[2].text, "Optimizing media: 3 of 5, movie.mov")
        XCTAssertEqual(messages[3], .init(text: "cwebp was not found. The file was kept as it is.", isError: true))
        XCTAssertEqual(messages[4], .init(text: "Could not optimize b.mp4: ffmpeg failed: oops", isError: true))
    }

    // MARK: The commands

    private func fake(_ harness: UIPluginHarness) throws -> FakeCompressor {
        let fake = FakeCompressor()
        _ = try harness.kernel.services.provide(.mediaCompression, fake as MediaCompressionService)
        return fake
    }

    func testPickingAFileListsTheBiggestFirstAndOptimizesTheChosenOne() async throws {
        let harness = try harness()
        let fake = try fake(harness)
        fake.files = [
            MediaCandidate(path: "Attachments/small.png", kind: .image, size: 2_000),
            MediaCandidate(path: "Trips/big.mov", kind: .video, size: 90_000_000),
        ]
        _ = try await harness.run("squeeze.pick")
        XCTAssertEqual(harness.quickPick.query("").map(\.id), ["Trips/big.mov", "Attachments/small.png"])
        XCTAssertEqual(harness.quickPick.query("small").map(\.id), ["Attachments/small.png"])
        XCTAssertEqual(harness.quickPick.items?("").first?.symbol, "film")
        _ = harness.quickPick.query("")
        harness.quickPick.choose(id: "Trips/big.mov")
        for _ in 0..<100 where harness.toasts.messages.count < 2 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(fake.optimized, ["Trips/big.mov"])
        XCTAssertEqual(harness.toasts.messages.first?.text, "Optimizing big.mov…")
        XCTAssertEqual(harness.toasts.messages.last?.text, "Optimized big.mp4: 90 MB to 9 MB")
    }

    func testOptimizingEverythingAsksFirst() async throws {
        let harness = try harness()
        let fake = try fake(harness)
        fake.files = [MediaCandidate(path: "a.png", kind: .image, size: 1_000_000), MediaCandidate(path: "b.mp4", kind: .video, size: 3_000_000)]
        fake.report = MediaBatchReport(analysed: 2, optimized: 1, failed: 0, bytesSaved: 2_000_000)

        var asked: [String] = []
        SqueezeUIPlugin.confirm = { asked.append($0); return false }
        let declined = try await harness.run("squeeze.optimize-all")
        XCTAssertEqual(declined, "Cancelled.")
        XCTAssertEqual(fake.batches, 0)
        XCTAssertTrue(asked[0].hasPrefix("2 media files (4 MB) will be looked at"), asked[0])
        XCTAssertTrue(asked[0].contains(".trash"), "it says where the originals go: \(asked[0])")
        XCTAssertTrue(asked[0].contains("PDFs keep only their pictures"))

        fake.keepsOriginals = false
        _ = try await harness.run("squeeze.optimize-all")
        XCTAssertFalse(asked[1].contains(".trash"), "no trash promise when originals are not kept: \(asked[1])")

        SqueezeUIPlugin.confirm = { _ in true }
        let done = try await harness.run("squeeze.optimize-all")
        XCTAssertEqual(done, "Saved 2 MB across 1 of 2 files.")
        XCTAssertEqual(fake.batches, 1)
        fake.files = []
        let none = try await harness.run("squeeze.optimize-all")
        XCTAssertEqual(none, "No media to optimize.")
    }

    // MARK: The whole path

    func testADroppedPdfIsRasterizedByPDFKitAndItsLinkStays() async throws {
        let pdf = try samplePDF(pages: 3)
        let harness = try harness([NoteGraphPlugin.self, AttachmentsPlugin.self, SqueezePlugin.self])

        let attachments = try XCTUnwrap(harness.kernel.services.service(.attachments))
        let replaced = expectation(description: "replaced")
        _ = harness.kernel.events.on(AttachmentReplaced.self) { _ in replaced.fulfill() }
        let imported = try await attachments.importFile(AttachmentImport(name: "doc.pdf", contents: .file(pdf), notePath: "Inbox/Note.md"))
        XCTAssertEqual(imported.markdown, "![](Attachments/doc.pdf)")
        await fulfillment(of: [replaced], timeout: 60)

        let stored = try XCTUnwrap(PDFDocument(url: harness.vault.url("Attachments/doc.pdf")))
        XCTAssertEqual(stored.pageCount, 3)
        XCTAssertFalse(stored.string?.contains("selectable text") == true)
        XCTAssertLessThan(try MediaSize.of(harness.vault.url("Attachments/doc.pdf")), try MediaSize.of(pdf) / 3)
        XCTAssertTrue(harness.vault.exists(".trash/Attachments/doc.pdf"), "the original is in the trash")
        for _ in 0..<100 where !harness.toasts.messages.contains(where: { $0.text.hasPrefix("Optimized doc.pdf: ") }) {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(harness.toasts.messages.contains { $0.text.hasPrefix("Optimizing doc.pdf") })
        XCTAssertTrue(harness.toasts.messages.contains { $0.text.hasPrefix("Optimized doc.pdf: ") }, "\(harness.toasts.messages)")
    }
}

private enum MediaSize {
    static func of(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }
}

/// A compressor that records what it was asked, for the commands' tests.
private final class FakeCompressor: MediaCompressionService, @unchecked Sendable {
    var files: [MediaCandidate] = []
    var report = MediaBatchReport()
    var keepsOriginals = true
    private(set) var optimized: [String] = []
    private(set) var batches = 0

    func candidates() throws -> [MediaCandidate] { files }

    func optimize(_ path: String) async throws -> MediaOptimization {
        optimized.append(path)
        return MediaOptimization(outcome: .optimized, path: path.replacingOccurrences(of: ".mov", with: ".mp4"), before: 90_000_000, after: 9_000_000)
    }

    func optimizeVault() async -> MediaBatchReport {
        batches += 1
        return report
    }
}
