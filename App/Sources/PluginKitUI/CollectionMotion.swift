import SwiftUI

/// The motion of collection views: short springs for what moves (rows and cards coming, going or changing place,
/// a view replacing another), quick fades for hover. Under "Reduce motion" everything becomes a short cross-fade.
/// The numbers are `Motion`'s (see docs/design/MOTION.md); these names stay for the collection plugins.
public enum CollectionMotion {
    /// What changes place or size: entries sorted, filtered, added, removed.
    public static let layout = Motion.Spring.standard.animation
    /// A view replacing another, a field opening.
    public static let reveal = Motion.Spring.smooth.animation
    /// Hover and focus colours.
    public static let hover = Motion.hover
    /// What replaces motion when the system asks to reduce it.
    public static let fade = Motion.fade
    /// A row or card appearing: a little lower and smaller, fading in.
    public static var enter: AnyTransition { .opacity.combined(with: .scale(scale: 0.96, anchor: .top)) }
    /// A row or card leaving: fading out in place.
    public static var leave: AnyTransition { .opacity }
}

extension View {
    /// `animation(_:value:)` that falls back to a short fade under "Reduce motion".
    public func collectionAnimation<Value: Equatable>(_ animation: Animation = CollectionMotion.layout, value: Value) -> some View {
        modifier(CollectionAnimation(animation: animation, value: value))
    }

    /// `transition(_:)` that falls back to a fade under "Reduce motion".
    public func collectionTransition(_ transition: AnyTransition) -> some View {
        modifier(CollectionTransition(transition: transition))
    }

    /// A soft rounded fill behind the view while the pointer is over it (a tab, a tool button, a table row).
    public func collectionHover(cornerRadius: CGFloat = 6, strength: Double = 0.06, isEnabled: Bool = true) -> some View {
        modifier(CollectionHover(cornerRadius: Corners.r(cornerRadius), strength: strength, isEnabled: isEnabled))
    }
}

private struct CollectionAnimation<Value: Equatable>: ViewModifier {
    let animation: Animation
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion || Motion.reduceMotion ? CollectionMotion.fade : animation, value: value)
    }
}

private struct CollectionTransition: ViewModifier {
    let transition: AnyTransition
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transition(reduceMotion || Motion.reduceMotion ? .opacity : transition)
    }
}

private struct CollectionHover: ViewModifier {
    let cornerRadius: CGFloat
    let strength: Double
    let isEnabled: Bool
    @State private var hovered = false
    @Environment(\.themeTokens) private var theme

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: Corners.r(cornerRadius), style: .continuous)
                    .fill(theme.accent.opacity(hovered && isEnabled ? strength * 1.3 : 0))
            }
            .onHover { hovered = $0 }
            .animation(CollectionMotion.hover, value: hovered)
    }
}

/// What a collection view shows without entries: a quiet icon, one line, and "New entry" when nothing was
/// searched for. The same action as the page's "+".
public struct CollectionEmptyState: View {
    let model: CollectionViewModel
    let symbol: String

    public init(model: CollectionViewModel, symbol: String = "tray") {
        self.model = model
        self.symbol = symbol
    }

    private var query: String { model.searchText.trimmingCharacters(in: .whitespaces) }

    public var body: some View {
        EmptyState(
            query.isEmpty ? "No entries yet" : "No results",
            symbol: query.isEmpty ? symbol : "magnifyingglass",
            message: query.isEmpty ? "Notes of this collection appear here." : "Nothing matches “\(query)”.",
            actionTitle: query.isEmpty ? "New entry" : nil,
            action: query.isEmpty ? { [model] in
                if let path = model.newEntry() { model.open(path, placement: .beside) }
            } : nil
        )
    }
}

/// "Field “Status” deleted · Undo", at the bottom of a collection page for a few seconds after a deletion.
public struct CollectionUndoBar: View {
    let message: String
    let undo: () -> Void
    @Environment(\.themeTokens) private var theme

    public init(message: String, undo: @escaping () -> Void) {
        self.message = message
        self.undo = undo
    }

    public var body: some View {
        HStack(spacing: 12) {
            Text(message.uiLocalized).lineLimit(1).foregroundStyle(theme.text)
            Button("Undo", action: undo)
                .buttonStyle(.plain)
                .foregroundStyle(theme.accent)
                .fontWeight(.semibold)
        }
        .font(.ui(.body))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(ThemeCapsule().fill(theme.background))
        .overlay(ThemeCapsule().strokeBorder(theme.separator.opacity(0.7)))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .padding(.bottom, 14)
    }
}
