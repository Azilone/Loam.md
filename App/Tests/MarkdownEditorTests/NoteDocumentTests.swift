import Foundation
import XCTest
@testable import MarkdownEditor

/// A note read into blocks and written back: byte for byte when nothing was edited, canonical Markdown that reads back
/// the same for what was.
final class NoteDocumentTests: XCTestCase {
    /// `LOAM_FUZZ_ROUNDS=50000 swift test --filter NoteDocumentTests` for a longer run.
    static let fuzzRounds = ProcessInfo.processInfo.environment["LOAM_FUZZ_ROUNDS"].flatMap(Int.init)

    /// Notes with every kind of block, and the odd things files hold.
    static let corpus: [String] = [
        "",
        "\n",
        "Just a line",
        "Just a line\n",
        "Two\nlines of one paragraph\n",
        "# Title\n\nA paragraph with **bold**, *italic*, `code`, ~~strike~~ and a [link](https://craft.do).\n",
        "---\nstatus: To do\ntags: [project, audit]\n---\n\n# Audit\n\nText.\n",
        "---\ntitle: x\n---\nNo blank line after the frontmatter\n",
        "- one\n- two\n  - nested\n    - deeper\n- three\n",
        "* star\n+ plus\n",
        "1. first\n2. second\n3. third\n",
        "1. first\n1. lazy\n1. numbering\n",
        "3. starts at three\n4. four\n",
        "- [ ] open\n- [x] done\n  - [ ] nested task\n",
        "- loose\n\n- list\n\n  with a second paragraph\n",
        "> a quote\n> on two lines\n\n> another\n",
        "> first paragraph\n>\n> second paragraph\n",
        "> [!NOTE]\n> A callout\n",
        "> [!WARNING] With a title\n> Careful.\n>\n> Two paragraphs.\n",
        "> - a list in a quote\n> - two\n",
        "> > nested quote\n> back\n",
        "```swift\nlet x = 1\n\nlet y = 2\n```\n",
        "````\n```\nfence inside\n```\n````\n",
        "~~~\ntilde fence\n~~~\n",
        "    indented code\n    more\n",
        "Before\n\n---\n\nAfter\n",
        "| a | b |\n| --- | --- |\n| 1 | 2 |\n",
        "![](assets/picture.png)\n",
        "![alt|300](assets/picture.png)\n",
        "Inline ![img](a.png) image\n",
        "<div>\nraw html\n</div>\n",
        "<!-- a comment -->\n\nText\n",
        "Text with a [ref][r].\n\n[r]: https://example.com\n",
        "Setext\n======\n\nSub\n---\n",
        "Hard  \nbreak and\\\nanother\n",
        "Escapes \\* \\_ \\# \\[x\\]\n",
        "A <mark>highlight</mark> and <mark style=\"background: #c9e7ff\">blue</mark>\n",
        "Due 📅 2026-10-21 and done ✅ 2026-10-22\n",
        "Tags #one #two/three\n",
        "Auto <https://craft.do> link\n",
        "Trailing spaces   \n\n\n\nMany blank lines\n\n\n",
        "No final newline",
        "Windows\r\nline\r\nendings\r\n",
        "- item\n\n      code in item\n",
        "1. a\n   - b\n     1. c\n",
        "- > quote in a list\n",
        "- # heading in a list\n",
        "-\n  marker alone\n",
        "Text\n- list right after\n",
        "Emoji 😀 and accents éàü, CJK 漢字\n",
        "[![badge](b.svg)](https://x.y)\n",
        "Footnote[^1]\n\n[^1]: The note.\n",
        "Term with *nested **bold** inside*\n",
        "***both***\n",
        "See.\n    ",
        "> - [x] a task in a quote\n> - [ ] open\n",
        "An ==Obsidian highlight== and a==b\n",
        "A [[Note]], [[Note|alias]], ![[Note#Part]] and \\[[not a link]]\n",
        "Math $E = mc^2$, a price $5 and $6, $$x$$\n\n$$\n\\frac{\\sqrt{\\pi}}{2}\\,dx\n$$\n",
        "%%hidden%%\n\nText %%inline%% after\n",
        "<u>under</u> x<sup>2</sup> H<sub>2</sub>O <kbd>Cmd</kbd>\n",
        "<details>\n<summary>More</summary>\n\nInside.\n\n</details>\n",
        "> [!info]- Folded\n> Hidden.\n\n> > nested\n",
    ]

