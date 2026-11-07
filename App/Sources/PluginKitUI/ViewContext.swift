import Foundation
import Observation
import SwiftUI

/// What one tab gives the view it shows: the resource, whether the tab is focused, and a small saved state.
///
/// The shell creates one per tab and keeps it for the tab's life, so a view rebuilt by SwiftUI finds its state
/// again. The state (caret, scroll, zoom) is opaque JSON the shell stores with the layout, so a view can save
/// anything `Codable` without the shell knowing its type.
@MainActor
@Observable
public final class ViewContext {
    public let resource: Resource
    /// Where the view is shown: a tab's page, or embedded in another view (a card on a board). A hint, as
    /// `Placement` is: an embedded view drops its page chrome (toolbars, banners, its own background), does not take
    /// the keyboard on its own, and leaves scrolling to its host unless it is active.
    public let presentation: ViewPresentation
    /// Whether this tab is the focused one. Set by the shell only; a view reads it.
    public var isActive: Bool
    /// The encoded state, as the shell stores it. Views use `state(_:)` and `setState(_:)` instead.
    public private(set) var stateData: Data?
    /// What the page's toolbar shows once the view's own title has scrolled under it, as Craft shows a note's name
    /// and folder there; nil shows nothing. Set by the view, read by the shell.
    public var toolbarTitle: ToolbarTitle?
    /// The tabs the view gives the right sidebar (`setInspector`); nil for none. Set by the view, read by the shell.
    public var inspector: InspectorContent?
    /// What Back does first while the view shows something over its page (a diagram shown large): closing it, so
    /// Back leaves the page only once the page is what shows. Set by the view while it lasts, called by the shell.
    @ObservationIgnored public var back: (@MainActor () -> Void)? {
        didSet { hasBack = back != nil }
    }
    /// Whether `back` is set, observed so the toolbar's Back is enabled while it is.
    public private(set) var hasBack = false
    /// For an embedded view whose content has a natural size (a mindmap on a board): where its content lies, in the
    /// view's own points at 100 %, the view drawing it at that scale with nothing round it. A host may then make its
    /// card that size, and move the card by as much as the content's origin moves, so the content stays put on
    /// screen as it grows. Set by the view, read by the host; nil for a view that fills whatever it is given.
    public var contentBounds: CGRect?
    /// Called by `setState` with the new encoded state, so the shell can save the layout. Set by the shell.
    @ObservationIgnored public var onStateChange: ((Data?) -> Void)?

    public init(resource: Resource, state: Data? = nil, isActive: Bool = false, presentation: ViewPresentation = .page) {
        self.resource = resource
        self.presentation = presentation
        self.stateData = state
        self.isActive = isActive
    }

    /// The saved state, or nil if there is none or it does not decode as `T` (an older version of the view
    /// saved something else: starting fresh is better than failing).
    public func state<T: Decodable>(_ type: T.Type) -> T? {
        guard let stateData else { return nil }
        return try? JSONDecoder().decode(T.self, from: stateData)
    }

    /// Saves `value` as this tab's state and tells the shell. A value that fails to encode clears the state.
    public func setState<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        stateData = try? encoder.encode(value)
        onStateChange?(stateData)
    }
}

/// Where a view is shown: see `ViewContext.presentation`.
public enum ViewPresentation: String, Codable, Sendable {
    /// The whole page of a tab.
    case page
    /// Inside another view, such as a card on a board. `isActive` says whether it has the user's attention (the
    /// card was entered); while it is not, the host takes the clicks.
    case embedded
}

/// A title for the page's toolbar: a name and, under it, where it lives (a note's folder).
public struct ToolbarTitle: Equatable, Sendable {
    public var title: String
    public var subtitle: String?
    /// The SF Symbol before the subtitle: a folder for a note's place, the file's own for a viewer's details.
    public var symbol: String

    public init(title: String, subtitle: String? = nil, symbol: String = "folder") {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
    }
}

/// The page's own measurements, shared by its toolbar and the views under it so their left edges meet.
public enum PageMetrics {
    /// The page's narrowest side margin, and where the toolbar's first button starts: the text of a narrow note or
    /// of the home page lines up with Back.
    public static let edge: CGFloat = 32
}

public extension EnvironmentValues {
    /// The height of the page's toolbar, which floats over the top of a tab's view. A view that scrolls under it
    /// (`.ignoresSafeArea(.container, edges: .top)`) keeps this much room above its content; others are laid out
    /// below it.
    @Entry var pageChromeInset: CGFloat = 0
    /// True while a sidebar slides in or out: a page's view can move its content to the new width with the slide.
    @Entry var sidebarSliding = false
}
