import AppKit
import SwiftUI

/// A note's first blocks drawn small, as Craft's cards show a document: headings bolder, lists with bullets or
/// numbers, tasks with a box, quotes with a bar, inline bold, links and tags.
public struct NotePreviewView: View {
    let preview: NotePreview
    /// The lines one block may take; nil for all of them.
    var lineLimit: Int?
    /// The body text size; the card sizes (10) scale from it.
    var size: CGFloat
    /// Document-like headings (much larger than the text) rather than the card's, which stay close to it.
    var roomy: Bool
    /// Where the lines go across the width: a board's shapes centre their text.
    var alignment: TextAlignment
    @Environment(\.themeTokens) private var theme

    public init(_ preview: NotePreview, lineLimit: Int? = nil, size: CGFloat = 10, roomy: Bool = false) {
        self.init(preview, lineLimit: lineLimit, size: size, roomy: roomy, alignment: .leading)
    }

    /// Lines aligned across the width as `alignment` says (kept beside the first initialiser for compiled plugins).
    public init(_ preview: NotePreview, lineLimit: Int? = nil, size: CGFloat = 10, roomy: Bool = false,
                alignment: TextAlignment) {
        self.preview = preview
        self.lineLimit = lineLimit
        self.size = size
        self.roomy = roomy
        self.alignment = alignment
    }

    private var horizontal: HorizontalAlignment {
        switch alignment {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    private var frameAlignment: Alignment {
        switch alignment {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    private var k: CGFloat { size / 10 }

    public var body: some View {
        VStack(alignment: horizontal, spacing: roomy ? size * 0.4 : 3 * k) {
            ForEach(Array(preview.blocks.enumerated()), id: \.offset) { _, block in
                row(block)
            }
        }
        .font(.ui(size: size))
        .foregroundStyle(theme.text.opacity(roomy ? 0.92 : 0.82))
        .lineSpacing(roomy ? size * 0.2 : 1.5 * k)
        .lineLimit(lineLimit)
        .multilineTextAlignment(alignment)
        .frame(maxWidth: .infinity, alignment: frameAlignment)
    }

    @ViewBuilder private func row(_ block: NotePreview.Block) -> some View {
        switch block {
        case .heading(let level, let text):
            let sizes: [CGFloat] = roomy ? [1.75, 1.45, 1.25, 1.1] : [1.2, 1.1, 1.05, 1.05]
            Text(inline(text))
                .font(.ui(size: size * sizes[min(max(level, 1), 4) - 1], weight: level <= 2 ? .bold : .semibold))
                .foregroundStyle(theme.text)
                .padding(.top, roomy ? size * 0.25 : 5 * k)
        case .bullet(let depth, let text):
            marked("\u{2022}", depth: depth, text: text)
        case .ordered(let number, let depth, let text):
            marked(number + ".", depth: depth, text: text)
        case .task(let depth, let done, let text):
            HStack(alignment: .firstTextBaseline, spacing: 5 * k) {
                RoundedRectangle(cornerRadius: Corners.r(2.5 * k))
                    .fill(done ? theme.accent : Color.clear)
                    .overlay(RoundedRectangle(cornerRadius: Corners.r(2.5 * k)).stroke(done ? theme.accent : theme.secondaryText, lineWidth: max(1, k)))
                    .frame(width: 8 * k, height: 8 * k)
                Text(inline(text))
                    .strikethrough(done)
                    .foregroundStyle(done ? theme.secondaryText.opacity(0.7) : theme.text.opacity(0.82))
            }
            .padding(.leading, CGFloat(depth) * 10 * k)
        case .quote(let text):
            Text(inline(text))
                .foregroundStyle(theme.text.opacity(0.75))
                .padding(.leading, 7 * k)
                .overlay(alignment: .leading) { ThemeCapsule().fill(theme.text.opacity(0.7)).frame(width: max(2, 2 * k)) }
        case .code(let text):
            Text(text.isEmpty ? " " : text)
                .font(.system(size: 9 * k, design: .monospaced))
                .foregroundStyle(theme.accent.opacity(0.85))
                .lineLimit(1)
                .padding(.horizontal, 6 * k)
                .padding(.vertical, 1 * k)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.codeBackground)
        case .fenced(let language, let code):
            // A board (`roomy`) sizes its text from the lines: it keeps them.
            if roomy {
                CardCodeLines(code: code, size: size)
            } else {
                CardCodeBlock(language: language, code: code, size: size)
                    .padding(.vertical, 2 * k)
            }
        case .tableRow(let cells, let header):
            HStack(spacing: 0) {
                ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                    Text(inline(cell))
                        .font(.ui(size: 9.5 * k, weight: header ? .semibold : .regular))
                        .lineLimit(1)
                        .padding(.horizontal, 5 * k)
                        .padding(.vertical, 3 * k)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .leading) {
                            if index > 0 { Rectangle().fill(theme.text.opacity(0.1)).frame(width: 0.5) }
                        }
                }
            }
            .overlay(alignment: .bottom) { Rectangle().fill(theme.text.opacity(0.1)).frame(height: 0.5) }
            .overlay(alignment: .top) {
                if header { Rectangle().fill(theme.text.opacity(0.1)).frame(height: 0.5) }
            }
            // Rows of one table touch.
            .padding(.vertical, -1.5 * k)
        case .paragraph(let text):
            Text(inline(text))
        }
    }

    private func marked(_ marker: String, depth: Int, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4 * k) {
            Text(marker).foregroundStyle(theme.secondaryText)
            Text(inline(text))
        }
        .padding(.leading, CGFloat(depth) * 10 * k)
    }

