import XCTest
@testable import LoamCore
import NoteGraphPlugin
import AttachmentsPlugin
import PluginKit
import PluginKitTesting
@testable import SqueezePlugin

/// The optimizer on tiny media made by ffmpeg (skipped where the tools are missing), the plugin's work on imports,
/// its commands, and its settings.
final class SqueezeTests: XCTestCase {
    private var work: URL!
    private let ffmpeg = ToolLocator().locate("ffmpeg")?.path ?? ""
    private let cwebp = ToolLocator().locate("cwebp")?.path ?? ""

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory.appendingPathComponent("squeeze-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: work)
    }

    // MARK: Helpers

    private func requireFFmpeg() throws {
        try XCTSkipIf(ffmpeg.isEmpty, "ffmpeg is not installed")
    }

    /// Makes a media file with ffmpeg's generators.
    private func make(_ name: String, _ arguments: [String]) throws -> URL {
        try requireFFmpeg()
        let url = work.appendingPathComponent(name)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-nostdin", "-y", "-v", "error"] + arguments + [url.path]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "ffmpeg could not make \(name)")
        return url
    }

    private func picture(_ name: String = "shot.png") throws -> URL {
        try make(name, ["-f", "lavfi", "-i", "testsrc2=size=960x540:rate=1", "-frames:v", "1"])
    }

    private func sound(_ name: String = "voice.wav") throws -> URL {
        try make(name, ["-f", "lavfi", "-i", "sine=frequency=440:duration=3"])
    }

    private func clip(_ name: String = "clip.mov") throws -> URL {
        try make(name, [
            "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=24:duration=2", "-c:v", "libx264", "-crf", "6",
            "-preset", "ultrafast", "-pix_fmt", "yuv420p",
        ])
    }

    private func size(_ url: URL) throws -> Int { try MediaOptimizer.size(of: url) }

    private func settings(_ change: (inout SqueezeSettings) -> Void = { _ in }) -> SqueezeSettings {
        var settings = SqueezeSettings()
        settings.minimumSizeKB = 0
        settings.ffmpegPath = ffmpeg
        settings.cwebpPath = cwebp
        change(&settings)
        return settings
    }

    private func optimizer(_ settings: SqueezeSettings? = nil, rasterizer: PDFRasterizing? = nil) -> MediaOptimizer {
        let settings = settings ?? self.settings()
        return MediaOptimizer(settings: settings, tools: MediaTools(ffmpeg: settings.ffmpegPath, cwebp: settings.cwebpPath), rasterizer: rasterizer)
    }

    private func store(_ settings: SqueezeSettings, in harness: PluginTestHarness) throws {
        let value = try JSONDecoder().decode(PropertyValue.self, from: JSONEncoder().encode(settings))
        try harness.kernel.settingsBackend.setSettings(value, for: "squeeze")
    }

    private func harness(_ settings: SqueezeSettings? = nil, files: [String: String] = [:]) throws -> PluginTestHarness {
        let harness = try PluginTestHarness([NoteGraphPlugin.self, AttachmentsPlugin.self, SqueezePlugin.self], files: files)
        try store(settings ?? self.settings(), in: harness)
        return harness
    }

    // MARK: The optimizer

    func testAPngBecomesASmallerWebp() async throws {
        let png = try picture()
        let result = try await optimizer().optimize(png, name: "shot.png", force: false, workFolder: work.appendingPathComponent("out"))
        XCTAssertEqual(result.name, "shot.webp")
        XCTAssertEqual(result.before, try size(png))
        XCTAssertLessThan(result.after, Int(Double(result.before) * 0.9))
        let head = try Data(contentsOf: result.url).prefix(12)
        XCTAssertEqual(String(decoding: head.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: head.suffix(4), as: UTF8.self), "WEBP")
    }

    func testAnImageWorksWithFFmpegAloneAndALyingNameIsLeftAlone() async throws {
        let png = try picture()
        var noCwebp = settings()
        noCwebp.cwebpPath = ""
        let tools = MediaTools(ffmpeg: ffmpeg, cwebp: "")
        do {
            let result = try await MediaOptimizer(settings: noCwebp, tools: tools, rasterizer: nil)
                .optimize(png, name: "shot.png", force: false, workFolder: work.appendingPathComponent("out"))
            XCTAssertEqual(result.name, "shot.webp")
        } catch let error as ToolFailed {
            throw XCTSkip("this ffmpeg has no WebP encoder: \(error.message)")
        }
    }

