import PluginKitUI
import XCTest

final class BreadcrumbTests: XCTestCase {
    private func titles(_ segments: [Breadcrumb.Segment]) -> [String] { segments.map(\.title) }

    func testANoteShowsItsFoldersAndNotItself() {
        let trail = Breadcrumb(resource: .file("Areas/nested folder/deeper/Untitled.md"))
        XCTAssertEqual(titles(trail.folders), ["Areas", "nested folder", "deeper"])
        XCTAssertEqual(trail.folders.map(\.folder), ["Areas", "Areas/nested folder", "Areas/nested folder/deeper"])
    }

    func testAFolderShowsItsAncestorsNotItself() {
        XCTAssertEqual(titles(Breadcrumb(resource: .folder("Areas/Work/Notes")).folders), ["Areas", "Work"])
        XCTAssertTrue(Breadcrumb(resource: .folder("Areas")).isEmpty)
    }

    func testPagesInTheRootOrWithoutAPathHaveNone() {
        XCTAssertTrue(Breadcrumb(resource: .file("Untitled.md")).isEmpty)
        XCTAssertTrue(Breadcrumb(resource: .virtual("calendar:2026-10")).isEmpty)
        XCTAssertTrue(Breadcrumb(resource: .virtual("calendar:")).isEmpty)
        XCTAssertTrue(Breadcrumb(resource: .file("")).isEmpty)
    }

    func testAPageAboutANoteShowsTheNotesFolders() {
        let trail = Breadcrumb(resource: .virtual("kanban:Boards/Projects/Plan.md"))
        XCTAssertEqual(titles(trail.folders), ["Boards", "Projects"])
    }

    func testLeadingAndDoubledSlashesAreIgnored() {
        XCTAssertEqual(titles(Breadcrumb(resource: .file("/A//B/n.md")).folders), ["A", "B"])
    }

    func testCandidatesShrinkAndAlwaysKeepTheLastFolder() {
        let trail = Breadcrumb(folderNames: ["A", "B", "C", "D"])
        let candidates = trail.candidates.map(titles)
        XCTAssertEqual(candidates, [["A", "B", "C", "D"], ["A", "…", "D"], ["…", "D"], ["D"]])
        XCTAssertTrue(trail.candidates.allSatisfy { $0.last?.title == "D" })
    }

    func testShortTrailsHaveFewerCandidates() {
        XCTAssertEqual(Breadcrumb(folderNames: ["A"]).candidates.map(titles), [["A"]])
        XCTAssertEqual(Breadcrumb(folderNames: ["A", "B"]).candidates.map(titles), [["A", "B"], ["…", "B"], ["B"]])
        XCTAssertEqual(Breadcrumb(folderNames: ["A", "B", "C"]).candidates.map(titles), [["A", "B", "C"], ["A", "…", "C"], ["…", "C"], ["C"]])
        XCTAssertTrue(Breadcrumb(folderNames: []).candidates.isEmpty)
    }

    func testTheEllipsisOpensNothing() {
        let ellipsis = Breadcrumb(folderNames: ["A", "B", "C"]).candidates[1][1]
        XCTAssertTrue(ellipsis.isEllipsis)
        XCTAssertNil(ellipsis.folder)
    }
}
