import AppKit
import PluginKitUI
import SwiftUI

/// The table view of collections (`type: table`), as Craft draws it: "#", the title, then one column per field
/// with its kind's icon; cells edit in place, "+" adds a field, "+ New" an entry.
public final class CollectionTableUIPlugin: UIPlugin {
    public static let manifest = PluginManifest(
        id: "collection-table",
        name: "Collection table",
        version: "0.1.0",
        description: "The Table view of a collection: edit cells in place.",
        icon: "tablecells",
        optionalRequires: ["collections.views"],
        permissions: ["ui", "vault.read", "vault.write"]
    )

    public init() {}

    @MainActor public func activateUI(context: PluginContext) throws {
        context.addCollectionView(CollectionViewType(
            id: "table",
            title: "Table",
            symbol: "tablecells",
            order: 0,
            defaults: { definition, view in
                [.setOrder(view: view, order: [.title] + definition.properties.map(\.ref).filter { $0.namespace == .note })]
            }
        ) { model in
            AnyView(CollectionTableView(model: model))
        })
    }
}

/// Column widths, from the view's `columnSize` (Obsidian's key) where set.
enum TableMetrics {
    static let number: CGFloat = 44
    static let field: CGFloat = 200
    static let titleMinimum: CGFloat = 220
    static let rowHeight: CGFloat = 40
}

struct CollectionTableView: View {
    let model: CollectionViewModel
    @State private var adding = false
    @State private var newTitle = ""
    @State private var newField = ""
    @State private var addingField = false
    @FocusState private var titleFocused: Bool
    @Environment(\.themeTokens) private var theme