    /// Bold, italic, code and links through Foundation's inline Markdown, HTML tags left out; wikilinks and tags in the link colour.
    private func inline(_ text: String) -> AttributedString {
        var result = AttributedString()
        for run in InlineRun.split(text) {
            switch run {
            case .text(let plain):
                // Inline HTML (`<mark>`) shows its text, never its tags.
                let plain = plain.replacingOccurrences(of: #"</?[A-Za-z][^>]*>"#, with: "", options: .regularExpression)
                let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                // `==highlights==` are no CommonMark: shown as the editor shows them, not as their markers.
                for (index, piece) in plain.components(separatedBy: "==").enumerated() {
                    var part = (try? AttributedString(markdown: piece, options: options)) ?? AttributedString(piece)
                    if index % 2 == 1, plain.components(separatedBy: "==").count > 2 {
                        part.backgroundColor = theme.palette.highlight.map(Color.init) ?? Color.yellow.opacity(0.35)
                        if let text = theme.palette.highlightText { part.foregroundColor = Color(text) }
                    }
                    result += part
                }
            case .link(let name):
                var part = AttributedString(name)
                part.foregroundColor = theme.link
                result += part
            case .tag(let tag):
                var part = AttributedString("#" + tag)
                part.foregroundColor = theme.link
                result += part
            }
        }
        return result
    }
}

extension View {
    /// Draws the view as Craft's document card: glass-like paper (a light sheen over the top, a lit rim, a faint
    /// shade at the foot), rounded, with a soft layered shadow; the ring turns to the accent while hovered.
    /// For a card that also reacts to the pointer (rises, tilts, glints) use `interactiveNoteCard`.
    public func noteCard(isHovered: Bool = false, cornerRadius: CGFloat = 16) -> some View {
        modifier(NoteCardChrome(isHovered: isHovered, pointer: nil, cornerRadius: Corners.r(cornerRadius)))
    }

    /// `noteCard` plus the card's hover (`Motion.HoverPose`): it grows a little, rises, turns toward the pointer
    /// (which also moves a glint across the glass), comes to the front, and sinks back when the pointer leaves;
    /// pressing it squeezes it slightly. Under "Reduce motion" only the ring and the shadow change colour.
    public func interactiveNoteCard(cornerRadius: CGFloat = 16, pose: Motion.HoverPose = .card) -> some View {
        modifier(InteractiveNoteCard(cornerRadius: Corners.r(cornerRadius), pose: pose))
    }

