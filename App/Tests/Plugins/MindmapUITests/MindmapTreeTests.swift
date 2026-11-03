import CoreGraphics
import XCTest
@testable import MindmapUI

/// The mindmap format, the outline of a note with sections, and the layout, as pure functions.
final class MindmapTreeTests: XCTestCase {
    private let map = """
        ---
        mindmap-plugin: basic
        mindmap-layout: logic
        ---

        # Project

        - Ideas
        \t- [[Some note|A note]]
        \t- **Bold** idea
        - Tasks
          - Ship v1
            continued on a second line

        Some text after the list.

        """

    private func texts(_ topic: MindTopic) -> [String] { topic.all.map(\.text) }

    func testParsesTheCentralTopicAndTheNestedList() {
        let doc = MindmapDocument.parse(map, title: "file")
        XCTAssertEqual(doc.root.text, "Project")
        XCTAssertEqual(doc.root.children.map(\.text), ["Ideas", "Tasks"])
        XCTAssertEqual(doc.root.children[0].children.map(\.text), ["[[Some note|A note]]", "**Bold** idea"])
        XCTAssertEqual(doc.root.children[1].children.map(\.text), ["Ship v1 continued on a second line"])
        XCTAssertEqual(doc.extra, "Some text after the list.")
        XCTAssertEqual(doc.layout, .logic)
        XCTAssertTrue(MindmapDocument.hasFlag(map))
    }

    func testWritesBackTheSameFormat() {
        let doc = MindmapDocument.parse(map, title: "file")
        XCTAssertEqual(doc.serialized(), """
            ---
            mindmap-plugin: basic
            mindmap-layout: logic
            ---

            # Project

            - Ideas
            \t- [[Some note|A note]]
            \t- **Bold** idea
            - Tasks
            \t- Ship v1 continued on a second line

            Some text after the list.

            """)
        let again = MindmapDocument.parse(doc.serialized(), title: "file")
        XCTAssertEqual(again.serialized(), doc.serialized(), "stable")
    }

    func testANoteWithoutTitleUsesTheFileName() {
        let doc = MindmapDocument.parse("- One\n- Two\n", title: "Ideas")
        XCTAssertEqual(texts(doc.root), ["Ideas", "One", "Two"])
        XCTAssertEqual(doc.serialized(), "# Ideas\n\n- One\n- Two\n")
    }

    func testCodeBlocksAndNumberedListsAndBreaks() {
        let doc = MindmapDocument.parse("# T\n\n1. First\n2) Second\n\n---\n\n```\n- not an item\n```\n", title: "x")
        XCTAssertEqual(doc.root.children.map(\.text), ["First", "Second"])
        XCTAssertTrue(doc.extra.contains("- not an item"))
        XCTAssertTrue(doc.extra.contains("---"))
    }

    func testWhichNotesAreMindmaps() {
        XCTAssertTrue(MindmapDocument.isMindmapNote("# Title\n\n- a\n\t- b\n"))
        XCTAssertTrue(MindmapDocument.isMindmapNote("- a\n- b\n"))
        XCTAssertTrue(MindmapDocument.isMindmapNote("---\nmindmap-plugin: basic\n---\n## anything\n"))
        XCTAssertFalse(MindmapDocument.isMindmapNote("# Title\n\n## Section\n\n- a\n"))
        XCTAssertFalse(MindmapDocument.isMindmapNote("Intro\n\n# Late title\n"))
        XCTAssertTrue(MindmapDocument.isMindmapNote("# T\n\n```\n## in code\n```\n"))
    }

    func testPastedFragments() {
        let topics = MindmapDocument.parseFragment("- One\n  - One.a\n- Two\nPlain\n  # Heading child\n")
        XCTAssertEqual(topics.map(\.text), ["One", "Two", "Plain"])
        XCTAssertEqual(topics[0].children.map(\.text), ["One.a"])
        XCTAssertEqual(topics[2].children.map(\.text), ["Heading child"])
    }

