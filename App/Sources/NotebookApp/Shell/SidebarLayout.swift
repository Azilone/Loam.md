import Foundation
import Observation
import PluginKit
import PluginKitUI
import LoamCore

/// What the left sidebar shows, as chosen in its Customize mode: the order of the navigation rows and of the
/// sections, which of them are hidden, and which sections are folded.
///
/// Kept in `.loam/config.json`, so it travels with the vault and an agent can set it:
///
///     "sidebar": { "links":    { "order": ["explorer.all-notes", "tasks.link"], "hidden": ["graph.link"] },
///                  "sections": { "order": ["explorer.folders"], "hidden": ["explorer.recent"] },
///                  "collapsed": ["tags.section"], "expanded": [],
///                  "pinned": ["folder:Projects", "tag:decision"] }
///
/// Rows and sections the config does not name keep their registered order (after the named ones) and their default
/// visibility (`isShownByDefault`); a section's default fold is `isCollapsedByDefault` unless listed.
@MainActor
@Observable
public final class SidebarLayout {
    /// The top-level key of `.loam/config.json`.
    public static let configKey = "sidebar"

    /// One of the two lists the user arranges.
    public struct Group: Equatable, Sendable {
        public var order: [String] = []
        /// Ids hidden although shown by default.
        public var hidden: Set<String> = []
        /// Ids shown although hidden by default.
        public var shown: Set<String> = []

        /// `ids` (in registered order) arranged: the named ones first, in the user's order, then the others.
        public func arranged(_ ids: [String]) -> [String] {
            let known = Set(ids)
            let named = order.filter { known.contains($0) }
            return named + ids.filter { !named.contains($0) }
        }

        public func isShown(_ id: String, byDefault: Bool) -> Bool {
            byDefault ? !hidden.contains(id) : shown.contains(id)
        }
    }

    public private(set) var links = Group()
    public private(set) var sections = Group()
    /// Sections folded although open by default, and open although folded by default.
    public private(set) var collapsed: Set<String> = []
    public private(set) var expanded: Set<String> = []
    /// The sections the user added from a folder or a tag ("+ Section from a folder or tag").
    public private(set) var pinned: [Pin] = []

    /// A section of the notes of a folder, or of a tag.
    public struct Pin: Equatable, Hashable, Sendable {
        public enum Kind: String, Sendable { case folder, tag }
        public let kind: Kind
        public let value: String

        public init(kind: Kind, value: String) {
            self.kind = kind
            self.value = value
        }

        /// "folder:Projects", as stored; also the section's id after `pin:`.
        public var key: String { kind.rawValue + ":" + value }
        public var sectionID: String { "pin:" + key }
        public var title: String {
            kind == .tag ? "#" + value : (value.split(separator: "/").last.map(String.init) ?? value)
        }

        init?(key: String) {
            guard let colon = key.firstIndex(of: ":"), let kind = Kind(rawValue: String(key[..<colon])) else { return nil }
            let value = String(key[key.index(after: colon)...])
            guard !value.isEmpty else { return nil }
            self.init(kind: kind, value: value)
        }
    }

    @ObservationIgnored private let config: ConfigStore

    public init(config: ConfigStore) {
        self.config = config
        reload()
    }

    /// Reads the layout again from the config as last loaded.
    public func reload() {
        let map = Self.map(config.config.raw[Self.configKey])
        let links = Self.group(map["links"])
        let sections = Self.group(map["sections"])
        let collapsed = Set(Self.strings(map["collapsed"]))
        let expanded = Set(Self.strings(map["expanded"]))
        if links != self.links { self.links = links }
        if sections != self.sections { self.sections = sections }
        if collapsed != self.collapsed { self.collapsed = collapsed }
        if expanded != self.expanded { self.expanded = expanded }
        let pinned = Self.strings(map["pinned"]).compactMap(Pin.init(key:))
        if pinned != self.pinned { self.pinned = pinned }
    }

    /// Adds a section for `pin` at the end of the sections, shown. Does nothing when it is there already.
    public func add(_ pin: Pin) throws {
        guard !pinned.contains(pin) else { return }
        let keys = (pinned + [pin]).map(\.key)
        try mutate { map in map["pinned"] = .list(keys.map(JSONValue.string)) }
    }

    /// Removes the section of `pin`, and what the layout remembered of it.
    public func remove(_ pin: Pin) throws {
        let keys = pinned.filter { $0 != pin }.map(\.key)
        var group = sections
        group.order.removeAll { $0 == pin.sectionID }
        group.hidden.remove(pin.sectionID)
        try mutate { map in
            map["pinned"] = keys.isEmpty ? nil : .list(keys.map(JSONValue.string))
            map["sections"] = Self.json(group)
        }
    }

