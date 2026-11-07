import PluginKitUI
import SwiftUI

/// What an empty task list shows, as an empty board does: a small drawing, the mode's title and line, and three ways
/// to add a task drawn as small scenes that play under the pointer: write one here, give one a day, or write it in
/// today's note.
struct TaskEmptyState: View {
    let title: String
    let detail: String
    let write: () -> Void
    let plan: () -> Void
    let openNote: () -> Void
    @Environment(\.themeTokens) private var theme
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            EmptyState(title, message: detail) {
                TaskEmptyDrawing().frame(width: 120, height: 84)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Space.m) { tiles }
                VStack(spacing: Space.m) { tiles }
            }
            .padding(.top, -Space.l)
            .padding(.bottom, Space.xxxl)
        }
        .frame(maxWidth: .infinity)
        .onAppear { appeared = true }
    }

    @ViewBuilder private var tiles: some View {
        tile(.write, 0, write)
        tile(.plan, 1, plan)
        tile(.note, 2, openNote)
    }

    private func tile(_ kind: TaskStarter, _ index: Int, _ action: @escaping () -> Void) -> some View {
        TaskStarterTile(kind: kind, action: action)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 8)
            .animation(Motion.resolved(Motion.Spring.standard.animation).delay(Double(index) * Motion.Metrics.stagger),
                       value: appeared)
    }
}

enum TaskStarter {
    case write, plan, note

    var title: String {
        switch self {
        case .write: return "Write a task"
        case .plan: return "Give it a day"
        case .note: return "In today's note"
        }
    }

    var subtitle: String {
        switch self {
        case .write: return "Here, then Return"
        case .plan: return "📅 and a date on the line"
        case .note: return "Type /todo anywhere"
        }
    }
}

/// One way to add a task: a small scene over its name. It lifts under the pointer and the scene plays.
private struct TaskStarterTile: View {
    let kind: TaskStarter
    let action: () -> Void
    @Environment(\.themeTokens) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                TaskStarterPreview(kind: kind, progress: hovered ? 1 : 0)
                    .animation(Motion.resolved(Motion.Spring.slide.animation), value: hovered)
                    .frame(height: 78)
                    .frame(maxWidth: .infinity)
                    .background {
                        ZStack {
                            theme.text.opacity(colorScheme == .dark ? 0.05 : 0.025)
                            // The print look of the cards: a faint grain at rest, more rising on hover.
                            HalftoneCloud(corner: .topTrailing, step: 2, seed: 29, color: theme.accent.opacity(0.14))
                                .frame(width: 70, height: 40)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            HalftoneCloud(corner: .bottomTrailing, step: 2.5, seed: 17, color: theme.accent.opacity(0.4),
                                          progress: hovered ? 1 : 0)
                                .frame(width: 110, height: 60)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        }
                    }
                Rectangle().fill(theme.text.opacity(0.07)).frame(height: 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.title.uiLocalized).font(.ui(.body, weight: .semibold)).foregroundStyle(theme.text)
                    Text(kind.subtitle.uiLocalized).font(.ui(.caption)).foregroundStyle(theme.secondaryText)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 176)
            .background(theme.background)
            .clipShape(RoundedRectangle(cornerRadius: Corners.r(14), style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Corners.r(14), style: .continuous)
                .strokeBorder(hovered ? theme.accent.opacity(0.6) : theme.text.opacity(0.1), lineWidth: hovered ? 1.5 : 1))
            .shadow(color: .black.opacity(hovered ? 0.12 : 0.05), radius: hovered ? 14 : 6, y: hovered ? 6 : 2)
            .scaleEffect(hovered ? 1.02 : 1)
            .offset(y: hovered ? -2 : 0)
            .contentShape(RoundedRectangle(cornerRadius: Corners.r(14), style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { inside in withAnimation(Motion.resolved(Motion.Spring.lift.animation)) { hovered = inside } }
    }
}

