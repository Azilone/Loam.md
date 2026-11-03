import Foundation
import Observation

/// What a collection view draws from and acts through: one collection, its selected view's result, the search
/// text, and the actions (set a value, new entry, edit the definition, open a note). Built by the collection page
/// and given to the view type's `makeView`; every action goes through the `collections` and `note-query` services,
/// so it is also a command.
@MainActor
@Observable
public final class CollectionViewModel {
    public private(set) var source: CollectionSource
    /// True inside a note (a ` ```base ` block): the page shows "Open as page" and no title of its own.
    public let isEmbedded: Bool
    public private(set) var definition: CollectionDefinition?
    public private(set) var result: CollectionResult?
    /// The selected view's name; nil is the first.
    public var viewName: String? {
        didSet { if viewName != oldValue { reload() } }
    }
    /// Narrows the entries to those whose title or a shown field contains it, ignoring case.
    public var searchText = ""
    public private(set) var error: String?
    /// A field whose "Delete…" was chosen, waiting for the page to ask for confirmation.
    public var fieldToDelete: PropertyRef?
    /// A field whose "Rename…" was chosen, waiting for the page to ask for its new name.
    public var fieldToRename: PropertyRef?
    /// The last field deleted, until its "Undo" is used or lapses.
    public private(set) var deletedField: DeletedField?

    @ObservationIgnored private let collections: @MainActor () -> CollectionService?
    @ObservationIgnored private let noteQuery: @MainActor () -> NoteQueryService?
    @ObservationIgnored private let workspace: @MainActor () -> (any Workspace)?
    /// Called with the new YAML of a block after an edit, for the editor to write it. Nil for a `.base` file.
    @ObservationIgnored public var onInlineChange: ((CollectionSource) -> Void)?

    public init(
        source: CollectionSource,
        isEmbedded: Bool = false,
        collections: @escaping @MainActor () -> CollectionService?,
        noteQuery: @escaping @MainActor () -> NoteQueryService?,
        workspace: @escaping @MainActor () -> (any Workspace)?
    ) {
        self.source = source
        self.isEmbedded = isEmbedded
        self.collections = collections
        self.noteQuery = noteQuery
        self.workspace = workspace
        reload()
    }

    // MARK: Reading

    /// Reads the definition and runs the selected view again (after a change on disk).
    public func reload() {
        guard let service = collections() else {
            error = "The Collections plugin is not active."
            return
        }
        do {
            let definition = try service.definition(source)
            let name = viewName.flatMap { name in definition.views.contains { $0.name == name } ? name : nil }
            let result = try service.entries(source, view: name)
            if definition != self.definition { self.definition = definition }
            if result != self.result { self.result = result }
            if error != nil { error = nil }
        } catch {
            self.error = Self.describe(error)
        }
    }

    /// Replaces the YAML of a block (the editor's text changed).
    public func setSource(_ source: CollectionSource) {
        guard source != self.source else { return }
        self.source = source
        reload()
    }

    /// The selected view's settings.
    public var view: CollectionViewConfig? { result?.view }

    /// The entries the view shows, narrowed by the search.
    public var entries: [NoteRecord] { (result?.entries ?? []).filter(matchesSearch) }

    /// The board's groups, narrowed by the search; nil when the view does not group.
    public var groups: [CollectionGroup]? {
        arrangedGroups?.map { CollectionGroup(value: $0.value, entries: $0.entries.filter(matchesSearch)) }
    }

    /// The groups with the cards the user placed by hand in their places (see `moveEntry`), not narrowed by the
    /// search: a card's index in its column is the same whatever is typed in the search field.
    private var arrangedGroups: [CollectionGroup]? {
        guard let groups = result?.groups else { return nil }
        let order = manualOrder
        guard !order.isEmpty else { return groups }
        return groups.map { CollectionGroup(value: $0.value, entries: ManualOrder.arranged($0.entries, by: order)) }
    }

    /// The `.base` view option that holds the board's manual card order (vault paths, columns together).
    public static let manualOrderKey = "cardOrder"

    /// The paths of the cards the user placed by hand, in order: the selected view's `cardOrder`.
    public var manualOrder: [String] {
        guard case .list(let items)? = view?.options[Self.manualOrderKey] else { return [] }
        return items.compactMap { if case .string(let path) = $0 { path } else { nil } }
    }