    var body: some View {
        let entries = model.entries
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 0) {
                header
                ForEach(Array(entries.enumerated()), id: \.element.path) { index, entry in
                    VStack(spacing: 0) {
                        hairline
                        TableRow(model: model, entry: entry, number: index + 1, fields: model.fields, widths: widths)
                    }
                    .collectionTransition(.asymmetric(insertion: CollectionMotion.enter, removal: CollectionMotion.leave))
                }
                if entries.isEmpty {
                    hairline
                    CollectionEmptyState(model: model, symbol: "tablecells")
                        .collectionTransition(.opacity)
                }
            }
            .background(RoundedRectangle(cornerRadius: Corners.r(8), style: .continuous).fill(theme.background))
            .clipShape(RoundedRectangle(cornerRadius: Corners.r(8), style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Corners.r(8), style: .continuous).strokeBorder(theme.separator.opacity(0.7)))
            // Sorting, filtering, adding and removing move the rows instead of redrawing them.
            .collectionAnimation(value: entries.map(\.path))
            if !entries.isEmpty || model.searchText.isEmpty { newRow.padding(.top, 6) }
            Spacer(minLength: 0)
        }
        .alert("New field", isPresented: $addingField) {
            TextField("Name", text: $newField)
            Button("Add") { addField(newField) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var hairline: some View {
        Rectangle().fill(theme.separator.opacity(0.5)).frame(height: 1)
    }

    private var view: CollectionViewConfig? { model.view }

    private var widths: [PropertyRef: CGFloat] {
        Dictionary(model.fields.map { ($0, width(of: $0)) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 0) {
            headerCell(width: TableMetrics.number) {
                Image(symbol: "number").font(.ui(size: 12)).foregroundStyle(theme.secondaryText)
                    .frame(maxWidth: .infinity)
            }
            divider
            fieldHeader(.title).frame(minWidth: TableMetrics.titleMinimum, maxWidth: .infinity, alignment: .leading)
            ForEach(model.fields, id: \.self) { ref in
                divider
                fieldHeader(ref).frame(width: width(of: ref), alignment: .leading)
            }
            divider
            addFieldMenu
        }
        .frame(height: 36)
        .background(theme.text.opacity(0.025))
    }

    private var divider: some View {
        Rectangle().fill(theme.separator.opacity(0.5)).frame(width: 1)
    }

    private func headerCell<Content: View>(width: CGFloat, @ViewBuilder _ content: () -> Content) -> some View {
        content().frame(width: width)
    }

    private func fieldHeader(_ ref: PropertyRef) -> some View {
        Menu {
            Button("Sort Ascending") { sort(ref, descending: false) }
            Button("Sort Descending") { sort(ref, descending: true) }
            if ref.namespace == .note {
                Divider()
                Menu("Type") {
                    ForEach(PropertyKind.allCases, id: \.self) { kind in
                        Button { setKind(kind, of: ref) } label: {
                            Label(kind.rawValue.capitalized, symbol: propertyKindSymbol(kind))
                        }
                    }
                }
                Button("Rename…") { model.fieldToRename = ref }
                Button("Hide") { setOrder((view?.order ?? []).filter { $0 != ref }) }
                Divider()
                Button("Delete Field…", role: .destructive) { model.fieldToDelete = ref }
            }
        } label: {
            HStack(spacing: 6) {
                Image(symbol: propertyKindSymbol(model.kind(ref), isTitle: ref == .title))
                    .font(.ui(size: 11))
                Text(model.title(of: ref)).lineLimit(1)
                if let sort = view?.sort.first, sort.property == ref {
                    Image(symbol: sort.descending ? "arrow.down" : "arrow.up")
                        .font(.ui(size: 11, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                        .collectionTransition(.opacity.combined(with: .scale(scale: 0.6)))
                }
            }
            .font(.ui(size: 13))
            .foregroundStyle(theme.secondaryText)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .collectionHover(cornerRadius: Corners.r(0), strength: 0.05)
            .contentShape(Rectangle())
            .collectionAnimation(CollectionMotion.hover, value: view?.sort.first)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    private var addFieldMenu: some View {
        Menu {
            let shown = Set(view?.order ?? [])
            ForEach(model.knownFields.filter { !shown.contains($0) }, id: \.self) { ref in
                Button(model.title(of: ref)) { setOrder(order + [ref]) }
            }
            Divider()
            Button("New Field…") {
                newField = ""
                addingField = true
            }
        } label: {
            Image(symbol: "plus").font(.ui(size: 12, weight: .medium)).foregroundStyle(theme.secondaryText)
                .frame(width: 36, height: 36).collectionHover(cornerRadius: Corners.r(0), strength: 0.05).contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add a field")
    }

    // MARK: New entry

    @ViewBuilder private var newRow: some View {
        Group {
            if adding {
                HStack(spacing: 8) {
                    Image(symbol: "doc").foregroundStyle(theme.secondaryText)
                    TextField("Title", text: $newTitle)
                        .textFieldStyle(.plain)
                        .focused($titleFocused)
                        .onSubmit(commitNew)
                        .onExitCommand { adding = false }
                        .onAppear { titleFocused = true }
                }
                .padding(.horizontal, 12)
                .frame(height: TableMetrics.rowHeight)
                .background(RoundedRectangle(cornerRadius: Corners.r(8), style: .continuous).fill(theme.background))
                .overlay(RoundedRectangle(cornerRadius: Corners.r(8), style: .continuous).strokeBorder(theme.accent.opacity(0.5), lineWidth: 1.5))
                .collectionTransition(.opacity.combined(with: .offset(y: -6)))
            } else {
                Button {
                    newTitle = ""
                    adding = true
                } label: {
                    Label("New", symbol: "plus")
                        .font(.ui(size: 13))
                        .foregroundStyle(theme.secondaryText)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .collectionHover(cornerRadius: Corners.r(8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Add an entry: a new note in the collection")
                .collectionTransition(.opacity)
            }
        }
        .collectionAnimation(CollectionMotion.reveal, value: adding)
    }

    // MARK: Actions

    private var order: [PropertyRef] { view.map { $0.order.isEmpty ? [.title] : $0.order } ?? [.title] }

    private func width(of ref: PropertyRef) -> CGFloat {
        if case .map(let sizes)? = view?.options["columnSize"], case .number(let width)? = sizes[ref.description] {
            return CGFloat(width)
        }
        return TableMetrics.field
    }

    private func setOrder(_ order: [PropertyRef]) {
        guard let view else { return }
        model.edit([.setOrder(view: view.name, order: order.contains(.title) ? order : [.title] + order)])
    }

    private func sort(_ ref: PropertyRef, descending: Bool) {
        guard let view else { return }
        model.edit([.setSort(view: view.name, sort: [CollectionSort(property: ref, descending: descending)])])
    }

    private func setKind(_ kind: PropertyKind, of ref: PropertyRef) {
        model.setKind(kind, of: ref)
    }

    private func addField(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let ref = PropertyRef(.note, name)
        model.edit([.setProperty(property: CollectionProperty(ref: ref, kind: .text))])
        setOrder(order + [ref])
    }

    private func commitNew() {
        let title = newTitle.trimmingCharacters(in: .whitespaces)
        adding = false
        guard !title.isEmpty else { return }
        model.newEntry(title: title)
    }
}


/// A row: its number, the title (a click opens the note), then the fields, editable in place. The row lightens
/// under the pointer.
struct TableRow: View {
    let model: CollectionViewModel
    let entry: NoteRecord
    let number: Int
    let fields: [PropertyRef]
    let widths: [PropertyRef: CGFloat]
    @State private var hovered = false
    @Environment(\.themeTokens) private var theme

    var body: some View {
        HStack(spacing: 0) {
            Text("\(number)")
                .font(.ui(size: 13).monospacedDigit())
                .foregroundStyle(theme.secondaryText)
                .contentTransition(.numericText())
                .frame(width: TableMetrics.number)
            divider
            Text(entry.title)
                .font(.ui(size: 13))
                .foregroundStyle(theme.text)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(minWidth: TableMetrics.titleMinimum, maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { model.open(entry.path, placement: NSEvent.modifierFlags.contains(.command) ? .newTab : .replace) }
                .draggableResource(.file(entry.path))
                .help("Open \(entry.path)")
            ForEach(fields, id: \.self) { ref in
                divider
                PropertyValueEditor(model: model, ref: ref, entry: entry)
                    .font(.ui(size: 13))
                    .padding(.horizontal, 12)
                    .frame(width: widths[ref] ?? TableMetrics.field, alignment: .leading)
                    .frame(maxHeight: .infinity)
            }
            divider
            Color.clear.frame(width: 36)
        }
        .frame(height: TableMetrics.rowHeight)
        .background(theme.text.opacity(hovered ? 0.03 : 0))
        .onHover { hovered = $0 }
        .animation(CollectionMotion.hover, value: hovered)
    }

    private var divider: some View {
        Rectangle().fill(theme.separator.opacity(0.5)).frame(width: 1)
    }
}
