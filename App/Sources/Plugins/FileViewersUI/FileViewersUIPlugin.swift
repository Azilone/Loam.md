import Foundation
import PluginKitUI
import SwiftUI

/// Files that are not notes, shown in Loam: pictures (zoom, fit), PDFs (scroll, search), videos and sounds (the
/// system's player) and, for every other type, a Quick Look preview with the file's name, size and a way to open it
/// in its own app or reveal it in Finder. Each is a view type; a plugin owning a file type (a `.canvas` board)
/// registers its own with a higher priority and wins.
public final class FileViewersUIPlugin: UIPlugin {
    public static let manifest = PluginManifest(
        id: "file-viewers-ui",
        name: "File viewers",
        version: "0.1.0",
        description: "Opens pictures, PDFs, videos, sounds and any other file in Loam.",
        icon: "photo.on.rectangle.angled",
        permissions: ["ui", "vault.read"]
    )

    static let imageID = "files.image"
    static let pdfID = "files.pdf"
    static let mediaID = "files.media"
    static let previewID = "files.preview"

    public init() {}

    @MainActor public func activateUI(context: PluginContext) throws {
        let root = context.vault.rootURL
        func location(_ view: ViewContext) -> FileLocation? { FileLocation(resource: view.resource, root: root) }
        func opens(_ extensions: Set<String>) -> @MainActor (Resource) -> Bool {
            { $0.kind == .file && extensions.contains($0.pathExtension) }
        }

        try context.registerView(ViewType(
            id: Self.imageID, title: "Image", priority: 10, symbol: "photo", keepsExtension: true,
            canOpen: opens(FileKinds.images),
            makeView: { view in AnyView(ImageViewer(view: view, file: location(view)).environment(\.viewerIsEmbedded, view.presentation == .embedded)) }
        ))
        try context.registerView(ViewType(
            id: Self.pdfID, title: "PDF", priority: 10, symbol: "doc.richtext", keepsExtension: true,
            canOpen: opens(FileKinds.pdf),
            makeView: { view in AnyView(PDFViewer(view: view, file: location(view)).environment(\.viewerIsEmbedded, view.presentation == .embedded)) }
        ))
        try context.registerView(ViewType(
            id: Self.mediaID, title: "Player", priority: 10, symbol: "play.rectangle", keepsExtension: true,
            canOpen: opens(FileKinds.media),
            makeView: { view in AnyView(MediaViewer(view: view, file: location(view)).environment(\.viewerIsEmbedded, view.presentation == .embedded)) }
        ))
        // The catch-all: below every other type, so a plugin's own viewer (or the editor) is chosen first, and it
        // stays in "Open with" as the system's preview.
        try context.registerView(ViewType(
            id: Self.previewID, title: "Quick Look", priority: -1000, symbol: "doc", keepsExtension: true,
            canOpen: { $0.kind == .file && !FileKinds.notes.contains($0.pathExtension) },
            makeView: { view in AnyView(QuickLookViewer(view: view, file: location(view)).environment(\.viewerIsEmbedded, view.presentation == .embedded)) }
        ))
    }
}