    /// The fields the view shows after the title, in order.
    public var fields: [PropertyRef] { (view?.order ?? []).filter { $0 != .title } }

    public func property(_ ref: PropertyRef) -> CollectionProperty {
        definition?.property(ref) ?? CollectionProperty(ref: ref)
    }

    public func kind(_ ref: PropertyRef) -> PropertyKind {
        if let kind = result?.kinds[ref.description] { return kind }
        let property = property(ref)
        return property.kind ?? (property.options.isEmpty ? .text : .select)
    }

    /// A field's name for headers: its display name, "Title" for `file.name`, else its name.
    public func title(of ref: PropertyRef) -> String {
        if let name = property(ref).displayName, !name.isEmpty { return name }
        if ref == .title { return "Title" }
        guard ref.namespace == .note else { return ref.description }
        return ref.name.prefix(1).uppercased() + ref.name.dropFirst()
    }

    /// An entry's value for a field; `file.name` is its title.
    public func value(_ ref: PropertyRef, of entry: NoteRecord) -> PropertyValue? {
        let value: PropertyValue?
        switch ref.namespace {
        case .note: value = PropertyComparison.property(ref.name, of: entry.properties)
        case .formula: value = nil
        case .file:
            switch ref.name {
            case "name": value = .string(entry.title)
            case "path": value = .string(entry.path)
            case "folder": value = .string(VaultPath.directory(of: entry.path))
            case "tags": value = .list(entry.tags.map { .string($0) })
            case "mtime": value = .string(Self.dayFormatter.string(from: Date(timeIntervalSince1970: entry.modified)))
            default: value = nil
            }
        @unknown default: value = nil
        }
        return value == .null ? nil : value
    }

    /// Every field the entries have or the collection declares, for "add a field" menus: the declared ones first.
    public var knownFields: [PropertyRef] {
        var refs = (definition?.properties ?? []).map(\.ref).filter { $0.namespace == .note }
        var names = Set(refs.map { $0.name.lowercased() })
        for entry in result?.entries ?? [] {
            for key in entry.properties.keys.sorted() where !names.contains(key.lowercased()) && key.lowercased() != "tags" {
                names.insert(key.lowercased())
                refs.append(PropertyRef(.note, key))
            }
        }
        return refs
    }

    /// Every field of the collection, as an entry's page lists them under its title: `knownFields`, then the ones
    /// only a view names (a column, a grouping) that no note has yet.
    public var allFields: [PropertyRef] {
        var refs = knownFields
        var names = Set(refs.map { $0.name.lowercased() })
        for view in definition?.views ?? [] {
            for ref in view.order + [view.groupBy?.property].compactMap({ $0 })
            where ref.namespace == .note && !names.contains(ref.name.lowercased()) && ref.name.lowercased() != "tags" {
                names.insert(ref.name.lowercased())
                refs.append(ref)
            }
        }
        return refs
    }

