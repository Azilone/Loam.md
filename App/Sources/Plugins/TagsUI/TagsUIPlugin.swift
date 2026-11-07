import AppKit
import Foundation
import Observation
import PluginKitUI
import SwiftUI

/// The Tags section of the left sidebar: every tag with its note count. A click opens the tag's notes as a
/// collection (`collection:#tag`, a gallery and a table). Reads through `note-query`; writes nothing.
public final class TagsUIPlugin: UIPlugin {
    public static let manifest = PluginManifest(
        id: "tags",
        name: "Tags",
        version: "0.1.0",
        description: "The Tags section of the sidebar: every tag with its count.",
        icon: "tag",
        requires: ["note-query"],
        permissions: ["ui", "vault.read"]
    )

    static let sectionID = "tags.section"
    /// Internal: lets the tests reach the panel's model. Not a contract.
    static var modelKey: ServiceKey<TagsModel> { ServiceKey("tags.model") }
    /// The same key for tests in other modules.
    public static var modelKeyForTests: ServiceKey<TagsModel> { modelKey }

    public init() {}

    @MainActor public func activateUI(context: PluginContext) throws {
        let model = TagsModel(
            noteQuery: { [weak context] in context?.service(.noteQuery) },
            workspace: { [weak context] in context?.workspace }
        )
        model.refresh()
        try context.provide(Self.modelKey, model)
        try context.addSidebarSection(SidebarSection(id: Self.sectionID, title: "Tags", order: 20, isCollapsedByDefault: true) {
            AnyView(TagsSection(model: model))
        })
        try context.registerCommand(Command(
            id: "tags.list",
            title: "List tags",
            summary: "Lists every tag of the vault with how many notes carry it, most used first, as JSON. Writes nothing.",
            isInPalette: false
        ) { _ in
            try await MainActor.run { try JSON.string(model.tags.map { ["tag": $0.tag, "count": String($0.count)] }) }
        })
        context.on(VaultChanged.self) { [weak model] event in
            guard event.changes.contains(where: \.isNote) else { return }
            MainThread.run { model?.refreshSoon() }
        }
        context.on(NotesMoved.self) { [weak model] _ in MainThread.run { model?.refreshSoon() } }
        context.on(ActiveResourceChanged.self) { [weak model] event in
            let resource = event.resource
            MainThread.run { model?.active = resource }
        }
    }
}

/// The note query, carried to a background thread: its queries read the note graph, which is safe from any thread.
private struct TagsQueryBox: @unchecked Sendable {
    let service: NoteQueryService
}

public struct TagCount: Identifiable, Equatable, Sendable {
    public let tag: String
    public let count: Int
    public var id: String { tag.lowercased() }

    /// The page of a tag's notes.
    var resource: Resource { .virtual("collection:#" + tag) }
}

@MainActor
@Observable
public final class TagsModel {
    public private(set) var tags: [TagCount] = []
    var active: Resource?
    @ObservationIgnored private let noteQuery: @MainActor () -> NoteQueryService?
    @ObservationIgnored private let workspace: @MainActor () -> (any Workspace)?

    init(noteQuery: @escaping @MainActor () -> NoteQueryService?, workspace: @escaping @MainActor () -> (any Workspace)?) {
        self.noteQuery = noteQuery
        self.workspace = workspace
    }

    func refresh() {
        let new = Self.count((noteQuery()?.run(NoteQuery()) ?? []).flatMap(\.tags))
        if new != tags { tags = new }
    }

    @ObservationIgnored private var refreshing: Task<Void, Never>?
    @ObservationIgnored private var refreshAgain = false

    /// `refresh()` off the main thread, after a change on disk: reading every note's stamp and tags took a drop on
    /// a board ~30 ms, twice. The refreshes asked while one runs make one more, applied last.
    func refreshSoon() {
        if refreshing != nil {
            refreshAgain = true
            return
        }
        refreshing = Task { [weak self] in
            guard let self, let service = self.noteQuery() else { return }
            let box = TagsQueryBox(service: service)
            let new = await Task.detached(priority: .utility) { Self.count(box.service.run(NoteQuery()).flatMap(\.tags)) }.value
            self.refreshing = nil
            if self.refreshAgain {
                self.refreshAgain = false
                self.refreshSoon()
            } else if new != self.tags {
                self.tags = new
            }
        }
    }

    /// Waits for the refreshes under way (tests).
    func settled() async {
        while let refreshing { await refreshing.value }
    }

    func open(_ tag: TagCount, newTab: Bool) {
        workspace()?.open(tag.resource, placement: newTab ? .newTab : .replace)
    }

    /// Tags ignoring case, most used first, then by name.
    nonisolated static func count(_ tags: [String]) -> [TagCount] {
        var counts: [String: (tag: String, count: Int)] = [:]
        for tag in tags { counts[tag.lowercased(), default: (tag, 0)].count += 1 }
        return counts.values
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.tag.lowercased() < $1.tag.lowercased() }
            .map { TagCount(tag: $0.tag, count: $0.count) }
    }
}

struct TagsSection: View {
    let model: TagsModel
    @Environment(\.themeTokens) private var theme

    var body: some View {
        if model.tags.isEmpty {
            Text("No tags yet")
                .font(.ui(size: 12))
                .foregroundStyle(theme.secondaryText)
                .padding(.horizontal, SidebarStyle.rowPadding)
                .padding(.vertical, 4)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.tags) { tag in
                    TagRow(tag: tag, isActive: model.active == tag.resource) {
                        model.open(tag, newTab: NSEvent.modifierFlags.contains(.command))
                    }
                }
            }
        }
    }
}

private struct TagRow: View {
    let tag: TagCount
    let isActive: Bool
    let action: () -> Void
    @Environment(\.themeTokens) private var theme

    var body: some View {
        HStack(spacing: SidebarStyle.iconGap) {
            Text("#").foregroundStyle(theme.sidebarAccessory(selected: isActive).opacity(0.7)).frame(width: SidebarStyle.iconSize)
            Text(tag.tag).lineLimit(1)
            Spacer(minLength: 4)
            Text("\(tag.count)").themeLabel(size: UIType.caption.size).foregroundStyle(theme.sidebarAccessory(selected: isActive).opacity(0.7))
        }
        .sidebarRow(isSelected: isActive)
        .tappableRow(action)
        .draggableResource(tag.resource)
        .help("Open the notes tagged #\(tag.tag)")
    }
}

