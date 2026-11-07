import Foundation
import Observation
import PluginKitUI
import SwiftUI

/// Which collection a note belongs to, for the fields under its title. Cached, and forgotten when the vault
/// changes; reading it is observed, so open notes show or hide their fields as notes and `.base` files move.
@MainActor
@Observable
final class NoteFieldsStore {
    @ObservationIgnored private let collections: @MainActor () -> CollectionService?
    @ObservationIgnored private let noteQuery: @MainActor () -> NoteQueryService?
    @ObservationIgnored private let workspace: @MainActor () -> (any Workspace)?
    @ObservationIgnored private var cache: [String: String?] = [:]
    @ObservationIgnored private let models = NSMapTable<ViewContext, NoteFieldsModel>.weakToStrongObjects()
    /// Bumped when the vault changes, so views that asked `collection(containing:)` ask again.
    private var generation = 0

    init(
        collections: @escaping @MainActor () -> CollectionService?,
        noteQuery: @escaping @MainActor () -> NoteQueryService?,
        workspace: @escaping @MainActor () -> (any Workspace)?
    ) {
        self.collections = collections
        self.noteQuery = noteQuery
        self.workspace = workspace
    }

    /// The `.base` nearest to the note at `path` whose notes include it; nil for a note in no collection.
    func collection(containing path: String) -> String? {
        _ = generation
        guard path.lowercased().hasSuffix(".md") else { return nil }
        if let cached = cache[path] { return cached }
        let found = collections()?.collections(containing: path).first
        cache[path] = found
        return found
    }

    func model(for context: ViewContext) -> NoteFieldsModel? {
        guard let base = collection(containing: context.resource.path) else { return nil }
        if let model = models.object(forKey: context) {
            model.update(base: base, path: context.resource.path)
            return model
        }
        let model = NoteFieldsModel(
            collection: CollectionViewModel(source: .file(base), collections: collections, noteQuery: noteQuery,
                                            workspace: workspace),
            path: context.resource.path, noteQuery: noteQuery
        )
        models.setObject(model, forKey: context)
        return model
    }

    /// Forgets what `changes` can change (all of it for nil): a note's own collection when the note changed, every
    /// note's when a `.base` file did. Forgetting all at each save made each open note look for its collection again
    /// (a walk of the vault, ~25 ms a note page kept open, at each card dropped on a board).
    func vaultChanged(_ changes: [VaultChange]?) {
        if let changes, !changes.contains(where: { $0.path.lowercased().hasSuffix(".base") || (!$0.isNote && $0.kind != .modified) }) {
            let stale = changes.filter(\.isNote).map(\.path).filter { cache.keys.contains($0) }
            if !stale.isEmpty {
                for path in stale { cache[path] = nil }
                generation += 1
            }
        } else {
            cache = [:]
            generation += 1
        }
        for model in models.objectEnumerator()?.allObjects as? [NoteFieldsModel] ?? []
        where changes.map(model.collection.isAffected) ?? true {
            model.collection.reloadSoon()
        }
    }
}

/// One note's fields: its collection's model and the note's own record in it.
@MainActor
@Observable
final class NoteFieldsModel {
    let collection: CollectionViewModel
    private(set) var path: String
    @ObservationIgnored private let noteQuery: @MainActor () -> NoteQueryService?

    init(collection: CollectionViewModel, path: String, noteQuery: @escaping @MainActor () -> NoteQueryService?) {
        self.collection = collection
        self.path = path
        self.noteQuery = noteQuery
    }

    func update(base: String, path: String) {
        if self.path != path { self.path = path }
        if collection.source != .file(base) { collection.setSource(.file(base)) }
    }

    /// The note as the collection reads it: from its first view, else (a view's filter leaves it out) on its own.
    var entry: NoteRecord? {
        if let entry = collection.result?.entries.first(where: { $0.path == path }) { return entry }
        return noteQuery()?.run(NoteQuery(folder: VaultPath.directory(of: path))).first { $0.path == path }
    }
}

/// Craft's fields under an entry's title: a row per field of the collection (its kind's icon, its name, its value
/// edited in place), then "Add Field". A value is one line of the note's frontmatter, written as plain YAML.
struct NoteFieldsView: View {
    let model: NoteFieldsModel
    @State private var addingField = false
    @State private var fieldToRename: PropertyRef?
    @State private var newName = ""
    @State private var fieldToDelete: PropertyRef?
    @Environment(\.themeTokens) private var theme