    func testATagAtTheStartOfALineIsWrittenAsATag() {
        // `#tag` is no heading (it has no space): escaping it made it plain text for every other tool.
        XCTAssertEqual(InlineWriter.escape("#test", atLineStart: true, before: nil, after: nil), "#test")
        XCTAssertEqual(InlineWriter.escape("# title", atLineStart: true, before: nil, after: nil), "\\# title")
        XCTAssertEqual(InlineWriter.escape("#", atLineStart: true, before: nil, after: nil), "\\#")
    }

    func testEveryNoteOfTheCorpusIsWrittenBackByteForByte() {
        for markdown in Self.corpus {
            XCTAssertEqual(NoteDocument(markdown: markdown).markdown, markdown, "\(markdown.debugDescription)")
        }
    }

    /// The lines each block takes, counted while it is written, are those reading the Markdown again finds.
    func testTheLinesCountedWhileWritingAreThoseOfAReading() {
        func read(_ markdown: String) -> [Int] {
            let document = NoteDocument(markdown: markdown)
            func count(_ text: String) -> Int { text.utf8.filter { $0 == 10 }.count }
            var line = 1 + count(document.frontmatter)
            var result: [Int] = []
            for block in document.blocks {
                line += count(block.before)
                let length = max(1, count(block.source?.lines ?? "\n"))
                result += [line, line + length - 1]
                line += length
            }
            return result
        }
        for markdown in Self.corpus {
            let written = NoteWriter.lines(of: NoteDocument(markdown: markdown))
            XCTAssertEqual(written.markdown, markdown)
            XCTAssertEqual(written.lines.flatMap { [$0.first, $0.last] }, read(markdown), "\(markdown.debugDescription)")
        }
    }

    /// A long note opens with its first part read (`NoteReader.headLength`): those blocks must be the first blocks
    /// of the whole note, read the same.
    func testTheFirstPartOfALongNoteReadsAsTheStartOfTheWhole() throws {
        func same(_ a: NoteBlock, _ b: NoteBlock) -> Bool {
            a.kind == b.kind && a.text == b.text && a.depth == b.depth && a.quote == b.quote && a.callout == b.callout
        }
        func check(_ markdown: String, _ label: String) -> Bool {
            guard let cut = NoteReader.headLength(of: markdown, after: 2_000) else { return false }
            let head = NoteDocument(markdown: (markdown as NSString).substring(to: cut)).blocks
            let whole = NoteDocument(markdown: markdown).blocks
            XCTAssertGreaterThan(head.count, 0, label)
            XCTAssertTrue(whole.count >= head.count && zip(head, whole).allSatisfy(same), label)
            return true
        }
        var cuts = 0
        for (index, markdown) in Self.corpus.enumerated() {
            // Each note of the corpus repeated after a few paragraphs: the cut falls among its blocks.
            let long = String(repeating: "A paragraph to start with.\n\n", count: 70) + String(repeating: markdown + "\n\n", count: 60)
            if check(long, "corpus \(index)") { cuts += 1 }
        }
        XCTAssertGreaterThan(cuts, 0, "the corpus never cuts")
        let vault = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("TestVault")
        if let files = FileManager.default.enumerator(at: vault, includingPropertiesForKeys: nil) {
            for case let url as URL in files where url.pathExtension == "md" {
                if let markdown = try? String(contentsOf: url, encoding: .utf8) { _ = check(markdown, url.path) }
            }
        }
    }

    func testALongNoteIsNotCutInsideAFenceOrWhatReachesAcrossIt() {
        let filler = String(repeating: "A paragraph of filler text, long enough.\n\n", count: 120)
        let fenced = "# Code\n\n```\n" + filler + "```\n\nAfter the fence.\n"
        let cut = NoteReader.headLength(of: fenced, after: 100)
        XCTAssertEqual(cut, (fenced as NSString).range(of: "After the fence.").location)
        XCTAssertNil(NoteReader.headLength(of: filler + "[ref]: https://craft.do\n", after: 100), "a reference definition")
        XCTAssertNil(NoteReader.headLength(of: filler + "[^1]: A footnote.\n", after: 100), "a footnote")
        XCTAssertNil(NoteReader.headLength(of: "<details>\n\n" + filler + "</details>\n", after: 100))
        XCTAssertNil(NoteReader.headLength(of: "Short.\n\nNote.\n", after: 100), "too short to gain")
        let listed = String(repeating: "- an item\n\n  continued in the item\n\n", count: 200)
        XCTAssertNil(NoteReader.headLength(of: listed, after: 100), "inside a list: no line starts at its first column")
    }

