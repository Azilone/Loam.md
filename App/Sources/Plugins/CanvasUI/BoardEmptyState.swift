import CanvasPlugin
import PluginKitUI
import SwiftUI

/// What a new board shows: a small drawing, a line of welcome, four ways to start (a mindmap, a Kanban of three
/// columns, a table, sticky notes) drawn as small previews, and the keys that do the rest. A click on one puts it in
/// the middle of the board; the board's own gestures work everywhere else.
struct BoardEmptyState: View {
    let model: BoardModel
    @Environment(\.themeTokens) private var theme
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            BoardEmptyDrawing()
                .frame(width: 132, height: 92)
                .padding(.bottom, Space.m)
            Text("A blank board")
                .font(.ui(.section))
                .foregroundStyle(theme.text)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("Start from one of these, or write anywhere on the canvas.")
                .font(.ui(.body))
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Space.s)
            // One row when the board is wide enough, else two, else a short list without the drawings.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { tiles(BoardStarter.allCases) }
                VStack(spacing: 12) {
                    HStack(spacing: 12) { tiles(Array(BoardStarter.allCases.prefix(2))) }
                    HStack(spacing: 12) { tiles(Array(BoardStarter.allCases.suffix(2)), from: 2) }
                }
                VStack(spacing: 8) { rows }
                    .frame(maxWidth: 320)
            }
            .padding(.top, Space.xl)
            keys
                .padding(.top, Space.xl)
        }
        .padding(Space.xxl)
        .onAppear { appeared = true }
    }

    private var rows: some View {
        ForEach(Array(BoardStarter.allCases.enumerated()), id: \.element) { index, starter in
            BoardStarterRow(starter: starter) { start(starter) }
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 8)
                .animation(Motion.resolved(Motion.Spring.standard.animation)
                    .delay(Double(index) * Motion.Metrics.stagger), value: appeared)
        }
    }

    private func tiles(_ starters: [BoardStarter], from first: Int = 0) -> some View {
        ForEach(Array(starters.enumerated()), id: \.element) { index, starter in
            BoardStarterTile(starter: starter) { start(starter) }
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 8)
                .animation(Motion.resolved(Motion.Spring.standard.animation)
                    .delay(Double(first + index) * Motion.Metrics.stagger), value: appeared)
        }
    }

    /// The keys, whole, on as many centred lines as the board's width needs.
    private var keys: some View {
        BoardFlowLayout(spacing: 16, lineSpacing: 8) {
            key("Double-click", "text")
            key("S", "sticky note")
            key("N", "note")
            key("P", "pen")
            Text("or drop notes, pictures and links")
                .font(.ui(size: 12))
                .foregroundStyle(theme.secondaryText.opacity(0.8))
                .multilineTextAlignment(.center)
        }
    }

    private func key(_ key: String, _ what: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.ui(size: 11, weight: .semibold))
                .foregroundStyle(theme.text.opacity(0.75))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: Corners.r(6), style: .continuous).fill(theme.text.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: Corners.r(6), style: .continuous).strokeBorder(theme.text.opacity(0.1)))
            Text(what).font(.ui(size: 12)).foregroundStyle(theme.secondaryText)
        }
        .fixedSize()
    }

    private func start(_ starter: BoardStarter) {
        let point = model.viewCenter
        switch starter {
        case .mindmap: model.addMindmap(at: point)
        case .kanban: model.addKanban(at: point)
        case .table: model.addTable(at: point)
        case .stickies: model.addStickies(at: point)
        }
    }
}

enum BoardStarter: CaseIterable {
    case mindmap, kanban, table, stickies

    var title: String {
        switch self {
        case .mindmap: return "Mindmap"
        case .kanban: return "Kanban"
        case .table: return "Table"
        case .stickies: return "Sticky notes"
        }
    }

    var subtitle: String {
        switch self {
        case .mindmap: return "Ideas around a centre"
        case .kanban: return "To do, doing, done"
        case .table: return "Rows and columns"
        case .stickies: return "A quick brainstorm"
        }
    }

    var color: Color {
        switch self {
        case .mindmap: return BoardStyle.color("6")!
        case .kanban: return BoardStyle.color("2")!
        case .table: return BoardStyle.color("4")!
        case .stickies: return BoardStyle.color("3")!
        }
    }
}