    func testAGifNamedPngIsLeftAlone() async throws {
        let gif = try make("anim.gif", ["-f", "lavfi", "-i", "testsrc2=size=64x64:rate=5:duration=1"])
        let renamed = work.appendingPathComponent("anim.png")
        try FileManager.default.moveItem(at: gif, to: renamed)
        await assertSkipped(.unsupported) {
            _ = try await self.optimizer().optimize(renamed, name: "anim.png", force: false, workFolder: self.work.appendingPathComponent("out"))
        }
    }

    func testAnAnimatedPngIsKeptNotFlattened() async throws {
        let apng = try make("anim.png", [
            "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=5:duration=2", "-f", "apng", "-plays", "0",
        ])
        XCTAssertTrue(try MediaOptimizer.pngChunks([UInt8](Data(contentsOf: apng))).contains("acTL"), "the fixture is animated")
        await assertSkipped(.unsupported) {
            _ = try await self.optimizer().optimize(apng, name: "anim.png", force: false, workFolder: self.work.appendingPathComponent("out"))
        }
    }

    func testAPictureKeepsItsColourProfile() async throws {
        try XCTSkipIf(cwebp.isEmpty || !FileManager.default.isExecutableFile(atPath: "/usr/bin/sips"), "needs cwebp and sips")
        let profile = "/System/Library/ColorSync/Profiles/Display P3.icc"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: profile), "no Display P3 profile on this system")
        let png = try picture()
        let tagged = work.appendingPathComponent("p3.png")
        _ = try await MediaTools.run("/usr/bin/sips", ["-m", profile, png.path, "--out", tagged.path])
        let result = try await optimizer().optimize(tagged, name: "p3.png", force: false, workFolder: work.appendingPathComponent("out"))
        let bytes = try Data(contentsOf: result.url)
        XCTAssertNotNil(bytes.range(of: Data("ICCP".utf8)), "the WebP carries the ICC chunk")
    }

    func testAProfileThatFFmpegWouldDropMakesTheFallbackSkip() throws {
        // A PNG with an iCCP chunk: signature, then a chunk named iCCP of 4 bytes.
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 4, 0x69, 0x43, 0x43, 0x50, 1, 2, 3, 4, 0, 0, 0, 0]
        let url = work.appendingPathComponent("tagged.png")
        try Data(png).write(to: url)
        XCTAssertTrue(try MediaOptimizer.mayCarryColourProfile(url, format: .png))
        let plain = work.appendingPathComponent("plain.png")
        try Data(Array(png[0..<8]) + [0, 0, 0, 0, 0x49, 0x44, 0x41, 0x54, 0, 0, 0, 0]).write(to: plain)
        XCTAssertFalse(try MediaOptimizer.mayCarryColourProfile(plain, format: .png))
    }

    func testTheLedgerRemembersWhatWasOptimizedAcrossRuns() throws {
        let harness = try PluginTestHarness([NoteGraphPlugin.self, AttachmentsPlugin.self])
        let file = work.appendingPathComponent("a.mp4")
        try Data(repeating: 7, count: 200_000).write(to: file)
        let ledger = OptimizedLedger(vault: harness.vault)
        XCTAssertFalse(ledger.contains(file))
        ledger.insert(file)
        XCTAssertTrue(ledger.contains(file))
        XCTAssertTrue(OptimizedLedger(vault: harness.vault).contains(file), "stored in the vault")
        let moved = work.appendingPathComponent("b.mp4")
        try FileManager.default.copyItem(at: file, to: moved)
        XCTAssertTrue(ledger.contains(moved), "known by content, not by path")
        try Data(repeating: 8, count: 200_000).write(to: moved)
        XCTAssertFalse(ledger.contains(moved), "an edited file is looked at again")
    }

    func testAVideoOptimizedOnceIsNotEncodedAgainByTheVaultCommand() async throws {
        let mov = try clip()
        let harness = try harness()
        try harness.vault.writeData("clip.mov", try Data(contentsOf: mov))
        let first = try JSONDecoder().decode(MediaBatchReport.self, from: Data(try await harness.run("squeeze.optimize-vault", ["confirm": "true"]).utf8))
        XCTAssertEqual(first.optimized, 1)
        let result = harness.vault.url("clip.mp4")
        XCTAssertTrue(OptimizedLedger(vault: harness.vault).contains(result))
        let second = try JSONDecoder().decode(MediaBatchReport.self, from: Data(try await harness.run("squeeze.optimize-vault", ["confirm": "true"]).utf8))
        XCTAssertEqual(second.optimized, 0)
    }

    func testNoStartedMessageForAVideoThatIsTooSmall() async throws {
        let mov = try clip()
        let harness = try harness(settings { $0.minimumSizeKB = 5000 })
        let started = Collected<MediaOptimizationStarted>()
        _ = harness.kernel.events.on(MediaOptimizationStarted.self) { started.add($0) }
        _ = try await XCTUnwrap(harness.kernel.services.service(.attachments))
            .importFile(AttachmentImport(name: "clip.mov", contents: .file(mov)))
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertTrue(started.values.isEmpty)
        XCTAssertTrue(harness.vault.exists("Attachments/clip.mov"))
    }

    func testGifsWebpsAndSmallFilesAreLeftAlone() async throws {
        let png = try picture()
        await assertSkipped(.unsupported) {
            _ = try await self.optimizer().optimize(png, name: "anim.gif", force: false, workFolder: self.work.appendingPathComponent("o"))
        }
        await assertSkipped(.unsupported) {
            _ = try await self.optimizer().optimize(png, name: "a.webp", force: false, workFolder: self.work.appendingPathComponent("o"))
        }
        await assertSkipped(.tooSmall) {
            _ = try await self.optimizer(self.settings { $0.minimumSizeKB = 5000 })
                .optimize(png, name: "shot.png", force: false, workFolder: self.work.appendingPathComponent("o"))
        }
        // Asked for by name, the minimum size does not apply.
        _ = try await optimizer(settings { $0.minimumSizeKB = 5000 })
            .optimize(png, name: "shot.png", force: true, workFolder: work.appendingPathComponent("o"))
        await assertSkipped(.off) {
            _ = try await self.optimizer(self.settings { $0.images = false })
                .optimize(png, name: "shot.png", force: false, workFolder: self.work.appendingPathComponent("o"))
        }
    }

    func testAJpegTurnedOnItsSideKeepsItsOrientation() throws {
        // APP1 Exif, big-endian TIFF, one entry: tag 0x0112 (orientation) = 6.
        let exif: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE1, 0x00, 0x22] + Array("Exif\0\0".utf8)
            + [0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08, 0x00, 0x01, 0x01, 0x12, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01, 0x00, 0x06, 0x00, 0x00]
        XCTAssertEqual(MediaOptimizer.exifOrientation(exif), 6)
        XCTAssertEqual(MediaOptimizer.exifOrientation([0xFF, 0xD8, 0xFF, 0xDA, 0x00, 0x02]), 1)
    }

    func testASoundBecomesMonoAacWithTheSameDuration() async throws {
        let wav = try sound()
        let result = try await optimizer().optimize(wav, name: "voice.wav", force: false, workFolder: work.appendingPathComponent("out"))
        XCTAssertEqual(result.name, "voice.m4a")
        XCTAssertLessThan(result.after, result.before / 4)
        let probe = try await MediaTools(ffmpeg: ffmpeg).probe(result.url)
        XCTAssertEqual(probe.duration, 3, accuracy: 0.1)
    }

    func testACompactMp3IsNotEncodedAgain() async throws {
        let mp3 = try make("voice.mp3", ["-f", "lavfi", "-i", "sine=frequency=440:duration=3", "-ac", "1", "-b:a", "48k"])
        await assertSkipped(.alreadyCompact) {
            _ = try await self.optimizer().optimize(mp3, name: "voice.mp3", force: false, workFolder: self.work.appendingPathComponent("out"))
        }
    }

    func testAVideoBecomesAnH264Mp4() async throws {
        let mov = try clip()
        let result = try await optimizer().optimize(mov, name: "clip.mov", force: false, workFolder: work.appendingPathComponent("out"))
        XCTAssertEqual(result.name, "clip.mp4")
        XCTAssertLessThan(result.after, Int(Double(result.before) * 0.9))
        let probe = try await MediaTools(ffmpeg: ffmpeg).probe(result.url)
        XCTAssertEqual(probe.duration, 2, accuracy: 0.2)
        XCTAssertEqual(probe.height, 360, "never scaled up")
    }

    func testATallVideoIsScaledDown() async throws {
        let big = try make("big.mp4", [
            "-f", "lavfi", "-i", "testsrc2=size=1920x1280:rate=12:duration=1", "-c:v", "libx264", "-crf", "6", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
        ])
        let result = try await optimizer(settings { $0.videoMaxHeight = 480 })
            .optimize(big, name: "big.mp4", force: false, workFolder: work.appendingPathComponent("out"))
        let probe = try await MediaTools(ffmpeg: ffmpeg).probe(result.url)
        XCTAssertEqual(probe.height, 480)
    }

    func testAPdfNeedsALargeGainAndTheRasterizer() async throws {
        let pdf = work.appendingPathComponent("doc.pdf")
        try Data(repeating: 0x41, count: 100_000).write(to: pdf)
        let folder = work.appendingPathComponent("out")
        await assertSkipped(.unsupported) { _ = try await self.optimizer().optimize(pdf, name: "doc.pdf", force: false, workFolder: folder) }

        let rasterizer = FakeRasterizer(outputSize: 80_000)
        await assertSkipped(.notWorthIt) {
            _ = try await self.optimizer(rasterizer: rasterizer).optimize(pdf, name: "doc.pdf", force: false, workFolder: folder)
        }
        rasterizer.outputSize = 60_000
        let result = try await optimizer(rasterizer: rasterizer).optimize(pdf, name: "doc.pdf", force: false, workFolder: folder)
        XCTAssertEqual(result, OptimizedFile(url: result.url, name: "doc.pdf", before: 100_000, after: 60_000))
        XCTAssertEqual(rasterizer.calls.last?.dpi, 130)
        XCTAssertEqual(rasterizer.calls.last?.quality, 70)
    }

    func testAMissingToolIsNamed() async throws {
        let png = try picture()
        let none = optimizer(settings { $0.ffmpegPath = "/nowhere/ffmpeg"; $0.cwebpPath = "/nowhere/cwebp" })
        do {
            _ = try await none.optimize(png, name: "shot.png", force: false, workFolder: work.appendingPathComponent("out"))
            XCTFail("should throw")
        } catch let error as ToolMissing {
            XCTAssertEqual(error.tool, "cwebp")
            XCTAssertTrue(error.errorDescription?.contains("brew install webp") == true)
        }
    }

    // MARK: On the way in

    func testADroppedPngIsWrittenAsWebpAndItsLinkFollows() async throws {
        let png = try picture()
        let harness = try harness(files: ["Inbox/Note.md": "# Note\n"])
        let attachments = try XCTUnwrap(harness.kernel.services.service(.attachments))
        let imported = try await attachments.importFile(AttachmentImport(name: "shot.png", contents: .file(png), notePath: "Inbox/Note.md"))
        XCTAssertEqual(imported.path, "Attachments/shot.webp")
        XCTAssertEqual(imported.markdown, "![](Attachments/shot.webp)")
        XCTAssertLessThan(try size(harness.vault.url("Attachments/shot.webp")), try size(png))
        XCTAssertTrue(FileManager.default.fileExists(atPath: png.path), "the file the user dropped is not touched")
    }

    func testAPastedPictureKeepsItsOriginalInTheTrash() async throws {
        let png = try picture()
        let original = try Data(contentsOf: png)
        let harness = try harness()
        let attachments = try XCTUnwrap(harness.kernel.services.service(.attachments))
        let imported = try await attachments.importFile(AttachmentImport(name: "Pasted image.png", contents: .data(original)))
        XCTAssertEqual(imported.path, "Attachments/Pasted image.webp")
        XCTAssertEqual(try Data(contentsOf: harness.vault.url(".trash/Pasted image.png")), original)

        try store(settings { $0.keepOriginals = false }, in: harness)
        _ = try await attachments.importFile(AttachmentImport(name: "Other.png", contents: .data(original)))
        XCTAssertFalse(harness.vault.exists(".trash/Other.png"))
    }

    func testASoundIsWrittenAsM4aAndOtherFilesGoInUntouched() async throws {
        let wav = try sound()
        let harness = try harness()
        let attachments = try XCTUnwrap(harness.kernel.services.service(.attachments))
        let sound = try await attachments.importFile(AttachmentImport(name: "voice.wav", contents: .file(wav)))
        XCTAssertEqual(sound.path, "Attachments/voice.m4a")
        let zip = try await attachments.importFile(AttachmentImport(name: "a.zip", contents: .data(Data("zip".utf8))))
        XCTAssertEqual(zip.path, "Attachments/a.zip")
        let gif = try await attachments.importFile(AttachmentImport(name: "a.gif", contents: .data(Data("GIF89a".utf8))))
        XCTAssertEqual(try Data(contentsOf: harness.vault.url(gif.path)), Data("GIF89a".utf8))
    }

    func testTurnedOffNothingIsChanged() async throws {
        let png = try picture()
        let harness = try harness(settings { $0.optimizeNewFiles = false })
        let attachments = try XCTUnwrap(harness.kernel.services.service(.attachments))
        let imported = try await attachments.importFile(AttachmentImport(name: "shot.png", contents: .file(png)))
        XCTAssertEqual(imported.path, "Attachments/shot.png")
        // Gone before each import, or the same picture would be linked where it is.
        try FileManager.default.removeItem(at: harness.vault.url(imported.path))
        try store(settings { $0.images = false }, in: harness)
        let second = try await attachments.importFile(AttachmentImport(name: "b.png", contents: .file(png)))
        XCTAssertEqual(second.path, "Attachments/b.png")
        try FileManager.default.removeItem(at: harness.vault.url(second.path))
        try store(settings { $0.excludedFolders = "Attachments" }, in: harness)
        let third = try await attachments.importFile(AttachmentImport(name: "c.png", contents: .file(png)))
        XCTAssertEqual(third.path, "Attachments/c.png")
    }

    func testAMissingToolKeepsTheFileAndIsSaidOnce() async throws {
        let png = try picture()
        let harness = try harness(settings { $0.ffmpegPath = "/nowhere/ffmpeg"; $0.cwebpPath = "/nowhere/cwebp" })
        let failures = Collected<MediaOptimizationFailed>()
        _ = harness.kernel.events.on(MediaOptimizationFailed.self) { failures.add($0) }
        let attachments = try XCTUnwrap(harness.kernel.services.service(.attachments))
        for name in ["a.png", "b.png"] {
            let imported = try await attachments.importFile(AttachmentImport(name: name, contents: .file(png)))
            XCTAssertEqual(imported.path, "Attachments/\(name)", "kept as it is")
            try FileManager.default.removeItem(at: harness.vault.url(imported.path))
        }
        // The settings point at nothing, but an empty path would be searched: only the explicit one is missing.
        XCTAssertEqual(failures.values.count, 1)
        XCTAssertEqual(failures.values.first?.tool, "cwebp")
    }

    func testSuccessIsAnnouncedOnTheMainThread() async throws {
        let png = try picture()
        let harness = try harness()
        let seen = expectation(description: "optimized")
        _ = harness.kernel.events.on(MediaOptimized.self) { event in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(event.path, "shot.webp")
            XCTAssertLessThan(event.after, event.before)
            seen.fulfill()
        }
        _ = try await XCTUnwrap(harness.kernel.services.service(.attachments))
            .importFile(AttachmentImport(name: "shot.png", contents: .file(png)))
        await fulfillment(of: [seen], timeout: 5)
    }

    // MARK: Later

    func testAnImportedVideoIsReplacedAfterwardsAndItsLinkFollows() async throws {
        let mov = try clip()
        let harness = try harness(files: ["Inbox/Note.md": "# Note\n"])
        let attachments = try XCTUnwrap(harness.kernel.services.service(.attachments))
        let replaced = expectation(description: "replaced")
        _ = harness.kernel.events.on(AttachmentReplaced.self) { _ in replaced.fulfill() }
        let imported = try await attachments.importFile(AttachmentImport(name: "clip.mov", contents: .file(mov), notePath: "Inbox/Note.md"))
        XCTAssertEqual(imported.path, "Attachments/clip.mov", "the video goes in as it is, then shrinks")
        try harness.vault.write("Inbox/Note.md", "# Note\n\n\(imported.markdown)\n")
        await fulfillment(of: [replaced], timeout: 60)
        XCTAssertTrue(harness.vault.exists("Attachments/clip.mp4"))
        XCTAssertFalse(harness.vault.exists("Attachments/clip.mov"))
        XCTAssertTrue(harness.vault.exists(".trash/Attachments/clip.mov"), "the original is recoverable")
        XCTAssertEqual(try harness.vault.read("Inbox/Note.md"), "# Note\n\n![](Attachments/clip.mp4)\n")
    }

    // MARK: Commands

    func testTheOptimizeCommandReplacesAFileAndRewritesLinks() async throws {
        let png = try picture()
        let harness = try harness(settings { $0.optimizeNewFiles = false }, files: ["Note.md": "![](Attachments/shot.png)\n"])
        try harness.vault.writeData("Attachments/shot.png", try Data(contentsOf: png))
        let output = try await harness.run("squeeze.optimize", ["path": "Attachments/shot.png"])
        let result = try JSONDecoder().decode(MediaOptimization.self, from: Data(output.utf8))
        XCTAssertEqual(result.outcome, .optimized)
        XCTAssertEqual(result.path, "Attachments/shot.webp")
        XCTAssertGreaterThan(result.saved, 0)
        XCTAssertEqual(try harness.vault.read("Note.md"), "![](Attachments/shot.webp)\n")
        XCTAssertTrue(harness.vault.exists(".trash/Attachments/shot.png"))

        let again = try JSONDecoder().decode(MediaOptimization.self, from: Data(try await harness.run("squeeze.optimize", ["path": "Attachments/shot.webp"]).utf8))
        XCTAssertEqual(again.outcome, .skipped, "a WebP is left as it is")
        do {
            _ = try await harness.run("squeeze.optimize", ["path": "nope.png"])
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? VaultError, VaultError.notFound(path: "nope.png"))
        }
    }

    func testTheOriginalCanBeDroppedInsteadOfKept() async throws {
        let png = try picture()
        let harness = try harness(settings { $0.keepOriginals = false })
        try harness.vault.writeData("shot.png", try Data(contentsOf: png))
        _ = try await harness.run("squeeze.optimize", ["path": "shot.png"])
        XCTAssertTrue(harness.vault.exists("shot.webp"))
        XCTAssertFalse(harness.vault.exists(".trash/shot.png"))
    }

    func testTheVaultCommandAsksForConfirmationAndReportsWhatItSaved() async throws {
        let png = try picture()
        let wav = try sound()
        let harness = try harness(files: ["Note.md": "![](a/shot.png) ![](Skip/shot.png)"])
        for path in ["a/shot.png", "Skip/shot.png"] { try harness.vault.writeData(path, try Data(contentsOf: png)) }
        try harness.vault.writeData("voice.wav", try Data(contentsOf: wav))
        try harness.vault.writeData("notes.txt", Data("not media".utf8))
        try store(settings { $0.excludedFolders = "Skip" }, in: harness)

        let preview = try await harness.run("squeeze.optimize-vault")
        XCTAssertTrue(preview.contains("\"files\" : 2"), preview)
        XCTAssertTrue(harness.vault.exists("a/shot.png"), "nothing happens without confirm")

        let progress = Collected<MediaBatchProgress>()
        _ = harness.kernel.events.on(MediaBatchProgress.self) { progress.add($0) }
        let output = try await harness.run("squeeze.optimize-vault", ["confirm": "true"])
        let report = try JSONDecoder().decode(MediaBatchReport.self, from: Data(output.utf8))
        XCTAssertEqual(report.analysed, 2)
        XCTAssertEqual(report.optimized, 2)
        XCTAssertEqual(report.failed, 0)
        XCTAssertGreaterThan(report.bytesSaved, 0)
        XCTAssertTrue(harness.vault.exists("a/shot.webp"))
        XCTAssertTrue(harness.vault.exists("Skip/shot.png"), "excluded")
        XCTAssertTrue(harness.vault.exists("voice.m4a"))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(progress.values.map(\.done), [0, 1, 2])
        XCTAssertEqual(progress.values.last?.total, 2)
    }

    // MARK: Settings and unloading

    func testTheDefaultsAreStoredWithTheToolsFound() throws {
        let harness = try PluginTestHarness([NoteGraphPlugin.self, AttachmentsPlugin.self, SqueezePlugin.self])
        let stored = try XCTUnwrap(harness.kernel.settingsBackend.settings(for: "squeeze"))
        guard case .map(let map) = stored else { return XCTFail("not a map: \(stored)") }
        XCTAssertEqual(map["optimizeNewFiles"], .bool(true))
        XCTAssertEqual(map["imageQuality"], .number(80))
        XCTAssertEqual(map["audioBitrate"], .number(64))
        XCTAssertEqual(map["videoCRF"], .number(28))
        XCTAssertEqual(map["keepOriginals"], .bool(true))
        XCTAssertEqual(map["ffmpegPath"], .string(ffmpeg))
        XCTAssertEqual(map["cwebpPath"], .string(cwebp))
        XCTAssertNotNil(map["pdfs"])
        let pdfs = try XCTUnwrap(SqueezePlugin.settingDescriptions.first { $0.key == "pdfs" })
        XCTAssertTrue(pdfs.help.contains("selectable text"), "the cost is in the setting's help")
    }

    func testExcludedFoldersAndNumbersAreRead() {
        var settings = SqueezeSettings()
        settings.excludedFolders = " ARCHIVES, Media/Raw ,,../x\n/Slides"
        XCTAssertEqual(settings.excluded, ["ARCHIVES", "Media/Raw", "Slides"])
        XCTAssertTrue(settings.isExcluded("Media/Raw/a.png"))
        XCTAssertTrue(settings.isExcluded("ARCHIVES"))
        XCTAssertFalse(settings.isExcluded("ARCHIVES2/a.png"))
        settings.imageQuality = 250
        settings.videoCRF = 27.6
        XCTAssertEqual(settings.webpQuality, 100)
        XCTAssertEqual(settings.crf, 28)
    }

    func testUnloadingRemovesTheServiceCommandsAndProcessor() async throws {
        let harness = try PluginTestHarness([NoteGraphPlugin.self, AttachmentsPlugin.self, SqueezePlugin.self])
        XCTAssertEqual(harness.kernel.commands.all.map(\.id).filter { $0.hasPrefix("squeeze.") }.sorted(), ["squeeze.optimize", "squeeze.optimize-vault"])
        XCTAssertNotNil(harness.kernel.services.service(.mediaCompression))
        harness.host.deactivateAll()
        XCTAssertNil(harness.kernel.services.service(.mediaCompression))
        XCTAssertEqual(harness.kernel.commands.all.count, 0)
    }

    // MARK: Test support

    private func assertSkipped(_ expected: Skip, _ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await body()
            XCTFail("should have been skipped", file: file, line: line)
        } catch let skip as Skip {
            XCTAssertEqual(skip, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }
}

/// Stands in for the PDF drawing, which lives in the app: writes a file of a chosen size.
private final class FakeRasterizer: PDFRasterizing, @unchecked Sendable {
    var outputSize: Int
    var calls: [(dpi: Int, quality: Int)] = []

    init(outputSize: Int) {
        self.outputSize = outputSize
    }

    func rasterize(_ input: URL, to output: URL, dpi: Int, jpegQuality: Int) async throws {
        calls.append((dpi, jpegQuality))
        try Data(repeating: 0x42, count: outputSize).write(to: output)
    }
}

private final class Collected<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Value] = []

    func add(_ value: Value) {
        lock.lock()
        items.append(value)
        lock.unlock()
    }

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}