    private func matchesSearch(_ entry: NoteRecord) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        if entry.title.localizedCaseInsensitiveContains(query) { return true }
        return fields.contains { ref in
            value(ref, of: entry).map(Self.text).map { $0.localizedCaseInsensitiveContains(query) } ?? false
        }
    }

    /// A value as one line of text: list items joined by commas.
    public static func text(_ value: PropertyValue) -> String {
        switch value {
        case .list(let items): return items.map(text).joined(separator: ", ")
        case .map: return "…"
        case .null: return ""
        default: return PropertyComparison.text(of: value) ?? ""
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    // MARK: Fields

    /// What deleting a field took away, enough to put it back.
    public struct DeletedField: Equatable {
        public let ref: PropertyRef
        public let title: String
        /// Its declaration in the collection (kind, options, name), when it had one.
        let declared: CollectionProperty?
        /// The views as they were, for the columns, sorts and grouping it took with it.
        let views: [CollectionViewConfig]
        /// The value it had in each note whose value was deleted too.
        let values: [String: PropertyValue]
    }

    /// How many of the notes shown have a value for the field (what "and its values" would erase).
    public func valueCount(of ref: PropertyRef) -> Int {
        guard ref.namespace == .note else { return 0 }
        return (result?.entries ?? []).filter { value(ref, of: $0) != nil }.count
    }

    /// Deletes a field from the collection: its declaration, and its column, sort or grouping in every view. With
    /// `removingValues`, also its value in the frontmatter of the notes shown; without, the notes keep it and it
    /// stays available under "Fields". `undoDelete()` puts back all of it.
    public func deleteField(_ ref: PropertyRef, removingValues: Bool) {
        guard ref.namespace == .note, let definition else { return }
        var values: [String: PropertyValue] = [:]
        if removingValues {
            for entry in result?.entries ?? [] {
                if let value = value(ref, of: entry) { values[entry.path] = value }
            }
        }
        let deleted = DeletedField(ref: ref, title: title(of: ref), declared: definition.properties.first { $0.ref == ref },
                                   views: definition.views, values: values)
        edit([.removeProperty(ref: ref)])
        for path in values.keys.sorted() { set(ref, to: nil, on: path) }
        deletedField = deleted
    }

    /// Puts back the field `deleteField` removed.
    public func undoDelete() {
        guard let deleted = deletedField else { return }
        deletedField = nil
        var edits: [CollectionEdit] = []
        if let declared = deleted.declared { edits.append(.setProperty(property: declared)) }
        let current = definition?.views ?? []
        for old in deleted.views {
            guard let now = current.first(where: { $0.name == old.name }) else { continue }
            if now.order != old.order { edits.append(.setOrder(view: old.name, order: old.order)) }
            if now.sort != old.sort { edits.append(.setSort(view: old.name, sort: old.sort)) }
            if now.groupBy != old.groupBy { edits.append(.setGroupBy(view: old.name, groupBy: old.groupBy)) }
        }
        edit(edits)
        for (path, value) in deleted.values.sorted(by: { $0.key < $1.key }) { set(deleted.ref, to: value, on: path) }
    }

    /// Lets the undo go once its time is up.
    public func dismissDeletedField() { deletedField = nil }

    // MARK: Acting

    /// Writes a field of an entry (a frontmatter property), or removes it with nil.
    public func set(_ ref: PropertyRef, to value: PropertyValue?, on path: String) {
        guard ref.namespace == .note else { return }
        act { try noteQuery()?.setProperty(ref.name, to: value, in: path) }
    }

    /// Writes a new note in the collection with `values` and opens nothing; returns its path.
    @discardableResult
    public func newEntry(title: String? = nil, values: [String: PropertyValue] = [:]) -> String? {
        var path: String?
        act { path = try collections()?.newEntry(in: source, title: title, values: values) }
        return path
    }

    /// Applies edits to the collection's YAML (views, fields, filters).
    public func edit(_ edits: [CollectionEdit]) {
        guard !edits.isEmpty else { return }
        act { try applyEdits(edits) }
    }

    private func applyEdits(_ edits: [CollectionEdit]) throws {
        guard let edited = try collections()?.apply(edits, to: source) else { return }
        if case .inline = edited, edited != source {
            source = edited
            onInlineChange?(edited)
        }
    }

    /// Moves a card of a board to `index` in the column of `value` (nil is the column without a value): writes
    /// `field` on the note when the column changes, and the new manual order in the view (`cardOrder`), so the
    /// notes of the other cards stay untouched. `index` counts the column's other cards, as the board shows them
    /// while the card is held; it is clamped.
    public func moveEntry(_ path: String, to value: PropertyValue?, in field: PropertyRef, at index: Int) {
        guard let view, let groups = arrangedGroups,
              let source = groups.first(where: { $0.entries.contains { $0.path == path } })
        else { return }
        let target = groups.first { Self.sameColumn($0.value, value) }
        let column = (target?.entries ?? []).map(\.path).filter { $0 != path }
        let order = ManualOrder.inserting(
            path, at: index, into: column, of: groups.flatMap { $0.entries.map(\.path) },
            known: Set((result?.entries ?? []).map(\.path)))
        let changesColumn = !Self.sameColumn(source.value, value)
        act {
            if changesColumn, field.namespace == .note { try noteQuery()?.setProperty(field.name, to: value, in: path) }
            if order != manualOrder {
                try applyEdits([.setViewOption(view: view.name, key: Self.manualOrderKey, value: .list(order.map { .string($0) }))])
            }
        }
    }

    /// Whether two group values are the same column: the board files by text, ignoring case.
    static func sameColumn(_ a: PropertyValue?, _ b: PropertyValue?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (let a?, let b?): return text(a).caseInsensitiveCompare(text(b)) == .orderedSame
        default: return false
        }
    }

    /// Changes a field's kind; a select made from another kind takes the values its notes have as options.
    public func setKind(_ kind: PropertyKind, of ref: PropertyRef) {
        var property = property(ref)
        property.kind = kind
        if kind == .select || kind == .multiselect, property.options.isEmpty {
            var found: [String] = []
            for entry in result?.entries ?? [] {
                for item in value(ref, of: entry).map(PropertyValueView.items) ?? []
                where !found.contains(where: { $0.caseInsensitiveCompare(item) == .orderedSame }) {
                    found.append(item)
                }
            }
            property.options = found
        }
        edit([.setProperty(property: property)])
    }

    /// Adds a field to the collection, as Craft's "Add Field": declared with its kind, and a column of its tables.
    /// A field the collection already has only takes the kind.
    public func addField(_ name: String, kind: PropertyKind) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let definition else { return }
        if let existing = allFields.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return setKind(kind, of: existing)
        }
        let ref = PropertyRef(.note, name)
        var edits: [CollectionEdit] = [.setProperty(property: CollectionProperty(ref: ref, kind: kind))]
        for view in definition.views where view.type == "table" && !view.order.contains(ref) {
            edits.append(.setOrder(view: view.name, order: (view.order.contains(.title) ? view.order : [.title] + view.order) + [ref]))
        }
        edit(edits)
    }

    /// Adds an option at the end of a select field (a board's new column).
    public func addOption(_ option: String, to ref: PropertyRef) {
        let option = option.trimmingCharacters(in: .whitespaces)
        var property = property(ref)
        guard !option.isEmpty, !property.options.contains(where: { $0.caseInsensitiveCompare(option) == .orderedSame })
        else { return }
        property.options.append(option)
        if property.kind == nil { property.kind = kind(ref) == .multiselect ? .multiselect : .select }
        edit([.setProperty(property: property)])
    }

    /// Opens an entry's note; `origin` is the card it was opened from, which the page grows out of.
    public func open(_ path: String, placement: Placement = .replace, from origin: OpenOrigin? = nil) {
        workspace()?.open(.file(path), placement: placement, from: origin)
    }

    private func act(_ body: () throws -> Void) {
        do {
            try body()
            reload()
        } catch {
            self.error = Self.describe(error)
        }
    }

    static func describe(_ error: Error) -> String {
        switch error as? CollectionError {
        case .notACollection(let path)?: return "\(path) is not a collection."
        case .invalidYAML(let detail)?: return "The collection's YAML cannot be read: \(detail)"
        case .unknownView(let name)?: return "There is no view named \(name)."
        case .invalidArgument(let name)?: return "Invalid \(name)."
        case nil: return "\(error)"
        @unknown default: return "\(error)"
        }
    }
}

