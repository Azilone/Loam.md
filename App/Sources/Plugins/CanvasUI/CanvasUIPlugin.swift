import FileExplorerPlugin
import CanvasPlugin
import Foundation
import PluginKitUI
import SwiftUI

/// Boards in the app: a `.canvas` file opens as an infinite whiteboard of cards (notes, text, links, groups) joined
/// by arrows. Cards are moved, resized, connected and grouped with the mouse and the keyboard; every edit goes
/// through the `canvas` service of the logic plugin, so the CLI and agents do the same with the `canvas.*` commands.
public final class CanvasUIPlugin: UIPlugin {
    public static let manifest = PluginManifest(
        id: "canvas-ui",
        name: "Boards",
        version: "0.1.0",
        description: "Opens boards on an infinite canvas you can draw on.",
        icon: "rectangle.3.group",
        requires: ["canvas"],
        optionalRequires: ["attachments", "files"],
        permissions: ["ui", "vault.read", "vault.write"]
    )

    static let viewTypeID = "canvas.board"
    static let symbol = "rectangle.on.rectangle.angled"
    /// Internal: lets the tests reach the shared store. Not a contract.
    static var storeKey: ServiceKey<BoardStore> { ServiceKey("canvas-ui.store") }

    public init() {}

    @MainActor public func activateUI(context: PluginContext) throws {
        guard let service = context.service(.canvas) else { throw CanvasUIError.serviceMissing }
        let store = BoardStore(
            service: service,
            vault: context.vault,
            workspace: { [weak context] in context?.workspace },
            quickPick: { [weak context] in context?.quickPick },
            views: { [weak context] in context?.service(.views) },
            attachments: { [weak context] in context?.service(.attachments) }
        )
        try context.provide(Self.storeKey, store)
        store.managedFolders = { [weak context] in context?.waterfall(ManagedFolders()) ?? ManagedFolders() }
        // A new one left untouched goes to Recently Deleted once the focus moves away.
        let vault = context.vault
        let drafts = UntouchedDrafts(read: { try? vault.read($0) }, discard: { [weak context] path in
            _ = try? context?.service(.files)?.trash(path)
        })
        store.drafts = drafts
        context.on(ActiveResourceChanged.self) { event in
            onMainThread { drafts.focusMoved(to: event.resource) }
        }
        context.on(NotesMoved.self) { event in
            onMainThread { drafts.moved(event.moves) }
        }

        try context.registerView(ViewType(
            id: Self.viewTypeID,
            title: "Board",
            symbol: Self.symbol,
            canOpen: { $0.kind == .file && $0.pathExtension == CanvasFile.pathExtension },
            makeView: { view in AnyView(BoardTab(store: store, view: view)) }
        ))
        try context.addNewItem(NewItem(
            id: "canvas.new-board", title: "New Board", symbol: Self.symbol, order: 20, viewType: Self.viewTypeID
        ) { folder in
            _ = try? store.createBoard(in: folder)
        })
        try context.addSidebarLink(SidebarLink(
            id: "canvas.link", title: "Boards", symbol: Self.symbol,
            resource: .notes(titled: "Boards", openedBy: Self.viewTypeID), order: 31
        ))

        try context.registerCommand(Command(
            id: "canvas.new-board",
            title: "New board",
            summary: "Creates an empty board (a `.canvas` file) and opens it. Optional: folder (default: the active "
                + "note's folder, else Inbox; Inbox too when that folder belongs to a plugin), title. Writes a new "
                + "file; returns its path."
        ) { args in
            try await MainActor.run {
                let folder = args["folder"] ?? store.managedFolders().newItemFolder(from: store.activeFolder())
                return try store.createBoard(in: folder, title: args["title"].flatMap { $0.isEmpty ? nil : $0 })
            }
        })

        try context.registerCommand(Command(
            id: "canvas.export",
            title: "Export board",
            summary: "Draws a board as a PNG picture or a PDF and writes it to the vault. Arguments: path (the board); "
                + "optional format (png, the default, or pdf), slides=true (a PDF page per frame, in presentation "
                + "order), out (a vault path; default: beside the board). Returns the file's path.",
            isInPalette: false
        ) { args in
            try await MainActor.run {
                let path = try args.require("path")
                let format = BoardExport.Format(rawValue: args["format"] ?? "png") ?? .png
                let slides = args["slides"] == "true"
                let model = store.model(for: ViewContext(resource: .file(path)))
                let rects = slides ? BoardExport.slides(of: model) : BoardExport.area(of: model).map { [$0] } ?? []
                guard !rects.isEmpty else { throw CanvasUIError.nothingToExport }
                let data = slides || format == .pdf
                    ? BoardExport.pdf(model, rects, theme: .standard, scheme: .light)
                    : BoardExport.png(model, rects[0], theme: .standard, scheme: .light)
                guard let data else { throw CanvasUIError.nothingToExport }
                let out = args["out"].flatMap { $0.isEmpty ? nil : $0 }
                    ?? (path as NSString).deletingPathExtension + (slides ? " slides" : "") + "." + (slides ? "pdf" : format.rawValue)
                try store.vault.writeData(out, data)
                return out
            }
        })

        context.on(NoteDidChange.self) { [weak store] event in
            onMainThread { store?.fileChanged(event.path) }
        }
        context.on(VaultChanged.self) { [weak store] event in
            onMainThread { for change in event.changes { store?.fileChanged(change.path) } }
        }
        context.on(NotesMoved.self) { [weak store] event in
            onMainThread { store?.filesMoved(event.moves) }
        }
    }
}

enum CanvasUIError: Error, Equatable {
    /// The host activates this plugin after `canvas` (it is in `requires`), so this means a broken host.
    case serviceMissing
    /// The board has no cards (or no frames, for slides).
    case nothingToExport
}

/// Runs main-actor code from an event listener, which Swift cannot prove runs on the main thread.
func onMainThread(_ body: @MainActor @Sendable () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated { body() }
    } else {
        DispatchQueue.main.sync { MainActor.assumeIsolated { body() } }
    }
}