    /// Makes the view appear as part of a cascade: from a little lower and smaller, fading in, `index` x 30 ms
    /// after the first one. A nil `index` (not part of the first screenful, or the grid is already settled)
    /// shows the view at once. Under "Reduce motion" the cards only fade, all together.
    public func cascadeIn(index: Int?) -> some View {
        modifier(CascadeIn(index: index))
    }

    /// As tall as its content up to `maxHeight`; past that, cut and faded out at the bottom (a long note's card).
    public func cappedHeight(_ maxHeight: CGFloat, fade: CGFloat = 36) -> some View {
        modifier(CappedHeight(maxHeight: maxHeight, fade: fade))
    }
}

/// The pure parts of a card's hover and of the cascade, apart from the views so they can be tested.
public enum CardMotion {
    /// How many cards, from the first, take part in a cascade; the rest appear at once.
    public static let cascadeLimit = 12
    /// A card just opened starts this much lower, in points.
    public static let cascadeRise: CGFloat = 8
    /// The scale pressing a card squeezes it to.
    public static let pressScale: CGFloat = 0.985
    /// The light perspective of the tilt, so the near side grows a little.
    public static let perspective: CGFloat = 0.5

    /// The position of the pointer in a card of `size`, from (-1, -1) at the top left to (1, 1) at the bottom
    /// right, clamped.
    public static func pointer(_ location: CGPoint, in size: CGSize) -> CGPoint {
        guard size.width > 0, size.height > 0 else { return .zero }
        return CGPoint(
            x: min(max(location.x / size.width * 2 - 1, -1), 1),
            y: min(max(location.y / size.height * 2 - 1, -1), 1)
        )
    }

    /// The card's turn, in degrees, for a pointer at `pointer` (see `pointer(_:in:)`): about the vertical axis
    /// by the full tilt, about the horizontal one by half of it. A pointer on the right dips the right side, one
    /// at the bottom dips the bottom (the signs are those `rotation3DEffect` needs).
    public static func angles(for pointer: CGPoint, pose: Motion.HoverPose) -> (x: Double, y: Double) {
        (x: pose.tilt(pointerX: Double(pointer.y)) * 0.5, y: pose.tilt(pointerX: Double(pointer.x)))
    }

    /// The delay before card `index` of a grid appears, or nil when it takes no part in the cascade.
    public static func cascadeDelay(index: Int?, reduceMotion: Bool) -> Double? {
        guard let index, index >= 0, index < cascadeLimit else { return nil }
        return Motion.stagger(index: index, reduceMotion: reduceMotion)
    }
}

private struct NoteCardChrome: ViewModifier {
    let isHovered: Bool
    /// Where the pointer is on the card, -1...1 on each axis; nil when it is not over it.
    let pointer: CGPoint?
    let cornerRadius: CGFloat
    @Environment(\.themeTokens) private var theme

    func body(content: Content) -> some View {
        flat(content)
    }

    /// Paper with a hairline: no glaze. Under the pointer the hairline takes the accent, a soft glow of it rises under
    /// the card, and a halftone spreads out of the card's lower right corner behind the content, as ink soaking in.
    private func flat(_ content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Corners.r(min(cornerRadius, 10)), style: .continuous)
        return content
            .background {
                ZStack {
                    shape.fill(theme.background)
                        .shadow(color: theme.accent.opacity(isHovered ? 0.16 : 0), radius: 16, y: 6)
                    GeometryReader { card in
                        // A faint grain in the top right at rest, so the print look reaches the top of the card too.
                        HalftoneCloud(corner: .topTrailing, step: 2, seed: 29, color: theme.accent.opacity(0.14))
                            .frame(width: min(card.size.width * 0.3, 90), height: min(card.size.height * 0.22, 54))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        HalftoneCloud(corner: .bottomTrailing, step: 2.5, seed: 17, color: theme.accent.opacity(0.4), progress: isHovered ? 1 : 0)
                            .frame(width: card.size.width * 0.55, height: min(card.size.height * 0.5, 150))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    }
                    .clipShape(shape)
                }
            }
            .overlay {
                shape.strokeBorder(isHovered ? theme.accent.opacity(0.85) : theme.separator, lineWidth: 1)
            }
            .animation(.easeOut(duration: isHovered ? 0.45 : 0.25), value: isHovered)
    }
}

