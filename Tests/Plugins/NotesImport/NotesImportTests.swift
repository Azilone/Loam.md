import XCTest
import LoamCore
import PluginKit
import PluginKitTesting
#if canImport(SQLite3)
import SQLite3
#endif
@testable import NotesImportPlugin

final class NotesImportTests: XCTestCase {
    private var temp: URL!
    private var vault: Vault!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = temp.appendingPathComponent("vault")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        vault = Vault(rootURL: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    private func write(_ path: String, _ text: String, in folder: URL) throws {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Notion

    func testNotionLosesItsIdsAndKeepsPropertiesLinksAndDatabases() throws {
        let export = temp.appendingPathComponent("Export")
        let id1 = "3f1c2b4a5d6e7f8091a2b3c4d5e6f708", id2 = "0123456789abcdef0123456789abcdef"
        try write("Home \(id1).md", "# Home\n\nSee [Plan](Projects%20\(id2)/Plan%20\(id1).md).\n", in: export)
        try write("Projects \(id2).csv", "Name,Status\nPlan,Doing\n", in: export)
        try write("Projects \(id2)_all.csv", "Name,Status\nPlan,Doing\n", in: export)
        try write("Projects \(id2)/Plan \(id1).md", "# Plan\n\nStatus: Doing\nOwner: Léa\n\nThe text.\n", in: export)
        let report = try NotionImporter(vault: vault).run(source: export, into: "Imported/Notion", dryRun: false)
        XCTAssertEqual(report.converted, 2)
        XCTAssertEqual(report.collections, 1)
        XCTAssertEqual(try vault.read("Imported/Notion/Home.md"), "# Home\n\nSee [Plan](Projects/Plan.md).\n")
        XCTAssertEqual(try vault.read("Imported/Notion/Projects/Plan.md"),
                       "---\nStatus: Doing\nOwner: Léa\n---\n\n# Plan\n\nThe text.\n")
        XCTAssertTrue(try vault.read("Imported/Notion/Projects/Projects.base").contains("file.inFolder(\"Imported/Notion/Projects\")"))
        XCTAssertFalse(vault.exists("Imported/Notion/Projects_all.csv"))
    }

    func testADryRunWritesNothingAndExistingFilesStay() throws {
        let export = temp.appendingPathComponent("Export")
        try write("Home.md", "# Home\n", in: export)
        XCTAssertEqual(try NotionImporter(vault: vault).run(source: export, into: "", dryRun: true).converted, 1)
        XCTAssertFalse(vault.exists("Home.md"))
        try vault.write("Home.md", "mine")
        XCTAssertEqual(try NotionImporter(vault: vault).run(source: export, into: "", dryRun: false).skipped, ["Home.md"])
        XCTAssertEqual(try vault.read("Home.md"), "mine")
    }

    // MARK: Bear

    #if canImport(SQLite3)
    func testBearNotesAndTheirPicturesComeAlong() throws {
        let bear = temp.appendingPathComponent("Bear")
        try FileManager.default.createDirectory(at: bear, withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(bear.appendingPathComponent("database.sqlite").path, &db), SQLITE_OK)
        let sql = """
            CREATE TABLE ZSFNOTE (Z_PK INTEGER PRIMARY KEY, ZTITLE TEXT, ZTEXT TEXT, ZCREATIONDATE REAL,
              ZMODIFICATIONDATE REAL, ZARCHIVED INTEGER, ZTRASHED INTEGER, ZPERMANENTLYDELETED INTEGER, ZENCRYPTED INTEGER);
            CREATE TABLE ZSFNOTEFILE (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, ZNOTE INTEGER, ZUNIQUEIDENTIFIER TEXT,
              ZFILENAME TEXT, ZPERMANENTLYDELETED INTEGER);
            INSERT INTO ZSFNOTE VALUES (1, 'Groceries', '# Groceries\n#home\n![](pic.png)', 0, 0, 0, 0, 0, 0);
            INSERT INTO ZSFNOTE VALUES (2, 'Old', '# Old', 0, 0, 1, 0, 0, 0);
            INSERT INTO ZSFNOTE VALUES (3, 'Gone', '# Gone', 0, 0, 0, 1, 0, 0);
            INSERT INTO ZSFNOTE VALUES (4, 'Secret', '', 0, 0, 0, 0, 0, 1);
            INSERT INTO ZSFNOTEFILE VALUES (1, 9, 1, 'UUID-1', 'pic.png', 0);
            """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        try write("Local Files/Note Images/UUID-1/pic.png", "PNG", in: bear)

        let report = try BearImporter(vault: vault, folder: bear).run(into: "Imported/Bear", dryRun: false)
        XCTAssertEqual(report.converted, 2)
        XCTAssertEqual(report.copied, 1)
        XCTAssertEqual(report.warnings.count, 1, "the locked note")
        let groceries = try vault.read("Imported/Bear/Groceries.md")
        XCTAssertTrue(groceries.hasPrefix("---\ncreated: 2001-01-01T"))
        XCTAssertTrue(groceries.contains("#home\n![](Attachments/pic.png)"))
        XCTAssertTrue(vault.exists("Imported/Bear/Archive/Old.md"))
        XCTAssertFalse(vault.exists("Imported/Bear/Gone.md"))
    }
    #endif

    // MARK: Apple Notes

    func testAppleNotesBecomeMarkdownInTheirFolders() throws {
        let json = """
            [{"account":"iCloud","folder":"Notes","name":"Cabin","body":"<div><h1>Cabin</h1></div><div>By the <b>lake</b></div><ul><li>July</li></ul><div><img src=\\"data:image/png;base64,UE5H\\"></div>","created":"2026-10-21T08:00:00.000Z","modified":"2026-10-22T08:00:00.000Z","locked":false},
             {"account":"iCloud","folder":"Notes/Work","name":"Secret","body":"","created":null,"modified":null,"locked":true}]
            """
        let importer = AppleNotesImporter(vault: vault, script: { _ in json })
        let report = try importer.run(into: "Imported/Apple Notes", dryRun: false)
        XCTAssertEqual(report.converted, 1)
        XCTAssertEqual(report.copied, 1)
        let text = try vault.read("Imported/Apple Notes/Notes/Cabin.md")
        XCTAssertTrue(text.contains("# Cabin\n"))
        XCTAssertTrue(text.contains("By the **lake**"))
        XCTAssertTrue(text.contains("- July"))
        XCTAssertTrue(text.contains("![](../Attachments/Cabin%201.png)"))
        XCTAssertEqual(try Data(contentsOf: vault.rootURL.appendingPathComponent("Imported/Apple Notes/Attachments/Cabin 1.png")), Data("PNG".utf8))
    }

    func testTheCommandsAndTheServiceUnloadCleanly() async throws {
        let kernel = Kernel(vault: vault)
        let host = PluginHost(kernel: kernel)
        try host.register(NotesImportPlugin.self)
        try host.activateAll()
        XCTAssertTrue(kernel.services.service(.notesImport)?.available().contains(.notion) ?? false)
        let export = temp.appendingPathComponent("Export")
        try write("Home.md", "# Home\n", in: export)
        let command = try XCTUnwrap(kernel.commands.command(id: "import.notion"))
        let report = try JSONDecoder().decode(NotesImportReport.self, from: Data(try await command.handler(["source": export.path]).utf8))
        XCTAssertEqual(report.converted, 1)
        XCTAssertTrue(vault.exists("Imported/Notion/Home.md"))
        host.deactivateAll()
        XCTAssertNil(kernel.commands.command(id: "import.bear"))
    }
}