    // MARK: Reading

    /// The navigation rows in the user's order; with `all` false, only the shown ones.
    public func arranged(_ registered: [SidebarLink], all: Bool = false) -> [SidebarLink] {
        let byID = Dictionary(registered.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return links.arranged(registered.map(\.id)).compactMap { byID[$0] }
            .filter { all || isShown($0) }
    }

    /// The sections in the user's order; with `all` false, only the shown ones.
    public func arranged(_ registered: [SidebarSection], all: Bool = false) -> [SidebarSection] {
        let byID = Dictionary(registered.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return sections.arranged(registered.map(\.id)).compactMap { byID[$0] }
            .filter { all || isShown($0) }
    }

    public func isShown(_ link: SidebarLink) -> Bool { links.isShown(link.id, byDefault: link.isShownByDefault) }
    public func isShown(_ section: SidebarSection) -> Bool {
        sections.isShown(section.id, byDefault: section.isShownByDefault)
    }

    public func isCollapsed(_ section: SidebarSection) -> Bool {
        section.isCollapsedByDefault ? !expanded.contains(section.id) : collapsed.contains(section.id)
    }

    // MARK: Writing

    public func set(_ link: SidebarLink, shown: Bool) throws {
        var group = links
        Self.set(&group, id: link.id, shown: shown, byDefault: link.isShownByDefault)
        try write(links: group)
    }

    public func set(_ section: SidebarSection, shown: Bool) throws {
        var group = sections
        Self.set(&group, id: section.id, shown: shown, byDefault: section.isShownByDefault)
        try write(sections: group)
    }

    /// Saves the navigation rows' order (every id, as shown in Customize).
    public func reorderLinks(_ ids: [String]) throws {
        var group = links
        group.order = ids
        try write(links: group)
    }

    public func reorderSections(_ ids: [String]) throws {
        var group = sections
        group.order = ids
        try write(sections: group)
    }

    public func setCollapsed(_ section: SidebarSection, _ isCollapsed: Bool) throws {
        var collapsed = collapsed
        var expanded = expanded
        collapsed.remove(section.id)
        expanded.remove(section.id)
        if isCollapsed != section.isCollapsedByDefault {
            if isCollapsed { collapsed.insert(section.id) } else { expanded.insert(section.id) }
        }
        try mutate { map in
            map["collapsed"] = collapsed.isEmpty ? nil : .list(collapsed.sorted().map(JSONValue.string))
            map["expanded"] = expanded.isEmpty ? nil : .list(expanded.sorted().map(JSONValue.string))
        }
    }

    /// Goes back to the plugins' defaults: removes every choice.
    public func reset() throws {
        try config.mutate { $0.raw[Self.configKey] = nil }
        reload()
    }

    private static func set(_ group: inout Group, id: String, shown: Bool, byDefault: Bool) {
        group.hidden.remove(id)
        group.shown.remove(id)
        if shown != byDefault {
            if shown { group.shown.insert(id) } else { group.hidden.insert(id) }
        }
    }

    private func write(links: Group? = nil, sections: Group? = nil) throws {
        try mutate { map in
            if let links { map["links"] = Self.json(links) }
            if let sections { map["sections"] = Self.json(sections) }
        }
    }

    private func mutate(_ change: (inout [String: JSONValue]) -> Void) throws {
        try config.mutate { config in
            var map = Self.map(config.raw[Self.configKey])
            change(&map)
            config.raw[Self.configKey] = map.isEmpty ? nil : .map(map)
        }
        reload()
    }

    // MARK: JSON

    private static func json(_ group: Group) -> JSONValue? {
        var map: [String: JSONValue] = [:]
        if !group.order.isEmpty { map["order"] = .list(group.order.map(JSONValue.string)) }
        if !group.hidden.isEmpty { map["hidden"] = .list(group.hidden.sorted().map(JSONValue.string)) }
        if !group.shown.isEmpty { map["shown"] = .list(group.shown.sorted().map(JSONValue.string)) }
        return map.isEmpty ? nil : .map(map)
    }

    private static func group(_ value: JSONValue?) -> Group {
        let map = map(value)
        return Group(order: strings(map["order"]), hidden: Set(strings(map["hidden"])), shown: Set(strings(map["shown"])))
    }

    private static func map(_ value: JSONValue?) -> [String: JSONValue] {
        if case .map(let map)? = value { return map }
        return [:]
    }

    private static func strings(_ value: JSONValue?) -> [String] {
        guard case .list(let items)? = value else { return [] }
        return items.compactMap { if case .string(let text) = $0 { return text } else { return nil } }
    }
}
