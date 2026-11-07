import AppKit
import PluginKitUI
import SwiftUI

/// A collection shown inside a note, from an image link to its `.base` alone on a line (`![](Ideas/Ideas.base)`): the
/// same page, smaller, as the editor shows a picture. The note keeps a plain Markdown link; the notes stay in the
/// collection's folder.
struct CollectionEmbed: View {
    let model: CollectionViewModel
    let views: CollectionViewStore

    var body: some View {
        CollectionPage(model: model, views: views)
            .frame(maxWidth: .infinity, minHeight: 160, maxHeight: 420, alignment: .top)
            .padding(.vertical, 6)
    }
}

/// The `/` items that show a collection in a note, one per collection of the vault ("Show Ideas"), refreshed when a
/// `.base` comes or goes. Each writes `![](<path>.base)` on its own line.
@MainActor
final class CollectionSlashItems {
    private weak var context: PluginContext?
    private let collections: @MainActor () -> CollectionService?
    private var removers: [@MainActor () -> Void] = []
    private var shown: [String] = []

    init(context: PluginContext, collections: @escaping @MainActor () -> CollectionService?) {
        self.context = context
        self.collections = collections
        context.effect { [weak self] in MainActor.assumeIsolated { self?.removeAll() } }
    }

    func refresh() {
        let paths = collections()?.collections() ?? []
        guard paths != shown, let editor = context?.editor else { return }
        removeAll()
        shown = paths
        for path in paths { removers.append(editor.addSlashItem(Self.item(for: path))) }
    }

    private func removeAll() {
        for remove in removers { remove() }
        removers = []
        shown = []
    }

    /// The name a collection is shown by: its folder's for a folder's own `.base`, else its file's.
    nonisolated static func name(of path: String) -> String {
        let file = (path as NSString).lastPathComponent
        return (file as NSString).deletingPathExtension
    }

    nonisolated static func item(for path: String) -> SlashItem {
        SlashItem(
            id: "collection.embed:" + path,
            title: "Collection: " + name(of: path),
            symbol: CollectionsUIPlugin.symbol,
            keywords: ["collection", "base", "database", "table", "gallery", "kanban"]
        ) { text, trigger in
            let link = "![](" + VaultPath.relativeDestination(fromDirectory: "", to: path) + ")\n"
            let ns = text as NSString
            let lineStart = ns.lineRange(for: NSRange(location: trigger.location, length: 0)).location
            let replacement = (trigger.location > lineStart ? "\n" : "") + link
            let end = trigger.location + (replacement as NSString).length
            return TextChange(range: trigger, replacement: replacement, selection: NSRange(location: end, length: 0))
        }
    }
}

/// "New → Collection": asks for a name, makes a folder of that name that is a collection (a table of its notes), and
/// opens it. From the "New" button (which offers the Inbox) it goes at the root, next to the other folders; from a
/// folder's menu, inside that folder.
@MainActor
enum NewCollection {
    static func prompt(in folder: String, context: PluginContext) {
        let field = NSTextField(string: "")
        field.placeholderString = String(localized: "Collection name")
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        let alert = NSAlert()
        alert.messageText = String(localized: "New Collection")
        alert.informativeText = String(localized: "A folder whose notes show as a table, a board or a gallery.")
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Create"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        let finish: (NSApplication.ModalResponse) -> Void = { [weak context] response in
            guard response == .alertFirstButtonReturn, let context, let collections = context.service(.collections) else { return }
            let vault = context.vault
            if create(named: field.stringValue, in: folder, collections: collections, workspace: context.workspace,
                      exists: { vault.exists($0) }) == nil { NSSound.beep() }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    /// Makes the folder and its `.base` and opens it; returns the folder, nil when it could not be written.
    @discardableResult
    static func create(
        named name: String, in folder: String, collections: CollectionService, workspace: (any Workspace)?,
        exists: (String) -> Bool
    ) -> String? {
        let parent = folder == VaultPath.inbox ? "" : folder
        let path = uniqueFolder(named: name, in: parent, exists: exists)
        guard (try? collections.create(folder: path)) != nil else { return nil }
        workspace?.open(.folder(path), placement: .replace)
        return path
    }

    /// `name` (or "Collection") in `parent`, numbered past the folders that already exist: "Ideas 2".
    nonisolated static func uniqueFolder(named name: String, in parent: String, exists: (String) -> Bool) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty || cleaned.hasPrefix(".") ? "Collection" : cleaned
        let prefix = parent.isEmpty ? "" : parent + "/"
        var candidate = prefix + base
        var number = 2
        while exists(candidate) {
            candidate = prefix + base + " \(number)"
            number += 1
        }
        return candidate
    }
}
