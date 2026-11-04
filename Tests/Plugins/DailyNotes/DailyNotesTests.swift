import XCTest
import PluginKit
import LoamCore
@testable import DailyNotesPlugin

final class DailyNotesTests: XCTestCase {
    private var root: URL!
    private var vault: Vault!
    private var calendar: Calendar!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("daily-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        vault = Vault(rootURL: root)
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func daily(
        now: String = "2026-10-18T12:00:00Z", subfolders: DailyNotesSubfolders = .none
    ) -> DailyNotes {
        let date = ISO8601DateFormatter().date(from: now)!
        return DailyNotes(
            vault: vault, layout: DailyNotesLayout(subfolders: subfolders), calendar: calendar, now: { date }
        )
    }

    func testSubfoldersSortNewNotesByYearOrMonth() throws {
        XCTAssertEqual(try daily(subfolders: .year).path(for: nil), "Daily/2026/2026-10-18.md")
        XCTAssertEqual(try daily(subfolders: .month).path(for: nil), "Daily/2026/10 October/2026-10-18.md")
        XCTAssertEqual(try daily(subfolders: .month).path(for: "2025-01-02"), "Daily/2025/01 January/2025-01-02.md")
        try daily(subfolders: .month).append("Idea", date: nil)
        XCTAssertEqual(try vault.read("Daily/2026/10 October/2026-10-18.md"), "Idea\n")
    }

    func testNotesSortedAnotherWayAreStillFound() throws {
        try vault.write("Daily/2024-12-07.md", "Flat\n")
        try vault.write("Daily/2025/2025-03-01.md", "Year\n")
        try vault.write("Daily/2026/10 October/2026-10-18.md", "Month\n")
        try vault.write("Daily/Archive/2024-01-01.md", "Not a daily note\n")
        let notes = daily(subfolders: .month)
        XCTAssertEqual(try notes.existingDates(in: nil), ["2024-12-07", "2025-03-01", "2026-10-18"])
        XCTAssertEqual(try notes.existingDates(in: "2025-03"), ["2025-03-01"])
        XCTAssertEqual(try notes.path(for: "2024-12-07"), "Daily/2024-12-07.md")
        XCTAssertEqual(try notes.read(date: "2025-03-01"), "Year\n")
        try notes.append("More", date: "2024-12-07")
        XCTAssertEqual(try vault.read("Daily/2024-12-07.md"), "Flat\n\nMore\n")
        XCTAssertFalse(vault.exists("Daily/2024/12 December/2024-12-07.md"))
    }

    func testReorganizationMovesNotesAndTheirAssets() throws {
        try vault.write("Daily/2024-12-07.md", "Flat\n")
        try vault.writeData("Daily/2024-12-07.assets/Image.webp", Data([1]))
        try vault.write("Daily/2026/10 October/2026-10-18.md", "Already sorted\n")
        XCTAssertEqual(try daily(subfolders: .month).reorganizationMoves(), [
            "Daily/2024-12-07.md": "Daily/2024/12 December/2024-12-07.md",
            "Daily/2024-12-07.assets": "Daily/2024/12 December/2024-12-07.assets",
        ])
        XCTAssertEqual(try daily(subfolders: .none).reorganizationMoves(), [
            "Daily/2026/10 October/2026-10-18.md": "Daily/2026-10-18.md",
        ])
    }

    func testOldSettingsReadAsFlat() throws {
        let data = Data(#"{"folder":"Journal","template":""}"#.utf8)
        let settings = try JSONDecoder().decode(DailyNotesSettings.self, from: data)
        XCTAssertEqual(settings.subfolders, .none)
        XCTAssertEqual(settings.layout.folder, "Journal")
        let month = try JSONDecoder().decode(DailyNotesSettings.self, from: Data(#"{"subfolders":"month"}"#.utf8))
        XCTAssertEqual(month.subfolders, .month)
    }

    func testPathUsesTodayOrTheGivenDate() throws {
        let notes = daily()
        XCTAssertEqual(try notes.path(for: nil), "Daily/2026-10-18.md")
        XCTAssertEqual(try notes.path(for: "2025-01-02"), "Daily/2025-01-02.md")
        XCTAssertNil(try notes.read(date: nil))
    }

    func testInvalidDatesAreRejected() {
        let notes = daily()
        for bad in ["2026-13-01", "2026-02-30", "18-10-2026", "tomorrow", "../x"] {
            XCTAssertThrowsError(try notes.path(for: bad), bad) { error in
                XCTAssertEqual(error as? DailyNotesError, .invalidDate(bad))
            }
        }
    }

    func testAppendCreatesTheNoteThenAddsParagraphs() throws {
        let notes = daily()
        try notes.append("Met Bob", date: nil)
        try notes.append("Call Alice\n", date: nil)
        XCTAssertEqual(try vault.read("Daily/2026-10-18.md"), "Met Bob\n\nCall Alice\n")
    }

    func testTemplateIsUsedWithTheDateSubstituted() throws {
        try vault.write(".loam/templates/daily.md", "# {{date}}\n\n## Notes\n")
        try daily().append("Idea", date: "2026-10-20")
        XCTAssertEqual(try vault.read("Daily/2026-10-20.md"), "# 2026-10-20\n\n## Notes\n\nIdea\n")
    }

    func testPrependGoesBelowTheTitle() throws {
        let notes = daily()
        try notes.append("Met Bob", date: nil)
        try notes.prepend("Top", date: nil)
        XCTAssertEqual(try vault.read("Daily/2026-10-18.md"), "Top\n\nMet Bob\n")
    }

    func testPrependCreatesTheNoteToo() throws {
        try daily().prepend("Top", date: "2026-01-01")
        XCTAssertEqual(try vault.read("Daily/2026-01-01.md"), "Top\n")
    }

    func testEnsureCreatesFromTheTemplateAndNeverOverwrites() throws {
        try vault.write(".loam/templates/daily.md", "# {{date}}\n\n## Notes\n")
        let notes = daily()
        XCTAssertEqual(try notes.ensure(date: nil), "Daily/2026-10-18.md")
        XCTAssertEqual(try vault.read("Daily/2026-10-18.md"), "# 2026-10-18\n\n## Notes\n")
        try vault.write("Daily/2026-10-18.md", "Mine\n")
        XCTAssertEqual(try notes.ensure(date: "2026-10-18"), "Daily/2026-10-18.md")
        XCTAssertEqual(try vault.read("Daily/2026-10-18.md"), "Mine\n")
        XCTAssertThrowsError(try notes.ensure(date: "2026-02-30"))
    }

    func testEnsureWritesNothingWhenThereIsNothingToWrite() throws {
        let notes = daily()
        XCTAssertEqual(try notes.ensure(date: nil), "Daily/2026-10-18.md")
        XCTAssertFalse(vault.exists("Daily/2026-10-18.md"), "an empty daily note does not exist")
        try vault.write(".loam/templates/daily.md", "---\ntags: [daily]\n---\n")
        XCTAssertEqual(try notes.ensure(date: nil), "Daily/2026-10-18.md")
        XCTAssertFalse(vault.exists("Daily/2026-10-18.md"), "nor one holding only its template's properties")
    }

    func testStartingTextIsTheTemplateWithTheDay() throws {
        let notes = daily()
        XCTAssertEqual(try notes.startingText(for: nil), "")
        try vault.write(".loam/templates/daily.md", "## {{date}}\n")
        XCTAssertEqual(try notes.startingText(for: "2026-03-04"), "## 2026-03-04\n")
        XCTAssertThrowsError(try notes.startingText(for: "2026-02-30"))
        XCTAssertFalse(vault.exists("Daily/2026-03-04.md"), "reading the text creates nothing")
    }

    func testExistingDatesListsValidDailyNotesByMonth() throws {
        let notes = daily()
        XCTAssertEqual(try notes.existingDates(in: "2026-10"), [], "no Daily folder yet")
        for name in ["2026-10-18", "2026-10-01", "2026-09-30", "2026-11-02", "2026-02-30", "notes", "2026-10-05.txt"] {
            try vault.write("Daily/\(name)\(name.hasSuffix(".txt") ? "" : ".md")", "x\n")
        }
        try vault.write("Daily/2026-10-07/inner.md", "x\n")
        try vault.write("2026-10-09.md", "outside the folder\n")
        XCTAssertEqual(try notes.existingDates(in: "2026-10"), ["2026-10-01", "2026-10-18"])
        XCTAssertEqual(try notes.existingDates(in: nil), ["2026-09-30", "2026-10-01", "2026-10-18", "2026-11-02"])
        for bad in ["2026-13", "2026-1", "2026", "x"] {
            XCTAssertThrowsError(try notes.existingDates(in: bad), bad) { error in
                XCTAssertEqual(error as? DailyNotesError, .invalidMonth(bad))
            }
        }
    }

    func testEnsureAndListCommands() async throws {
        let kernel = Kernel(vault: vault)
        let host = PluginHost(kernel: kernel)
        try host.register(DailyNotesPlugin.self)
        try host.activateAll()
        defer { host.deactivateAll() }

        let ensure = try XCTUnwrap(kernel.commands.command(id: "daily.ensure"))
        let path = try await ensure.handler(["date": "2026-03-04"])
        XCTAssertEqual(path, "Daily/2026-03-04.md")
        XCTAssertFalse(vault.exists(path), "no template, nothing to write: an empty note does not exist")
        try vault.write(".loam/templates/daily.md", "## {{date}}\n")
        _ = try await ensure.handler(["date": "2026-03-04"])
        XCTAssertEqual(try vault.read(path), "## 2026-03-04\n")
        _ = try await ensure.handler(["date": "2026-04-01"])
        let list = try XCTUnwrap(kernel.commands.command(id: "daily.list"))
        let all = try await list.handler([:])
        XCTAssertEqual(all, "[\"2026-03-04\",\"2026-04-01\"]")
        let march = try await list.handler(["month": "2026-03"])
        XCTAssertEqual(march, "[\"2026-03-04\"]")
    }

    func testCommandsWorkThroughThePluginHost() async throws {
        let kernel = Kernel(vault: vault)
        let host = PluginHost(kernel: kernel)
        try host.register(DailyNotesPlugin.self)
        try host.activateAll()

        let append = try XCTUnwrap(kernel.commands.command(id: "daily.append"))
        let path = try await append.handler(["text": "Hello", "date": "2026-03-04"])
        XCTAssertEqual(path, "Daily/2026-03-04.md")
        let read = try XCTUnwrap(kernel.commands.command(id: "daily.read"))
        let contents = try await read.handler(["date": "2026-03-04"])
        XCTAssertEqual(contents, "Hello\n")
        let missing = try await read.handler(["date": "2020-01-01"])
        XCTAssertEqual(missing, "")

        host.deactivateAll()
        XCTAssertNil(kernel.commands.command(id: "daily.append"))
        XCTAssertNil(kernel.services.service(.dailyNotes))
    }

    func testTheFolderAndTemplateComeFromTheSettingsAndFollowThem() async throws {
        let config = try ConfigStore(vault: vault)
        try config.mutate { $0.setSettings(.map(["folder": .string("/Journal/ ")]), for: "daily-notes") }
        let kernel = Kernel(vault: vault, config: config)
        let host = PluginHost(kernel: kernel)
        try host.register(DailyNotesPlugin.self)
        try host.activateAll()
        defer { host.deactivateAll() }

        // The plugin manager learns every setting with its default, written or not.
        XCTAssertEqual(kernel.settingsDefault(for: "daily-notes"), .map([
            "folder": .string("Daily"), "template": .string(".loam/templates/daily.md"),
            "subfolders": .string("none"),
        ]))
        let path = try XCTUnwrap(kernel.commands.command(id: "daily.path"))
        let first = try await path.handler(["date": "2026-03-04"])
        XCTAssertEqual(first, "Journal/2026-03-04.md")

        try vault.write("Templates/Day.md", "# {{date}}\n")
        try config.mutate {
            $0.setSettings(.map(["folder": .string(""), "template": .string("Templates/Day.md")]), for: "daily-notes")
        }
        kernel.events.emit(PluginSettingsChanged(pluginID: "daily-notes"))
        let ensure = try XCTUnwrap(kernel.commands.command(id: "daily.ensure"))
        let second = try await ensure.handler(["date": "2026-03-05"])
        XCTAssertEqual(second, "2026-03-05.md")
        XCTAssertEqual(try vault.read("2026-03-05.md"), "# 2026-03-05\n")
    }
}
