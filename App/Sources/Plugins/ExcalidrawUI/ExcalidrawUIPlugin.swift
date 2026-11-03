import ExcalidrawPlugin
import Foundation
import PluginKitUI
import SwiftUI

/// Drawings in the app: a `.excalidraw.md` note (flagged `excalidraw-plugin`) or a `.excalidraw` file opens in
/// Excalidraw, the hand-drawn whiteboard, which runs offline in a web view. Every change is saved through the
/// `excalidraw` service of the logic plugin, images as files of the vault. A drawing on a board, or linked alone on its
/// line in a note (`![](Plan.excalidraw.md)`), shows as its picture.
public final class ExcalidrawUIPlugin: UIPlugin {
    public static let manifest = PluginManifest(
        id: "excalidraw-ui",
        name: "Drawings",
        version: "0.1.0",
        description: "Opens Excalidraw drawings: shapes, arrows, a pen, text and images, drawn by hand.",
        icon: "scribble.variable",
        requires: ["excalidraw"],
        optionalRequires: ["editor"],
        // `network`: libraries added from libraries.excalidraw.com are downloaded from there.
        permissions: ["ui", "vault.read", "vault.write", "network"]
    )

    static let viewTypeID = "excalidraw.drawing"
    static let symbol = "scribble.variable"
    /// Internal: lets the tests reach the shared store. Not a contract.
    static var storeKey: ServiceKey<ExcalidrawStore> { ServiceKey("excalidraw-ui.store") }

    public init() {}

    @MainActor public func activateUI(context: PluginContext) throws {
        guard let service = context.service(.excalidraw) else { throw ExcalidrawUIError.serviceMissing }
        let store = ExcalidrawStore(service: service, vault: context.vault,
                                    workspace: { [weak context] in context?.workspace })
        try context.provide(Self.storeKey, store)

        try context.registerView(ViewType(
            id: Self.viewTypeID,
            title: "Drawing",
            symbol: Self.symbol,
            canOpen: { $0.kind == .file && service.isDrawing($0.path) },
            prefers: { $0.kind == .file && $0.pathExtension == "md" && service.isDrawing($0.path) },
            makeView: { view in AnyView(DrawingTab(store: store, view: view)) }
        ))
        try context.addNewItem(NewItem(
            id: "excalidraw.new-drawing", title: "New Drawing", symbol: Self.symbol, order: 30, viewType: Self.viewTypeID
        ) { folder in
            _ = try? store.createDrawing(in: folder)
        })
        try context.addSidebarLink(SidebarLink(
            id: "excalidraw.link", title: "Drawings", symbol: Self.symbol,
            resource: .notes(titled: "Drawings", openedBy: Self.viewTypeID), order: 32
        ))

        try context.registerCommand(Command(
            id: "excalidraw.new-drawing",
            title: "New drawing",
            summary: "Creates an empty Excalidraw drawing (`<title>.excalidraw.md`) and opens it. Optional: folder "
                + "(default: the active note's folder, else Inbox), title. Writes a new file; returns its path."
        ) { args in
            try await MainActor.run {
                let folder = args["folder"] ?? store.activeFolder()
                return try store.createDrawing(in: folder, title: args["title"].flatMap { $0.isEmpty ? nil : $0 })
            }
        })

        context.addEmbedRenderer(EmbedRenderer(id: "excalidraw.embed", extensions: ["md", "excalidraw"]) { request in
            guard service.isDrawing(request.path),
                  let picture = await store.previews.picture(of: request.path, dark: false) else { return nil }
            return RenderedEmbed(size: picture.size, isInteractive: false) {
                AnyView(DrawingPreview(store: store, path: request.path))
            }
        })

        context.on(NoteDidChange.self) { [weak store] event in
            onMainThread { store?.fileChanged(event.path) }
        }
        context.on(NotesMoved.self) { [weak store] event in
            let moves = event.moves
            onMainThread { store?.moved(moves) }
        }
        context.on(VaultChanged.self) { [weak store] event in
            onMainThread { for change in event.changes { store?.fileChanged(change.path) } }
        }
        context.effect { MainActor.assumeIsolated { store.close() } }
    }
}

enum ExcalidrawUIError: Error, Equatable {
    /// The host activates this plugin after `excalidraw` (it is in `requires`), so this means a broken host.
    case serviceMissing
}

/// Runs main-actor code from an event listener, which Swift cannot prove runs on the main thread.
func onMainThread(_ body: @MainActor @Sendable () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated { body() }
    } else {
        DispatchQueue.main.sync { MainActor.assumeIsolated { body() } }
    }
}