/// One way to start: a small drawing of it over its name. It lifts under the pointer.
private struct BoardStarterTile: View {
    let starter: BoardStarter
    let action: () -> Void
    @Environment(\.themeTokens) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                BoardStarterPreview(starter: starter, progress: hovered ? 1 : 0)
                    // Slower than the tile's lift: the little scene plays out.
                    .animation(Motion.resolved(Motion.Spring.slide.animation), value: hovered)
                    .frame(height: 92)
                    .frame(maxWidth: .infinity)
                    .background(theme.text.opacity(colorScheme == .dark ? 0.05 : 0.025))
                Rectangle().fill(theme.text.opacity(0.07)).frame(height: 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Circle().fill(starter.color).frame(width: 7, height: 7)
                        Text(starter.title.uiLocalized).font(.ui(size: 13, weight: .semibold)).foregroundStyle(theme.text)
                    }
                    Text(starter.subtitle.uiLocalized).font(.ui(size: 11)).foregroundStyle(theme.secondaryText)
                        .padding(.leading, 13)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .frame(width: 168)
            .background(theme.background)
            .clipShape(RoundedRectangle(cornerRadius: Corners.r(14), style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Corners.r(14), style: .continuous)
                .strokeBorder(hovered ? starter.color.opacity(0.7) : theme.text.opacity(0.1), lineWidth: hovered ? 1.5 : 1))
            .shadow(color: .black.opacity(hovered ? 0.12 : 0.05), radius: hovered ? 14 : 6, y: hovered ? 6 : 2)
            .scaleEffect(hovered ? 1.02 : 1)
            .offset(y: hovered ? -2 : 0)
            .contentShape(RoundedRectangle(cornerRadius: Corners.r(14), style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { inside in withAnimation(Motion.resolved(Motion.Spring.lift.animation)) { hovered = inside } }
        .help("Add a \(starter.title.lowercased()) to the board")
    }
}

/// One way to start on a narrow board: its colour, name and line, no drawing. It lifts under the pointer.
private struct BoardStarterRow: View {
    let starter: BoardStarter
    let action: () -> Void
    @Environment(\.themeTokens) private var theme
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Circle().fill(starter.color).frame(width: 8, height: 8)
                Text(starter.title.uiLocalized).font(.ui(size: 13, weight: .semibold)).foregroundStyle(theme.text)
                    .lineLimit(1)
                Text(starter.subtitle.uiLocalized).font(.ui(size: 11)).foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(theme.background)
            .clipShape(RoundedRectangle(cornerRadius: Corners.r(10), style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Corners.r(10), style: .continuous)
                .strokeBorder(hovered ? starter.color.opacity(0.7) : theme.text.opacity(0.1), lineWidth: hovered ? 1.5 : 1))
            .shadow(color: .black.opacity(hovered ? 0.1 : 0.04), radius: hovered ? 10 : 4, y: hovered ? 4 : 1)
            .offset(y: hovered ? -1 : 0)
            .contentShape(RoundedRectangle(cornerRadius: Corners.r(10), style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { inside in withAnimation(Motion.resolved(Motion.Spring.lift.animation)) { hovered = inside } }
        .help("Add a \(starter.title.lowercased()) to the board")
    }
}

/// Lays its views out left to right on centred lines, starting a new line when the next one does not fit: a view is
/// never cut in two, and one wider than the line alone wraps its own text.
struct BoardFlowLayout: Layout {
    var spacing: CGFloat = 16
    var lineSpacing: CGFloat = 8

    private func lines(_ subviews: Subviews, width: CGFloat) -> [[(index: Int, size: CGSize)]] {
        var lines: [[(index: Int, size: CGSize)]] = [[]]
        var x: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            var size = subview.sizeThatFits(.unspecified)
            if size.width > width { size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
            if !lines[lines.count - 1].isEmpty, x + spacing + size.width > width {
                lines.append([])
                x = 0
            }
            x += (lines[lines.count - 1].isEmpty ? 0 : spacing) + size.width
            lines[lines.count - 1].append((index, size))
        }
        return lines
    }

