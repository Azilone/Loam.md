import PluginKitUI
import SwiftUI

/// The agent's answer as Craft shows it: headings, paragraphs, bullet, numbered and task lists with Craft's 28-point
/// indent, quotes, code blocks and tables, and every reference to a note (`[[Note]]`, a link to a `.md` path, a
/// `` `Note.md` `` in code) a link that opens it (`loam-note:`), underlined as Craft's.
struct MarkdownText: View {
    let text: String
    @Environment(\.craftColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownBlocks.parse(text).enumerated()), id: \.offset) { _, block in
                view(block)
            }
        }
        .font(.ui(size: 16))
        .lineSpacing(5)
        // No text selection: a selectable Text swallows link clicks and flips the cursor to an I-beam between lines.
        // The message's copy button covers copying.
        .tint(colors.send)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func view(_ block: MarkdownBlocks.Block) -> some View {
        switch block {
        case .heading(let level, let line):
            Text(Self.inline(line, colors: colors))
                .font(.ui(size: level == 1 ? 20 : level == 2 ? 18 : 16, weight: .semibold))
                .padding(.top, 4)
        case .paragraph(let line):
            Text(Self.inline(line, colors: colors))
        case .item(let depth, let marker, let line):
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Group {
                    switch marker {
                    case .bullet: Text("•")
                    case .number(let number): Text(number).monospacedDigit()
                    case .task(let done):
                        Image(symbol: done ? "checkmark.circle.fill" : "circle")
                            .font(.ui(size: 14))
                            .foregroundStyle(done ? colors.send : colors.ink.opacity(0.45))
                    }
                }
                .frame(width: 24, alignment: .leading)
                .padding(.leading, 4)
                Text(Self.inline(line, colors: colors))
                    .strikethrough(marker == .task(true), color: colors.ink.opacity(0.4))
                    .opacity(marker == .task(true) ? 0.55 : 1)
            }
            .padding(.leading, CGFloat(depth) * 24)
        case .quote(let line):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: Corners.r(1.5)).fill(colors.ink.opacity(0.18)).frame(width: 3)
                Text(Self.inline(line, colors: colors)).opacity(0.75)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 13, design: .monospaced))
                    .lineSpacing(3)
                    .padding(12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Corners.r(10), style: .continuous).fill(colors.chip))
        case .table(let rows):
            MarkdownTable(rows: rows)
        case .rule:
            Rectangle().fill(colors.ink.opacity(0.1)).frame(height: 1).padding(.vertical, 4)
        }
    }

    /// Inline Markdown, with notes as links. A note's link is the accent colour, semibold, without underline.
    static func inline(_ text: String, colors: CraftColors) -> AttributedString {
        var source = text.replacing(/\[\[([^\]|]+)(?:\|([^\]]+))?\]\]/) { match in
            let target = String(match.output.1)
            return "[\(match.output.2.map(String.init) ?? target)](\(noteURL(target)))"
        }
        // A link to a note's path: `[Plan](Projects/Plan.md)`.
        source = source.replacing(/\]\(((?!https?:|mailto:|loam-note:)[^)\s]+\.md)\)/) { match in
            "](\(noteURL(String(match.output.1).removingPercentEncoding ?? String(match.output.1))))"
        }
        // A note named in code: `Plan.md`.
        source = source.replacing(/`([^`\n]+\.md)`/) { match in
            let path = String(match.output.1)
            let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            return "[\(name)](\(noteURL(path)))"
        }
        var attributed = (try? AttributedString(
            markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
        for run in attributed.runs {
            if let url = run.link, url.scheme == "loam-note" {
                // A note's link: the accent colour, semibold, over an accent underline.
                attributed[run.range].foregroundColor = colors.send
                attributed[run.range].font = .ui(size: 16, weight: .semibold)
                attributed[run.range].underlineStyle = Text.LineStyle(pattern: .solid, color: colors.send.opacity(0.45))
            }
            if run.inlinePresentationIntent?.contains(.code) == true {
                attributed[run.range].font = .system(size: 14, design: .monospaced)
                attributed[run.range].backgroundColor = colors.chip
            }
        }
        return attributed
    }

    static func noteURL(_ target: String) -> String {
        "loam-note:" + (target.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? target)
    }
}

/// A GFM table: a tinted header, hairlines between rows, inside Craft's rounded frame.
private struct MarkdownTable: View {
    let rows: [[String]]
    @Environment(\.craftColors) private var colors

    var body: some View {
        let columns = rows.map(\.count).max() ?? 0
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { column in
                            Text(MarkdownText.inline(column < row.count ? row[column] : "", colors: colors))
                                .font(.ui(size: 14, weight: index == 0 ? .semibold : .regular))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .frame(minWidth: 60, maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                                .background(index == 0 ? colors.chip : .clear)
                        }
                    }
                    if index < rows.count - 1 {
                        Rectangle().fill(colors.ink.opacity(0.08)).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Corners.r(10), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Corners.r(10), style: .continuous).strokeBorder(colors.ink.opacity(0.1)))
    }
}

/// The block structure of an answer, read line by line: enough Markdown for what agents write.
enum MarkdownBlocks {
    enum Marker: Equatable {
        case bullet
        case number(String)
        case task(Bool)
    }

    enum Block: Equatable {
        case heading(Int, String)
        case paragraph(String)
        case item(depth: Int, marker: Marker, String)
        case quote(String)
        case code(String)
        case table([[String]])
        case rule
    }

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var code: [String]?
        var table: [[String]] = []
        var paragraph: [String] = []

        func flushParagraph() {
            // A single newline breaks the line, as in Craft's and every chat's answers (a poem keeps its lines).
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }
        func flushTable() {
            if !table.isEmpty { blocks.append(.table(table)) }
            table = []
        }

        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let open = code {
                    blocks.append(.code(open.joined(separator: "\n")))
                    code = nil
                } else {
                    flushParagraph()
                    flushTable()
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(raw)
                continue
            }
            if line.hasPrefix("|") {
                flushParagraph()
                let cells = line.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                    .components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                // The `| --- | :-: |` line under the header.
                if !cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } && !$0.isEmpty }) { table.append(cells) }
                continue
            }
            flushTable()
            if line.isEmpty {
                flushParagraph()
                continue
            }
            let depth = (raw.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }) / 2
            if line == "---" || line == "***" || line == "___" {
                flushParagraph()
                blocks.append(.rule)
            } else if let match = line.firstMatch(of: /^(#{1,6})\s+(.*)$/) {
                flushParagraph()
                blocks.append(.heading(match.output.1.count, String(match.output.2)))
            } else if let match = line.firstMatch(of: /^[-*+]\s+\[([ xX])\]\s+(.*)$/) {
                flushParagraph()
                blocks.append(.item(depth: depth, marker: .task(match.output.1 != " "), String(match.output.2)))
            } else if let match = line.firstMatch(of: /^[-*+•]\s+(.*)$/) {
                flushParagraph()
                blocks.append(.item(depth: depth, marker: .bullet, String(match.output.1)))
            } else if let match = line.firstMatch(of: /^(\d+[.)])\s+(.*)$/) {
                flushParagraph()
                blocks.append(.item(depth: depth, marker: .number(String(match.output.1)), String(match.output.2)))
            } else if line.hasPrefix(">") {
                flushParagraph()
                blocks.append(.quote(line.drop { $0 == ">" || $0 == " " }.description))
            } else {
                paragraph.append(line)
            }
        }
        if let code { blocks.append(.code(code.joined(separator: "\n"))) }
        flushParagraph()
        flushTable()
        return blocks
    }
}

/// Craft's shimmer on a step that is still running: a light band sweeping across the text.
struct Shimmer: ViewModifier {
    let active: Bool
    @State private var phase: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if active && !reduceMotion {
            content
                .overlay {
                    GeometryReader { proxy in
                        LinearGradient(
                            colors: [.clear, .white.opacity(0.55), .clear],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: proxy.size.width * 0.5)
                        .offset(x: phase * proxy.size.width * 1.5)
                        .blendMode(.sourceAtop)
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                }
                .onAppear {
                    phase = -0.5
                    withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { phase = 1 }
                }
        } else {
            content
        }
    }
}

extension View {
    func shimmering(_ active: Bool) -> some View {
        modifier(Shimmer(active: active))
    }
}
