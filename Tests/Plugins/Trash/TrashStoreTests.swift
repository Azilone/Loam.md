import XCTest
import PluginKit
import PluginKitTesting
@testable import TrashPlugin

/// The trash's dates, purge, restore and delete, with a clock the test moves.
final class TrashStoreTests: XCTestCase {
    private final class Clock {
        var date = Date(timeIntervalSince1970: 1_800_000_000)
        func advance(days: Double) { date = date.addingTimeInterval(days * 86_400) }
    }

    private func make(_ files: [String: String], days: Int = 30) throws -> (TemporaryVault, TrashStore, Clock) {
        let vault = try TemporaryVault()
        for (path, text) in files { try vault.write(path, text) }
        let clock = Clock()
        let store = TrashStore(vault: vault, retentionDays: { days }, now: { clock.date })
        return (vault, store, clock)
    }

    func testRecordedItemExpiresAfterRetentionAndKeepsFileDates() throws {
        let (vault, store, clock) = try make([".trash/Notes/a.md": "x"])
        try store.record(".trash/Notes/a.md")
        var items = try store.items()
        XCTAssertEqual(items.map(\.originalPath), ["Notes/a.md"])
        XCTAssertEqual(items.first?.daysLeft, 30)
        clock.advance(days: 29.5)
        items = try store.items()
        XCTAssertEqual(items.first?.daysLeft, 1)
        XCTAssertEqual(try store.purgeExpired(), [])
        clock.advance(days: 1)
        XCTAssertEqual(try store.purgeExpired(), [".trash/Notes/a.md"])
        XCTAssertFalse(vault.exists(".trash/Notes/a.md"))
        XCTAssertFalse(vault.exists(".trash/Notes"), "the emptied folder goes too")
        XCTAssertTrue(try store.items().isEmpty)
    }

    func testRecordingLeavesTheFilesOwnDatesAlone() throws {
        let (vault, store, _) = try make([".trash/a.md": "x"])
        let url = vault.url(".trash/a.md")
        let old = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        try store.record(".trash/a.md")
        _ = try store.items()
        let after = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        XCTAssertEqual(after, old)
    }

