import AppKit
import Synchronization
import SwiftUI

/// Loam's own symbols, for what SF Symbols has no picture of (a mindmap). Drawn as SF Symbol templates in
/// App/Resources/Symbols.xcassets, compiled into the app's asset catalog by scripts/build-app.sh, so they follow the
/// font, weight and colour like any SF Symbol. A symbol name anywhere in Loam (a view type, a command, a plugin's
/// icon) is either an SF Symbol or one of these `loam.` names: show it with `Image(symbol:)` or `NSImage(symbol:)`.
public enum LoamSymbol {
    /// A central topic with branches out to both sides.
    public static let mindmap = "loam.mindmap"

    /// The SF Symbol shown in place of each one when the app's catalog is missing (tests, a bare `swift build`).
    /// GitHub's mark (Primer Octicons, MIT), for the sync's GitHub rows.
    public static let github = "loam.github"
    static let fallbacks = [mindmap: "point.3.connected.trianglepath.dotted",
                            github: "chevron.left.forwardslash.chevron.right"]

    /// Whether `name` is one of Loam's symbols rather than an SF Symbol.
    public static func isLoam(_ name: String) -> Bool { name.hasPrefix("loam.") }

    /// The catalog image of one of Loam's symbols, nil when the app has no catalog.
    static func image(_ name: String) -> NSImage? { Bundle.main.image(forResource: name) }

    /// Whether the app's catalog has `name`, asked once per name: views ask on every draw.
    static func inCatalog(_ name: String) -> Bool {
        if let known = catalog.withLock({ $0[name] }) { return known }
        let found = image(name) != nil
        catalog.withLock { $0[name] = found }
        return found
    }

    private static let catalog = Mutex<[String: Bool]>([:])

    /// Whether `name` shows as a symbol here: an SF Symbol of this system, or one of Loam's.
    public static func exists(_ name: String) -> Bool {
        if isLoam(name) { return fallbacks[name] != nil }
        return NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }
}

public extension Image {
    /// An SF Symbol or one of Loam's own symbols (`LoamSymbol`).
    init(symbol name: String) {
        if LoamSymbol.isLoam(name) {
            if LoamSymbol.image(name) != nil {
                self.init(name)
            } else {
                self.init(systemName: LoamSymbol.fallbacks[name] ?? "questionmark.square.dashed")
            }
        } else {
            self.init(systemName: name)
        }
    }
}

public extension Label where Title == Text, Icon == Image {
    /// A label with an SF Symbol or one of Loam's own symbols (`LoamSymbol`).
    init(_ title: some StringProtocol, symbol name: String) {
        self.init { Text(title) } icon: { Image(symbol: name) }
    }

    /// A localized label with an SF Symbol or one of Loam's own symbols (`LoamSymbol`).
    init(_ titleKey: LocalizedStringKey, symbol name: String) {
        self.init { Text(titleKey) } icon: { Image(symbol: name) }
    }
}

public extension Button where Label == SwiftUI.Label<Text, Image> {
    /// A button with an SF Symbol or one of Loam's own symbols.
    init(_ titleKey: LocalizedStringKey, symbol name: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.init(role: role, action: action) { SwiftUI.Label(titleKey, symbol: name) }
    }

    @_disfavoredOverload
    init(_ title: some StringProtocol, symbol name: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.init(role: role, action: action) { SwiftUI.Label(title, symbol: name) }
    }
}

public extension ContentUnavailableView where Label == SwiftUI.Label<Text, Image>, Description == Text?, Actions == EmptyView {
    /// An empty state with an SF Symbol or one of Loam's own symbols.
    init(_ titleKey: LocalizedStringKey, symbol name: String, description: Text? = nil) {
        self.init { SwiftUI.Label(titleKey, symbol: name) } description: { description }
    }

    @_disfavoredOverload
    init(_ title: some StringProtocol, symbol name: String, description: Text? = nil) {
        self.init { SwiftUI.Label(title, symbol: name) } description: { description }
    }
}

public extension NSImage {
    /// An SF Symbol or one of Loam's own symbols (`LoamSymbol`), nil when this system has neither. Takes a symbol
    /// configuration like any SF Symbol.
    static func symbol(_ name: String, accessibilityDescription description: String?) -> NSImage? {
        guard LoamSymbol.isLoam(name) else {
            return NSImage(systemSymbolName: name, accessibilityDescription: description)
        }
        if let image = LoamSymbol.image(name)?.copy() as? NSImage {
            image.accessibilityDescription = description
            return image
        }
        return LoamSymbol.fallbacks[name].flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: description) }
    }
}
