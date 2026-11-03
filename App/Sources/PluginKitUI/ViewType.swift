import SwiftUI

/// A kind of view a plugin offers for some resources: the Markdown editor for `.md` files, a board for a Kanban
/// note, a calendar for `calendar:` pages.
///
/// When several types can open one resource, the highest `priority` wins and the user can pick another with
/// "Open with". The closures run on the main actor because they touch SwiftUI.
public struct ViewType: Identifiable, Sendable {
    /// Dotted and owned by the plugin, such as `markdown.editor`. "Open with" choices are saved under it.
    public let id: String
    /// Shown in "Open with".
    public let title: String
    public let priority: Int
    /// SF Symbol of the view: the icon of the notes it opens by default (sidebar, grid) and of its button in the
    /// page's view switcher. Nil for none.
    public let symbol: String?
    /// True for a viewer of files that are not Loam's own formats (pictures, PDFs): tabs and the Files panel show
    /// their whole name, `photo.heic`, since `photo.jpg` is another file. A note or a board shows without it.
    public let keepsExtension: Bool
    public let canOpen: @MainActor (Resource) -> Bool
    /// True for the resources this type should open by default whatever the priorities, such as a note flagged as a
    /// board or a mindmap. The editor still opens them with "Open with" or the view switcher.
    public let prefers: @MainActor (Resource) -> Bool
    public let makeView: @MainActor (ViewContext) -> AnyView
    /// True when the view can follow its tab to another resource of the same type: a link, a sidebar row or a
    /// backlink that replaces the page keeps the view and hands it the new resource's `ViewContext`, instead of making
    /// the view again (the editor keeps its text view and swaps the text in). The view must then read everything about
    /// its resource from the `ViewContext` it is given now, not from its first one. Pages opened from a card, Back
    /// and other tabs still get a new view. False by default.
    public var followsResource = false
    /// True when the view, embedded, draws its content at 100 % at its own size and says where it is
    /// (`ViewContext.contentBounds`): a mindmap. A host shows it as content of its own (a board: no card round it,
    /// sized to it) rather than as a window onto a file. False by default.
    public var sizesToContent = false

    public init(
        id: String,
        title: String,
        priority: Int = 0,
        symbol: String? = nil,
        keepsExtension: Bool = false,
        canOpen: @escaping @MainActor (Resource) -> Bool,
        prefers: @escaping @MainActor (Resource) -> Bool = { _ in false },
        makeView: @escaping @MainActor (ViewContext) -> AnyView
    ) {
        self.id = id
        self.title = title
        self.priority = priority
        self.symbol = symbol
        self.keepsExtension = keepsExtension
        self.canOpen = canOpen
        self.prefers = prefers
        self.makeView = makeView
    }
}
