import XCTest
@testable import LoamCore
import NoteGraphPlugin
import PluginKit
import PluginKitTesting
@testable import AttachmentsPlugin

/// Imports into the one folder, the links they give, the processors, replacing, and the hidden folder.
final class AttachmentsTests: XCTestCase {
    private var outside: URL!

    override func setUpWithError() throws {
        outside = FileManager.default.temporaryDirectory.appendingPathComponent("attachments-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: outside)
    }

    /// A file outside the vault, as Finder would drop it.
    private func file(_ name: String, _ contents: String = "bytes") throws -> URL {
        let url = outside.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func service(_ harness: PluginTestHarness) throws -> AttachmentsService {
        try XCTUnwrap(harness.kernel.services.service(.attachments))
    }

    func testAFileGoesIntoTheFolderAndItsLinkIsRelativeToTheNote() async throws {
        let harness = try PluginTestHarness([AttachmentsPlugin.self], files: ["Inbox/Note.md": "# Note\n"])
        let imported = try await service(harness).importFile(AttachmentImport(
            name: "photo.png", contents: .file(try file("photo.png", "png")), notePath: "Inbox/Note.md"
        ))
        XCTAssertEqual(imported, ImportedAttachment(path: "Attachments/photo.png", kind: .image, markdown: "![](Attachments/photo.png)"))
        XCTAssertEqual(try Data(contentsOf: harness.vault.url("Attachments/photo.png")), Data("png".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("photo.png").path), "a copy, not a move")
    }

    func testTakenNamesGetANumberAndSpacesAreEncoded() async throws {
        let harness = try PluginTestHarness([AttachmentsPlugin.self])
        let attachments = try service(harness)
        let first = try await attachments.importFile(AttachmentImport(name: "My clip.mov", contents: .data(Data("1".utf8))))
        let second = try await attachments.importFile(AttachmentImport(name: "My clip.mov", contents: .data(Data("2".utf8))))
        XCTAssertEqual(first.path, "Attachments/My clip.mov")
        XCTAssertEqual(second.path, "Attachments/My clip 2.mov")
        XCTAssertEqual(second.kind, .video)
        XCTAssertEqual(second.markdown, "![](Attachments/My%20clip%202.mov)")
        XCTAssertEqual(try Data(contentsOf: harness.vault.url("Attachments/My clip.mov")), Data("1".utf8), "never overwritten")
    }

    func testTheSameFileTwiceIsLinkedWhereItIs() async throws {
        let harness = try PluginTestHarness([AttachmentsPlugin.self], files: ["Old/kept.png": "pixels"])
        let attachments = try service(harness)
        let first = try await attachments.importFile(AttachmentImport(name: "Pasted image.png", contents: .data(Data("png".utf8))))
        let again = try await attachments.importFile(AttachmentImport(
            name: "Pasted image later.png", contents: .file(try file("copy.png", "png")), notePath: "N.md"
        ))
        XCTAssertEqual(again, first, "no second copy")
        XCTAssertFalse(harness.vault.exists("Attachments/Pasted image later.png"))
        let elsewhere = try await attachments.importFile(AttachmentImport(name: "new.png", contents: .data(Data("pixels".utf8))))
        XCTAssertEqual(elsewhere.path, "Old/kept.png", "a copy anywhere in the vault counts")
        let other = try await attachments.importFile(AttachmentImport(name: "other.png", contents: .data(Data("pnh".utf8))))
        XCTAssertEqual(other.path, "Attachments/other.png", "same size, other bytes: a new file")
    }

    func testMediaGetImageLinksAndOtherFilesPlainOnes() async throws {
        let harness = try PluginTestHarness([AttachmentsPlugin.self])
        let attachments = try service(harness)
        for (name, kind) in [("a.gif", AttachmentKind.image), ("b.m4a", .audio), ("c.mp4", .video), ("d.pdf", .pdf), ("e.HEIC", .image)] {
            let imported = try await attachments.importFile(AttachmentImport(name: name, contents: .data(Data()), notePath: "N.md"))
            XCTAssertEqual(imported.kind, kind, name)
            XCTAssertEqual(imported.markdown, "![](Attachments/\(name))")
        }
        let zip = try await attachments.importFile(AttachmentImport(name: "[draft].zip", contents: .data(Data()), notePath: "N.md"))
        XCTAssertEqual(zip.kind, .file)
        XCTAssertEqual(zip.markdown, "[[draft].zip](Attachments/%5Bdraft%5D.zip)", "paired brackets need no escape")
        XCTAssertEqual(AttachmentNames.markdownLink(to: "Attachments/a].zip"), "[a\\].zip](Attachments/a%5D.zip)", "unpaired ones do")
        for name in ["v.svg", "s.ogg", "s.opus"] {
            XCTAssertEqual(AttachmentKind(path: name), .file, "nothing shows \(name), so it is a plain link")
        }
    }

    func testNamesStayInTheFolderAndInSight() {
        XCTAssertEqual(AttachmentNames.sanitized("../../etc/passwd"), "-..-etc-passwd")
        XCTAssertEqual(AttachmentNames.sanitized(".hidden.png"), "hidden.png")
        XCTAssertEqual(AttachmentNames.sanitized("  .png "), "file.png")
        XCTAssertEqual(AttachmentNames.sanitized("a:b\nc.jpg"), "a-b-c.jpg")
        let date = Date(timeIntervalSince1970: 1_792_492_325) // 2026-10-20 10:32:05 UTC
        XCTAssertEqual(
            AttachmentNames.pasted(extension: "PNG", at: date, timeZone: TimeZone(identifier: "UTC")!),
            "Pasted image 2026-10-20 at 10.32.05.png"
        )
    }

    func testTheFolderComesFromTheSettings() async throws {
        let vault = try TemporaryVault()
        let settings = Box(AttachmentSettings())
        let attachments = AttachmentStore(vault: vault, settings: { settings.value })
        XCTAssertEqual(attachments.folder, "Attachments")
        settings.value = AttachmentSettings(folder: "Media/Files")
        XCTAssertEqual(attachments.folder, "Media/Files")
        let imported = try await attachments.importFile(AttachmentImport(name: "a.png", contents: .data(Data()), notePath: "Media/N.md"))
        XCTAssertEqual(imported.markdown, "![](Media/Files/a.png)")
        for invalid in ["", "  ", "../out", ".hidden", "/abs"] {
            XCTAssertEqual(AttachmentSettings(folder: invalid).folderPath, "Attachments", invalid)
        }
    }

    func testTheDefaultsAreStoredOnceSoTheSettingsFormListsThem() throws {
        let harness = try PluginTestHarness([AttachmentsPlugin.self])
        let backend = harness.kernel.settingsBackend
        XCTAssertEqual(backend.settings(for: "attachments"), .map(["attachmentsFolder": .string("Attachments"), "hideAttachmentsFolder": .bool(false)]))
        try backend.setSettings(.map(["attachmentsFolder": .string("Files"), "hideAttachmentsFolder": .bool(true)]), for: "attachments")
        harness.host.deactivateAll()
        try harness.host.activateAll()
        XCTAssertEqual(backend.settings(for: "attachments"), .map(["attachmentsFolder": .string("Files"), "hideAttachmentsFolder": .bool(true)]), "kept")
    }

    func testProcessorsChangeTheFileBeforeItIsWritten() async throws {
        let harness = try PluginTestHarness([AttachmentsPlugin.self])
        let attachments = try service(harness)
        let remove = attachments.addProcessor(AttachmentProcessor(id: "test.jpeg", kinds: [.image]) { file in
            var file = file
            file.name = (file.name as NSString).deletingPathExtension + ".jpg"
            file.contents = .data(Data("smaller".utf8))
            return file
        })
        _ = attachments.addProcessor(AttachmentProcessor(id: "test.broken") { _ in throw VaultError.notFound(path: "x") })
        let photo = try await attachments.importFile(AttachmentImport(name: "IMG.heic", contents: .data(Data("big".utf8)), notePath: "N.md"))
        XCTAssertEqual(photo.path, "Attachments/IMG.jpg")
        XCTAssertEqual(photo.markdown, "![](Attachments/IMG.jpg)")
        XCTAssertEqual(try Data(contentsOf: harness.vault.url("Attachments/IMG.jpg")), Data("smaller".utf8))

        let song = try await attachments.importFile(AttachmentImport(name: "song.mp3", contents: .data(Data("mp3".utf8))))
        XCTAssertEqual(song.path, "Attachments/song.mp3", "not an image: the image processor leaves it alone")
        remove()
        let raw = try await attachments.importFile(AttachmentImport(name: "IMG.heic", contents: .data(Data("big".utf8))))
        XCTAssertEqual(raw.path, "Attachments/IMG.heic", "removed processors no longer run")
    }

    func testImportsAreAnnouncedOnTheMainThread() async throws {
        let harness = try PluginTestHarness([AttachmentsPlugin.self])
        let received = expectation(description: "imported")
        _ = harness.kernel.events.on(AttachmentImported.self) { event in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(event, AttachmentImported(path: "Attachments/a.pdf", kind: .pdf, notePath: "N.md"))
            received.fulfill()
        }
        _ = try await service(harness).importFile(AttachmentImport(name: "a.pdf", contents: .data(Data()), notePath: "N.md"))
        await fulfillment(of: [received], timeout: 2)
    }

    func testReplacingKeepsTheOldFileInTheTrashAndRewritesLinks() async throws {
        let harness = try PluginTestHarness([NoteGraphPlugin.self, AttachmentsPlugin.self], files: [
            "Inbox/Note.md": "# Note\n\n![](../Attachments/IMG.heic)\n",
            "Other.md": "See [the photo](Attachments/IMG.heic).\n",
        ])
        try harness.vault.writeData("Attachments/IMG.heic", Data("original".utf8))
        let replaced = try await service(harness).replace("Attachments/IMG.heic", with: .data(Data("jpeg".utf8)), name: "IMG.jpg")
        XCTAssertEqual(replaced, AttachmentReplacement(path: "Attachments/IMG.jpg", trashed: ".trash/Attachments/IMG.heic", updated: ["Inbox/Note.md", "Other.md"]))
        XCTAssertEqual(try harness.vault.read("Inbox/Note.md"), "# Note\n\n![](../Attachments/IMG.jpg)\n")
        XCTAssertEqual(try harness.vault.read("Other.md"), "See [the photo](Attachments/IMG.jpg).\n")
        XCTAssertEqual(try Data(contentsOf: harness.vault.url("Attachments/IMG.jpg")), Data("jpeg".utf8))
        XCTAssertEqual(try Data(contentsOf: harness.vault.url(".trash/Attachments/IMG.heic")), Data("original".utf8))
        XCTAssertFalse(harness.vault.exists("Attachments/IMG.heic"))

        let same = try await service(harness).replace("Attachments/IMG.jpg", with: .data(Data("smaller".utf8)), name: nil)
        XCTAssertEqual(same, AttachmentReplacement(path: "Attachments/IMG.jpg", trashed: ".trash/Attachments/IMG.jpg", updated: []))
        XCTAssertEqual(try Data(contentsOf: harness.vault.url("Attachments/IMG.jpg")), Data("smaller".utf8))
    }

    func testReplacingAnnouncesTheMoveOnTheMainThread() async throws {
        let harness = try PluginTestHarness([NoteGraphPlugin.self, AttachmentsPlugin.self], files: ["N.md": "![](Attachments/a.heic)\n"])
        try harness.vault.writeData("Attachments/a.heic", Data("original".utf8))
        let moved = expectation(description: "moved")
        _ = harness.kernel.events.on(NotesMoved.self) { _ in
            XCTAssertTrue(Thread.isMainThread, "the app's listeners assume the main thread")
            moved.fulfill()
        }
        // Off the main thread, as a compressor working in the background calls it.
        let attachments = try service(harness)
        _ = try await Task.detached { try await attachments.replace("Attachments/a.heic", with: .data(Data("jpeg".utf8)), name: "a.jpg") }.value
        await fulfillment(of: [moved], timeout: 2)
        XCTAssertEqual(try harness.vault.read("N.md"), "![](Attachments/a.jpg)\n")
        XCTAssertEqual(try Data(contentsOf: harness.vault.url("Attachments/a.jpg")), Data("jpeg".utf8))
    }

    func testTheImportCommandCanAppendTheLinkToTheNote() async throws {
        let harness = try PluginTestHarness([AttachmentsPlugin.self], files: ["Inbox/Trip.md": "# Trip\n\nDay one."])
        let output = try await harness.run("attachments.import", [
            "file": try file("beach.jpg").path, "note": "Inbox/Trip.md", "append": "true",
        ])
        let imported = try JSONDecoder().decode(ImportedAttachment.self, from: Data(output.utf8))
        XCTAssertEqual(imported.markdown, "![](Attachments/beach.jpg)")
        XCTAssertEqual(try harness.vault.read("Inbox/Trip.md"), "# Trip\n\nDay one.\n\n![](Attachments/beach.jpg)\n")

        let listed = try await harness.run("attachments.list")
        XCTAssertEqual(listed, try JSON.string([AttachmentEntry(path: "Attachments/beach.jpg", kind: .image, size: 5)]))
        do {
            _ = try await harness.run("attachments.import", ["file": outside.appendingPathComponent("missing.png").path])
            XCTFail("a missing file should throw")
        } catch {
            XCTAssertNotNil(error as? VaultError)
        }
    }

    func testTheFolderCanBeHiddenFromFileBrowsers() async throws {
        let harness = try PluginTestHarness([AttachmentsPlugin.self])
        XCTAssertEqual(harness.kernel.events.waterfall(HiddenFolders()).paths, [])
        var changes = 0
        _ = harness.kernel.events.on(HiddenFoldersChanged.self) { _ in changes += 1 }
        let output = try await harness.run("attachments.hide-folder")
        XCTAssertTrue(output.contains("\"hidden\" : true"), output)
        XCTAssertEqual(harness.kernel.events.waterfall(HiddenFolders(paths: ["Other"])).paths, ["Other", "Attachments"])
        XCTAssertEqual(changes, 1)
        _ = try await harness.run("attachments.hide-folder", ["hidden": "false"])
        XCTAssertEqual(harness.kernel.events.waterfall(HiddenFolders()).paths, [])
        XCTAssertEqual(changes, 2)
    }

    func testUnloadingRemovesTheServiceCommandsAndListeners() async throws {
        let harness = try PluginTestHarness([AttachmentsPlugin.self])
        XCTAssertEqual(Set(harness.kernel.commands.all.map(\.id)), [
            "attachments.import", "attachments.list", "attachments.replace", "attachments.hide-folder",
        ])
        _ = try await harness.run("attachments.hide-folder", ["hidden": "true"])
        XCTAssertEqual(harness.kernel.events.waterfall(HiddenFolders()).paths, ["Attachments"])
        harness.host.deactivateAll()
        XCTAssertNil(harness.kernel.services.service(.attachments))
        XCTAssertEqual(harness.kernel.commands.all.map(\.id), [])
        XCTAssertEqual(harness.kernel.events.waterfall(HiddenFolders()).paths, [])
    }
}

/// A value the test changes while the store reads it.
private final class Box<Value>: @unchecked Sendable {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func testAVaultThatAlreadyUsesAssetsKeepsIt() async throws {
        let harness = try PluginTestHarness([AttachmentsPlugin.self], files: ["assets/old.png": "pixels"])
        let attachments = try XCTUnwrap(harness.kernel.services.service(.attachments))
        let imported = try await attachments.importFile(AttachmentImport(name: "new.png", contents: .data(Data("x".utf8))))
        XCTAssertEqual(imported.path, "assets/new.png", "one attachments folder, the one the vault has")
        XCTAssertFalse(harness.vault.exists("Attachments"))
    }
}