    private func lineWidth(_ line: [(index: Int, size: CGSize)]) -> CGFloat {
        line.reduce(0) { $0 + $1.size.width } + spacing * CGFloat(max(line.count - 1, 0))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = lines(subviews, width: proposal.width ?? .infinity)
        let width = lines.map(lineWidth).max() ?? 0
        let height = lines.reduce(0) { $0 + ($1.map(\.size.height).max() ?? 0) }
            + lineSpacing * CGFloat(max(lines.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(subviews, width: bounds.width) {
            let height = line.map(\.size.height).max() ?? 0
            var x = bounds.minX + (bounds.width - lineWidth(line)) / 2
            for item in line {
                subviews[item.index].place(at: CGPoint(x: x, y: y + (height - item.size.height) / 2),
                                           proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += height + lineSpacing
        }
    }
}

/// A starter drawn small, in its colour. Under the pointer it comes alive (`progress` 0 to 1, animated): a map's
/// branches reach out and a new one grows, a Kanban card moves to the next column, a table gains a row, sticky notes
/// fan out.
private struct BoardStarterPreview: View, Animatable {
    let starter: BoardStarter
    var progress: Double
    @Environment(\.themeTokens) private var theme

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let color = starter.color
        let line = theme.text.opacity(0.12)
        let t = progress
        Canvas { context, size in
            let mid = CGPoint(x: size.width / 2, y: size.height / 2)
            switch starter {
            case .mindmap:
                let centre = CGRect(x: mid.x - 52, y: mid.y - 10, width: 40, height: 20)
                // Three branches make room for a fourth, which grows out of the third.
                let branches: [(dy: Double, width: Double, alpha: Double)] = [
                    (-24 - 9 * t, 36, 1), (-11 * t, 46, 1), (24 - 13 * t, 30, 1), (24 + 9 * t, 26, t),
                ]
                for branch in branches where branch.alpha > 0.01 {
                    let end = CGPoint(x: mid.x + 14 + 6 * t, y: mid.y + branch.dy)
                    var curve = Path()
                    curve.move(to: CGPoint(x: centre.maxX, y: mid.y))
                    curve.addCurve(to: end, control1: CGPoint(x: centre.maxX + 14, y: mid.y),
                                   control2: CGPoint(x: end.x - 14, y: end.y))
                    var drawn = context
                    drawn.opacity = branch.alpha
                    drawn.stroke(curve, with: .color(color.opacity(0.55)), lineWidth: 1.5)
                    drawn.fill(Path(roundedRect: CGRect(x: end.x, y: end.y - 7, width: branch.width, height: 14), cornerRadius: Corners.r(8)),
                               with: .color(color.opacity(0.18 + 0.1 * t)))
                }
                context.fill(Path(roundedRect: centre.insetBy(dx: -2 * t, dy: -1 * t), cornerRadius: Corners.r(8)), with: .color(color))
            case .kanban:
                let columns = (0..<3).map { CGRect(x: mid.x - 66 + Double($0) * 45, y: mid.y - 34, width: 40, height: 68) }
                for (index, rect) in columns.enumerated() {
                    context.fill(Path(roundedRect: rect, cornerRadius: Corners.r(6)), with: .color(theme.background))
                    context.stroke(Path(roundedRect: rect, cornerRadius: Corners.r(6)), with: .color(line), lineWidth: 1)
                    for card in 0..<(3 - index) where !(index == 0 && card == 0) {
                        let tint = card == 0 ? [color, BoardStyle.color("5")!, BoardStyle.color("4")!][index] : theme.text
                        // Cards of the second column make room for the one arriving.
                        let shift = index == 1 ? 15 * t : 0
                        context.fill(Path(roundedRect: CGRect(x: rect.minX + 5, y: rect.minY + 6 + Double(card) * 15 + shift,
                                                              width: 30, height: 11), cornerRadius: Corners.r(4)),
                                     with: .color(tint.opacity(card == 0 ? 0.35 : 0.08)))
                    }
                }
                // The first task travels to "doing", lifted on its way.
                let lift = sin(t * .pi) * 6
                let moving = CGRect(x: columns[0].minX + 5 + 45 * t, y: columns[0].minY + 6 - lift, width: 30, height: 11)
                context.fill(Path(roundedRect: moving.offsetBy(dx: 0, dy: 2), cornerRadius: Corners.r(4)), with: .color(.black.opacity(0.1 * t)))
                context.fill(Path(roundedRect: moving, cornerRadius: Corners.r(4)), with: .color(color.opacity(0.35 + 0.4 * t)))
            case .table:
                let height = 60 + 15 * t
                let rect = CGRect(x: mid.x - 60, y: mid.y - height / 2, width: 120, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: Corners.r(6)), with: .color(theme.background))
                context.fill(Path(roundedRect: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 15), cornerRadius: Corners.r(6)),
                             with: .color(color.opacity(0.85)))
                // The new row, and its first cell being written.
                context.fill(Path(CGRect(x: rect.minX + 1, y: rect.maxY - 15, width: 39, height: 14)),
                             with: .color(theme.accent.opacity(0.18 * t)))
                var grid = Path()
                for x in [rect.minX + 40, rect.minX + 80] {
                    grid.move(to: CGPoint(x: x, y: rect.minY))
                    grid.addLine(to: CGPoint(x: x, y: rect.maxY))
                }
                for y in stride(from: rect.minY + 30, to: rect.maxY - 1, by: 15) {
                    grid.move(to: CGPoint(x: rect.minX, y: y))
                    grid.addLine(to: CGPoint(x: rect.maxX, y: y))
                }
                context.stroke(grid, with: .color(line), lineWidth: 1)
                context.stroke(Path(roundedRect: rect, cornerRadius: Corners.r(6)), with: .color(line), lineWidth: 1)
            case .stickies:
                for (index, preset) in ["3", "5", "1"].enumerated() {
                    let spread = Double(index - 1) * 8 * t
                    let rise = index == 1 ? -6 * t : -2 * t
                    let rect = CGRect(x: mid.x - 58 + Double(index) * 36 + spread, y: mid.y - 26 + (index == 1 ? 6 : 0) + rise,
                                      width: 42, height: 42)
                    var sticky = context
                    sticky.translateBy(x: rect.midX, y: rect.midY)
                    sticky.rotate(by: .degrees([-6, 3, -2][index] * (1 + 1.2 * t)))
                    let local = CGRect(x: -21, y: -21, width: 42, height: 42)
                    sticky.fill(Path(roundedRect: local.offsetBy(dx: 0, dy: 2 + 2 * t), cornerRadius: Corners.r(4)),
                                with: .color(.black.opacity(0.08 + 0.06 * t)))
                    sticky.fill(Path(roundedRect: local, cornerRadius: Corners.r(4)), with: .color(BoardStyle.color(preset)!.opacity(0.75)))
                    sticky.fill(Path(roundedRect: CGRect(x: -14, y: -12, width: 24, height: 3), cornerRadius: Corners.r(1.5)),
                                with: .color(.black.opacity(0.18)))
                }
            }
        }
    }
}

/// The empty board's drawing: a card and a sticky note leaning on it, a plus to add more.
private struct BoardEmptyDrawing: View {
    @Environment(\.themeTokens) private var theme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Corners.r(10), style: .continuous)
                .fill(theme.background)
                .overlay(RoundedRectangle(cornerRadius: Corners.r(10), style: .continuous).strokeBorder(theme.text.opacity(0.14)))
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 6) {
                        ThemeCapsule().fill(theme.text.opacity(0.22)).frame(width: 40, height: 5)
                        ThemeCapsule().fill(theme.text.opacity(0.12)).frame(width: 52, height: 4)
                        ThemeCapsule().fill(theme.text.opacity(0.12)).frame(width: 30, height: 4)
                    }
                    .padding(12)
                }
                .frame(width: 84, height: 58)
                .rotationEffect(.degrees(-5))
                .offset(x: -22, y: 6)
                .shadow(color: .black.opacity(0.06), radius: 6, y: 3)
            RoundedRectangle(cornerRadius: Corners.r(6), style: .continuous)
                .fill(BoardStyle.color("3")!.opacity(0.8))
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 5) {
                        ThemeCapsule().fill(.black.opacity(0.2)).frame(width: 26, height: 4)
                        ThemeCapsule().fill(.black.opacity(0.13)).frame(width: 18, height: 4)
                    }
                    .padding(10)
                }
                .frame(width: 54, height: 54)
                .rotationEffect(.degrees(6))
                .offset(x: 30, y: -10)
                .shadow(color: .black.opacity(0.1), radius: 6, y: 3)
            Image(symbol: "plus")
                .font(.ui(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(theme.accent))
                .overlay(Circle().strokeBorder(theme.background, lineWidth: 2.5))
                .offset(x: 54, y: 18)
        }
    }
}
