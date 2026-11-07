import SwiftUI

public extension EnvironmentValues {
    /// How a status bar panel is drawn where the shell puts it (`StatusStyle`).
    @Entry var statusStyle = StatusStyle.item
}

/// The forms of a status bar panel. One with no state worth showing draws nothing in the small ones.
public enum StatusStyle: Sendable {
    /// Its own icon.
    case item
    /// A small coloured dot over something else (the vault's icon in the left sidebar).
    case dot
    /// The dot and a few words, at the end of a menu row (the vault menu's "Sync": "2 min ago").
    case detail
}

/// The places of the window that plugins fill. The shell owns their layout; a panel only says where it goes.
public enum Slot: String, Codable, CaseIterable, Sendable {
    case leading, trailing, statusBar
}

/// A view placed in a slot: the file explorer in `.leading`, backlinks in `.trailing`, a word count in
/// `.statusBar`. Panels are not tied to a resource; one that follows the open note listens to
/// `ActiveResourceChanged` or reads `Workspace.activeResource`.
public struct Panel: Identifiable, Sendable {
    public let id: String
    public let title: String
    /// SF Symbol name, for the slot's tab bar.
    public let symbol: String
    public let slot: Slot
    /// Position within the slot, lowest first.
    public let order: Int
    /// Display options shown under the panel in Settings > Sidebars (Files: "Show recent notes").
    public let options: [PanelOption]
    public let makeView: @MainActor () -> AnyView

    public init(
        id: String,
        title: String,
        symbol: String,
        slot: Slot,
        order: Int = 0,
        options: [PanelOption] = [],
        makeView: @escaping @MainActor () -> AnyView
    ) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.slot = slot
        self.order = order
        self.options = options
        self.makeView = makeView
    }
}

/// A switch about how a panel looks, which the shell puts under the panel in Settings > Sidebars. The plugin keeps
/// the value (usually in its `context.settings`) and redraws the panel when `set` is called.
public struct PanelOption: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let isOn: @MainActor () -> Bool
    public let set: @MainActor (Bool) -> Void

    public init(id: String, title: String, isOn: @escaping @MainActor () -> Bool, set: @escaping @MainActor (Bool) -> Void) {
        self.id = id
        self.title = title
        self.isOn = isOn
        self.set = set
    }
}

/// A row of the navigation group at the top of the left sidebar (Craft's "All Docs", "Tasks", "Calendar"): a
/// title and a symbol that open a resource, usually a plugin's virtual page. The shell draws the group; a plugin
/// only says what to open.
public struct SidebarLink: Identifiable, Sendable {
    public let id: String
    public let title: String
    /// SF Symbol name.
    public let symbol: String
    /// What a click opens, in the focused tab.
    public let resource: Resource
    /// Position in the group, lowest first, until the user reorders the group (Customize).
    public let order: Int
    /// False for a row that starts hidden until turned on in Customize.
    public let isShownByDefault: Bool
    /// A number shown in grey at the row's end (the open tasks), nil for none. Read when drawing, so it should read
    /// observable state.
    public let count: (@MainActor @Sendable () -> Int?)?
    /// Run on a click instead of opening `resource` (the recorder's "Record"), nil to open it.
    public let action: (@MainActor @Sendable () -> Void)?

    public init(
        id: String, title: String, symbol: String, resource: Resource, order: Int = 0, isShownByDefault: Bool = true,
        count: (@MainActor @Sendable () -> Int?)? = nil, action: (@MainActor @Sendable () -> Void)? = nil
    ) {
        self.action = action
        self.id = id
        self.title = title
        self.symbol = symbol
        self.resource = resource
        self.order = order
        self.isShownByDefault = isShownByDefault
        self.count = count
    }
}

/// A section of the left sidebar under the navigation group (Craft's "Starred", "Folders", "Tags"): a title the
/// shell draws, folds and hides, over the rows the plugin draws. The rows go in the sidebar's one scroll view, so
/// the view must not scroll itself.
public struct SidebarSection: Identifiable, Sendable {
    public let id: String
    public let title: String
    /// Position among the sections, lowest first, until the user reorders them (Customize).
    public let order: Int
    /// False for a section that starts hidden until turned on in Customize.
    public let isShownByDefault: Bool
    /// True for a section that starts folded.
    public let isCollapsedByDefault: Bool
    /// The "+" the title shows on hover (Craft's "New Folder" beside "Folders"): its tooltip and what it does.
    public let add: SidebarSectionAdd?
    public let makeView: @MainActor @Sendable () -> AnyView
    /// True while the section has nothing to show: the sidebar leaves it out, title included (Favorites, until a note
    /// is starred). Read when drawing, so it should read observable state.
    public var isEmpty: (@MainActor @Sendable () -> Bool)?

    public init(
        id: String, title: String, order: Int = 0, isShownByDefault: Bool = true, isCollapsedByDefault: Bool = false,
        add: SidebarSectionAdd?, makeView: @escaping @MainActor @Sendable () -> AnyView
    ) {
        self.id = id
        self.title = title
        self.order = order
        self.isShownByDefault = isShownByDefault
        self.isCollapsedByDefault = isCollapsedByDefault
        self.add = add
        self.makeView = makeView
    }

    /// The init of plugin SDK 1.3, kept for the plugins built against it.
    public init(
        id: String, title: String, order: Int = 0, isShownByDefault: Bool = true, isCollapsedByDefault: Bool = false,
        makeView: @escaping @MainActor @Sendable () -> AnyView
    ) {
        self.init(
            id: id, title: title, order: order, isShownByDefault: isShownByDefault,
            isCollapsedByDefault: isCollapsedByDefault, add: nil, makeView: makeView
        )
    }
}

/// The "+" of a sidebar section's title: "New Folder" for "Folders".
public struct SidebarSectionAdd: Sendable {
    public let title: String
    public let action: @MainActor @Sendable () -> Void

    public init(title: String, action: @escaping @MainActor @Sendable () -> Void) {
        self.title = title
        self.action = action
    }
}

/// A kind of note a plugin can create besides a plain one, offered in the page toolbar's "+" menu and in a
/// folder's menu: "New Mindmap", "New Board". `create` makes it in a folder ("" for the vault's root) and opens it.
public struct NewItem: Identifiable, Sendable {
    public let id: String
    public let title: String
    /// SF Symbol name.
    public let symbol: String
    public let order: Int
    /// The view type what it creates opens in first: the "+" of that kind's page (`Resource.notes(titled:openedBy:)`)
    /// creates this rather than a note.
    public let viewType: String?
    public let create: @MainActor @Sendable (_ folder: String) -> Void

    /// Kept for plugins built before `viewType`.
    public init(
        id: String, title: String, symbol: String, order: Int = 0,
        create: @escaping @MainActor @Sendable (_ folder: String) -> Void
    ) {
        self.init(id: id, title: title, symbol: symbol, order: order, viewType: nil, create: create)
    }

    public init(
        id: String, title: String, symbol: String, order: Int = 0, viewType: String?,
        create: @escaping @MainActor @Sendable (_ folder: String) -> Void
    ) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.order = order
        self.viewType = viewType
        self.create = create
    }
}