    func testUnrecordedItemCountsFromFirstSeenNotFromItsOldDate() throws {
        let (vault, store, clock) = try make([".trash/old.md": "x"])
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000_000_000)], ofItemAtPath: vault.url(".trash/old.md").path
        )
        XCTAssertEqual(try store.purgeExpired(), [], "an old note trashed by another tool is not purged at once")
        XCTAssertEqual(try store.items().first?.daysLeft, 30)
        clock.advance(days: 31)
        XCTAssertEqual(try store.purgeExpired(), [".trash/old.md"])
    }

    func testRetentionSettingAndOff() throws {
        let (_, store, clock) = try make([".trash/a.md": "x"], days: 7)
        try store.record("a.md")
        clock.advance(days: 8)
        XCTAssertEqual(try store.purgeExpired().count, 1)
        let (_, never, later) = try make([".trash/a.md": "x"], days: 0)
        try never.record("a.md")
        later.advance(days: 4000)
        XCTAssertEqual(try never.purgeExpired(), [])
        XCTAssertNil(try never.items().first?.daysLeft)
    }

    func testRestoreToOriginalPathOrFreeName() throws {
        let (vault, store, _) = try make([".trash/Notes/a.md": "trashed", "Notes/a.md": "new"])
        try store.record("Notes/a.md")
        XCTAssertEqual(try store.restore(".trash/Notes/a.md"), "Notes/a 2.md")
        XCTAssertEqual(try vault.read("Notes/a 2.md"), "trashed")
        XCTAssertEqual(try vault.read("Notes/a.md"), "new")
        XCTAssertFalse(vault.exists(".trash/Notes"))
        try vault.write(".trash/b.md", "b")
        try store.record("b.md")
        XCTAssertEqual(try store.restore("b.md"), "b.md")
        XCTAssertTrue(try store.items().isEmpty)
    }

    func testFolderIsOneItemAndRestoresWhole() throws {
        let (vault, store, _) = try make([".trash/Proj/x.md": "1", ".trash/Proj/sub/y.md": "2"])
        try store.record("Proj")
        let items = try store.items()
        XCTAssertEqual(items.map(\.path), [".trash/Proj"])
        XCTAssertTrue(items[0].isFolder)
        XCTAssertEqual(try store.restore("Proj"), "Proj")
        XCTAssertEqual(try vault.read("Proj/sub/y.md"), "2")
        XCTAssertFalse(vault.exists(".trash/Proj"))
    }

    func testDeleteForeverAndEmpty() throws {
        let (vault, store, _) = try make([".trash/a.md": "", ".trash/d/b.md": "", ".trash/d/c.md": ""])
        try store.record("a.md")
        try store.deleteForever(".trash/a.md")
        XCTAssertFalse(vault.exists(".trash/a.md"))
        XCTAssertEqual(try store.empty(), 2)
        XCTAssertTrue(try store.items().isEmpty)
        XCTAssertThrowsError(try store.deleteForever("a.md")) { XCTAssertEqual($0 as? TrashError, .notFound("a.md")) }
        XCTAssertThrowsError(try store.restore(".trash")) { XCTAssertEqual($0 as? TrashError, .notInTrash(".trash")) }
        XCTAssertThrowsError(try store.deleteForever("../x.md"))
    }

    func testIndexIsAHiddenFileAndDroppedEntriesAreForgotten() throws {
        let (vault, store, _) = try make([".trash/a.md": ""])
        try store.record("a.md")
        XCTAssertTrue(try vault.read(".trash/.trashed.json").contains("\"a.md\""))
        try FileManager.default.removeItem(at: vault.url(".trash/a.md"))
        XCTAssertTrue(try store.items().isEmpty)
        XCTAssertFalse(try vault.read(".trash/.trashed.json").contains("\"a.md\""))
    }

    func testFolderTakesTheLatestDateOfItsRecordedContent() throws {
        let (vault, store, clock) = try make([".trash/P/old.md": ""])
        try store.record("P")
        clock.advance(days: 20)
        try vault.write(".trash/P/new.md", "")
        try store.record("P/new.md")
        clock.advance(days: 15)
        XCTAssertEqual(try store.purgeExpired(), [], "the folder holds something trashed 15 days ago")
        XCTAssertEqual(try store.items().first?.daysLeft, 15)
    }

    func testRestoreGoesToTheTrueOriginalWhenTheTrashNameWasSuffixed() throws {
        let (vault, store, _) = try make([".trash/Untitled 2.md": "x"])
        try store.record(".trash/Untitled 2.md", originalPath: "Untitled.md")
        XCTAssertEqual(try store.items().first?.originalPath, "Untitled.md")
        XCTAssertEqual(try store.restore(".trash/Untitled 2.md"), "Untitled.md")
        XCTAssertTrue(vault.exists("Untitled.md"))
    }

    func testRestoreNumbersOnlyOnARealCollision() throws {
        let (vault, store, _) = try make([".trash/a 2.md": "x", "a.md": "taken"])
        try store.record(".trash/a 2.md", originalPath: "a.md")
        XCTAssertEqual(try store.restore("a 2.md"), "a 2.md")
        XCTAssertEqual(try vault.read("a.md"), "taken")
    }

    func testOldIndexOfBareDatesIsStillRead() throws {
        let (vault, store, _) = try make([
            ".trash/a.md": "x",
            ".trash/.trashed.json": #"{"version":1,"trashed":{"a.md":"2026-10-20T09:00:00Z"}}"#,
        ])
        let item = try XCTUnwrap(try store.items().first)
        XCTAssertEqual(item.trashedAt, "2026-10-20T09:00:00Z")
        XCTAssertEqual(item.originalPath, "a.md")
        XCTAssertFalse(item.firstSeen)
        XCTAssertTrue(vault.exists(".trash/a.md"))
    }

    func testItemsFoundInTheTrashAreMarkedFirstSeen() throws {
        let (_, store, _) = try make([".trash/o.md": "x", ".trash/n.md": "y"])
        try store.record("n.md")
        let seen = Dictionary(uniqueKeysWithValues: try store.items().map { ($0.originalPath, $0.firstSeen) })
        XCTAssertEqual(seen, ["o.md": true, "n.md": false])
        XCTAssertEqual(try store.items().first { $0.originalPath == "o.md" }?.firstSeen, true, "still marked next time")
    }

    func testFolderWithOnlyDSStoreLeftIsPruned() throws {
        let (vault, store, _) = try make([".trash/P/a.md": "x", ".trash/P/.DS_Store": ""])
        try store.record("P/a.md")
        _ = try store.restore("P/a.md")
        XCTAssertFalse(vault.exists(".trash/P"))
    }

    func testConcurrentWritersKeepEveryEntry() throws {
        var files: [String: String] = [:]
        for i in 0..<20 { files[".trash/n\(i).md"] = "x" }
        let (_, store, _) = try make(files)
        DispatchQueue.concurrentPerform(iterations: 20) { i in try? store.record("n\(i).md") }
        XCTAssertEqual(try store.items().count, 20)
        XCTAssertTrue(try store.items().allSatisfy { !$0.firstSeen })
    }
}