    /// Every note of the test vault (not a real one) comes back identical: opening and saving changes nothing.
    func testEveryNoteOfTheTestVaultIsWrittenBackByteForByte() throws {
        let vault = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("TestVault")
        guard let files = FileManager.default.enumerator(at: vault, includingPropertiesForKeys: nil) else {
            throw XCTSkip("no ~/TestVault")
        }
        var count = 0
        var different: [String] = []
        for case let url as URL in files where url.pathExtension == "md" {
            guard let markdown = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if NoteDocument(markdown: markdown).markdown != markdown { different.append(url.path) }
            count += 1
        }
        if count == 0 { throw XCTSkip("no notes in ~/TestVault") }
        XCTAssertEqual(different, [], "written back differently")
    }

    func testBlocksHoldNoSyntax() {
        let document = NoteDocument(markdown: """
        ---
        status: To do
        ---

        # Audit

        Some **bold** and a [link](https://craft.do).

        - [ ] A task
          - Nested
        1. Numbered

        > [!NOTE]
        > A callout

        ```swift
        let x = 1
        ```

        ---
        """)
        XCTAssertEqual(document.frontmatter, "---\nstatus: To do\n---\n")
        XCTAssertEqual(document.blocks.map(\.kind), [
            .heading(level: 1), .paragraph, .task(checked: false), .bullet, .numbered(start: 1), .paragraph,
            .code(language: "swift"), .divider,
        ])
        XCTAssertEqual(document.blocks.map(\.text.string), [
            "Audit", "Some bold and a link.", "A task", "Nested", "Numbered", "A callout", "let x = 1", "",
        ])
        XCTAssertEqual(document.blocks[1].text.runs, [
            InlineRun(NSRange(location: 5, length: 4), .strong),
            InlineRun(NSRange(location: 16, length: 4), .link(destination: "https://craft.do")),
        ])
        XCTAssertEqual(document.blocks[3].depth, 1)
        XCTAssertEqual(document.blocks[5].quote, 1)
        XCTAssertEqual(document.blocks[5].callout, Callout(kind: "NOTE", opens: true))
    }

    /// Syntax Markdown reads as text but the page shows as something else: atoms carrying it as written, and the
    /// HTML marks Markdown has no syntax for.
    func testNoteLinksFootnotesMathAndCommentsAreAtoms() {
        let document = NoteDocument(markdown: """
        See [[Plan|the plan]] and ![[Plan#Goals]][^1], $\\frac{a}{b}$ %%note%%.

        [^1]: The note.

        %%a comment%%

        $$
        \\int_0^1 x\\,dx
        $$

        <u>u</u><sup>2</sup><sub>3</sub><kbd>K</kbd> \\[[plain]] costs $5 and $6
        """)
        let atoms = document.blocks.map { block in block.text.runs.compactMap { run -> String? in
            if case .atom(let markdown) = run.mark { markdown } else { nil }
        } }
        XCTAssertEqual(atoms, [
            ["[[Plan|the plan]]", "![[Plan#Goals]]", "[^1]", "$\\frac{a}{b}$", "%%note%%"],
            ["[^1]: "],
            ["$$\n\\int_0^1 x\\,dx\n$$"],
            [],
        ])
        XCTAssertEqual(document.blocks[3].text.string, "u23K [[plain]] costs $5 and $6")
        XCTAssertEqual(document.blocks[3].text.runs.map(\.mark), [.underline, .superscript, .subscript, .keyboard])
        var edited = document
        edited.blocks[3].text.string = "u23K [[plain]] costs $5 and $6!"
        XCTAssertTrue(edited.markdown.hasSuffix("<u>u</u><sup>2</sup><sub>3</sub><kbd>K</kbd> \\[\\[plain\\]\\] costs \\$5 and \\$6!\n"), edited.markdown)
    }

    func testAnEditedBlockIsRewrittenAndTheRestStaysAsWritten() {
        let markdown = "#  Spaced   title\n\nFirst   *one*.\n\n- __old__ style\n- kept   as is\n"
        var document = NoteDocument(markdown: markdown)
        document.blocks[2].text = InlineText("new style", runs: [InlineRun(NSRange(location: 0, length: 3), .strong)])
        XCTAssertEqual(document.markdown, "#  Spaced   title\n\nFirst   *one*.\n\n- **new** style\n- kept   as is\n")
    }

