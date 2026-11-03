import AppKit
import PluginKitUI
import SwiftUI

/// How high a card stands off the board: resting, under the pointer, or in the hand.
enum BoardElevation {
    case rest, hover, held

    var shadowOpacity: Double {
        switch self {
        case .rest: 0.02
        case .hover: 0.08
        case .held: 0.22
        }
    }

    var shadowRadius: CGFloat {
        switch self {
        case .rest: 3
        case .hover: 6
        case .held: 18
        }
    }

    var shadowY: CGFloat {
        switch self {
        case .rest: 1
        case .hover: 3
        case .held: 10
        }
    }
}

/// A card as it is drawn: the title, then the shown fields that have a value, on a white card.
struct BoardCardFace: View {
    let model: CollectionViewModel
    let entry: NoteRecord
    var elevation = BoardElevation.rest
    @Environment(\.themeTokens) private var theme
    @Environment(\.boardChecklist) private var checklist

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.title)
                .font(.ui(size: 15, weight: .semibold))
                .foregroundStyle(theme.text)
                .lineLimit(3)
            ForEach(model.fields, id: \.self) { ref in
                if let value = model.value(ref, of: entry) {
                    PropertyValueView(value, kind: model.kind(ref), options: model.property(ref).options)
                        .font(.ui(size: 13))
                }
            }
            if let list = checklist(entry) {
                HStack(spacing: 6) {
                    Image(symbol: "checklist").font(.ui(size: 11))
                    Text("\(list.done)/\(list.total)").font(.ui(size: 12).monospacedDigit())
                    ZStack(alignment: .leading) {
                        ThemeCapsule().fill(theme.fillHover)
                        ThemeCapsule().fill(list.done == list.total ? Color.green.opacity(0.85) : theme.accent)
                            .frame(width: max(4, 64 * CGFloat(list.done) / CGFloat(list.total)))
                    }
                    .frame(width: 64, height: 4)
                }
                .foregroundStyle(theme.secondaryText)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(list.done) of \(list.total) checklist items done")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Corners.r(8), style: .continuous).fill(theme.background))
        .overlay(RoundedRectangle(cornerRadius: Corners.r(8), style: .continuous)
            .strokeBorder(theme.separator.opacity(elevation == .rest ? 0.5 : 0.9)))
        .shadow(color: .black.opacity(elevation.shadowOpacity), radius: elevation.shadowRadius, y: elevation.shadowY)
    }
}

/// A move the card's menu offers: to the column named `name`.
struct BoardMove: Identifiable {
    let name: String
    let action: () -> Void
    var id: String { name }
}

/// A card in the board. While it is in the hand this is its ghost: the same card at the gap, faded, with a dashed
/// outline in its column's colour; the card that follows the pointer is `HeldCardLayer`'s copy.
struct BoardCardView: View {
    let model: CollectionViewModel
    let entry: NoteRecord
    let drag: BoardDragModel
    let tint: Color
    let moves: [BoardMove]
    let delete: () -> Void
    @State private var hovered = false
    @State private var pointerX = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isGhost: Bool { drag.heldPath == entry.path }

    var body: some View {
        let pose = Motion.HoverPose.compact.resolved(hovered: hovered && !drag.isHolding, reduceMotion: reduceMotion)
        BoardCardFace(model: model, entry: entry, elevation: pose == .rest ? .rest : .hover)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: BoardSpace.content) } action: { frame in
                drag.cardFrames[entry.path] = frame
            }
            .onDisappear { drag.cardFrames[entry.path] = nil }
            .scaleEffect(pose.scale)
            .rotation3DEffect(.degrees(pose.tilt(pointerX: pointerX)), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
            .offset(y: -pose.lift)
            .motion(Motion.Spring.lift, value: pose == .rest)
            .motion(Motion.follow, value: pointerX)
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    hovered = true
                    pointerX = Double(point.x / BoardMetrics.cardWidth) * 2 - 1
                case .ended:
                    hovered = false
                    pointerX = 0
                }
            }
            // The ghost: swapped for the card at once, under the copy that is lifted from the same frame.
            .opacity(isGhost ? 0.35 : 1)
            .overlay {
                RoundedRectangle(cornerRadius: Corners.r(8), style: .continuous)
                    .strokeBorder(tint.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .opacity(isGhost ? 1 : 0)
            }
            .animation(nil, value: isGhost)
            .zIndex(hovered ? 1 : 0)
            .tappableRow { model.open(entry.path, placement: NSEvent.modifierFlags.contains(.command) ? .newTab : .beside) }
            .contextMenu {
                Button("Open") { model.open(entry.path, placement: .beside) }
                Button("Open in New Tab") { model.open(entry.path, placement: .newTab) }
                if !moves.isEmpty {
                    Menu("Move to") {
                        ForEach(moves) { move in Button(move.name, action: move.action) }
                    }
                }
                Divider()
                Button("Delete", role: .destructive, action: delete)
            }
            .help("Open \(entry.title)")
    }
}

