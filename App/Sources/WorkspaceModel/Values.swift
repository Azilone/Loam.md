import Foundation
import PluginKitUI

/// Identifies a tab for its whole life, across moves between panes, so a view's state follows it.
public struct TabID: Hashable, Codable, Sendable {
    public let raw: UUID
    public init(raw: UUID) { self.raw = raw }
}

/// Identifies a pane, so the shell can focus or drop onto it without holding a path into the tree.
public struct PaneID: Hashable, Codable, Sendable {
    public let raw: UUID
    public init(raw: UUID) { self.raw = raw }
}

/// One resource shown with one view type. `state` is the view's own small `Codable` state (caret, scroll, zoom),
/// opaque to the model so the layout can be saved without knowing any view.
public struct Tab: Codable, Equatable, Sendable {
    public let id: TabID
    public var resource: Resource
    /// The view type chosen with "Open with"; nil lets the shell pick the highest priority one.
    public var viewType: String?
    public var state: Data?

    public init(id: TabID, resource: Resource, viewType: String? = nil, state: Data? = nil) {
        self.id = id
        self.resource = resource
        self.viewType = viewType
        self.state = state
    }
}

/// A stack of tabs with one selected. Empty only when it is the last pane of the workspace.
public struct Pane: Codable, Equatable, Sendable {
    public let id: PaneID
    public var tabs: [Tab]
    public var selected: TabID?

    public init(id: PaneID, tabs: [Tab] = [], selected: TabID? = nil) {
        self.id = id
        self.tabs = tabs
        self.selected = selected
    }
}

/// `horizontal` puts the children side by side, `vertical` stacks them.
public enum SplitAxis: String, Codable, Sendable { case horizontal, vertical }

/// The layout tree. A split's `fractions` give each child's share of the split's length and sum to 1.
public indirect enum LayoutNode: Codable, Equatable, Sendable {
    case pane(Pane)
    case split(id: UUID, axis: SplitAxis, children: [LayoutNode], fractions: [Double])
}

/// Where a tab or a resource is dropped on a pane: an edge splits the pane, the center adds a tab to it.
public enum DropEdge: Sendable, Equatable {
    case leading, trailing, top, bottom, center
}