    func testANewBlockGetsCanonicalGapsAndTheOthersKeepTheirs() {
        var document = NoteDocument(markdown: "A\n\n\n\nB\n- one\n- two\n")
        document.blocks.insert(NoteBlock(id: 100, kind: .bullet, text: "new"), at: 3)
        XCTAssertEqual(document.markdown, "A\n\n\n\nB\n- one\n- new\n- two\n")
        document.blocks.insert(NoteBlock(id: 101, kind: .paragraph, text: "between"), at: 1)
        XCTAssertEqual(document.markdown, "A\n\nbetween\n\nB\n- one\n- new\n- two\n")
    }

    func testNumbersFollowTheList() {
        var document = NoteDocument(markdown: "1. a\n2. b\n3. c\n")
        document.blocks.remove(at: 1)
        XCTAssertEqual(document.markdown, "1. a\n2. c\n")
    }

    func testAnItemNestedUnderANumberedOneIsIndentedToItsText() {
        var document = NoteDocument(markdown: "10. ten\n")
        document.blocks.append(NoteBlock(id: 50, kind: .bullet, depth: 1, text: "under"))
        XCTAssertEqual(document.markdown, "10. ten\n    - under\n")
    }

    func testDeletingABlockKeepsTheReferenceDefinitionsBeforeIt() {
        var document = NoteDocument(markdown: "A [x][r]\n\n[r]: https://e.com\n\nB\n\nC\n")
        document.blocks.remove(at: 1)
        let written = document.markdown
        XCTAssertTrue(written.contains("[r]: https://e.com\n"), written)
        XCTAssertEqual(NoteDocument(markdown: written).blocks.map(\.text.string), ["A x", "C"])
    }

    func testAnEmptyParagraphWritesNothing() {
        var document = NoteDocument(markdown: "A\n\nB\n")
        document.blocks.insert(NoteBlock(id: 9, kind: .paragraph), at: 1)
        XCTAssertEqual(document.markdown, "A\n\nB\n")
    }

    func testSyntaxTypedAsTextIsEscaped() {
        var document = NoteDocument()
        let typed = ["# not a heading", "- not a list", "1. not a number", "> not a quote", "**not bold**", "a_b_c and _x_",
                     "<b>not html</b>", "[not](a link)", "`not code`", "~~not strike~~", "&amp; stays", "C:\\Users\\me", "==",
                     "---", "+ plus"]
        document.blocks = typed.enumerated().map { NoteBlock(id: $0.offset + 1, kind: .paragraph, text: InlineText($0.element)) }
        let read = NoteDocument(markdown: document.markdown)
        XCTAssertEqual(read.blocks.map(\.text.string), typed, document.markdown)
        XCTAssertTrue(read.blocks.allSatisfy { $0.kind == .paragraph && $0.text.runs.isEmpty }, document.markdown)
    }

    func testMarksMarkdownCannotSayAreWrittenAsTags() {
        // A strong ending in punctuation before a letter: `**"a"**b` would not close.
        let text = InlineText("\"a\"b", runs: [InlineRun(NSRange(location: 0, length: 3), .strong)])
        var document = NoteDocument()
        document.blocks = [NoteBlock(id: 1, kind: .paragraph, text: text)]
        XCTAssertEqual(NoteDocument(markdown: document.markdown).blocks.first?.text, text, document.markdown)
    }

