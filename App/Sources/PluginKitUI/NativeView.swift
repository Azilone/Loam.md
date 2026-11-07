import AppKit
import Observation
import SwiftUI

/// What a host tells a plugin's AppKit view (`ViewType.makeNSView`, `CollectionViewType.makeNSView`) as it changes.
public struct NativeViewEnvironment: Equatable, Sendable {
    public var theme: ThemeTokens
    /// The height of the page's toolbar over the top of the view: a view that scrolls keeps this much room above its
    /// content, which then scrolls up under the toolbar's glass (`pageChromeInset` in SwiftUI). Zero when embedded.
    public var topInset: CGFloat

    public init(theme: ThemeTokens, topInset: CGFloat = 0) {
        self.theme = theme
        self.topInset = topInset
    }
}

/// Adopted by a plugin's AppKit view that follows its host: the theme and the toolbar's room, and the size it wants
/// when embedded (a collection in a note is as tall as its content). A view that does not adopt it is shown as made,
/// filling what it is given.
@MainActor
public protocol NativeHostedView: AnyObject {
    /// Called once before the view is first shown, then on each change.
    func hostEnvironmentChanged(_ environment: NativeViewEnvironment)
    /// The size the view wants for a width, at most `maxHeight` when the host has a limit; nil takes what it is given.
    func fittingSize(width: CGFloat, maxHeight: CGFloat?) -> CGSize?
}

public extension NativeHostedView {
    func fittingSize(width: CGFloat, maxHeight: CGFloat?) -> CGSize? { nil }
}

/// Shows an AppKit view inside SwiftUI with the host's environment: a collection view type's `makeNSView` in the
/// collection page, a `makeView` that is its AppKit view (one implementation, no SwiftUI twin).
public struct NativeView: NSViewRepresentable {
    private let make: @MainActor () -> NSView
    @Environment(\.themeTokens) private var theme
    @Environment(\.pageChromeInset) private var chromeInset

    public init(_ make: @escaping @MainActor () -> NSView) {
        self.make = make
    }

    public func makeNSView(context: Context) -> NSView {
        let view = make()
        updateNSView(view, context: context)
        return view
    }

    public func updateNSView(_ view: NSView, context: Context) {
        (view as? NativeHostedView)?.hostEnvironmentChanged(NativeViewEnvironment(theme: theme, topInset: chromeInset))
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        // SwiftUI asks for an ideal size with an infinite or missing width: the view's own width then.
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? nsView.bounds.width
        let maxHeight = proposal.height.flatMap { $0.isFinite ? $0 : nil }
        if let hosted = nsView as? NativeHostedView, let size = hosted.fittingSize(width: width, maxHeight: maxHeight) {
            return size
        }
        return proposal.replacingUnspecifiedDimensions(by: .zero)
    }
}

/// Runs `apply` with what `read` returns now, then again each time something `read` observed changes and the value
/// it returns is a new one: what an AppKit view uses in place of a SwiftUI body to follow an `@Observable` model. A
/// value that came back the same runs nothing.
///
/// `apply` runs on the turn of the main queue after the change (Observation tells before the change is made), before
/// the frame is drawn. Stops when it is released.
@MainActor
public final class Follow<Value: Equatable> {
    private let read: @MainActor () -> Value
    private let apply: @MainActor (Value) -> Void
    private var last: Value?

    public init(_ read: @escaping @MainActor () -> Value, apply: @escaping @MainActor (Value) -> Void) {
        self.read = read
        self.apply = apply
        run()
    }

    private func run() {
        let value = withObservationTracking { read() } onChange: { [weak self] in
            DispatchQueue.main.async { self?.run() }
        }
        guard value != last else { return }
        last = value
        apply(value)
    }
}
