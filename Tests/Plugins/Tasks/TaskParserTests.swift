import PluginKit
import XCTest
@testable import TasksPlugin

final class TaskParserTests: XCTestCase {
    private func parse(_ text: String, path: String = "Notes/Plan.md") -> [TaskItem] {
        TaskParser.tasks(in: text, path: path)
    }

    func testMarkersIndentAndState() {
        let text = """
        # Plan
        - [ ] dash
        * [x] star
        + [X] plus
        1. [ ] numbered
        12) [ ] paren
            - [ ] nested
        \t- [ ] tab
        - [] not a task
        - [-] cancelled is not a task
        - [ ]
        -[ ] no space
        [ ] no marker
        - [ ]no space after
        Text - [ ] in a paragraph
        """
        let tasks = parse(text)
        XCTAssertEqual(tasks.map(\.text), ["dash", "star", "plus", "numbered", "paren", "nested", "tab"])
        XCTAssertEqual(tasks.map(\.line), [2, 3, 4, 5, 6, 7, 8])
        XCTAssertEqual(tasks.map(\.done), [false, true, true, false, false, false, false])
        XCTAssertEqual(tasks[0].id, "Notes/Plan.md:2")
    }

    func testCodeBlocksAndFrontmatterAreSkipped() {
        let text = """
        ---
        tags: [a]
        note: "- [ ] in frontmatter"
        ---
        - [ ] one
        ```
        - [ ] in code
        ```
        ~~~~ swift
        - [ ] in tilde code
        ~~~
        - [ ] still code: the fence needs four tildes
        ~~~~
          ```md
          - [ ] in an indented fence
          ```
        - [ ] two
        """
        XCTAssertEqual(parse(text).map(\.text), ["one", "two"])
        XCTAssertEqual(parse(text).map(\.line), [5, 17])
    }

    func testDuePriorityTagsAndCompletion() {
        let text = """
        - [ ] Pay rent 📅 2026-10-20 #home ⏫
        - [ ] Call Bob due:2026-11-01 !low #work/calls
        - [x] Ship it !high ✅ 2026-10-17 📅 2026-10-15
        - [ ] Plain #1 and a#b and [link](a.md#part)
        - [ ] Renew due: 2026-10-20 but due:soon stays text
        - [ ] 🔽 low first
        """
        let tasks = parse(text)
        XCTAssertEqual(tasks[0], TaskItem(
            path: "Notes/Plan.md", line: 1, text: "Pay rent #home", done: false, due: "2026-10-20",
            priority: .high, tags: ["home"], project: "Notes"
        ))
        XCTAssertEqual(tasks[1].text, "Call Bob #work/calls")
        XCTAssertEqual(tasks[1].due, "2026-11-01")
        XCTAssertEqual(tasks[1].priority, .low)
        XCTAssertEqual(tasks[1].tags, ["work/calls"])
        XCTAssertEqual(tasks[2].text, "Ship it")
        XCTAssertEqual(tasks[2].completed, "2026-10-17")
        XCTAssertEqual(tasks[2].due, "2026-10-15")
        XCTAssertEqual(tasks[2].priority, .high)
        XCTAssertEqual(tasks[3].tags, ["1"])
        XCTAssertEqual(tasks[3].priority, .normal)
        XCTAssertNil(tasks[3].due)
        XCTAssertEqual(tasks[4].due, "2026-10-20", "due: with one space still reads")
        XCTAssertEqual(tasks[4].text, "Renew but due:soon stays text")
        XCTAssertEqual(tasks[5].text, "low first")
        XCTAssertEqual(tasks[5].priority, .low)
    }

    func testProjectFromFrontmatterElseFolder() {
        XCTAssertEqual(parse("- [ ] a\n", path: "Work/Q4/Plan.md").first?.project, "Work/Q4")
        XCTAssertEqual(parse("- [ ] a\n", path: "Root.md").first?.project, "")
        let cases: [(String, String)] = [
            ("project: Launch", "Launch"),
            ("project: \"Launch site\" # the big one", "Launch site"),
            ("Project: '[[Launch]]'", "Launch"),
            ("project: \"[[Projects/Launch|Launch]]\"", "Projects/Launch"),
            ("project: [Launch, Other]", "Launch"),
            ("project:\n  - Launch\n  - Other", "Launch"),
            ("project:", "Work"),
            ("project: null", "Work"),
            ("subproject: Nope", "Work"),
        ]
        for (yaml, expected) in cases {
            let text = "---\r\n\(yaml)\r\n---\r\n- [ ] a\r\n"
            XCTAssertEqual(parse(text, path: "Work/Note.md").first?.project, expected, yaml)
            XCTAssertEqual(parse(text, path: "Work/Note.md").first?.text, "a", "no \\r in the text")
        }
    }
}
