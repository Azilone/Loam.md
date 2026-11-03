import XCTest
@testable import GitSyncPlugin

final class ConflictPlanTests: XCTestCase {
    private func entry(_ path: String, _ stage: Int, oid: String? = nil, mode: String = "100644") -> Git.UnmergedEntry {
        Git.UnmergedEntry(mode: mode, oid: oid ?? "\(path)-\(stage)", stage: stage, path: path)
    }

    private func steps(_ entries: [Git.UnmergedEntry], taken: Set<String> = []) -> [ConflictPlan.Step] {
        ConflictPlan.steps(for: entries, device: "MacBook", day: "2026-10-20") { taken.contains($0) }
    }

    func testBothChangedKeepsOursAndCopiesTheirs() {
        XCTAssertEqual(steps([entry("Plan.md", 1), entry("Plan.md", 2), entry("Plan.md", 3)]), [
            .keepOursWithCopy(path: "Plan.md", oid: "Plan.md-3", copy: "Plan (conflict MacBook 2026-10-20).md"),
        ])
        XCTAssertEqual(steps([entry("New.md", 2), entry("New.md", 3)]), [
            .keepOursWithCopy(path: "New.md", oid: "New.md-3", copy: "New (conflict MacBook 2026-10-20).md"),
        ], "added on both sides")
    }

    func testAFileOnlyOneSideStillHasIsKept() {
        XCTAssertEqual(steps([entry("A.md", 1), entry("A.md", 2)]), [.keepOurs(path: "A.md")])
        XCTAssertEqual(steps([entry("B.md", 1), entry("B.md", 3)]), [.keepTheirs(path: "B.md")])
        XCTAssertEqual(steps([entry("C.md", 3)]), [.keepTheirs(path: "C.md")])
        XCTAssertEqual(steps([entry("D.md", 1)]), [.remove(path: "D.md")])
    }

    func testSymlinksAndIdenticalVersionsGetNoCopy() {
        XCTAssertEqual(steps([entry("link", 2, mode: "120000"), entry("link", 3, mode: "120000")]), [.keepOurs(path: "link")])
        XCTAssertEqual(steps([entry("Same.md", 2, oid: "x"), entry("Same.md", 3, oid: "x")]), [.keepOurs(path: "Same.md")])
    }

    func testCopyNamesKeepTheFolderAndExtensionAndNeverCollide() {
        let taken: Set = ["Ideas/Plan (conflict MacBook 2026-10-20).md"]
        XCTAssertEqual(steps([entry("Ideas/Plan.md", 2), entry("Ideas/Plan.md", 3)], taken: taken).first, .keepOursWithCopy(
            path: "Ideas/Plan.md", oid: "Ideas/Plan.md-3", copy: "Ideas/Plan (conflict MacBook 2026-10-20 2).md"
        ))
        XCTAssertEqual(ConflictPlan.copyPath(for: "img/photo.png", device: "A", day: "2026-10-20") { _ in false },
                       "img/photo (conflict A 2026-10-20).png")
        XCTAssertEqual(ConflictPlan.copyPath(for: ".gitignore", device: "A", day: "2026-10-20") { _ in false },
                       ".gitignore (conflict A 2026-10-20)")
        XCTAssertEqual(ConflictPlan.copyPath(for: "Makefile", device: "A", day: "2026-10-20") { _ in false },
                       "Makefile (conflict A 2026-10-20)")
        let two = steps([entry("x/A.md", 2), entry("x/A.md", 3), entry("x/A.md ", 2), entry("x/A.md ", 3)])
        XCTAssertEqual(Set(two.compactMap { if case .keepOursWithCopy(_, _, let copy) = $0 { return copy } else { return nil } }).count, 2)
    }

    func testCopiesAreRecognised() {
        XCTAssertTrue(ConflictPlan.isCopy("Ideas/Plan (conflict MacBook 2026-10-20).md"))
        XCTAssertTrue(ConflictPlan.isCopy("Plan (conflict A b 2026-10-20 3).md"))
        XCTAssertTrue(ConflictPlan.isCopy("Makefile (conflict A 2026-10-20)"))
        XCTAssertFalse(ConflictPlan.isCopy("Plan.md"))
        XCTAssertFalse(ConflictPlan.isCopy("Notes on conflict 2026-10-20.md"))
    }

    func testOnlyCopiesWhoseNoteExistsCount() {
        XCTAssertEqual(ConflictPlan.original(of: "x/Plan (conflict A 2026-10-20 2).md"), "x/Plan.md")
        XCTAssertEqual(ConflictPlan.original(of: "Makefile (conflict A 2026-10-20)"), "Makefile")
        XCTAssertNil(ConflictPlan.original(of: "Plan.md"))
        XCTAssertEqual(ConflictPlan.copies(in: ["Plan.md", "Plan (conflict A 2026-10-20).md",
                                                "Talk (conflict B 2026-01-01).md"]),
                       ["Plan (conflict A 2026-10-20).md"])
    }

    func testDeviceNamesFitInAFileName() {
        XCTAssertEqual(ConflictPlan.clean("Kévin's Mac/Pro: (2)"), "Kévin's Mac Pro 2")
        XCTAssertEqual(ConflictPlan.clean(" / "), "device")
    }

    private func json(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }
    private func object(_ data: Data?) -> NSDictionary { (try! JSONSerialization.jsonObject(with: data!)) as! NSDictionary }

    func testSettingsMergeKeyByKey() {
        let base = json(["plugins": ["a": ["x": 1, "y": 1], "b": ["z": 1]]])
        let ours = json(["plugins": ["a": ["x": 2, "y": 1], "b": ["z": 1]]])
        let theirs = json(["plugins": ["a": ["x": 1, "y": 3], "b": ["z": 1], "c": ["w": 1]]])
        let merged = object(ConflictPlan.mergeJSON(base: base, ours: ours, theirs: theirs))
        XCTAssertEqual(merged, ["plugins": ["a": ["x": 2, "y": 3], "b": ["z": 1], "c": ["w": 1]]] as NSDictionary)
        let both = object(ConflictPlan.mergeJSON(base: base, ours: json(["plugins": ["a": ["x": 5]]]),
                                                 theirs: json(["plugins": ["a": ["x": 9]]])))
        XCTAssertEqual((both["plugins"] as! NSDictionary)["a"] as! NSDictionary, ["x": 5], "both changed: ours")
    }

    func testAJoiningDeviceKeepsTheVaultsSettings() {
        let vaults = json(["squeeze": ["ffmpegPath": "/opt/homebrew/bin/ffmpeg"], "git-sync": ["auto": true]])
        let joining = json(["squeeze": ["ffmpegPath": ""], "meetings": ["myName": "Me"]])
        let merged = object(ConflictPlan.mergeJSON(base: nil, ours: joining, theirs: vaults))
        XCTAssertEqual(merged, ["squeeze": ["ffmpegPath": "/opt/homebrew/bin/ffmpeg"], "git-sync": ["auto": true],
                                "meetings": ["myName": "Me"]] as NSDictionary)
        XCTAssertNil(ConflictPlan.mergeJSON(base: nil, ours: Data("not json".utf8), theirs: vaults))
        XCTAssertTrue(ConflictPlan.isSettings(".loam/config.json"))
        XCTAssertFalse(ConflictPlan.isSettings("Notes/config.json"))
    }
}
