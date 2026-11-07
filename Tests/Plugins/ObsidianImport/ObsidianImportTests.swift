import XCTest
import PluginKit
import LoamCore
@testable import ObsidianImportPlugin

final class ObsidianConverterTests: XCTestCase {
    private func converter(into: String = "") -> ObsidianConverter {
        let notes = ["Home.md", "Projects/Plan.md", "Archive/Plan.md", "People/Bob Smith.md"]
        return ObsidianConverter(
            resolver: NoteResolver(notePaths: notes, filePaths: notes + ["img/Photo One.png", "docs/spec.pdf"]),
            destinationFolder: into
        )
    }

    private func convert(_ text: String, at path: String = "Home.md", into: String = "") -> (String, [String]) {
        var warnings: [String] = []
        let result = converter(into: into).convert(text, notePath: path, warnings: &warnings)
        return (result, warnings)
    }

    func testWikilinksBecomeStandardRelativeLinks() {
        XCTAssertEqual(convert("See [[Bob Smith]] and [[Bob Smith|Bob]].").0,
                       "See [Bob Smith](People/Bob%20Smith.md) and [Bob](People/Bob%20Smith.md).")
        XCTAssertEqual(convert("[[Home]]", at: "People/Bob Smith.md").0, "[Home](../Home.md)")
    }

    func testHeadingFragmentsAndBlockReferences() {
        XCTAssertEqual(convert("[[Home#Big Plans!]]").0, "[Home > Big Plans!](Home.md#big-plans)")
        XCTAssertEqual(convert("[[Home#^abc123|there]]").0, "[there](Home.md)")
        XCTAssertEqual(convert("[[#Local Heading]]").0, "[Local Heading](#local-heading)")
    }

    func testShortestPathWinsAndAmbiguityIsReported() {
        let (text, warnings) = convert("[[Plan]]")
        XCTAssertEqual(text, "[Plan](Archive/Plan.md)")
        XCTAssertEqual(warnings.count, 1)
        XCTAssertEqual(convert("[[Projects/Plan]]").0, "[Plan](Projects/Plan.md)")
    }

    func testUnresolvedLinksBecomePlainTextWithAWarning() {
        let (text, warnings) = convert("Maybe [[Nowhere]] or [[Nowhere|that]].")
        XCTAssertEqual(text, "Maybe Nowhere or that.")
        XCTAssertEqual(warnings.count, 2)
    }

    func testEmbeds() {
        XCTAssertEqual(convert("![[Photo One.png]]").0, "![Photo One](img/Photo%20One.png)")
        XCTAssertEqual(convert("![[Photo One.png|300]]").0, "![Photo One](img/Photo%20One.png)")
        XCTAssertEqual(convert("![[spec.pdf]]").0, "[spec.pdf](docs/spec.pdf)")
        XCTAssertEqual(convert("![[Bob Smith]]").0, "[Bob Smith](People/Bob%20Smith.md)")
    }

    func testCalloutsBecomeGitHubAlerts() {
        XCTAssertEqual(convert("> [!tip]\n> Be kind").0, "> [!TIP]\n> Be kind")
        XCTAssertEqual(convert("> [!warning]- Careful now\n> Hot").0, "> [!WARNING]\n> **Careful now**\n> Hot")
        XCTAssertEqual(convert("> [!question] Why?\n> Because").0, "> [!NOTE]\n> **Why?**\n> Because")
    }

    func testCommentsAreRemoved() {
        XCTAssertEqual(convert("Keep %%hidden%% this").0, "Keep  this")
        XCTAssertEqual(convert("A\n%%\nsecret\n[[Home]]\n%%\nB").0, "A\nB")
    }

    func testCodeIsNeverConverted() {
        let text = "Use `[[Home]]` here, [[Home]] there.\n\n```\n[[Home]]\n> [!tip]\n```\n"
        XCTAssertEqual(convert(text).0, "Use `[[Home]]` here, [Home](Home.md) there.\n\n```\n[[Home]]\n> [!tip]\n```\n")
    }

