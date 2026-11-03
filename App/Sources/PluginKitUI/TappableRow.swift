import SwiftUI

public extension View {
    /// A row that runs `action` when clicked, and that VoiceOver, keyboard access and UI automation see as one
    /// button with the row's text as its label. A bare `onTapGesture` leaves the row invisible to them.
    func tappableRow(_ action: @escaping () -> Void) -> some View {
        contentShape(Rectangle())
            .onTapGesture { action() }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }
}
