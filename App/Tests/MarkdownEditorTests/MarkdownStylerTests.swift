import Foundation
import XCTest
@testable import MarkdownEditor

final class MarkdownStylerTests: XCTestCase {
    /// The source text each span of `style` covers.
    private func texts(_ style: MarkdownStyle, in text: String) -> [String] {
        let ns = text as NSString
        return MarkdownStyler.spans(in: text).filter { $0.style == style }.map { ns.substring(with: $0.range) }
    }

    func testMarkIsAHighlightWithItsColourAndHiddenTags() {
        let text = #"a <mark>yes</mark> <mark style="background: #a2c6fa">blue</mark> `<mark>no</mark>`"#
        XCTAssertEqual(texts(.highlight(color: nil), in: text), ["yes"])
        XCTAssertEqual(texts(.highlight(color: "#a2c6fa"), in: text), ["blue"])
        XCTAssertEqual(
            texts(.concealable, in: text).filter { $0.contains("mark") },
            ["<mark>", "</mark>", #"<mark style="background: #a2c6fa">"#, "</mark>"]
        )
    }

    func testATXHeadingStylesTheLineAndDimsTheHashes() {
        let text = "## Hello world\nbody"
        XCTAssertEqual(texts(.heading(level: 2), in: text), ["## Hello world"])
        XCTAssertEqual(texts(.marker, in: text), ["## "])
    }

    func testSyntaxIsConcealedOrMadeInvisibleAndTablesStay() {
        let text = "# Title\n\na **b** [l](x.md) ![i](p.png)\n\n```\ncode\n```\n\n> quote\n\n---\n"
        XCTAssertEqual(texts(.concealable, in: text), ["# ", "**", "**", "[", "](x.md)", "![", "](p.png)", "```", "```", "> "])
        XCTAssertEqual(texts(.invisible, in: text), ["---"])
        // An image without alt text keeps its syntax: hiding it would leave nothing.
        XCTAssertEqual(texts(.concealable, in: "![](p.png)"), [])
    }

    func testFrontmatterIsHiddenButItsTags() {
        let text = "---\ntags: [a]\n---\n# Title\n"
        let block = MarkdownStyler.frontmatterRange(in: text as NSString)!
        XCTAssertEqual(texts(.concealable, in: text), ["# "])
        XCTAssertEqual(texts(.concealedOutside(block: block), in: text), ["tags: [", "]", "---\n", "---\n"])
        XCTAssertEqual(texts(.frontmatter, in: text), ["---\ntags: [a]\n---\n"])
    }

    func testFrontmatterTagsArePillsAndTheirYAMLIsHidden() {
        let text = "---\ntitle: x\ntags: [lecture, concept]\n---\nbody\n"
        let block = MarkdownStyler.frontmatterRange(in: text as NSString)!
        XCTAssertEqual(texts(.tag(frontmatter: block), in: text), ["lecture", "concept"])
        XCTAssertEqual(texts(.concealedOutside(block: block), in: text), ["tags: [", ",", "]", "---\n", "title: x\n", "---\n"])
    }

    func testFrontmatterTagsAsAListOrAString() {
        let list = "---\ntags:\n  - a\n  - '#b'\nother: c\n---\n"
        let listBlock = MarkdownStyler.frontmatterRange(in: list as NSString)!
        XCTAssertEqual(texts(.tag(frontmatter: listBlock), in: list), ["a", "b"])
        let plain = "---\ntags: a, b\n---\n"
        XCTAssertEqual(texts(.tag(frontmatter: MarkdownStyler.frontmatterRange(in: plain as NSString)!), in: plain), ["a", "b"])
    }

    func testInlineTagsButNotHeadingsCodeOrAnchors() {
        let text = "# Title\n\nSee #idea and #a/b, `#code`, [x](n.md#part), C#.\n"
        XCTAssertEqual(texts(.tag(frontmatter: nil), in: text), ["#idea", "#a/b"])
    }

    func testFrontmatterTagsShowAsYAMLWhileTheCaretIsInTheFrontmatter() {
        let text = "---\ntags: [a]\n---\nbody"
        let storage = NSTextStorage(string: text)
        let spans = MarkdownStyler.spans(in: text)
        MarkdownTheme().apply(spans, to: storage, revealing: NSRange(location: text.utf16.count, length: 0))
        XCTAssertEqual(storage.attribute(.markdownTag, at: 11, effectiveRange: nil) as? Bool, true)
        XCTAssertEqual(storage.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? NSColor, .clear, "`tags:` is hidden")
        MarkdownTheme().apply(spans, to: storage, revealing: NSRange(location: 6, length: 0))
        XCTAssertNil(storage.attribute(.markdownTag, at: 11, effectiveRange: nil))
        XCTAssertNotEqual(storage.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? NSColor, .clear)
        XCTAssertEqual(storage.string, text)
    }

    func testTheCaretRevealsOnlyTheSyntaxItIsInside() {
        let marker = NSRange(location: 2, length: 2)
        XCTAssertFalse(MarkdownTheme.reveals(NSRange(location: 2, length: 0), marker), "just before")
        XCTAssertTrue(MarkdownTheme.reveals(NSRange(location: 3, length: 0), marker))
        XCTAssertFalse(MarkdownTheme.reveals(NSRange(location: 4, length: 0), marker), "just after")
        XCTAssertTrue(MarkdownTheme.reveals(NSRange(location: 0, length: 3), marker), "a selection over it")
    }

    func testBulletsAndTaskBoxesAreDrawnInsteadOfTheirSyntax() {
        let text = "- one\n- [x] done\n"
        let storage = NSTextStorage(string: text)
        MarkdownTheme().apply(MarkdownStyler.spans(in: text), to: storage, revealing: NSRange(location: text.utf16.count, length: 0))
        XCTAssertNotNil(storage.attribute(.markdownBullet, at: 0, effectiveRange: nil))
        XCTAssertNil(storage.attribute(.markdownBullet, at: 6, effectiveRange: nil), "a task item has its box, no bullet")
        XCTAssertEqual(storage.attribute(.foregroundColor, at: 8, effectiveRange: nil) as? NSColor, .clear, "the box is drawn")
        XCTAssertEqual(storage.string, text)
    }

    func testConcealedSyntaxIsHiddenOutsideTheRevealedLines() {
        let text = "a **b**\nc **d**\n"
        let storage = NSTextStorage(string: text)
        MarkdownTheme().apply(MarkdownStyler.spans(in: text), to: storage, revealing: NSRange(location: 0, length: 8))
        func color(at index: Int) -> NSColor? { storage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor }
        XCTAssertNotEqual(color(at: 2), .clear, "the first line holds the caret")
        XCTAssertEqual(color(at: 10), .clear)
        XCTAssertNotEqual(color(at: 12), .clear, "the text itself stays")
        XCTAssertEqual(storage.string, text)
    }

    func testSetextHeadingDimsTheUnderline() {
        let text = "Title\n=====\n\nbody"
        XCTAssertEqual(texts(.heading(level: 1), in: text), ["Title"])
        XCTAssertEqual(texts(.marker, in: text), ["====="])
    }

    func testALoneDashUnderAnItemIsANestedItemNotAHeading() {
        // Return then Tab in a list: the new empty item reads as a setext underline.
        let text = "- one\n  - "
        XCTAssertTrue(texts(.heading(level: 2), in: text).isEmpty)
        XCTAssertEqual(texts(.listMarker(depth: 1), in: text), ["-"])
    }

    func testAHeadingWithNoTextShowsItsMarks() {
        let spans = MarkdownStyler.spans(in: "Intro\n\n## ")
        XCTAssertFalse(spans.contains { $0.style == .concealable })
        XCTAssertEqual(texts(.concealable, in: "## Title"), ["## "])
    }

    func testStrongAndEmphasisDimTheirDelimiters() {
        let text = "a **bold** and *it* and ~~gone~~"
        XCTAssertEqual(texts(.strong, in: text), ["**bold**"])
        XCTAssertEqual(texts(.emphasis, in: text), ["*it*"])
        XCTAssertEqual(texts(.strikethrough, in: text), ["~~gone~~"])
        XCTAssertEqual(texts(.marker, in: text), ["**", "**", "*", "*", "~~", "~~"])
    }

    func testOffsetsSurviveAccentsAndEmoji() {
        let text = "Hé 😀 **bold** `code`"
        XCTAssertEqual(texts(.strong, in: text), ["**bold**"])
        XCTAssertEqual(texts(.inlineCode, in: text), ["`code`"])
    }

    func testLinkTextIsTheLinkAndTheRestIsDimmed() {
        let text = "See [the note](Folder/Other%20note.md) now"
        XCTAssertEqual(texts(.link(destination: "Folder/Other%20note.md"), in: text), ["the note"])
        XCTAssertEqual(texts(.marker, in: text), ["[", "](Folder/Other%20note.md)"])
    }

    func testAutolinkIsAWholeLink() {
        let text = "Go to <https://example.com> please"
        XCTAssertEqual(texts(.link(destination: "https://example.com"), in: text), ["https://example.com"])
        XCTAssertEqual(texts(.concealable, in: text), ["<", ">"])
    }

    func testBoldInsideALinkIsStyled() {
        XCTAssertEqual(texts(.strong, in: "[a **b** c](x.md)"), ["**b**"])
    }

    func testListMarkersAndTaskBoxes() {
        let text = "- one\n- [ ] todo\n- [x] done\n12. twelve"
        XCTAssertEqual(texts(.listMarker(depth: 0), in: text), ["-", "-", "-", "12."])
        XCTAssertEqual(texts(.taskBox(checked: false), in: text), ["[ ]"])
        XCTAssertEqual(texts(.taskBox(checked: true), in: text), ["[x]"])
        XCTAssertEqual(texts(.completedTask, in: text), ["done"])
    }

    func testFencedCodeBlockDimsItsFences() {
        let text = "```swift\nlet x = 1\n```\nafter"
        XCTAssertEqual(texts(.codeBlock, in: text), ["```swift\nlet x = 1\n```"])
        XCTAssertEqual(texts(.marker, in: text), ["```swift", "```"])
    }

    func testAClosedFenceWithALanguageCanBeDrawnAsAPicture() {
        let text = "```Mermaid extra\nflowchart LR\n  A --> B\n```\nafter"
        let spans = MarkdownStyler.spans(in: text).filter { if case .fencedCode = $0.style { true } else { false } }
        XCTAssertEqual(spans.count, 1)
        guard case .fencedCode(let language, let code) = spans[0].style else { return XCTFail() }
        XCTAssertEqual(language, "mermaid")
        XCTAssertEqual((text as NSString).substring(with: code), "flowchart LR\n  A --> B")
        XCTAssertEqual((text as NSString).substring(with: spans[0].range), "```Mermaid extra\nflowchart LR\n  A --> B\n```")
        // The caret inside shows the code again.
        XCTAssertEqual(spans[0].revealRange, spans[0].range)

        let empty = "```mermaid\n```"
        let emptyCode = MarkdownStyler.spans(in: empty).compactMap { if case .fencedCode(_, let code) = $0.style { code } else { nil } }
        XCTAssertEqual(emptyCode.map(\.length), [0])
        // No language, or no closing fence: a code block only.
        for other in ["```\nflowchart LR\n```", "```mermaid\nflowchart LR\n", "    indented\n"] {
            XCTAssertFalse(MarkdownStyler.spans(in: other).contains { if case .fencedCode = $0.style { true } else { false } }, other)
        }
    }

    func testCodeIsNotParsedAsMarkdown() {
        XCTAssertEqual(texts(.strong, in: "```\n**not bold**\n```"), [])
    }

    func testQuoteAndAlert() {
        let text = "> [!WARNING]\n> careful\n\nafter"
        XCTAssertEqual(texts(.quote, in: text), ["> [!WARNING]\n> careful"])
        XCTAssertEqual(texts(.alert, in: text), ["[!WARNING]"])
        XCTAssertEqual(texts(.marker, in: text), ["> ", "[!", "]", "> "])
    }

    func testQuoteCoversTheEmptyLineAfterReturn() {
        XCTAssertEqual(texts(.quote, in: "> test1\n> "), ["> test1\n> "])
        XCTAssertEqual(texts(.quote, in: "> test1\n> \nafter"), ["> test1\n> "])
        XCTAssertEqual(texts(.quote, in: "> [!NOTE]\n> "), ["> [!NOTE]\n> "])
    }

    func testEmptyQuoteLineKeepsTheBodyLineHeight() throws {
        for text in ["> test1\n> ", "> [!NOTE]\n> "] {
            let storage = NSTextStorage(string: text)
            let theme = MarkdownTheme()
            let end = (text as NSString).length
            theme.apply(MarkdownStyler.spans(in: text), to: storage, revealing: NSRange(location: end, length: 0))
            let style = try XCTUnwrap(storage.attribute(.paragraphStyle, at: end - 1, effectiveRange: nil) as? NSParagraphStyle)
            XCTAssertGreaterThanOrEqual(style.minimumLineHeight, theme.bodyFont.ascender - theme.bodyFont.descender, text)
        }
    }

    func testFrontmatterIsStyledAndNotParsedAsHeadings() {
        let text = "---\ntitle: x\ntags: [a]\n---\n# Real\n"
        XCTAssertEqual(texts(.frontmatter, in: text), ["---\ntitle: x\ntags: [a]\n---\n"])
        XCTAssertEqual(texts(.heading(level: 1), in: text), ["# Real"])
        XCTAssertEqual(texts(.heading(level: 2), in: text), [])
    }

    func testATableIsOneSpanWhoseLinesTheEditorHides() {
        let text = "| a | b |\n|---|---|\n| 1 | 2 |"
        XCTAssertEqual(texts(.table, in: text), [text])
        XCTAssertEqual(texts(.marker, in: text), [], "no pipes to dim: the cells are a component's")
    }

    func testDividerIsDimmed() {
        XCTAssertEqual(texts(.marker, in: "a\n\n---\n\nb"), ["---"])
    }

    func testEmptyAndPlainTextHaveNoSpans() {
        XCTAssertEqual(MarkdownStyler.spans(in: ""), [])
        XCTAssertEqual(MarkdownStyler.spans(in: "just words"), [])
    }
}

extension MarkdownStylerTests {
    func testUnclosedFenceRunsToTheEnd() {
        let text = "intro\n\n```\ncode\n"
        let spans = MarkdownStyler.spans(in: text).filter { $0.style == .codeBlock }
        XCTAssertEqual(spans.map { ($0.range.location, NSMaxRange($0.range)) }.first?.1, (text as NSString).length)
    }

