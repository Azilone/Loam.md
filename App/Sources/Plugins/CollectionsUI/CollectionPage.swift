import AppKit
import PluginKitUI
import SwiftUI

/// Craft's collection: the name with its tools on the right (search, new entry, view settings), the views as tabs
/// under it ("+" adds one), then the selected view, drawn by the plugin of its type.
struct CollectionPage: View {
    @Bindable var model: CollectionViewModel
    let views: CollectionViewStore
    var context: ViewContext?
    /// The `ViewType.id` the page is shown with in a tab, for the right sidebar; nil inside a note.
    var viewType: String?
    @State private var searching = false
    @State private var showsSettings = false
    @State private var renaming: String?
    @State private var newName = ""
    @State private var fieldName = ""
    @FocusState private var searchFocused: Bool
    @Namespace private var tabSelection
    @Environment(\.themeTokens) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            tabs.padding(.top, Space.m)
            notices
            // The view replaces the previous one with a short cross-fade rather than a cut.
            ZStack(alignment: .top) {
                content
                    .id(model.view?.name)
                    .collectionTransition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: 6)), removal: .opacity))
            }
            .padding(.top, Space.m)
            .frame(maxHeight: .infinity, alignment: .top)
            .collectionAnimation(CollectionMotion.reveal, value: model.view?.name)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .pageColumn(model.isEmbedded ? .full : .wide, top: model.isEmbedded ? 0 : PageMetrics.top)
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear { [model, views, context, viewType] in
            guard let context, let viewType else { return }
            context.setInspector(viewType: viewType, tabs: [
                InspectorTab(id: "collection.view", title: "View") {
                    AnyView(CollectionInspector(model: model, views: views))
                },
            ])
        }
        .alert("Rename view", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let old = renaming, !newName.isEmpty, newName != old {
                    model.edit([.renameView(name: old, to: newName)])
                    select(newName)
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .alert("Rename field", isPresented: Binding(get: { model.fieldToRename != nil }, set: { if !$0 { model.fieldToRename = nil } })) {
            TextField("Name", text: $fieldName)
            Button("Rename") {
                if let ref = model.fieldToRename {
                    var property = model.property(ref)
                    property.displayName = fieldName.isEmpty ? nil : fieldName
                    model.edit([.setProperty(property: property)])
                }
                model.fieldToRename = nil
            }
            Button("Cancel", role: .cancel) { model.fieldToRename = nil }
        }
        .onChange(of: model.fieldToRename) { _, ref in
            if let ref { fieldName = model.title(of: ref) }
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { model.fieldToDelete != nil }, set: { if !$0 { model.fieldToDelete = nil } }),
                            titleVisibility: .visible) {
            if let ref = model.fieldToDelete {
                Button("Delete Field", role: .destructive) { model.deleteField(ref, removingValues: false) }
                if model.valueCount(of: ref) > 0 {
                    Button("Delete Field and Its Values", role: .destructive) { model.deleteField(ref, removingValues: true) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteMessage)
        }
        .overlay(alignment: .bottom) {
            if let deleted = model.deletedField {
                CollectionUndoBar(message: "Field “\(deleted.title)” deleted") { model.undoDelete() }
                    .collectionTransition(.opacity.combined(with: .offset(y: 12)))
            }
        }
        .collectionAnimation(CollectionMotion.reveal, value: model.deletedField)
        .task(id: model.deletedField) {
            guard model.deletedField != nil else { return }
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { model.dismissDeletedField() }
        }
    }

    private var deleteTitle: String {
        "Delete the field “\(model.fieldToDelete.map(model.title(of:)) ?? "")”?"
    }

    private var deleteMessage: String {
        guard let ref = model.fieldToDelete else { return "" }
        let count = model.valueCount(of: ref)
        let kept = count == 0 ? "No note has a value for it." : "\(count) note\(count == 1 ? "" : "s") shown "
            + "\(count == 1 ? "has" : "have") a value for it in their frontmatter; \"Delete Field\" keeps those values, "
            + "the other button erases them."
        return "It disappears from every view of this collection. \(kept) You can undo for a few seconds."
    }

    /// A folder's page is named after the folder, a `.base` after its file.
    private var title: String {
        if let context, context.resource.kind == .folder { return context.resource.name }
        if let context, let tag = CollectionStore.tag(of: context.resource) { return "#" + tag }
        return model.definition?.name ?? "Collection"
    }

    @ViewBuilder private var notices: some View {
        Group {
            if let error = model.error {
                Text(error).font(.ui(.body)).foregroundStyle(theme.danger).padding(.top, Space.s)
                    .collectionTransition(.opacity.combined(with: .offset(y: -4)))
            }
            if let warnings = model.result?.warnings, !warnings.isEmpty {
                Text("Loam cannot read part of this collection's filter (\(warnings.joined(separator: ", "))); "
                     + "the notes it cannot decide on are shown.")
                    .font(.ui(.caption)).foregroundStyle(theme.secondaryText).padding(.top, Space.s)
                    .collectionTransition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .collectionAnimation(CollectionMotion.reveal, value: model.error)
    }

    private var header: some View {
        Group {
            if model.isEmbedded {
                HStack(alignment: .center, spacing: Space.m) {
                    Text(title.uiLocalized)
                        .font(.ui(.section))
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                    Spacer(minLength: Space.m)
                    tools
                }
            } else {
                PageHeader(title) { tools }
            }
        }
        .collectionAnimation(CollectionMotion.reveal, value: searching)
    }

    /// The page's tools: search, new entry, view settings, in one capsule.
    private var tools: some View {
        HStack(spacing: Space.m) {
            if searching { searchField }
            HStack(spacing: Space.xxs) {
                toolButton("magnifyingglass", help: "Search", active: searching) {
                    searching.toggle()
                    if searching { searchFocused = true } else { model.searchText = "" }
                }
                toolButton("plus.circle.fill", help: "New entry") {
                    if let path = model.newEntry() { model.open(path, placement: .beside) }
                }
                toolButton("slider.horizontal.3", help: "View settings", active: showsSettings) { showsSettings.toggle() }
                    .popover(isPresented: $showsSettings, arrowEdge: .bottom) {
                        ViewSettings(model: model, views: views, close: { showsSettings = false })
                    }
            }
            .padding(3)
            .background(ThemeCapsule().fill(theme.background))
            .overlay(ThemeCapsule().strokeBorder(theme.separator.opacity(0.6)))
        }
    }

    /// Craft's search field: a quiet capsule with the magnifier inside and a clear button once there is text.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(symbol: "magnifyingglass")
                .font(.ui(size: 12, weight: .medium))
                .foregroundStyle(theme.secondaryText)
            TextField("Search", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.ui(size: 13))
                .focused($searchFocused)
                .onExitCommand {
                    model.searchText = ""
                    searching = false
                }
            if !model.searchText.isEmpty {
                Button { model.searchText = "" } label: {
                    Image(symbol: "xmark.circle.fill")
                        .font(.ui(size: 12))
                        .foregroundStyle(theme.secondaryText.opacity(0.7))
                }
                .buttonStyle(.plain)
                .collectionTransition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 210, height: 30)
        .background(ThemeCapsule().fill(theme.fillSubtle))
        .overlay(ThemeCapsule().strokeBorder(searchFocused ? theme.accent.opacity(0.55) : .clear, lineWidth: 1.5))
        .collectionAnimation(CollectionMotion.hover, value: searchFocused)
        .collectionAnimation(CollectionMotion.hover, value: model.searchText.isEmpty)
        .collectionTransition(.opacity.combined(with: .scale(scale: Motion.Metrics.enterScale, anchor: .trailing)))
    }

    private func toolButton(_ symbol: String, help: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(symbol: symbol)
                .font(.ui(.body, weight: .medium))
                .foregroundStyle(theme.text.opacity(active ? 1 : 0.8))
                .frame(width: 30, height: 26)
                .contentShape(ThemeCapsule())
                .collectionHover(cornerRadius: Corners.r(12), strength: active ? 0.1 : 0.07)
                .background(ThemeCapsule().fill(theme.text.opacity(active ? 0.07 : 0)))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            ForEach(model.definition?.views ?? [], id: \.name) { view in
                let selected = view.name == model.view?.name
                Button { select(view.name) } label: {
                    Text(view.name)
                        .font(.ui(.body, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? theme.text : theme.secondaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .collectionHover(isEnabled: !selected)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: Corners.r(6), style: .continuous)
                                    .fill(theme.text.opacity(0.06))
                                    .matchedGeometryEffect(id: "selectedTab", in: tabSelection)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu { tabMenu(view) }
                .collectionTransition(.opacity.combined(with: .scale(scale: 0.9)))
            }
            Menu {
                ForEach(views.types) { type in
                    Button { add(type) } label: { Label(type.title, symbol: type.symbol) }
                }
            } label: {
                Image(symbol: "plus")
                    .font(.ui(size: 13, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 24, height: 24)
                    .collectionHover(cornerRadius: Corners.r(6))
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add a view")
        }
        .collectionAnimation(CollectionMotion.reveal, value: model.view?.name)
        .collectionAnimation(CollectionMotion.layout, value: model.definition?.views.map(\.name) ?? [])
    }

    @ViewBuilder private func tabMenu(_ view: CollectionViewConfig) -> some View {
        Button("Rename…") {
            newName = view.name
            renaming = view.name
        }
        Menu("Turn Into") {
            ForEach(views.types.filter { $0.id != view.type }) { type in
                Button { turn(view, into: type) } label: { Label(type.title, symbol: type.symbol) }
            }
        }
        Divider()
        Button("Delete View", role: .destructive) { model.edit([.removeView(name: view.name)]) }
            .disabled((model.definition?.views.count ?? 0) < 2)
    }

    @ViewBuilder private var content: some View {
        if let view = model.view {
            if let type = views.type(view.type) {
                if let make = type.makeNSView {
                    NativeView { make(model) }
                } else {
                    type.makeView(model)
                }
            } else {
                message("No plugin draws \(view.type) views", "Enable the plugin that adds them, or turn this view into a table.")
            }
        } else if model.error == nil {
            ProgressView().frame(maxWidth: .infinity)
        }
    }

    private func message(_ title: String, _ detail: String) -> some View {
        EmptyState(title, symbol: "rectangle.dashed", message: detail)
    }

    private func select(_ name: String) { actions.select(name) }

    private func add(_ type: CollectionViewType) { actions.add(type) }

    private func turn(_ view: CollectionViewConfig, into type: CollectionViewType) { actions.turn(view, into: type) }

    private var actions: CollectionActions { CollectionActions(model: model, context: context) }
}

/// What the page and the right sidebar both do to a collection's views: pick one, add one, turn one into another
/// type. The chosen view is saved in the tab.
@MainActor
struct CollectionActions {
    let model: CollectionViewModel
    let context: ViewContext?

    func select(_ name: String) {
        model.viewName = name
        context?.setState(PageState(view: name))
    }

    func add(_ type: CollectionViewType) {
        let existing = model.definition?.views.map(\.name) ?? []
        var name = type.title
        var number = 2
        while existing.contains(name) {
            name = "\(type.title) \(number)"
            number += 1
        }
        model.edit([.addView(type: type.id, name: name)])
        if let definition = model.definition { model.edit(type.defaults(definition, name)) }
        select(name)
    }

    func turn(_ view: CollectionViewConfig, into type: CollectionViewType) {
        // A new view of the other type takes the old one's place, name and fields.
        let temporary = view.name + " (\(type.title))"
        model.edit([.addView(type: type.id, name: temporary), .setOrder(view: temporary, order: view.order),
                    .setSort(view: temporary, sort: view.sort)])
        if let definition = model.definition { model.edit(type.defaults(definition, temporary)) }
        let index = model.definition?.views.firstIndex { $0.name == view.name } ?? 0
        model.edit([.removeView(name: view.name), .renameView(name: temporary, to: view.name),
                    .moveView(name: view.name, to: index)])
        select(view.name)
    }
}

/// The view settings popover: the fields shown, the sort, and the grouping of a board.
struct ViewSettings: View {
    let model: CollectionViewModel
    let views: CollectionViewStore
    /// Closes the popover, so a dialog the page then shows is not hidden behind it.
    let close: () -> Void
    @Environment(\.themeTokens) private var theme

    var body: some View {
        if let view = model.view {
            VStack(alignment: .leading, spacing: 12) {
                Text(view.name).font(.ui(.body, weight: .semibold))
                if views.type(view.type)?.groupsEntries == true {
                    Picker("Group by", selection: Binding(
                        get: { view.groupBy?.property },
                        set: { ref in model.edit([.setGroupBy(view: view.name, groupBy: ref.map { CollectionSort(property: $0) })]) }
                    )) {
                        Text("None").tag(PropertyRef?.none)
                        ForEach(model.knownFields, id: \.self) { ref in Text(model.title(of: ref)).tag(PropertyRef?.some(ref)) }
                    }
                }
                Picker("Sort by", selection: Binding(
                    get: { view.sort.first?.property ?? .title },
                    set: { ref in
                        model.edit([.setSort(view: view.name, sort: [CollectionSort(property: ref, descending: view.sort.first?.descending ?? false)])])
                    }
                )) {
                    Text("Title").tag(PropertyRef.title)
                    ForEach(model.knownFields, id: \.self) { ref in Text(model.title(of: ref)).tag(ref) }
                    Text("Modified").tag(PropertyRef(.file, "mtime"))
                }
                Toggle("Descending", isOn: Binding(
                    get: { view.sort.first?.descending ?? false },
                    set: { model.edit([.setSort(view: view.name, sort: [CollectionSort(property: view.sort.first?.property ?? .title, descending: $0)])]) }
                ))
                Divider()
                Text("Fields").font(.subheadline.weight(.semibold)).foregroundStyle(theme.secondaryText)
                ForEach(model.knownFields, id: \.self) { ref in
                    HStack(spacing: 4) {
                        Toggle(model.title(of: ref), isOn: Binding(
                            get: { view.order.contains(ref) },
                            set: { shown in
                                var order = view.order.isEmpty ? [.title] : view.order
                                if shown { order.append(ref) } else { order.removeAll { $0 == ref } }
                                model.edit([.setOrder(view: view.name, order: order)])
                            }
                        ))
                        Spacer(minLength: 0)
                        FieldMenu(model: model, ref: ref, close: close)
                    }
                }
                if model.knownFields.isEmpty {
                    Text("No fields yet: add one from a table's \"+\" column.").font(.ui(.caption)).foregroundStyle(theme.secondaryText)
                }
            }
            .padding(16)
            .frame(width: 280)
        }
    }
}

/// A field's "…" in the view settings: the same Rename and Delete as its table header's menu.
private struct FieldMenu: View {
    let model: CollectionViewModel
    let ref: PropertyRef
    let close: () -> Void
    @Environment(\.themeTokens) private var theme

    var body: some View {
        Menu {
            Button("Rename…") {
                close()
                model.fieldToRename = ref
            }
            Divider()
            Button("Delete Field…", role: .destructive) {
                close()
                model.fieldToDelete = ref
            }
        } label: {
            Image(symbol: "ellipsis")
                .font(.ui(size: 12, weight: .medium))
                .foregroundStyle(theme.secondaryText)
                .frame(width: 24, height: 22)
                .collectionHover(cornerRadius: Corners.r(6))
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Field options")
    }
}
