import AppKit
import PluginKitUI
import SwiftUI
import TruffleSearchPlugin

/// The Search panel: a field, Names / Content / Meaning, then the results grouped by note.
struct SearchPanel: View {
    let model: SearchModel
    @Environment(\.themeTokens) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: theme.spacing.small) {
                TextField("Search", text: Binding(get: { model.query }, set: { model.setQuery($0) }))
                    .textFieldStyle(.roundedBorder)
                Picker("Search by", selection: Binding(get: { model.kind }, set: { model.setKind($0) })) {
                    Text("Names").tag(SearchKind.names)
                    Text("Content").tag(SearchKind.content)
                    Text("Meaning").tag(SearchKind.meaning)
                        .disabled(!model.meaningAvailable)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help(model.meaningAvailable ? "Search names, content, or by meaning" : SearchModel.meaningUnavailable)
                if model.status != nil, !model.meaningAvailable {
                    HStack(spacing: 4) {
                        Text(SearchModel.meaningUnavailable)
                            .lineLimit(1)
                        Link("?", destination: SearchModel.truffleURL)
                            .help("What is Truffle?")
                    }
                    .font(.ui(.caption))
                    .foregroundStyle(theme.secondaryText)
                }
            }
            .padding(theme.spacing.medium)
            Divider()
            results
        }
        // Truffle may have started or stopped since the last look.
        .onAppear { model.refreshStatus() }
    }

    @ViewBuilder private var results: some View {
        if let message = model.message {
            note(message)
        } else if model.query.trimmingCharacters(in: .whitespaces).isEmpty {
            note("Type to search your notes.")
        } else if model.groups.isEmpty {
            note(model.isSearching ? "Searching…" : "No results.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.groups) { group in
                        GroupHeader(model: model, group: group)
                        ForEach(group.rows) { row in
                            HitRow(model: model, row: row)
                        }
                    }
                }
                .padding(.vertical, theme.spacing.small)
            }
            .softScrollEdges()
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.ui(.label))
            .foregroundStyle(theme.secondaryText)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(theme.spacing.medium)
    }
}

/// A note: its title and folder. A click opens it.
private struct GroupHeader: View {
    let model: SearchModel
    let group: SearchModel.Group
    @Environment(\.themeTokens) private var theme

    var body: some View {
        HStack(spacing: theme.spacing.small) {
            Image(symbol: "doc.text").foregroundStyle(theme.secondaryText)
            Text(emphasised(group.title, model.kind == .names ? model.query : ""))
                .fontWeight(.semibold)
                .lineLimit(1)
                .foregroundStyle(theme.text)
            if !group.folder.isEmpty {
                Text(group.folder).font(.ui(.caption)).lineLimit(1).foregroundStyle(theme.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, theme.spacing.medium)
        .padding(.top, theme.spacing.small)
        .padding(.bottom, 2)
        .contentShape(Rectangle())
        .tappableRow { model.open(group.path, beside: commandKeyDown()) }
        .draggableResource(.file(group.path))
    }
}

/// A matching line or passage under its note, the match in bold.
private struct HitRow: View {
    let model: SearchModel
    let row: SearchModel.Row
    @Environment(\.themeTokens) private var theme

    var body: some View {
        if let snippet = row.hit.snippet.map(SearchModel.plainSnippet), !snippet.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: theme.spacing.small) {
                Text(emphasised(snippet, model.kind == .content ? model.query : ""))
                    .font(.ui(.label))
                    .lineLimit(3)
                    .foregroundStyle(theme.text)
                Spacer(minLength: 0)
                if let line = row.hit.line {
                    Text("\(line)").font(.ui(.caption).monospacedDigit()).foregroundStyle(theme.secondaryText)
                }
            }
            .padding(.leading, theme.spacing.medium + 20)
            .padding(.trailing, theme.spacing.medium)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .tappableRow { model.open(row.hit.path, beside: commandKeyDown()) }
        }
    }
}

/// `text` with every case- and accent-insensitive occurrence of `query` in bold.
func emphasised(_ text: String, _ query: String) -> AttributedString {
    var attributed = AttributedString(text)
    let needle = query.trimmingCharacters(in: .whitespaces)
    guard !needle.isEmpty else { return attributed }
    var start = attributed.startIndex
    while start < attributed.endIndex,
          let range = attributed[start...].range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) {
        attributed[range].inlinePresentationIntent = .stronglyEmphasized
        start = range.upperBound
    }
    return attributed
}

private func commandKeyDown() -> Bool {
    NSEvent.modifierFlags.contains(.command)
}