    func testTaskDatesArePills() {
        let text = "- [ ] Call 📅 2026-10-21 #work\n- [x] Done due:2026-10-19 ✅ 2026-10-19\nOn 📅 2026-10-22, `📅 2026-10-23`\n"
        let spans = MarkdownStyler.spans(in: text)
        let ns = text as NSString
        let dates = spans.compactMap { span -> String? in
            guard case .date(let day, let completion, let open) = span.style else { return nil }
            return "\(ns.substring(with: span.range))|\(day)|\(completion)|\(open)"
        }
        XCTAssertEqual(dates, [
            "📅 2026-10-21|2026-10-21|false|true",
            "due:2026-10-19|2026-10-19|false|false",
            "✅ 2026-10-19|2026-10-19|true|false",
            "📅 2026-10-22|2026-10-22|false|false",
        ])
    }

    func testADatePillHidesItsTextUnlessTheSelectionIsInIt() {
        let text = "- [ ] Call 📅 2026-10-17"
        let storage = NSTextStorage(string: text)
        let spans = MarkdownStyler.spans(in: text)
        MarkdownTheme().apply(spans, to: storage, revealing: NSRange(location: 0, length: 0), today: "2026-10-19")
        let mark = storage.attribute(.markdownDate, at: 11, effectiveRange: nil) as? DatePillMark
        XCTAssertEqual(mark?.pill.label, "Sat, Oct 17")
        XCTAssertEqual(mark?.pill.tone, .overdue)
        XCTAssertEqual(storage.attribute(.foregroundColor, at: 14, effectiveRange: nil) as? NSColor, .clear)
        MarkdownTheme().apply(spans, to: storage, revealing: NSRange(location: 14, length: 0), today: "2026-10-19")
        XCTAssertNil(storage.attribute(.markdownDate, at: 11, effectiveRange: nil))
        XCTAssertEqual(storage.string, text)
    }

    func testDatePillLabels() {
        XCTAssertEqual(DatePill.label(day: "2026-10-19", today: "2026-10-19"), "Today")
        XCTAssertEqual(DatePill.label(day: "2026-10-20", today: "2026-10-19"), "Tomorrow")
        XCTAssertEqual(DatePill.label(day: "2026-10-18", today: "2026-10-19"), "Yesterday")
        XCTAssertEqual(DatePill.label(day: "2026-10-21", today: "2026-10-19"), "Wed, Oct 21")
        XCTAssertEqual(DatePill.label(day: "2027-01-04", today: "2026-10-19"), "Jan 4, 2027")
        XCTAssertEqual(DatePill(day: "2026-10-17", today: "2026-10-19", completion: false, openTask: false).tone, .done)
        XCTAssertEqual(DatePill(day: "2026-10-21", today: "2026-10-19", completion: false, openTask: true).tone, .due)
    }
}
