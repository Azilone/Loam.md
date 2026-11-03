import PluginKitUI
import SwiftUI
import WorkspaceModel

/// What a pane's page is, for the purpose of telling that it changed: the selected tab, the resource it shows and the
/// view type picked for it.
struct PageKey: Hashable {
    let tab: TabID
    let resource: Resource
    let viewType: String?

    init(_ tab: WorkspaceModel.Tab) {
        self.tab = tab.id
        resource = tab.resource
        viewType = tab.viewType
    }
}

/// A pane as it was before and after a change: its page and the order of its tabs.
struct PaneSnapshot: Equatable {
    var key: PageKey?
    var tabs: [TabID]

    init(key: PageKey?, tabs: [TabID]) {
        self.key = key
        self.tabs = tabs
    }

    init(_ pane: Pane) {
        key = pane.tabs.first { $0.id == pane.selected }.map(PageKey.init)
        tabs = pane.tabs.map(\.id)
    }

    static func of(_ layout: WorkspaceLayout) -> [PaneID: PaneSnapshot] {
        Dictionary(layout.panes.map { ($0.id, PaneSnapshot($0)) }, uniquingKeysWith: { first, _ in first })
    }
}

/// Why a pane's page changed, which decides how the new page arrives and the old one leaves
/// (`docs/design/MOTION.md`, "Pages, tabs and panes"). Computed by the controller when the layout changes, from the
/// pane before and after, so the views only draw it.
enum PageChange: Equatable {
    /// No known reason: the pages cross-fade.
    case crossfade
    /// A resource replaced the page in the same tab with no origin (a sidebar row, a link, a backlink): the new page
    /// is there at once, as in Craft. A fade here would hold the note back for its whole length.
    case replaced
    /// Another tab was selected, or one was opened: the page comes from the side of the new tab (+1 right of the
    /// old one, -1 left of it).
    case tab(direction: Int)
    /// The selected tab was closed (or moved away): the neighbour's page fades in, with no direction.
    case closed
    /// The same resource in another view (table, board, cards): a swap in place.
    case swap
    /// A resource replaced the page, from where the click came.
    case opened(OpenOrigin)
    /// Back to what the tab showed before: the page shrinks to where it had come from (only when known).
    case back(OpenOrigin?)

    /// The change of one pane's page, nil when the page is the same. `origin` and `isBack` describe the user action
    /// behind it, and count only for the tab that stays the same (a page replacing another in a tab).
    static func between(_ before: PaneSnapshot, _ after: PaneSnapshot, origin: OpenOrigin?, isBack: Bool) -> PageChange? {
        guard before.key != after.key else { return nil }
        guard let old = before.key, let new = after.key else { return .crossfade }
        if old.tab != new.tab {
            guard let from = after.tabs.firstIndex(of: old.tab), let to = after.tabs.firstIndex(of: new.tab) else {
                return .closed
            }
            return .tab(direction: to > from ? 1 : -1)
        }
        if old.resource == new.resource { return .swap }
        // Back to a page that came from no card swaps at once, as a link does (Craft's): scaling two whole pages
        // while the arriving one lays out its text dropped frames.
        if isBack { return origin.map { .back($0) } ?? .replaced }
        if let origin { return .opened(origin) }
        return .replaced
    }

    /// The spring or fade the arriving page moves with. Reduce Motion replaces it by the short fade where it is used.
    var animation: Animation {
        switch self {
        case .crossfade, .tab, .closed, .replaced: Motion.crossfade
        case .swap, .opened, .back: Motion.Spring.smooth.animation
        }
    }

    /// How the arriving page starts, in a pane at `pane` (window coordinates).
    func arriving(in pane: CGRect) -> PageEffect {
        switch self {
        case .crossfade, .closed:
            return .identity
        case .replaced:
            return .instant
        case .tab(let direction):
            return PageEffect(offset: CGSize(width: CGFloat(direction) * Motion.Metrics.tabShift, height: 0))
        case .swap:
            return PageEffect(scale: Motion.Metrics.swapScale)
        case .back:
            return PageEffect(scale: Motion.Metrics.pageLeaveScale)
        case .opened(let origin):
            switch origin.source {
            case .frame:
                return PageEffect(scale: Motion.Metrics.pageEnterScale, anchor: origin.anchor(in: pane))
            case .sidebar(let edge):
                let side: CGFloat = edge == .leading ? -1 : 1
                return PageEffect(offset: CGSize(width: side * Motion.Metrics.sidebarShift, height: 0))
            case .palette:
                return PageEffect(scale: Motion.Metrics.pageLeaveScale, anchor: .top)
            }
        }
    }

    /// How the leaving page ends: it fades, and a page replaced from a card is already a little smaller; one going
    /// back shrinks toward where it came from.
    func leaving(in pane: CGRect) -> PageEffect {
        switch self {
        case .opened:
            return PageEffect(scale: Motion.Metrics.pageLeaveScale)
        case .back(let origin?):
            return PageEffect(scale: Motion.Metrics.pageEnterScale, anchor: origin.anchor(in: pane))
        case .back(nil):
            return PageEffect(scale: Motion.Metrics.pageEnterScale)
        case .replaced:
            return .instant
        case .crossfade, .tab, .closed, .swap:
            return .identity
        }
    }
}

/// The pose of a page at the start of its arrival or the end of its departure. Opacity is not here: a page always
/// fades, and that is all it does under Reduce Motion.
struct PageEffect: Equatable {
    var scale: CGFloat = 1
    var anchor: UnitPoint = .center
    var offset: CGSize = .zero
    /// The page does not animate at all: it appears (or goes) in the same frame.
    var isInstant = false

    static let identity = PageEffect()
    static let instant = PageEffect(isInstant: true)
}

extension Motion.Metrics {
    /// A page opened from a card starts this much smaller, and a page going back ends this much smaller.
    static let pageEnterScale: CGFloat = 0.94
    /// The page that is replaced, and one rising from the palette, differ from rest by this much.
    static let pageLeaveScale: CGFloat = 0.98
    /// A view swapped in place (table, board, cards) starts this much smaller.
    static let swapScale: CGFloat = 0.99
    /// A page of another tab comes from the side by this many points.
    static let tabShift: CGFloat = 12
    /// A page opened from a sidebar arrives from its edge by this many points.
    static let sidebarShift: CGFloat = 8
    /// A pane opened in a split arrives from its edge by this many points.
    static let paneShift: CGFloat = 24
}