    /// Any text with any marks, in any kind of block, reads back as written (once prepared: no spaces at the ends of
    /// lines or inside markers).
    func testRandomTextWithRandomMarksReadsBackTheSame() {
        var generator = SystemRandomNumberGenerator()
        let alphabet = Array("ab cd*_`[]()<>!#-+=.1~&;\\|\"'éà😀$%^") + [InlineText.lineBreak]
        let marks: [InlineMark] = [.strong, .emphasis, .strikethrough, .code, .highlight(color: nil), .underline, .superscript,
                                   .subscript, .keyboard,
                                   .highlight(color: "#c9e7ff"), .link(destination: "https://x.y/a_b")]
        let kinds: [BlockKind] = [.paragraph, .heading(level: 2), .bullet, .numbered(start: 1), .task(checked: true)]
        var failures = 0
        for round in 0..<(Self.fuzzRounds ?? 3000) {
            let string = String((0..<Int.random(in: 1...16, using: &generator)).map { _ in alphabet.randomElement(using: &generator)! })
            // Marks start and end between characters, as they do in a text view.
            var boundaries = [0]
            for character in string { boundaries.append(boundaries.last! + character.utf16.count) }
            var runs: [InlineRun] = []
            for _ in 0..<Int.random(in: 0...3, using: &generator) {
                let start = Int.random(in: 0..<(boundaries.count - 1), using: &generator)
                let end = Int.random(in: (start + 1)..<boundaries.count, using: &generator)
                runs.append(InlineRun(NSRange(location: boundaries[start], length: boundaries[end] - boundaries[start]),
                                      marks.randomElement(using: &generator)!))
            }
            let kind = kinds.randomElement(using: &generator)!
            var block = NoteBlock(id: 1, kind: kind, quote: Int.random(in: 0...1, using: &generator), text: InlineText(string, runs: runs))
            var document = NoteDocument()
            document.blocks = [block]
            let written = document.markdown
            block.text = InlineWriter.prepared(block.text)
            if case .heading = kind { block.text.string = block.text.string.replacingOccurrences(of: "\u{2028}", with: " ") }
            let read = NoteDocument(markdown: written).blocks
            // A block whose text is all spaces writes nothing, which reads as no block.
            if block.text.string.isEmpty, kind == .paragraph { continue }
            if read.count != 1 || read[0].text != block.text || read[0].kind != kind {
                failures += 1
                if failures <= 5 {
                    XCTFail("round \(round): \(block.text) in \(kind) wrote \(written.debugDescription), read \(read.map { ($0.kind, $0.text) })")
                }
            }
        }
        XCTAssertEqual(failures, 0)
    }

    /// Any sequence of blocks made in the editor (kinds, list depths, quotes, callouts) reads back as the same blocks:
    /// the gaps and indents written keep each block where it was.
    func testRandomBlocksReadBackAsTheSameBlocks() {
        var generator = SystemRandomNumberGenerator()
        let kinds: [BlockKind] = [.paragraph, .heading(level: 1), .heading(level: 3), .bullet, .numbered(start: 1),
                                  .task(checked: false), .task(checked: true), .code(language: "swift"), .divider]
        let words = ["alpha", "beta **x**", "1. one", "- dash", "> gt", "# hash", "`tick`", "[a](b)", "😀", "a_b"]
        var failures = 0
        for round in 0..<(Self.fuzzRounds ?? 1500) {
            var blocks: [NoteBlock] = []
            var depth = 0
            var quote = 0
            for index in 0..<Int.random(in: 1...8, using: &generator) {
                let kind = kinds.randomElement(using: &generator)!
                let previousQuote = quote
                if Int.random(in: 0..<4, using: &generator) == 0 { quote = quote == 0 ? 1 : 0 }
                // An item can nest one deeper than the item above it in the same quote; anything else starts at the
                // top of a list.
                let previousIsItem = blocks.last?.kind.isListItem == true && previousQuote == quote
                if kind.isListItem {
                    depth = previousIsItem ? Int.random(in: 0...min(depth + 1, 3), using: &generator) : 0
                } else {
                    depth = 0
                }
                let text = kind == .divider ? "" : words.shuffled(using: &generator).prefix(Int.random(in: 1...3, using: &generator)).joined(separator: " ")
                blocks.append(NoteBlock(id: index + 1, kind: kind, depth: depth, quote: quote, text: InlineText(text)))
            }
            var document = NoteDocument()
            document.blocks = blocks
            let written = document.markdown
            let read = NoteDocument(markdown: written).blocks
            let expected = blocks.map { ($0.kind, $0.depth, $0.quote, InlineWriter.prepared($0.text).string) }
            let got = read.map { ($0.kind, $0.depth, $0.quote, $0.text.string) }
            if expected.count != got.count || zip(expected, got).contains(where: { $0.0 != $1.0 || $0.1 != $1.1 || $0.2 != $1.2 || $0.3 != $1.3 }) {
                failures += 1
                if failures <= 5 { XCTFail("round \(round): wrote \(written.debugDescription)\nexpected \(expected)\ngot \(got)") }
            }
        }
        XCTAssertEqual(failures, 0)
    }
}