/// The copy of the card that follows the pointer, above everything, 1:1: it rises under the hand (bigger, a deeper
/// shadow, leaning with the hand's speed) and, when let go, falls onto its ghost.
struct HeldCardLayer: View {
    let model: CollectionViewModel
    let entry: NoteRecord
    let drag: BoardDragModel
    @State private var lifted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let held = lifted && !drag.isLanding
        BoardCardFace(model: model, entry: entry, elevation: held ? .held : .rest)
            .frame(width: drag.heldSize.width)
            .scaleEffect(held && !reduceMotion ? 1.03 : 1)
            .rotationEffect(.degrees(reduceMotion ? 0 : drag.tilt))
            .motion(Motion.Spring.lift, value: held)
            .offset(x: drag.heldTopLeft.x, y: drag.heldTopLeft.y)
            // 1:1 with the hand: the gap's spring never reaches it.
            .animation(nil, value: drag.heldTopLeft)
            .allowsHitTesting(false)
            .transition(.identity)
            .onAppear { lifted = true }
    }
}

/// A column's tinted background; it takes the stronger tint and a dashed outline while a card is held over it.
struct BoardColumnBackground: View {
    let swatch: OptionPalette.Swatch
    let targeted: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: Corners.r(10), style: .continuous)
            .fill(targeted ? swatch.fill : swatch.tint)
            .overlay(RoundedRectangle(cornerRadius: Corners.r(10), style: .continuous)
                .strokeBorder(swatch.text.opacity(targeted ? 0.25 : 0), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
            .motion(Motion.hover, value: targeted)
    }
}

/// The value as a pill and how many cards.
struct BoardColumnHeader: View {
    let name: String
    let options: [String]
    let count: Int
    @Environment(\.themeTokens) private var theme

    var body: some View {
        HStack(spacing: 8) {
            OptionPill(name, options: options, size: 14)
            Text("\(count)").monospacedDigit().themeLabel(size: UIType.label.size).foregroundStyle(theme.secondaryText)
                .contentTransition(.numericText())
                .motion(Motion.Spring.standard, value: count)
            Spacer(minLength: 0)
        }
        .padding(.bottom, 2)
    }
}

/// The inline field that turns into a card on Return.
struct BoardAddField: View {
    @Binding var title: String
    let commit: () -> Void
    let cancel: () -> Void
    @FocusState private var focused: Bool
    @Environment(\.themeTokens) private var theme

    var body: some View {
        TextField("Title", text: $title)
            .textFieldStyle(.plain)
            .font(.ui(size: 15, weight: .semibold))
            .focused($focused)
            .onSubmit(commit)
            .onExitCommand(perform: cancel)
            .onAppear { focused = true }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: Corners.r(8), style: .continuous).fill(theme.background))
            .overlay(RoundedRectangle(cornerRadius: Corners.r(8), style: .continuous)
                .strokeBorder(theme.accent.opacity(0.5), lineWidth: 1.5))
    }
}

/// "+" under a column's cards.
struct BoardPlusButton: View {
    let swatch: OptionPalette.Swatch
    let help: String
    let action: () -> Void
    @Environment(\.themeTokens) private var theme

    var body: some View {
        Button(action: action) {
            Image(symbol: "plus").font(.ui(size: 15)).foregroundStyle(theme.secondaryText)
                .frame(maxWidth: .infinity, minHeight: 40)
                .collectionHover(cornerRadius: Corners.r(8), strength: 0.07)
                .background(RoundedRectangle(cornerRadius: Corners.r(8), style: .continuous).fill(theme.background.opacity(0.55)))
                .overlay(RoundedRectangle(cornerRadius: Corners.r(8), style: .continuous).strokeBorder(swatch.text.opacity(0.08)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// "“Title” deleted · Undo", at the bottom of the board for a few seconds after a card went to the trash.
struct BoardUndoBar: View {
    let title: String
    let undo: () -> Void
    @Environment(\.themeTokens) private var theme

    var body: some View {
        HStack(spacing: 12) {
            Text("“\(title)” deleted").lineLimit(1).foregroundStyle(theme.text)
            Button("Undo", action: undo)
                .buttonStyle(.plain)
                .foregroundStyle(theme.accent)
                .fontWeight(.semibold)
        }
        .font(.ui(size: 13))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(ThemeCapsule().fill(theme.background))
        .overlay(ThemeCapsule().strokeBorder(theme.separator.opacity(0.7)))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .padding(.bottom, 14)
    }
}