    func testTheLayoutSettingGoesInTheFrontmatter() {
        var doc = MindmapDocument.parse("# T\n- a\n", title: "x")
        XCTAssertNil(doc.layout)
        doc.setLayout(.timeline)
        XCTAssertEqual(doc.serialized(), "---\nmindmap-layout: timeline\n---\n\n# T\n\n- a\n")
        doc.setLayout(.mindmap)
        XCTAssertEqual(doc.layout, .mindmap)
        XCTAssertEqual(MindmapDocument.parse("---\nmindmap-layout: balanced\n---\n# T\n", title: "x").layout, .mindmap)
    }

    func testTheSidesGoInTheFrontmatterOnlyWhenSet() {
        var doc = MindmapDocument.parse("---\nmindmap-plugin: basic\n---\n# T\n- a\n- b\n", title: "x")
        XCTAssertNil(doc.rightCount)
        doc.rightCount = 2
        XCTAssertEqual(doc.serialized(), "---\nmindmap-plugin: basic\nmindmap-right: 2\n---\n\n# T\n\n- a\n- b\n")
        XCTAssertEqual(MindmapDocument.parse(doc.serialized(), title: "x").rightCount, 2)
        doc.rightCount = 0
        XCTAssertEqual(doc.rightCount, 0)
        doc.rightCount = nil
        XCTAssertEqual(doc.serialized(), "---\nmindmap-plugin: basic\n---\n\n# T\n\n- a\n- b\n")

        var bare = MindmapDocument.parse("# T\n- a\n", title: "x")
        bare.rightCount = 1
        bare.rightCount = nil
        XCTAssertEqual(bare.serialized(), "# T\n\n- a\n", "an emptied frontmatter goes away")
        XCTAssertEqual(MindmapDocument.parse("---\nmindmap-right: \"3\"\n---\n# T\n", title: "x").rightCount, 3)
    }

    func testReusedIDsFollowTheShape() {
        let old = MindmapDocument.parse("# T\n- a\n- b\n", title: "x").root
        let new = MindmapDocument.parse("# T\n- a\n- b changed\n- c\n", title: "x").root
        MindmapDocument.reuseIDs(from: old, into: new)
        XCTAssertEqual(new.id, old.id)
        XCTAssertEqual(new.children[1].id, old.children[1].id)
        XCTAssertFalse([old.id, old.children[0].id, old.children[1].id].contains(new.children[2].id))
    }

    // MARK: - Outline of a note with sections

    func testOutlineOfHeadingsAndLists() {
        let note = """
            ---
            title: Plan
            ---
            # Plan

            ## Goals

            - Ship
              - Soon

            ```
            # not a heading
            ```

            ## Risks
            """
        let root = MindmapTree.build(text: note, title: "file")
        XCTAssertEqual(root.text, "Plan")
        XCTAssertEqual(root.children.map(\.text), ["Goals", "Risks"])
        XCTAssertEqual(root.children[0].children.map(\.text), ["Ship"])
        XCTAssertEqual(root.children[0].children[0].children.map(\.text), ["Soon"])
        XCTAssertEqual(root.children[0].line, 6, "lines count the frontmatter")
        XCTAssertEqual(MindmapTree.build(text: note, title: "f", includeLists: false).all.count, 3)
    }

    // MARK: - Layout

    private func layout(_ text: String, mode: MindmapLayoutMode, folded: Set<String> = [])
        -> (MindTopic, [String: MindmapPlacement]) {
        let root = MindmapDocument.parse(text, title: "x").root
        let placements = MindmapLayout.compute(root, mode: mode, folded: folded) { topic, depth in
            CGSize(width: 40 + CGFloat(topic.text.count) * 7, height: depth == 0 ? 40 : 24)
        }
        return (root, placements)
    }

    private let big = "# Root\n" + (1 ... 6).map { i in
        "- Branch \(i)\n" + (1 ... i).map { "\t- Leaf \(i).\($0)\n" }.joined()
    }.joined()