/// A starter's scene, `progress` 0 to 1: a task gets checked and struck; a task flies into tomorrow on a small
/// calendar; a line of a note becomes a task, its box popping in.
private struct TaskStarterPreview: View, Animatable {
    let kind: TaskStarter
    var progress: Double
    @Environment(\.themeTokens) private var theme

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let t = progress
        let accent = theme.accent, line = theme.text.opacity(0.14), paper = theme.background, text = theme.text
        Canvas { context, size in
            let mid = CGPoint(x: size.width / 2, y: size.height / 2)
            func box(_ origin: CGPoint, checked: Double) {
                let rect = CGRect(x: origin.x, y: origin.y, width: 12, height: 12)
                context.stroke(Path(roundedRect: rect, cornerRadius: Corners.r(3.5)), with: .color(text.opacity(0.35 * (1 - checked))),
                               lineWidth: 1.3)
                guard checked > 0.01 else { return }
                let filled = rect.insetBy(dx: 6 * (1 - checked), dy: 6 * (1 - checked))
                context.fill(Path(roundedRect: filled, cornerRadius: Corners.r(3.5)), with: .color(accent))
                var tick = Path()
                tick.move(to: CGPoint(x: rect.minX + 3, y: rect.midY))
                tick.addLine(to: CGPoint(x: rect.minX + 5.2, y: rect.midY + 2.4))
                tick.addLine(to: CGPoint(x: rect.minX + 9, y: rect.midY - 2.6))
                context.stroke(tick.trimmedPath(from: 0, to: max(0, (checked - 0.4) / 0.6)), with: .color(.white),
                               style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
            switch kind {
            case .write:
                for row in 0..<3 {
                    let y = mid.y - 24 + Double(row) * 18
                    let checked = row == 1 ? t : row == 0 ? 1 : 0
                    box(CGPoint(x: mid.x - 52, y: y), checked: checked)
                    let width = [62.0, 78, 50][row]
                    let bar = CGRect(x: mid.x - 32, y: y + 4, width: width, height: 4)
                    context.fill(Path(roundedRect: bar, cornerRadius: Corners.r(2)), with: .color(text.opacity(checked > 0.5 ? 0.12 : 0.22)))
                    if checked > 0 {
                        var strike = Path()
                        strike.move(to: CGPoint(x: bar.minX - 2, y: bar.midY))
                        strike.addLine(to: CGPoint(x: bar.minX - 2 + (width + 4) * min(1, checked * 1.2), y: bar.midY))
                        context.stroke(strike, with: .color(text.opacity(0.35)), lineWidth: 1)
                    }
                }
            case .plan:
                let grid = CGRect(x: mid.x - 56, y: mid.y - 26, width: 112, height: 54)
                context.fill(Path(roundedRect: grid, cornerRadius: Corners.r(6)), with: .color(paper))
                context.stroke(Path(roundedRect: grid, cornerRadius: Corners.r(6)), with: .color(line), lineWidth: 1)
                let cell = CGSize(width: grid.width / 7, height: (grid.height - 12) / 3)
                context.fill(Path(roundedRect: CGRect(x: grid.minX, y: grid.minY, width: grid.width, height: 10), cornerRadius: Corners.r(6)),
                             with: .color(Color.red.opacity(0.75))) // ui-rules: illustration
                for row in 0..<3 {
                    for column in 0..<7 {
                        let dot = CGRect(x: grid.minX + Double(column) * cell.width + cell.width / 2 - 1.5,
                                         y: grid.minY + 12 + Double(row) * cell.height + cell.height / 2 - 1.5, width: 3, height: 3)
                        context.fill(Path(ellipseIn: dot), with: .color(text.opacity(0.18)))
                    }
                }
                // Tomorrow, and the task landing on it.
                let target = CGRect(x: grid.minX + 3 * cell.width + 1, y: grid.minY + 12 + cell.height + 1,
                                    width: cell.width - 2, height: cell.height - 2)
                context.fill(Path(roundedRect: target, cornerRadius: Corners.r(4)), with: .color(accent.opacity(0.12 + 0.18 * t)))
                let start = CGPoint(x: grid.minX - 30, y: grid.maxY + 2), end = CGPoint(x: target.midX, y: target.midY)
                let position = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t - sin(t * .pi) * 14)
                let chip = CGRect(x: position.x - 9 * (1 - 0.3 * t), y: position.y - 4, width: 18 * (1 - 0.3 * t), height: 8)
                var moving = context
                moving.opacity = t
                moving.fill(Path(roundedRect: chip, cornerRadius: Corners.r(4)), with: .color(accent))
            case .note:
                let page = CGRect(x: mid.x - 42, y: mid.y - 32, width: 84, height: 64)
                context.fill(Path(roundedRect: page, cornerRadius: Corners.r(6)), with: .color(paper))
                context.stroke(Path(roundedRect: page, cornerRadius: Corners.r(6)), with: .color(line), lineWidth: 1)
                context.fill(Path(roundedRect: CGRect(x: page.minX + 9, y: page.minY + 9, width: 34, height: 5), cornerRadius: Corners.r(2.5)),
                             with: .color(text.opacity(0.3)))
                for row in 0..<3 {
                    let y = page.minY + 24 + Double(row) * 12
                    let isTask = row == 1
                    let indent = isTask ? 16 * t : 0
                    if isTask, t > 0.01 {
                        var popped = context
                        popped.translateBy(x: page.minX + 9 + 4, y: y + 2)
                        popped.scaleBy(x: t, y: t)
                        let rect = CGRect(x: -4.5, y: -4.5, width: 9, height: 9)
                        popped.stroke(Path(roundedRect: rect, cornerRadius: Corners.r(2.5)), with: .color(accent), lineWidth: 1.3)
                    }
                    context.fill(Path(roundedRect: CGRect(x: page.minX + 9 + indent, y: y, width: [60.0, 52, 44][row] - indent,
                                                          height: 4), cornerRadius: Corners.r(2)),
                                 with: .color(isTask ? accent.opacity(0.25 + 0.35 * t) : text.opacity(0.14)))
                }
            }
        }
    }
}

