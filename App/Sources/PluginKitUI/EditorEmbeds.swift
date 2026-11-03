import CoreGraphics
import Foundation
import SwiftUI

/// Files dropped on a note (from Finder, another app) or pasted into it (a copied screenshot), for a plugin to store
/// and link. The editor inserts what the plugin returns where they were dropped, or at the caret for a paste.
public struct DroppedFiles: Sendable, Equatable {
    public enum Item: Sendable, Equatable {
        /// A file on disk, outside the vault or in it.
        case file(URL)
        /// Bytes and the extension of their format (`png`), such as an image copied to the clipboard.
        case data(Data, pathExtension: String)
    }

    public let items: [Item]
    /// The note they went into, vault-relative.
    public let notePath: String

    public init(items: [Item], notePath: String) {
        self.items = items
        self.notePath = notePath
    }
}

/// What a plugin does with files dropped or pasted into a note (the Attachments plugin copies them into the vault).
public struct FileDropHandler: Identifiable, Sendable {
    /// Dotted and owned by the plugin, such as `attachments.import`.
    public let id: String
    /// The Markdown to insert for the files, one block per line; nil leaves them to the next handler. With no handler
    /// taking them, the editor inserts nothing for files and pastes text as usual.
    public let handle: @MainActor @Sendable (DroppedFiles) async -> String?

    public init(id: String, handle: @escaping @MainActor @Sendable (DroppedFiles) async -> String?) {
        self.id = id
        self.handle = handle
    }
}

/// Shows image links alone on their line (`![](../assets/clip.mp4)`) as what they point to: a picture, a player, a
/// preview. The note keeps the link: the editor shows the embed in place of the line, and the line again (the embed
/// under it) while the caret is on it. A link whose file is missing, or that no renderer shows, stays text.
public struct EmbedRenderer: Identifiable, Sendable {
    /// Dotted and owned by the plugin, such as `attachments.video`.
    public let id: String
    /// The file extensions it shows, lowercased, without the dot (`mp4`).
    public let extensions: [String]
    /// The embed of a file; nil when it cannot be shown (not really a video), and the link stays text. Called again
    /// only when the file changes on disk.
    public let render: @MainActor @Sendable (EmbedRequest) async -> RenderedEmbed?

    public init(
        id: String,
        extensions: [String],
        render: @escaping @MainActor @Sendable (EmbedRequest) async -> RenderedEmbed?
    ) {
        self.id = id
        self.extensions = extensions.map { $0.lowercased() }
        self.render = render
    }
}

/// One link to show, with the file it points to inside the vault.
public struct EmbedRequest: Hashable, Sendable {
    /// The destination as written in the note (`../assets/My%20clip.mp4`).
    public var destination: String
    /// The link's text, `![this](...)`: a caption, often empty.
    public var alt: String
    /// The file, vault-relative, and on disk; it exists when asked.
    public var path: String
    public var file: URL
    /// The note holding the link.
    public var notePath: String

    public init(destination: String, alt: String, path: String, file: URL, notePath: String) {
        self.destination = destination
        self.alt = alt
        self.path = path
        self.file = file
        self.notePath = notePath
    }
}

/// An embed: a picture the editor draws, or a live view it hosts (a player, an animated picture).
public struct RenderedEmbed: @unchecked Sendable {
    public enum Content {
        /// Drawn by the editor: cheap, for still pictures.
        case image(CGImage)
        /// Hosted by the editor while its line exists in the note, kept across edits (a playing video keeps playing).
        case view(@MainActor () -> AnyView)
    }

    public let content: Content
    /// The size it is shown at, in points, when the column has room; the editor scales it down to the column, keeping
    /// its ratio, unless `keepsHeight`.
    public let size: CGSize
    /// Takes the column's width (up to `size.width`) at `size.height` instead of scaling: a player bar, a card.
    public let keepsHeight: Bool
    /// Whether clicks go to the view (a player's controls). Otherwise a click puts the caret on the link's line, and
    /// a double click opens the file, as on a picture.
    public let isInteractive: Bool

    public init(image: CGImage, size: CGSize) {
        content = .image(image)
        self.size = size
        keepsHeight = false
        isInteractive = false
    }

    public init(size: CGSize, keepsHeight: Bool = false, isInteractive: Bool = true, view: @escaping @MainActor () -> AnyView) {
        content = .view(view)
        self.size = size
        self.keepsHeight = keepsHeight
        self.isInteractive = isInteractive
    }
}