/// The order a person gave the cards of a board by hand: one list of paths for the whole view, so a card can move
/// between columns without the other cards' notes being touched. Cards that are not in the list (new notes) come
/// after the listed ones, in the view's own order.
public enum ManualOrder {
    /// `entries` with the listed ones first, in the list's order; the rest keep their order after them.
    public static func arranged(_ entries: [NoteRecord], by order: [String]) -> [NoteRecord] {
        guard !order.isEmpty, entries.count > 1 else { return entries }
        var rank: [String: Int] = [:]
        for (index, path) in order.enumerated() where rank[path] == nil { rank[path] = index }
        let listed = entries.filter { rank[$0.path] != nil }.sorted { rank[$0.path]! < rank[$1.path]! }
        return listed + entries.filter { rank[$0.path] == nil }
    }

    /// The new list after `path` moved to `index` among `column` (the target column's paths without `path`):
    /// `flat` is every card as the board shows them now, so the list is complete afterwards. Paths not in `known`
    /// (notes that left the collection) are dropped.
    public static func inserting(_ path: String, at index: Int, into column: [String], of flat: [String], known: Set<String>) -> [String] {
        var order = flat.filter { $0 != path && known.contains($0) }
        let index = min(max(index, 0), column.count)
        if index < column.count, let anchor = order.firstIndex(of: column[index]) {
            order.insert(path, at: anchor)
        } else if let last = column.last, let anchor = order.firstIndex(of: last) {
            order.insert(path, at: anchor + 1)
        } else {
            order.append(path)
        }
        return order
    }
}