    private var collection: CollectionViewModel { model.collection }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let entry = model.entry {
                ForEach(shownFields(of: entry), id: \.self) { ref in
                    NoteFieldRow(collection: collection, ref: ref, entry: entry, fontSize: fontSize) { action in
                        switch action {
                        case .rename:
                            newName = collection.title(of: ref)
                            fieldToRename = ref
                        case .delete:
                            fieldToDelete = ref
                        }
                    }
                    .collectionTransition(.opacity.combined(with: .offset(y: -4)))
                }
            }
            addFieldButton
        }
        .font(.ui(size: fontSize))
        .collectionAnimation(value: collection.allFields)
        .alert("Rename field", isPresented: Binding(get: { fieldToRename != nil }, set: { if !$0 { fieldToRename = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let ref = fieldToRename {
                    var property = collection.property(ref)
                    let name = newName.trimmingCharacters(in: .whitespaces)
                    property.displayName = name.isEmpty || name == ref.name ? nil : name
                    collection.edit([.setProperty(property: property)])
                }
                fieldToRename = nil
            }
            Button("Cancel", role: .cancel) { fieldToRename = nil }
        }
        .confirmationDialog(
            "Delete the field “\(fieldToDelete.map(collection.title(of:)) ?? "")”?",
            isPresented: Binding(get: { fieldToDelete != nil }, set: { if !$0 { fieldToDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Field", role: .destructive) {
                if let ref = fieldToDelete { collection.deleteField(ref, removingValues: true) }
                fieldToDelete = nil
            }
            Button("Cancel", role: .cancel) { fieldToDelete = nil }
        } message: {
            Text("It disappears from every note of this collection, with its values.")
        }
    }

    /// Craft's rows are a little smaller than the text.
    private var fontSize: CGFloat { (theme.bodySize * 0.94).rounded() }

    /// The collection's own fields (declared, or named by a view), then the other notes' fields this note has a value
    /// for: a key only some other note of the folder holds (a mindmap's flags) is not offered as an empty row here.
    private func shownFields(of entry: NoteRecord) -> [PropertyRef] {
        let own = Set(((collection.definition?.properties ?? []).map(\.ref)
            + (collection.definition?.views ?? []).flatMap { $0.order + [$0.groupBy?.property].compactMap { $0 } })
            .map { $0.name.lowercased() })
        return collection.allFields.filter { own.contains($0.name.lowercased()) || collection.value($0, of: entry) != nil }
    }

    private var addFieldButton: some View {
        Button { addingField = true } label: {
            HStack(spacing: 10) {
                Image(symbol: "plus")
                    .font(.ui(size: fontSize * 0.85, weight: .regular))
                    .frame(width: NoteFieldRow.iconWidth)
                Text("Add Field")
            }
            .foregroundStyle(theme.secondaryText)
            .padding(.horizontal, 6)
            .frame(height: NoteFieldRow.height)
            .contentShape(Rectangle())
            .collectionHover()
        }
        .buttonStyle(.plain)
        .popover(isPresented: $addingField, arrowEdge: .bottom) {
            AddFieldForm { name, kind in
                collection.addField(name, kind: kind)
                addingField = false
            } cancel: {
                addingField = false
            }
        }
    }
}

/// A field's row: its icon and name (a click opens its menu: type, rename, delete), then its value.
struct NoteFieldRow: View {
    enum Action { case rename, delete }

    static let height: CGFloat = 32
    static let iconWidth: CGFloat = 18

    let collection: CollectionViewModel
    let ref: PropertyRef
    let entry: NoteRecord
    let fontSize: CGFloat
    let act: (Action) -> Void
    @Environment(\.themeTokens) private var theme

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                nameMenu.frame(width: geometry.size.width * 0.42, alignment: .leading)
                PropertyValueEditor(model: collection, ref: ref, entry: entry)
                    .foregroundStyle(theme.text)
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .collectionHover()
            }
        }
        .frame(height: Self.height)
    }

    private var nameMenu: some View {
        Menu {
            Menu("Type") {
                ForEach(PropertyKind.allCases, id: \.self) { kind in
                    Button { collection.setKind(kind, of: ref) } label: {
                        Label(kind.title, symbol: propertyKindSymbol(kind))
                    }
                }
            }
            Button("Rename…") { act(.rename) }
            Divider()
            Button("Delete Field…", role: .destructive) { act(.delete) }
        } label: {
            HStack(spacing: 10) {
                Image(symbol: propertyKindSymbol(collection.kind(ref)))
                    .font(.ui(size: fontSize * 0.85))
                    .frame(width: Self.iconWidth)
                Text(collection.title(of: ref)).lineLimit(1)
            }
            .foregroundStyle(theme.secondaryText)
            .padding(.horizontal, 6)
            .frame(maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .collectionHover()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// Craft's "Add Field" popover: the name, the kind, and the button.
struct AddFieldForm: View {
    let add: (String, PropertyKind) -> Void
    let cancel: () -> Void
    @State private var name = ""
    @State private var kind = PropertyKind.text
    @FocusState private var nameFocused: Bool
    @Environment(\.themeTokens) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Add Field").font(.ui(size: 15, weight: .semibold))
                Spacer()
                Button(action: cancel) {
                    Image(symbol: "xmark.circle.fill").font(.ui(size: 15)).foregroundStyle(theme.secondaryText.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
            Divider()
            HStack(spacing: 8) {
                Image(symbol: propertyKindSymbol(kind))
                    .font(.ui(size: 13))
                    .frame(width: 32, height: 28)
                    .background(RoundedRectangle(cornerRadius: Corners.r(8)).strokeBorder(theme.separator))
                    .contentTransition(.symbolEffect(.replace))
                TextField("Field Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .focused($nameFocused)
                    .onSubmit(submit)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Type").font(.ui(size: 12, weight: .medium)).foregroundStyle(theme.secondaryText)
                Picker("Type", selection: $kind) {
                    ForEach(PropertyKind.plain, id: \.self) { kind in
                        Label(kind.title, symbol: propertyKindSymbol(kind)).tag(kind)
                    }
                    Divider()
                    ForEach(PropertyKind.choices, id: \.self) { kind in
                        Label(kind.title, symbol: propertyKindSymbol(kind)).tag(kind)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity)
            }
            Button(action: submit) {
                Text("Add Field").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(18)
        .frame(width: 280)
        .onAppear { nameFocused = true }
    }

    private func submit() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        add(trimmed, kind)
    }
}

extension PropertyKind {
    /// The name Craft gives the kind.
    var title: String {
        switch self {
        case .text: "Text"
        case .number: "Number"
        case .checkbox: "Checkbox"
        case .date: "Date"
        case .url: "URL"
        case .select: "Single Select"
        case .multiselect: "Multiple Select"
        @unknown default: "Text"
        }
    }

    /// Craft's menu: the plain kinds, then the choices.
    static let plain: [PropertyKind] = [.text, .number, .checkbox, .date, .url]
    static let choices: [PropertyKind] = [.select, .multiselect]
}