/// The empty list's drawing: a card of tasks, one checked, a round check badge over its corner.
private struct TaskEmptyDrawing: View {
    @Environment(\.themeTokens) private var theme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Corners.r(12), style: .continuous)
                .fill(theme.background)
                .overlay(RoundedRectangle(cornerRadius: Corners.r(12), style: .continuous).strokeBorder(theme.text.opacity(0.14)))
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 9) {
                        row(done: true, width: 44)
                        row(done: false, width: 56)
                        row(done: false, width: 34)
                    }
                    .padding(12)
                }
                .overlay {
                    HalftoneCloud(corner: .bottomTrailing, step: 2, seed: 53, color: theme.accent.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: Corners.r(12), style: .continuous))
                }
                .frame(width: 96, height: 72)
                .rotationEffect(.degrees(-3))
                .shadow(color: .black.opacity(0.07), radius: 8, y: 3)
            Image(symbol: "checkmark")
                .font(.ui(size: 12, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(theme.accent))
                .overlay(Circle().strokeBorder(theme.background, lineWidth: 3))
                .offset(x: 46, y: -30)
        }
    }

    private func row(done: Bool, width: CGFloat) -> some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: Corners.r(4))
                .fill(done ? theme.accent : .clear)
                .overlay(RoundedRectangle(cornerRadius: Corners.r(4)).strokeBorder(done ? theme.accent : theme.text.opacity(0.3), lineWidth: 1.3))
                .frame(width: 11, height: 11)
            ThemeCapsule().fill(theme.text.opacity(done ? 0.12 : 0.22)).frame(width: width, height: 4)
        }
    }
}
