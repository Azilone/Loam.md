import XCTest
@testable import MarkdownEditor

/// The incremental spans must be what a full parse finds, whatever the edit: the editor trusts them.
final class IncrementalSpansTests: XCTestCase {
    /// A note with most of what the editor styles, and what reaches across blank lines.
    private let note = """
    ---
    title: Mixed
    tags: [a, b]
    ---
    # Title

    A paragraph with **bold**, *italic*, `code`, ~~strike~~ and a [link](https://example.com).
    Another line with #tag and a date 📅 2026-10-21.

    ## Lists

    - one
    - two
      - nested
    - [ ] task 📅 2026-10-22
    - [x] done ✅ 2026-10-20

    1. first

    2. second after a blank line

    - loose

    - items

    > a quote
    > over two lines

    > [!NOTE]
    > an alert

    ```swift
    let a = 1

    let b = 2
    ```

    | a | b |
    |---|---|
    | 1 | 2 |

    <mark>highlight</mark> and <!-- a comment -->

    [ref]: https://example.com "Title"

    A [reference link][ref] and a footnote[^1].

    [^1]: The note.

        indented code

    ![image](picture.png)

    Setext heading
    ==============

    ---

    Last paragraph, plain text only.
    """

    private func full(_ text: String) -> [StyleSpan] { MarkdownStyler.spans(in: text) }

    func testEditsGiveTheSpansOfAFullParse() {
        var generator = SystemRandomNumberGenerator()
        let alphabet = Array("ab *_`#-[]()>!|\\1.:~<=\n".utf16)
        var text = note
        var incrementalRuns = 0
        let trials = 600
        for trial in 0..<trials {
            let units = Array(text.utf16)
            let base = IncrementalSpans.Base(units: units, spans: full(text))
            var edited = units
            let at = Int.random(in: 0...units.count, using: &generator)
            if units.isEmpty || Bool.random(using: &generator) {
                edited.insert(alphabet.randomElement(using: &generator)!, at: at)
            } else if at < units.count {
                edited.remove(at: at)
            }
            let newText = String(decoding: edited, as: UTF16.self)
            if let incremental = IncrementalSpans.spans(for: newText, units: edited, after: base) {
                incrementalRuns += 1
                XCTAssertEqual(Set(incremental), Set(full(newText)), "trial \(trial): edit at \(at) of \(newText.count)")
                XCTAssertEqual(incremental.count, full(newText).count, "trial \(trial): same number of spans")
            }
            // Keep the text near the note: most edits are undone, so the document keeps its shape.
            if trial % 3 == 2 { text = note } else { text = newText }
        }
        XCTAssertGreaterThan(incrementalRuns, trials / 4, "the incremental path is taken for plain edits")
    }

    func testTypingInAParagraphKeepsTheOtherSpans() throws {
        let units = Array(note.utf16)
        let base = IncrementalSpans.Base(units: units, spans: full(note))
        let target = (note as NSString).range(of: "Last paragraph")
        var edited = units
        edited.insert(120, at: target.location + 4)
        let newText = String(decoding: edited, as: UTF16.self)
        let incremental = try XCTUnwrap(IncrementalSpans.spans(for: newText, units: edited, after: base))
        XCTAssertEqual(Set(incremental), Set(full(newText)))
    }

    func testTypingInTheTitleAfterTheFrontmatterIsIncremental() throws {
        let units = Array(note.utf16)
        let base = IncrementalSpans.Base(units: units, spans: full(note))
        var edited = units
        edited.insert(120, at: (note as NSString).range(of: "# Title").location + 3)
        let newText = String(decoding: edited, as: UTF16.self)
        let incremental = try XCTUnwrap(IncrementalSpans.spans(for: newText, units: edited, after: base))
        XCTAssertEqual(Set(incremental), Set(full(newText)))
        // An edit inside the frontmatter parses everything.
        var inYAML = units
        inYAML.insert(120, at: (note as NSString).range(of: "Mixed").location)
        XCTAssertNil(IncrementalSpans.spans(for: String(decoding: inYAML, as: UTF16.self), units: inYAML, after: base))
    }

    func testAnEditWithALineBreakOrInACodeBlockParsesEverything() {
        let units = Array(note.utf16)
        let base = IncrementalSpans.Base(units: units, spans: full(note))
        var withBreak = units
        withBreak.insert(10, at: (note as NSString).range(of: "Last paragraph").location + 4)
        XCTAssertNil(IncrementalSpans.spans(for: String(decoding: withBreak, as: UTF16.self), units: withBreak, after: base))
        var inCode = units
        inCode.insert(120, at: (note as NSString).range(of: "let b").location + 2)
        XCTAssertNil(IncrementalSpans.spans(for: String(decoding: inCode, as: UTF16.self), units: inCode, after: base))
    }
}
