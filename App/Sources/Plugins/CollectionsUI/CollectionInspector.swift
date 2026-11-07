import PluginKit
import PluginKitUI
import SwiftUI

/// A collection's "View" tab in the right sidebar: how the shown view groups its cards (a board), which fields it
/// shows, and its sort. The views themselves and the columns' counts stay on the page. Every change is an edit of
/// the `.base` file, as the page's own view settings make.
struct CollectionInspector: View {
    let model: CollectionViewModel
    let views: CollectionViewStore

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorStyle.groupSpacing) {
            if model.definition != nil, let current = model.view {
                // A choice of one is no choice: a board with a single field to group by shows nothing for it.
                if views.type(current.type)?.groupsEntries == true, groupFields.count > 1 {
                    grouping(current)
                }
                fields(current)
                sorting(current)
            } else if let error = model.error {
                InspectorEmpty(error, systemImage: "exclamationmark.triangle")
            }
        }
    }

    // MARK: Board

    /// The fields a board can group by: its selects and checkboxes, else any field.
    private var groupFields: [PropertyRef] {
        let candidates = model.knownFields.filter { [.select, .multiselect, .checkbox].contains(model.kind($0)) }
        return candidates.isEmpty ? model.knownFields : candidates
    }

    @ViewBuilder private func grouping(_ view: CollectionViewConfig) -> some View {
        let fields = groupFields
        InspectorGroup("Group by") {
            if fields.isEmpty {
                InspectorEmpty("Add a field to group the cards by.", systemImage: "rectangle.3.group")
            } else if fields.count <= 3 {
                InspectorSegmented(
                    fields.map { (value: $0, title: model.title(of: $0)) },
                    selection: Binding(
                        get: { view.groupBy?.property ?? fields[0] },
                        set: { setGroup($0, of: view) }
                    )
                )
            } else {
                InspectorCard {
                    ForEach(fields, id: \.self) { ref in
                        InspectorRow(model.title(of: ref), isSelected: view.groupBy?.property == ref) { setGroup(ref, of: view) }
                    }
                }
            }
        }
    }

    private func setGroup(_ ref: PropertyRef, of view: CollectionViewConfig) {
        model.edit([.setGroupBy(view: view.name, groupBy: CollectionSort(property: ref))])
    }

    // MARK: Sort and fields

    private func sorting(_ view: CollectionViewConfig) -> some View {
        let current = view.sort.first?.property ?? .title
        let descending = view.sort.first?.descending ?? false
        let choices: [PropertyRef] = [.title] + model.knownFields + [PropertyRef(.file, "mtime")]
        return InspectorGroup("Sort by") {
            InspectorCard {
                InspectorRow("Field") {
                    Menu {
                        ForEach(choices, id: \.self) { ref in
                            Button(sortTitle(ref)) { setSort(ref, descending: descending, of: view) }
                        }
                    } label: {
                        Text(sortTitle(current))
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .fixedSize()
                }
                InspectorToggleRow("Descending", isOn: Binding(
                    get: { descending },
                    set: { setSort(current, descending: $0, of: view) }
                ))
            }
        }
    }

    private func sortTitle(_ ref: PropertyRef) -> String {
        if ref == .title { return "Title" }
        if ref == PropertyRef(.file, "mtime") { return "Modified" }
        return model.title(of: ref)
    }

    private func setSort(_ ref: PropertyRef, descending: Bool, of view: CollectionViewConfig) {
        model.edit([.setSort(view: view.name, sort: [CollectionSort(property: ref, descending: descending)])])
    }

    @ViewBuilder private func fields(_ view: CollectionViewConfig) -> some View {
        InspectorGroup(view.type == "table" ? "Columns shown" : "On the cards") {
            if model.knownFields.isEmpty {
                InspectorEmpty("No fields yet: add one from a table's \"+\" column.", systemImage: "tablecells")
            } else {
                InspectorCard {
                    ForEach(model.knownFields, id: \.self) { ref in
                        InspectorToggleRow(model.title(of: ref), isOn: Binding(
                            get: { view.order.contains(ref) },
                            set: { shown in
                                var order = view.order.isEmpty ? [.title] : view.order
                                if shown { order.append(ref) } else { order.removeAll { $0 == ref } }
                                model.edit([.setOrder(view: view.name, order: order)])
                            }
                        ))
                    }
                }
            }
        }
    }
}
