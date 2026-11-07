import Foundation
import PluginKitUI

/// The map's keyboard actions as commands, so the palette lists them with their keys and agents reach them. They
/// act on the map that has the keyboard, else on the focused tab's map, its central topic when nothing is selected.
/// Their ⌘ shortcuts apply only while a map has the keyboard (`isShortcutEnabled`), so ⌘↑ still moves the caret in
/// a note, and `.loam/config.json` can change them. Keys without ⌘ or ⌃ (Tab, Return…) are the map's own
/// (`MindmapTabModel.handleKey`): the palette shows them (`Command.viewKey`), the shell never takes them.
@MainActor
enum MindmapCommands {
    struct Action {
        let id: String
        let title: String
        let summary: String
        /// The default key: a shortcut with ⌘ or ⌃, else a key of the map's own.
        let key: String?
        /// Takes the command's arguments (`text` for the commands that add a topic).
        let run: @MainActor (MindmapTabModel, [String: String]) -> Void
    }

    static let actions: [Action] = [
        Action(id: "mindmap.add-child", title: "Mindmap: add child topic",
               summary: "Adds a child to the selected topic of the focused mindmap and opens it for typing. "
                   + "Argument: text (optional), written at once instead. Writes the note.",
               key: "tab") { tab, args in tab.addChild(text: text(args)) },
        Action(id: "mindmap.add-sibling", title: "Mindmap: add sibling topic",
               summary: "Adds a topic below the selected one, on its side, and opens it for typing (a child of the "
                   + "central topic). Argument: text (optional), written at once instead. Writes the note.",
               key: "return") { tab, args in tab.addSibling(text: text(args)) },
        Action(id: "mindmap.add-sibling-above", title: "Mindmap: add sibling topic above",
               summary: "Adds a topic above the selected one and opens it for typing. Argument: text (optional).",
               key: "shift+return") { tab, args in tab.addSibling(above: true, text: text(args)) },
        Action(id: "mindmap.edit-topic", title: "Mindmap: edit topic",
               summary: "Opens the selected topic's text for typing (F2 too, or type to replace it).",
               key: "space") { tab, _ in if let id = tab.focusID { tab.startEdit(id) } },
        Action(id: "mindmap.delete-topic", title: "Mindmap: delete topic",
               summary: "Deletes the selected topics with their branches (never the central topic). Undoable. "
                   + "Writes the note.",
               key: "delete") { tab, _ in tab.deleteSelection() },
        Action(id: "mindmap.outdent", title: "Mindmap: move topic up a level",
               summary: "Moves the selected topic out of its parent, just after it. Writes the note.",
               key: "shift+tab") { tab, _ in tab.outdent() },
        Action(id: "mindmap.move-up", title: "Mindmap: move topic up",
               summary: "Moves the selected topic above its previous sibling (a main topic stays on its side). "
                   + "Writes the note.",
               key: "cmd+up") { tab, _ in tab.moveSibling(by: -1) },
        Action(id: "mindmap.move-down", title: "Mindmap: move topic down",
               summary: "Moves the selected topic below its next sibling. Writes the note.",
               key: "cmd+down") { tab, _ in tab.moveSibling(by: 1) },
        Action(id: "mindmap.move-left", title: "Mindmap: move topic left",
               summary: "Moves the selected topic left: toward the central topic it goes up a level and a main "
                   + "topic crosses to the left side; away from it, under the sibling above it. Writes the note.",
               key: "cmd+left") { tab, _ in tab.moveHorizontally(-1) },
        Action(id: "mindmap.move-right", title: "Mindmap: move topic right",
               summary: "Moves the selected topic right, as move left does the other way (a main topic on the "
                   + "left crosses to the right side). Writes the note.",
               key: "cmd+right") { tab, _ in tab.moveHorizontally(1) },
        Action(id: "mindmap.move-to-other-side", title: "Mindmap: move topic to the other side",
               summary: "Moves the selected main topic (a child of the central topic) to the other side of the "
                   + "map. Writes the note (`mindmap-right:` in its frontmatter when needed).",
               key: nil) { tab, _ in tab.moveToOtherSide() },
        Action(id: "mindmap.toggle-fold", title: "Mindmap: fold or unfold topic",
               summary: "Folds the selected topics' branches, or unfolds them. Saved with the tab, not in the note.",
               key: "cmd+.") { tab, _ in tab.foldSelection() },
        Action(id: "mindmap.fold", title: "Mindmap: fold topic",
               summary: "Folds the selected topic's branch; on a topic without children, the branch it is in.",
               key: "opt+cmd+left") { tab, _ in tab.foldFocused() },
        Action(id: "mindmap.unfold", title: "Mindmap: unfold topic",
               summary: "Unfolds the selected topic's branch.",
               key: "opt+cmd+right") { tab, _ in tab.unfoldFocused() },
        Action(id: "mindmap.fold-all", title: "Mindmap: fold all",
               summary: "Folds every branch of the focused mindmap, leaving the main topics.",
               key: "shift+opt+cmd+left") { tab, _ in tab.setAllFolded(true) },
        Action(id: "mindmap.unfold-all", title: "Mindmap: unfold all",
               summary: "Unfolds every branch of the focused mindmap.",
               key: "shift+opt+cmd+right") { tab, _ in tab.setAllFolded(false) },
        Action(id: "mindmap.zoom-to-fit", title: "Mindmap: zoom to fit",
               summary: "Shows the whole focused mindmap.",
               key: "cmd+0") { tab, _ in tab.fit() },
        Action(id: "mindmap.shortcuts", title: "Mindmap: keyboard shortcuts",
               summary: "Shows the list of the mindmap's keys over the focused map (also `?` in the map).",
               key: nil) { tab, _ in tab.showsShortcuts = true },
    ]

    static func register(in context: PluginContext, store: MindmapStore) throws {
        for action in actions {
            let run = action.run
            let key = action.key.flatMap(KeyShortcut.init(parsing:))
            let isMapKey = key.map { $0.modifiers.isDisjoint(with: [.command, .control]) } ?? false
            try context.registerCommand(Command(
                id: action.id,
                title: action.title,
                summary: action.summary,
                shortcut: isMapKey ? nil : key,
                isShortcutEnabled: { store.keyboardTab != nil },
                viewKey: isMapKey ? key : nil
            ) { args in
                try await MainActor.run {
                    guard let tab = store.commandTab, tab.root != nil else { throw MindmapCommandError.noMap }
                    if tab.focusID == nil, let root = tab.root { tab.select(root.id) }
                    run(tab, args)
                    tab.requestKeyboard()
                    return ""
                }
            })
        }
    }

    private static func text(_ args: [String: String]) -> String? {
        args["text"].flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }
}

enum MindmapCommandError: LocalizedError {
    case noMap

    var errorDescription: String? { "Open a mindmap first." }
}
