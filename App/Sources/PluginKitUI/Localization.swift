import Foundation

public extension String {
    /// This text in the app's language: the translation in the app bundle's `Localizable.strings`, or itself.
    /// SwiftUI translates literal `Text("…")` on its own; titles that arrive as `String` (commands, menu items,
    /// sections) go through this.
    var uiLocalized: String {
        Bundle.main.localizedString(forKey: self, value: self, table: nil)
    }
}