/// A card's hover: its ring takes the accent and the paper rises a little.
private struct InteractiveNoteCard: ViewModifier {
    let cornerRadius: CGFloat
    let pose: Motion.HoverPose
    @State private var pointer: CGPoint?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Environment(\.themeTokens) private var theme

    func body(content: Content) -> some View {
        // The card stays where it is: only its ring answers the pointer, and a small rise lifts the paper off the page.
        content
            .modifier(NoteCardChrome(isHovered: pointer != nil, pointer: nil, cornerRadius: Corners.r(cornerRadius)))
            .offset(y: pointer != nil && !reduceMotion ? -2 : 0)
            .animation(Motion.resolved(Motion.Spring.lift.animation, reduceMotion: reduceMotion), value: pointer != nil)
            .onHover { pointer = $0 ? .zero : nil }
    }
}

private struct CascadeIn: ViewModifier {
    let index: Int?
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let delay = CardMotion.cascadeDelay(index: index, reduceMotion: reduceMotion)
        content
            .opacity(shown || delay == nil ? 1 : 0)
            .scaleEffect(shown || delay == nil || reduceMotion ? 1 : Motion.Metrics.enterScale)
            .offset(y: shown || delay == nil || reduceMotion ? 0 : CardMotion.cascadeRise)
            .onAppear {
                guard let delay, !shown else { return }
                let animation = reduceMotion ? Motion.fade : Motion.Spring.standard.animation
                withAnimation(animation.delay(delay)) { shown = true }
            }
    }
}

private struct CappedHeight: ViewModifier {
    let maxHeight: CGFloat
    let fade: CGFloat
    @State private var natural: CGFloat = 0

    func body(content: Content) -> some View {
        let overflows = natural > maxHeight + 0.5
        content
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { natural = $0 }
            .frame(maxHeight: maxHeight, alignment: .top)
            .clipped()
            .fadingEdges(overflows ? .bottom : [], length: fade)
    }
}

/// Cards in columns of equal width, each placed in the shortest column, so cards as tall as their notes pack
/// together as on Craft's "All Docs" (a masonry). The columns are as many as fit at `minColumnWidth`, at most
/// `maxColumns`.
public struct MasonryLayout: Layout {
    public var minColumnWidth: CGFloat
    public var maxColumns: Int
    public var spacing: CGFloat

    public init(minColumnWidth: CGFloat, maxColumns: Int = 8, spacing: CGFloat = 16) {
        self.minColumnWidth = minColumnWidth
        self.maxColumns = maxColumns
        self.spacing = spacing
    }

    /// How many columns of at least `minColumnWidth` fit in `width`; at least one.
    public func columnCount(for width: CGFloat) -> Int {
        min(maxColumns, max(1, Int((width + spacing) / (minColumnWidth + spacing))))
    }

    private func frames(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], height: CGFloat) {
        let count = columnCount(for: width)
        let columnWidth = max(0, (width - spacing * CGFloat(count - 1)) / CGFloat(count))
        var heights = Array(repeating: CGFloat(0), count: count)
        var frames: [CGRect] = []
        for subview in subviews {
            let column = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            let size = subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil))
            let y = heights[column] == 0 ? 0 : heights[column] + spacing
            frames.append(CGRect(x: CGFloat(column) * (columnWidth + spacing), y: y, width: columnWidth, height: size.height))
            heights[column] = y + size.height
        }
        return (frames, heights.max() ?? 0)
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? minColumnWidth
        return CGSize(width: width, height: frames(width: width, subviews: subviews).height)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placed = frames(width: bounds.width, subviews: subviews).frames
        for (subview, frame) in zip(subviews, placed) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }
}
