import Foundation
import PluginKitUI

/// Cmd+O: find a note by name and open it, or create it when it does not exist yet.
///
/// The shell owns the popup (`QuickPick`); this plugin only lists, ranks and acts. It uses the note graph for
/// titles when it is there and falls back to file names, so it works in a vault without it.
public final class QuickSwitcherPlugin: UIPlugin {
    public static let manifest = PluginManifest(
        id: "quick-switcher",
        name: "Quick switcher",
        version: "0.1.0",
        description: "Cmd+O: open a note by name, or create it.",
        icon: "magnifyingglass.circle",
        // `files` will create notes once that service exists; until then the switcher writes through the vault.
        optionalRequires: ["note-graph", "files", "editor"],
        permissions: ["ui", "vault.read", "vault.write"]
    )

    public init() {}

    @MainActor public func activateUI(context: PluginContext) throws {
        let switcher = Switcher(context: context)
        // The notes listed stay good until the vault changes: listing them walks the vault and sorts every note.
        context.on(VaultChanged.self) { [weak switcher] _ in MainThread.run { switcher?.forgetCandidates() } }
        context.on(NotesMoved.self) { [weak switcher] _ in MainThread.run { switcher?.forgetCandidates() } }
        try context.registerCommand(Command(
            id: "switcher.open",
            title: "Open note…",
            summary: "Shows a popup to find a note by fuzzy name and open it; typing a name no note has offers to "
                + "create that note in Inbox (the file is only written once text is typed in it).",
            shortcut: KeyShortcut("o", [.command])
        ) { _ in
            await MainActor.run { switcher.show() }
        })
    }
}

/// The command's state: the context, held until the command is unregistered on unload.
@MainActor
final class Switcher {
    private let context: PluginContext
    /// The notes the popup lists, from the last opening, until the vault changes.
    private var candidates: [NoteCandidate]?

    init(context: PluginContext) {
        self.context = context
    }

    func forgetCandidates() { candidates = nil }

    /// Opens the popup, or says why it cannot (the CLI has no popup).
    func show() -> String {
        guard let quickPick = context.quickPick else { return "No quick switcher popup in this host." }
        let candidates = self.candidates ?? NoteCandidate.all(vault: context.vault, graph: context.service(.noteGraph))
        self.candidates = candidates
        // Each note shows the icon of the view it opens with (a board, a mindmap, a drawing), as in the explorer.
        let views = context.service(.views)
        let symbol = { (path: String) in views?.symbol(for: .file(path)) ?? "doc.text" }
        quickPick.show(
            placeholder: "Open a note…",
            items: { SwitcherRanking.items(for: $0, in: candidates, symbol: symbol) },
            choose: { [weak self] in self?.choose($0) }
        )
        // Empty: the popup is the feedback; the palette shows no toast for an empty result.
        return ""
    }

    private func choose(_ item: QuickPickItem) {
        if item.id.hasPrefix(SwitcherRanking.notePrefix) {
            open(String(item.id.dropFirst(SwitcherRanking.notePrefix.count)))
        } else if item.id.hasPrefix(SwitcherRanking.createPrefix) {
            create(String(item.id.dropFirst(SwitcherRanking.createPrefix.count)))
        }
    }

    /// Opens the existing note of that name, or a new one in the inbox (never the vault's root). With an editor the
    /// new note is a draft: the file is written once text is typed, so nothing empty is left behind. Without one the
    /// file is written at once. A later version will go through the `files` service (templates) instead.
    private func create(_ query: String) {
        guard let name = NoteName.sanitize(query) else { return }
        let inbox = VaultPath.inbox + "/" + name
        if let existing = [name, inbox].first(where: context.vault.exists) { return open(existing) }
        if let editor = context.service(.editor) {
            editor.beginDraft(at: inbox)
        } else if (try? context.vault.write(inbox, "")) == nil {
            // The popup has no way to show an error; on failure nothing opens, which the user sees.
            return
        }
        Sounds.play(.created)
        open(inbox)
    }

    private func open(_ path: String) {
        context.workspace?.open(.file(path), placement: .replace)
    }
}