    func testFrontmatterIsKeptAndTablePipesAreHandled() {
        let text = "---\nlinks: \"[[Home]]\"\n---\n| a |\n|---|\n| [[Home\\|Back]] |\n"
        XCTAssertEqual(convert(text).0, "---\nlinks: \"[[Home]]\"\n---\n| a |\n|---|\n| [Back](Home.md) |\n")
    }

    func testLinksAreRelativeToTheDestinationFolder() {
        XCTAssertEqual(convert("[[Bob Smith]]", at: "Home.md", into: "Imported").0, "[Bob Smith](People/Bob%20Smith.md)")
        XCTAssertEqual(convert("[[Home]]", at: "People/Bob Smith.md", into: "Imported").0, "[Home](../Home.md)")
    }
}

final class ObsidianImporterTests: XCTestCase {
    private var source: URL!
    private var root: URL!
    private var vault: Vault!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString)")
        source = base.appendingPathComponent("obsidian")
        root = base.appendingPathComponent("vault")
        try FileManager.default.createDirectory(at: source.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        vault = Vault(rootURL: root)
        try write("Home.md", "# Home\n[[Plan]] > [!note]\n")
        try write("Notes/Plan.md", "# Plan\nBack to [[Home]]\n![[pic.png]]\n")
        try write("pic.png", "PNGDATA")
        try write("board.canvas", "{\"nodes\":[],\"edges\":[]}")
        try write(".obsidian/app.json", "{}")
        try write(".obsidian/daily-notes.json", "{\"folder\":\"Journal\",\"format\":\"YYYY-MM-DD\"}")
        try write(".obsidian/community-plugins.json", "[\"dataview\",\"templater-obsidian\"]")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
    }

    private func write(_ path: String, _ text: String) throws {
        let url = source.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func testImportConvertsNotesAndCopiesTheRest() throws {
        let report = try ObsidianImporter(vault: vault).run(ImportOptions(source: source))
        XCTAssertEqual(report.converted, 2)
        XCTAssertEqual(report.copied, 2)
        XCTAssertEqual(report.skipped, [])
        XCTAssertEqual(report.dailyNotes, ImportReport.DailyNotesHint(folder: "Journal", format: "YYYY-MM-DD", template: ""))
        XCTAssertEqual(report.communityPlugins, ["dataview", "templater-obsidian"])
        XCTAssertEqual(try vault.read("Home.md"), "# Home\n[Plan](Notes/Plan.md) > [!note]\n")
        XCTAssertEqual(try vault.read("Notes/Plan.md"), "# Plan\nBack to [Home](../Home.md)\n![pic](../pic.png)\n")
        XCTAssertEqual(try vault.read("board.canvas"), "{\"nodes\":[],\"edges\":[]}")
        XCTAssertFalse(vault.exists(".obsidian/app.json"))
    }

    /// A vault that files its days by year, in three date formats, with attachments next to the notes.
    private func writeJournalVault() throws {
        try write(".obsidian/daily-notes.json", "{\"folder\":\"JOURNAL/2026/Journalier\",\"format\":\"YYYY.MM.DD\"}")
        try write("JOURNAL/2026/Journalier/2026.07.28.md", "# 2026.07.28\n![Image](JOURNAL/2026/Journalier/2026.07.28.assets/Image%20(2).webp)\nSee [[Home]]\n")
        try write("JOURNAL/2026/Journalier/2026.07.28.assets/Image (2).webp", "WEBP")
        try write("JOURNAL/2025/Journalier/Mon 14 Jul 2025.md", "# a\n")
        try write("JOURNAL/2025/Journalier/lun. 14 juil. 2025.md", "# b\n")
        try write("JOURNAL/2024/Journalier/dim. 08 d\u{00E9}c. 2024.md", "# c\nBack to [[2026.07.28]]\n")
        try write("Meetings/Call/Summary.md", "# Call\n")
        try write("Meetings/Call/.raw/mic-0.mp3", "MP3")
        try write("Meetings/Call/audio.mp3", "MP3")
        try write("Home.md", "# Home\nToday: [[2026.07.28]]\n![pic](pic.png)\n[[Plan]]\n")
    }

    private func layoutImporter() -> ObsidianImporter {
        ObsidianImporter(vault: vault, dailyNotesFolder: { "Daily" }, attachmentsFolder: { "Attachments" })
    }

    func testDailyNotesLandInTheDailyFolderWhateverTheirNameFormat() throws {
        try writeJournalVault()
        let report = try layoutImporter().run(ImportOptions(source: source))
        XCTAssertEqual(report.dailyNotesMoved, 3)
        XCTAssertTrue(vault.exists("Daily/2026-07-28.md"))
        XCTAssertTrue(vault.exists("Daily/2025-07-14.md"))
        XCTAssertTrue(vault.exists("Daily/2024-12-08.md"))
        XCTAssertFalse(vault.exists("JOURNAL/2026/Journalier/2026.07.28.md"))
        // Two notes for one day: the second stays where it is, and the report says so.
        XCTAssertTrue(vault.exists("JOURNAL/2025/Journalier/lun. 14 juil. 2025.md"))
        XCTAssertTrue(report.warnings.contains { $0.contains("same day") })
    }

    func testLinksToAndFromMovedFilesStillResolve() throws {
        try writeJournalVault()
        _ = try layoutImporter().run(ImportOptions(source: source))
        XCTAssertTrue(try vault.read("Home.md").contains("[2026.07.28](Daily/2026-07-28.md)"))
        XCTAssertTrue(try vault.read("Home.md").contains("![pic](Attachments/pic.png)"))
        let day = try vault.read("Daily/2026-07-28.md")
        XCTAssertTrue(day.contains("![Image](../Attachments/Image%20%282%29.webp)") || day.contains("![Image](../Attachments/Image%20(2).webp)"))
        XCTAssertTrue(day.contains("[Home](../Home.md)"))
        XCTAssertTrue(try vault.read("Daily/2024-12-08.md").contains("(2026-07-28.md)"))
    }

    func testOnlyLinkedFilesGoToAttachmentsAndHiddenFoldersStay() throws {
        try writeJournalVault()
        let report = try layoutImporter().run(ImportOptions(source: source))
        XCTAssertEqual(report.attachmentsMoved, 2)
        XCTAssertTrue(vault.exists("Attachments/pic.png"))
        XCTAssertTrue(vault.exists("Attachments/Image (2).webp"))
        XCTAssertFalse(vault.exists("pic.png"))
        // Not linked from any note, or inside a hidden folder: unmoved.
        XCTAssertTrue(vault.exists("Meetings/Call/audio.mp3"))
        XCTAssertTrue(vault.exists("Meetings/Call/.raw/mic-0.mp3"))
    }

    func testALinkByFileNameAloneIsRewrittenToWork() throws {
        try write("Notes/N.md", "![](photo.png) and [doc](spec.pdf)\n")
        try write("img/photo.png", "P")
        try write("docs/spec.pdf", "D")
        _ = try ObsidianImporter(vault: vault).run(ImportOptions(source: source))
        XCTAssertEqual(try vault.read("Notes/N.md"), "![](../img/photo.png) and [doc](../docs/spec.pdf)\n")
        let moved = try layoutImporter().run(ImportOptions(source: source, overwrite: true))
        XCTAssertEqual(moved.attachmentsMoved >= 2, true)
        XCTAssertEqual(try vault.read("Notes/N.md"), "![](../Attachments/photo.png) and [doc](../Attachments/spec.pdf)\n")
    }

    func testTwoAttachmentsWithOneNameKeepBoth() throws {
        try write("A/pic.png", "ONE")
        try write("B/pic.png", "TWO")
        try write("Notes/N.md", "![[A/pic.png]] ![[B/pic.png]]\n")
        let report = try layoutImporter().run(ImportOptions(source: source))
        // The vault's own `pic.png` (linked from Notes/Plan.md) is the third.
        XCTAssertEqual(report.attachmentsMoved, 3)
        XCTAssertEqual(try vault.read("Attachments/pic.png"), "ONE")
        XCTAssertEqual(try vault.read("Attachments/pic 2.png"), "TWO")
    }

    func testKeepLayoutAndImportIntoAFolderLeaveEveryPath() throws {
        try writeJournalVault()
        let kept = try layoutImporter().run(ImportOptions(source: source, keepLayout: true))
        XCTAssertEqual(kept.dailyNotesMoved + kept.attachmentsMoved, 0)
        XCTAssertTrue(vault.exists("JOURNAL/2026/Journalier/2026.07.28.md"))
        XCTAssertTrue(vault.exists("pic.png"))
    }

    func testDailyNoteNames() {
        XCTAssertEqual(DailyNoteName.day(of: "2026.07.28"), "2026-07-28")
        XCTAssertEqual(DailyNoteName.day(of: "2026-07-28"), "2026-07-28")
        XCTAssertEqual(DailyNoteName.day(of: "Fri 08 Aug 2025"), "2025-08-08")
        XCTAssertEqual(DailyNoteName.day(of: "dim. 08 d\u{00E9}c. 2024"), "2024-12-08")
        XCTAssertEqual(DailyNoteName.day(of: "mar. 14 f\u{00E9}vr. 2025"), "2025-02-14")
        XCTAssertEqual(DailyNoteName.day(of: "dim. 08 de\u{0301}c. 2024"), "2024-12-08")
        XCTAssertNil(DailyNoteName.day(of: "SEMAINE 52 d\u{00E9}c. 2024"))
        XCTAssertNil(DailyNoteName.day(of: "Home"))
    }

    func testBoardsFollowTheImportAndLoseTheirWikilinks() throws {
        try write("Maps/trip.canvas", """
            {"nodes":[{"id":"a","type":"file","file":"Notes/Plan.md","x":0,"y":0,"width":400,"height":400},\
            {"id":"b","type":"text","text":"See [[Home]]","x":500,"y":0,"width":250,"height":60}],"edges":[]}
            """)
        let report = try ObsidianImporter(vault: vault).run(ImportOptions(source: source, into: "Imported"))
        XCTAssertEqual(report.copied, 3)
        let board = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try vault.read("Imported/Maps/trip.canvas").utf8))
            as? [String: Any])
        let nodes = try XCTUnwrap(board["nodes"] as? [[String: Any]])
        XCTAssertEqual(nodes[0]["file"] as? String, "Imported/Notes/Plan.md")
        XCTAssertEqual(nodes[1]["text"] as? String, "See [Home](../Home.md)")
        XCTAssertEqual(nodes[1]["width"] as? Int, 250)
    }

    func testExistingFilesAreNeverOverwrittenByDefault() throws {
        try vault.write("Home.md", "mine")
        let report = try ObsidianImporter(vault: vault).run(ImportOptions(source: source))
        XCTAssertEqual(report.skipped, ["Home.md"])
        XCTAssertEqual(try vault.read("Home.md"), "mine")
        _ = try ObsidianImporter(vault: vault).run(ImportOptions(source: source, overwrite: true))
        XCTAssertNotEqual(try vault.read("Home.md"), "mine")
    }

    func testAGitFileDoesNotHideTheFolderAfterIt() throws {
        try write(".git", "gitdir: ../elsewhere")
        let folders = ["A", "B", "M", "TEMPLATES", "Z"]
        for folder in folders { try write("\(folder)/n.md", "x") }
        let report = try ObsidianImporter(vault: vault).run(ImportOptions(source: source, dryRun: true))
        XCTAssertEqual(report.converted, 2 + folders.count)
    }

    func testTheImportSaysWhereItStandsNoteByNote() async throws {
        var steps: [ImportProgress] = []
        let report = try await ObsidianImporter(vault: vault).run(ImportOptions(source: source)) { steps.append($0) }
        XCTAssertEqual(report.converted, 2)
        XCTAssertEqual(steps.first, ImportProgress(done: 0, total: 2, file: "Home.md", next: ["Notes/Plan.md"]))
        XCTAssertTrue(steps.contains(ImportProgress(done: 1, total: 2, file: "Notes/Plan.md")))
        XCTAssertEqual(steps.last, ImportProgress(done: 2, total: 2))
    }

    func testAFileThatCannotBeWrittenStopsTheImportAndSaysWhich() async throws {
        // A folder where the note should go: the note cannot be written.
        try FileManager.default.createDirectory(at: vault.rootURL.appendingPathComponent("Notes/Plan.md"), withIntermediateDirectories: true)
        do {
            _ = try await ObsidianImporter(vault: vault).run(ImportOptions(source: source, overwrite: true)) { _ in }
            XCTFail("expected a failure")
        } catch let failure as ImportFailure {
            XCTAssertEqual(failure.file, "Notes/Plan.md")
            XCTAssertEqual(failure.total, 2)
            XCTAssertEqual(failure.done, 1, "Home.md came first")
        }
    }

    func testDryRunWritesNothing() throws {
        let report = try ObsidianImporter(vault: vault).run(ImportOptions(source: source, dryRun: true))
        XCTAssertEqual(report.converted, 2)
        XCTAssertEqual(try vault.markdownPaths(), [])
    }

    func testImportIntoAFolderKeepsLinksWorking() throws {
        _ = try ObsidianImporter(vault: vault).run(ImportOptions(source: source, into: "Imported"))
        XCTAssertEqual(try vault.read("Imported/Notes/Plan.md"), "# Plan\nBack to [Home](../Home.md)\n![pic](../pic.png)\n")
        XCTAssertTrue(vault.exists("Imported/pic.png"))
    }

    func testTheCommandReportsJSONAndSourceStaysUntouched() async throws {
        let kernel = Kernel(vault: vault)
        let host = PluginHost(kernel: kernel)
        try host.register(ObsidianImportPlugin.self)
        try host.activateAll()
        let command = try XCTUnwrap(kernel.commands.command(id: "import.obsidian"))
        let output = try await command.handler(["source": source.path])
        let report = try JSONDecoder().decode(ImportReport.self, from: Data(output.utf8))
        XCTAssertEqual(report.converted, 2)
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("Home.md"), encoding: .utf8), "# Home\n[[Plan]] > [!note]\n")
        do {
            _ = try await command.handler([:])
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? CommandError, .missingArgument(name: "source"))
        }
    }
}

final class ObsidianVaultsTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for path in ["Old/a.md", "Recent/b.md", "Recent/Sub/c.md", "Recent/.obsidian/x.md", "Recent/pic.png"] {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "x".write(to: url, atomically: true, encoding: .utf8)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testFindsObsidiansVaultsMostRecentFirstAndSkipsMissingFolders() throws {
        let list = folder.appendingPathComponent("obsidian.json")
        let json = """
            {"vaults":{
              "a":{"path":"\(folder.appendingPathComponent("Old").path)","ts":1000},
              "b":{"path":"\(folder.appendingPathComponent("Recent").path)","ts":2000,"open":true},
              "c":{"path":"\(folder.appendingPathComponent("Gone").path)","ts":3000}
            }}
            """
        try json.write(to: list, atomically: true, encoding: .utf8)
        let vaults = ObsidianVaults.find(list: list)
        XCTAssertEqual(vaults.map(\.name), ["Recent", "Old"])
        XCTAssertEqual(vaults.map(\.notes), [2, 1])
        XCTAssertEqual(vaults.first?.opened, Date(timeIntervalSince1970: 2))
        XCTAssertEqual(ObsidianVaults.find(list: folder.appendingPathComponent("none.json")), [])
    }
}