    func testNoTopicsOverlapInAnyLayout() {
        for mode in MindmapLayoutMode.allCases {
            let (root, placements) = layout(big, mode: mode)
            XCTAssertEqual(placements.count, root.all.count, "\(mode)")
            let frames = Array(placements.values.map(\.frame))
            for i in frames.indices {
                for j in frames.indices where i < j {
                    XCTAssertFalse(frames[i].intersects(frames[j]), "\(mode): \(frames[i]) and \(frames[j])")
                }
            }
        }
    }

    func testMindmapBalancesBothSidesAndLogicGrowsRight() {
        let (root, balanced) = layout(big, mode: .mindmap)
        let sides = Set(root.children.map { balanced[$0.id]!.direction })
        XCTAssertEqual(sides, [1, -1])
        XCTAssertEqual(balanced[root.id]!.frame.midX, 0, accuracy: 0.01)
        for child in root.children {
            let placement = balanced[child.id]!
            for leaf in child.children {
                XCTAssertEqual(balanced[leaf.id]!.direction, placement.direction, "a branch stays on its side")
                XCTAssertEqual(balanced[leaf.id]!.branch, placement.branch)
            }
        }

        let (logicRoot, logic) = layout(big, mode: .logic)
        for topic in logicRoot.all where topic !== logicRoot {
            XCTAssertGreaterThan(logic[topic.id]!.frame.minX, logic[logicRoot.id]!.frame.maxX)
        }
    }

    func testTheRightCountPutsTheFirstBranchesOnTheRight() {
        let root = MindmapDocument.parse(big, title: "x").root
        let size: (MindTopic, Int) -> CGSize = { _, depth in CGSize(width: 80, height: depth == 0 ? 40 : 24) }
        for count in [0, 2, 6] {
            let placements = MindmapLayout.compute(root, mode: .mindmap, rightCount: count, size: size)
            XCTAssertEqual(root.children.map { placements[$0.id]!.direction },
                           root.children.indices.map { $0 < count ? 1 : -1 }, "\(count)")
        }
        let logic = MindmapLayout.compute(root, mode: .logic, rightCount: 0, size: size)
        XCTAssertTrue(root.children.allSatisfy { logic[$0.id]!.direction == 1 }, "a logic chart has one side")
    }

    func testFoldingNeverMovesABranchAcross() {
        let root = MindmapDocument.parse(big, title: "x").root
        let size: (MindTopic, Int) -> CGSize = { _, _ in CGSize(width: 80, height: 24) }
        let open = MindmapLayout.compute(root, mode: .mindmap, size: size)
        let folded = MindmapLayout.compute(root, mode: .mindmap, folded: [root.children[5].id], size: size)
        XCTAssertEqual(root.children.map { open[$0.id]!.direction }, root.children.map { folded[$0.id]!.direction })
        XCTAssertEqual(MindmapLayout.balancedSplit(root, size: size),
                       root.children.filter { open[$0.id]!.direction == 1 }.count)
    }

    func testFoldedBranchesHideTheirTopics() {
        let root = MindmapDocument.parse(big, title: "x").root
        let folded = root.children[5]
        let placements = MindmapLayout.compute(root, mode: .mindmap, folded: [folded.id]) { _, _ in
            CGSize(width: 80, height: 24)
        }
        XCTAssertNotNil(placements[folded.id])
        XCTAssertTrue(folded.children.allSatisfy { placements[$0.id] == nil })
    }

    func testMeasuredSizesGrowWithTextAndWrap() {
        let short = MindmapStyle.size(of: "Hi", depth: 2)
        let long = MindmapStyle.size(of: String(repeating: "word ", count: 40), depth: 2)
        XCTAssertGreaterThan(long.width, short.width)
        XCTAssertLessThanOrEqual(long.width, MindmapStyle.maxTextWidth(depth: 2) + 20)
        XCTAssertGreaterThan(long.height, short.height, "long texts wrap")
        XCTAssertEqual(MindmapStyle.plain("**Bold** [[Note|alias]] and [[Other]]"), "Bold alias and Other")
    }
}
