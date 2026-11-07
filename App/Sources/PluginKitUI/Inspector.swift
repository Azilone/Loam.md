import Observation
import SwiftUI

/// The right sidebar follows what the focused tab shows, as Craft's inspector does: a note offers "Insert", a
/// mindmap its "Style", a board its "Board", each with its own options, and every resource ends with "Info".
///
/// Two sources fill it:
/// - **The view** of the focused tab publishes its own tabs on its `ViewContext` (`setInspector`), built over its
///   own model, so they act on that very tab.
/// - **Plugins** add `InspectorSection`s for the resources they know about: in a tab of their own (a note's
///   "Outline", "Links", "Stats"), under the view's first tab, or in "Info".
///
/// One tab does one job, and shows nothing the page already shows, nothing empty, no count nobody needs.
///
/// The shell draws the tabs as a segmented control, each tab a scrolling column of titled groups. Plugins build
/// their groups from the shared bricks (`InspectorGroup`, `InspectorCard`, `InspectorTile`...), so every
/// sidebar looks the same whoever drew it.
public struct InspectorTab: Identifiable, Sendable {
    /// Owned by the view, such as `mindmap.style`.
    public let id: String
    /// One short word, shown in the segmented control: "Style", "Board".
    public let title: String
    public let makeView: @MainActor @Sendable () -> AnyView

    public init(id: String, title: String, makeView: @escaping @MainActor @Sendable () -> AnyView) {
        self.id = id
        self.title = title
        self.makeView = makeView
    }

    /// The id of the "Info" tab the shell adds last, made of the sections placed `.info`.
    public static let infoID = "inspector.info"
}

/// What a view gives the inspector: its tabs, and which view published them, so that a tab shown with another view
/// ("Open with") never keeps the previous view's tabs.
public struct InspectorContent: Sendable {
    /// The `ViewType.id` of the view that published it.
    public let viewType: String
    public let tabs: [InspectorTab]

    public init(viewType: String, tabs: [InspectorTab]) {
        self.viewType = viewType
        self.tabs = tabs
    }
}

public extension ViewContext {
    /// Publishes the inspector tabs of the view `viewType` shows in this tab. Call it when the view's model exists
    /// (`onAppear`); the closures may keep the model. An embedded view publishes nothing: only a tab's page has a
    /// sidebar.
    func setInspector(viewType: String, tabs: [InspectorTab]) {
        guard presentation == .page else { return }
        inspector = InspectorContent(viewType: viewType, tabs: tabs)
    }
}

/// A tab that plugins' sections make on their own, as Bear's "Table of Contents", "Backlinks" and "Statistics":
/// one short word, and where it goes among the view's own tabs (order 0); "Info" stays last.
public struct InspectorPage: Hashable, Sendable {
    public let id: String
    public let title: String
    /// Left to right: lower first; the view's own tabs count as 0.
    public let order: Int

    public init(id: String, title: String, order: Int) {
        self.id = id
        self.title = title
        self.order = order
    }
}

/// A titled group of a resource's inspector, added by a plugin: Backlinks, Outline, Calendar.
public struct InspectorSection: Identifiable, Sendable {
    public enum Placement: Hashable, Sendable {
        /// In a tab of its own, shared with the other sections naming the same page ("Outline", "Links").
        case tab(InspectorPage)
        /// In "Info", the last tab, for what fits nowhere else.
        case info
        /// In the first tab of the view: after the view's own groups (a note's outline under "Insert"), or before
        /// them for a negative `order` (a daily note's calendar). A view without tabs shows these in a tab of their
        /// own.
        case primary
    }

    /// Dotted and owned by the plugin, such as `backlinks.section`.
    public let id: String
    /// The group's title; nil for a section that draws its own titles (or none).
    public let title: String?
    public let placement: Placement
    /// Top to bottom: lower first. In `.primary`, a negative order goes above the view's own groups.
    public let order: Int
    /// The `ViewType.id`s it shows with, such as the editor's for a note's outline; nil for any view.
    public let viewTypes: Set<String>?
    public let appliesTo: @MainActor @Sendable (Resource) -> Bool
    /// Drawn without a scroll view of its own: the tab scrolls.
    public let makeView: @MainActor @Sendable (Resource) -> AnyView

