import BuiltinPlugins
import PluginKit
import PluginKitUI
import PluginKitUITesting
import XCTest
@testable import CanvasUI
@testable import FileViewersUI

@MainActor
final class FileViewersUITests: XCTestCase {
    private func harness(canvas: Bool = false) throws -> UIPluginHarness {
        try UIPluginHarness(
            logicPlugins: builtinPlugins.filter { $0.manifest.id == "canvas" },
            uiPlugins: canvas ? [FileViewersUIPlugin.self, CanvasUIPlugin.self] : [FileViewersUIPlugin.self],
            files: ["Note.md": "# Note\n"]
        )
    }

    private func first(_ harness: UIPluginHarness, _ path: String) -> String? {
        harness.views.viewTypes(for: .file(path)).first?.id
    }

    func testEachKindOpensWithItsViewer() throws {
        let harness = try harness()
        defer { harness.close() }
        XCTAssertTrue(harness.host.isActive("file-viewers-ui"), "\(harness.report)")
        for path in ["a.png", "b.HEIC", "c.webp", "d.svg", "e.jpg", "f.gif"] {
            XCTAssertEqual(first(harness, path), "files.image", path)
        }
        XCTAssertEqual(first(harness, "Docs/paper.pdf"), "files.pdf")
        for path in ["song.mp3", "voice.m4a", "clip.mp4", "movie.mov", "talk.webm"] {
            XCTAssertEqual(first(harness, path), "files.media", path)
        }
        for path in ["sheet.xlsx", "archive.zip", "model.usdz", "noextension"] {
            XCTAssertEqual(first(harness, path), "files.preview", path)
        }
    }

    func testNotesAndFoldersAreLeftAlone() throws {
        let harness = try harness()
        defer { harness.close() }
        XCTAssertTrue(harness.views.viewTypes(for: .file("Note.md")).isEmpty)
        XCTAssertTrue(harness.views.viewTypes(for: .folder("Attachments")).isEmpty)
        XCTAssertTrue(harness.views.viewTypes(for: .virtual("calendar:")).isEmpty)
    }

    func testAnotherPluginsViewerComesFirst() throws {
        let harness = try harness(canvas: true)
        defer { harness.close() }
        XCTAssertEqual(harness.views.viewTypes(for: .file("Board.canvas")).map(\.id), ["canvas.board", "files.preview"])
    }

    func testPictureHasQuickLookToo() throws {
        let harness = try harness()
        defer { harness.close() }
        XCTAssertEqual(harness.views.viewTypes(for: .file("a.png")).map(\.id), ["files.image", "files.preview"])
    }

    func testViewedFilesKeepTheirExtensionInTitles() throws {
        let harness = try harness(canvas: true)
        defer { harness.close() }
        XCTAssertEqual(harness.views.title(for: .file("Attachments/photo.heic")), "photo.heic")
        XCTAssertEqual(harness.views.title(for: .file("Attachments/photo.jpg")), "photo.jpg")
        XCTAssertEqual(harness.views.title(for: .file("Boards/Plan.canvas")), "Plan")
        XCTAssertEqual(harness.views.title(for: .file("Note.md")), "Note")
        XCTAssertEqual(harness.views.title(for: .folder("Boards")), "Boards")
    }

    func testUnloadsCleanly() throws {
        let harness = try harness()
        defer { harness.close() }
        harness.host.deactivateAll()
        XCTAssertTrue(harness.views.all.isEmpty)
    }

    func testLocationStaysInsideTheVault() {
        let root = URL(fileURLWithPath: "/tmp/vault")
        XCTAssertEqual(FileLocation(resource: .file("Attachments/a.png"), root: root)?.url.path, "/tmp/vault/Attachments/a.png")
        XCTAssertNil(FileLocation(resource: .file("../secret.pdf"), root: root))
        XCTAssertNil(FileLocation(resource: .file("A/../../secret.pdf"), root: root))
        XCTAssertNil(FileLocation(resource: .folder("A"), root: root))
    }

    func testClockAndSpeedLabels() {
        XCTAssertEqual(PlaybackModel.clock(0), "0:00")
        XCTAssertEqual(PlaybackModel.clock(75.9), "1:15")
        XCTAssertEqual(PlaybackModel.clock(3725), "1:02:05")
        XCTAssertEqual(PlaybackModel.clock(.nan), "0:00")
        XCTAssertEqual(PlaybackModel.label(for: 1), "1×")
        XCTAssertEqual(PlaybackModel.label(for: 1.25), "1.25×")
    }

    func testTheToolbarSaysWhatKindOfFileItIs() throws {
        let root = URL(fileURLWithPath: "/tmp/vault")
        let symbols = ["a.png": "photo", "b.PDF": "doc.richtext", "c.mp3": "waveform", "d.mp4": "play.rectangle", "e.zip": "doc"]
        for (path, symbol) in symbols {
            XCTAssertEqual(FileLocation(resource: .file(path), root: root)?.symbol, symbol, path)
        }
        let file = try XCTUnwrap(FileLocation(resource: .file("a.png"), root: root))
        XCTAssertTrue(file.summary("1600 × 900").hasSuffix("1600 × 900"))
    }

    /// A one-second mono WAV: silence, then a loud tone: the waveform follows.
    func testTheWaveformFollowsTheLoudness() async throws {
        let rate = 8000
        var samples = [Int16](repeating: 0, count: rate / 2)
        samples += (0..<rate / 2).map { Int16(16000 * sin(Double($0) * 0.3)) }
        var wav = Data()
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        wav.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + samples.count * 2))
        wav.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(rate)); put(UInt32(rate * 2)); put(UInt16(2)); put(UInt16(16))
        wav.append(contentsOf: Array("data".utf8)); put(UInt32(samples.count * 2))
        for sample in samples { put(sample) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("loam-\(UUID().uuidString).wav")
        try wav.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let bars = await Waveform.bars(of: url, count: 10)
        XCTAssertEqual(bars.count, 10)
        XCTAssertLessThan(bars[1], 0.1)
        XCTAssertGreaterThan(bars[8], 0.8)
    }
}