    public init(
        id: String,
        title: String? = nil,
        placement: Placement = .info,
        order: Int = 0,
        viewTypes: Set<String>? = nil,
        appliesTo: @escaping @MainActor @Sendable (Resource) -> Bool,
        makeView: @escaping @MainActor @Sendable (Resource) -> AnyView
    ) {
        self.id = id
        self.title = title
        self.placement = placement
        self.order = order
        self.viewTypes = viewTypes
        self.appliesTo = appliesTo
        self.makeView = makeView
    }
}

/// Where inspector sections are registered. Plugins use `context.addInspectorSection`, which also unregisters on
/// unload.
@MainActor
public protocol InspectorRegistry: AnyObject {
    func register(_ section: InspectorSection) -> @MainActor () -> Void
    /// The sections placed `placement` that apply to `resource` shown by the view `viewType` (nil: no view), by
    /// `order`, then by id.
    func sections(
        for resource: Resource, viewType: String?, in placement: InspectorSection.Placement
    ) -> [InspectorSection]
    /// The tabs sections make for `resource` shown by `viewType`, by their order, each with its sections in order.
    func pages(for resource: Resource, viewType: String?) -> [(page: InspectorPage, sections: [InspectorSection])]
}

/// The standard `InspectorRegistry`. Observable, so the sidebar shows a section as soon as its plugin loads.
@MainActor
@Observable
public final class InspectorStore: InspectorRegistry {
    private var entries = RegistryEntries<InspectorSection>()

    public init() {}

    public func register(_ section: InspectorSection) -> @MainActor () -> Void {
        let token = entries.insert(section, id: section.id)
        return { [weak self] in self?.entries.remove(token) }
    }

    public func sections(
        for resource: Resource, viewType: String?, in placement: InspectorSection.Placement
    ) -> [InspectorSection] {
        entries.values
            .filter { section in
                Self.samePlace(section.placement, placement) && section.appliesTo(resource)
                    && (section.viewTypes.map { viewType.map($0.contains) ?? false } ?? true)
            }
            .sorted { $0.order != $1.order ? $0.order < $1.order : $0.id < $1.id }
    }

    public func pages(for resource: Resource, viewType: String?) -> [(page: InspectorPage, sections: [InspectorSection])] {
        var pages: [String: InspectorPage] = [:]
        for section in entries.values {
            if case .tab(let page) = section.placement, pages[page.id] == nil { pages[page.id] = page }
        }
        return pages.values
            .sorted { $0.order != $1.order ? $0.order < $1.order : $0.id < $1.id }
            .map { page in (page, sections(for: resource, viewType: viewType, in: .tab(page))) }
            .filter { !$0.sections.isEmpty }
    }

    public var all: [InspectorSection] { entries.values }

    /// Two placements in one place: tabs by their id alone.
    private static func samePlace(_ a: InspectorSection.Placement, _ b: InspectorSection.Placement) -> Bool {
        if case .tab(let x) = a, case .tab(let y) = b { return x.id == y.id }
        return a == b
    }
}

public extension ServiceKey where Service == any InspectorRegistry {
    static var inspector: ServiceKey<any InspectorRegistry> { ServiceKey<any InspectorRegistry>("ui.inspector") }
}

@MainActor
public extension PluginContext {
    /// Adds a group to the right sidebar of the resources `section.appliesTo` accepts. Throws
    /// `UIContractError.registryMissing("ui.inspector")` without the shell.
    func addInspectorSection(_ section: InspectorSection) throws {
        guard let registry = service(.inspector) else {
            throw UIContractError.registryMissing(ServiceKey<any InspectorRegistry>.inspector.id)
        }
        let remove = registry.register(section)
        effect { MainActor.assumeIsolated { remove() } }
    }
}
