import AppKit
import CanvasPlugin
import Foundation
import Observation
import PluginKit
import PluginKitUI

/// What a card shows of the file behind it: its title and, for a note, its first blocks.
struct CardFile: Equatable {
    enum Kind: Equatable { case note, board, image, pdf, audio, video, other }

    let path: String
    let kind: Kind
    let title: String
    let preview: NotePreview?
    let exists: Bool

    static func kind(of path: String) -> Kind {
        switch (path as NSString).pathExtension.lowercased() {
        case "md": return .note
        case CanvasFile.pathExtension: return .board
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "svg", "avif": return .image
        case "pdf": return .pdf
        case "mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac", "opus", "ogg", "oga": return .audio
        case "mp4", "m4v", "mov", "webm", "mkv", "avi", "3gp": return .video
        default: return .other
        }
    }

    /// The size of a new card for a file of this kind, in board units.
    static func defaultSize(of path: String, imageSize: CGSize?) -> (width: Double, height: Double) {
        switch kind(of: path) {
        case .note: return CanvasDocument.fileSize
        case .image:
            guard let imageSize, imageSize.width > 0, imageSize.height > 0 else { return (400, 300) }
            let width = min(max(imageSize.width, 240), 420)
            return (width.rounded(), (width * imageSize.height / imageSize.width).rounded())
        case .pdf: return (400, 520)
        case .audio: return (360, 150)
        case .video: return (480, 300)
        case .board: return (400, 300)
        case .other: return (280, 140)
        }
    }

    static func title(of path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return ["md", CanvasFile.pathExtension].contains((name as NSString).pathExtension.lowercased())
            ? (name as NSString).deletingPathExtension : name
    }
}

/// Shared by every board tab: the service, the previews of the notes on cards (read once, refreshed when a note
/// changes) and the open boards, which reload when their file changes outside them.
@MainActor
@Observable
final class BoardStore {
    /// The folders plugins own, so a new board never lands in one (set by the plugin).
    var managedFolders: @MainActor () -> ManagedFolders = { ManagedFolders() }
    /// New boards the user may leave untouched; set by the plugin.
    var drafts: UntouchedDrafts?
    let service: CanvasService
    /// The previews of the boards' links.
    let links = BoardLinkPreviews()
    @ObservationIgnored let vault: VaultAccess
    @ObservationIgnored let workspace: () -> (any Workspace)?
    @ObservationIgnored let quickPick: () -> (any QuickPick)?
    @ObservationIgnored let views: () -> (any ViewRegistry)?
    @ObservationIgnored let attachments: () -> (any AttachmentsService)?
    /// Bumped when a previewed note changes, so cards read their preview again.
    private(set) var previewVersion = 0
    @ObservationIgnored private var previews: [String: CardFile] = [:]
    @ObservationIgnored private var images: [String: NSImage] = [:]
    @ObservationIgnored private var markdown: [String: NotePreview] = [:]
    @ObservationIgnored var titles: [String: String] = [:]
    @ObservationIgnored var smalls: [String: SmallImage] = [:]
    @ObservationIgnored private var heights: [String: Double] = [:]
    @ObservationIgnored private var freeSizes: [String: (width: Double, height: Double)] = [:]
    @ObservationIgnored var tables: [String: BoardTableLayout?] = [:]
    @ObservationIgnored private var inks: [String: CanvasInk?] = [:]
    @ObservationIgnored private var embeds: [String: ViewType?] = [:]
    @ObservationIgnored private var thumbnails: [String: CanvasDocument?] = [:]
    @ObservationIgnored private var tabs: [WeakBoard] = []

    init(service: CanvasService, vault: VaultAccess, workspace: @escaping () -> (any Workspace)?,
         quickPick: @escaping () -> (any QuickPick)?, views: @escaping () -> (any ViewRegistry)? = { nil },
         attachments: @escaping () -> (any AttachmentsService)? = { nil }) {
        self.service = service
        self.attachments = attachments
        self.vault = vault
        self.workspace = workspace
        self.quickPick = quickPick
        self.views = views
    }

    func register(_ board: BoardModel) {
        tabs.removeAll { $0.board == nil }
        tabs.append(WeakBoard(board: board))
    }

    /// The model of a tab, made once per tab: SwiftUI may build the tab's view many times.
    func model(for view: ViewContext) -> BoardModel {
        if let known = boards.first(where: { $0.view === view }) { return known }
        return BoardModel(store: self, view: view)
    }

    private var boards: [BoardModel] { tabs.compactMap(\.board) }

    // MARK: - Files behind cards

    /// The vault path for a file dropped or pasted from outside: its own path when it is already in the vault, else
    /// a copy made in the attachments folder. Nil when it cannot be brought in.
    func bringIn(_ url: URL) async -> String? {
        let root = vault.rootURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
        guard let attachments = attachments() else { return nil }
        let imported = try? await attachments.importFile(
            AttachmentImport(name: url.lastPathComponent, contents: .file(url))
        )
        return imported?.path
    }

    /// The files directly in a folder of the vault, by name, hidden ones left out.
    func files(in folder: String) -> [String] {
        let prefix = folder.isEmpty ? "" : folder + "/"
        let stamps = (try? vault.stamps()) ?? [:]
        return stamps.keys.filter { path in
            path.hasPrefix(prefix) && !path.dropFirst(prefix.count).contains("/")
                && !(path as NSString).lastPathComponent.hasPrefix(".")
        }.sorted()
    }

    /// A picture pasted as data, saved in the attachments folder.
    func bringIn(imageData data: Data, pathExtension: String) async -> String? {
        guard let attachments = attachments() else { return nil }
        let name = "Pasted image " + Self.stamp.string(from: Date()) + "." + pathExtension
        return try? await attachments.importFile(AttachmentImport(name: name, contents: .data(data))).path
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    func file(_ path: String) -> CardFile {
        if let known = previews[path] { return known }
        let kind = CardFile.kind(of: path)
        let title = CardFile.title(of: path)
        let exists = vault.exists(path)
        var preview: NotePreview?
        if kind == .note, exists, let text = try? vault.read(path) {
            preview = NotePreview.parse(text, title: title, limit: 24)
        }
        let file = CardFile(path: path, kind: kind, title: title, preview: preview, exists: exists)
        previews[path] = file
        return file
    }

    /// The Markdown of a text card, parsed once.
    func preview(ofText text: String) -> NotePreview {
        if let known = markdown[text] { return known }
        if markdown.count > 600 { markdown.removeAll() }
        let parsed = NotePreview.parse(text, title: "", limit: 100_000)
        markdown[text] = parsed
        return parsed
    }

    /// How tall a text card's Markdown is at a font size and width, measured once.
    func textHeight(_ text: String, fontSize: Double, width: Double) -> Double {
        let key = "\(fontSize)|\(width)|" + text
        if let known = heights[key] { return known }
        if heights.count > 600 { heights.removeAll() }
        let height = BoardText.height(of: text, fontSize: fontSize, width: width)
        heights[key] = height
        return height
    }

    /// The drawing a card holds, relative to the card; read once per text.
    func ink(_ node: CanvasNode) -> CanvasInk? {
        guard node.kind == .text, let text = node.text, CanvasInk.isDrawing(text) else { return nil }
        if let known = inks[text] { return known }
        if inks.count > 400 { inks.removeAll() }
        let ink = CanvasInk(svg: text)
        inks[text] = .some(ink)
        return ink
    }

    /// The size of free text at a font size, measured once.
    func freeTextSize(_ text: String, fontSize: Double) -> (width: Double, height: Double) {
        let key = "\(fontSize)|" + text
        if let known = freeSizes[key] { return known }
        if freeSizes.count > 600 { freeSizes.removeAll() }
        let size = BoardText.freeSize(of: text, fontSize: fontSize)
        freeSizes[key] = size
        return size
    }

    /// An image file of the vault, read once.
    func image(_ path: String) -> NSImage? {
        if let known = images[path] { return known }
        let image = NSImage(contentsOf: vault.rootURL.appendingPathComponent(path))
        images[path] = image
        return image
    }

    /// The view a note is meant to be seen with when it is not the editor: the view type that prefers it (a
    /// mindmap note, a Kanban note). Its card shows that view, live. Nil for plain notes, which show a preview.
    func embeddedViewType(for path: String) -> ViewType? {
        if let known = embeds[path] { return known }
        let resource = Resource.file(path)
        var found: ViewType?
        if CardFile.kind(of: path) == .note, let first = views()?.viewTypes(for: resource).first,
           first.id != CanvasUIPlugin.viewTypeID, first.prefers(resource) {
            found = first
        }
        embeds[path] = .some(found)
        return found
    }

    /// The viewer that plays or shows a PDF, a video or a sound inside its card, if a plugin provides one.
    func mediaViewType(for path: String) -> ViewType? {
        guard CardFile.kind(of: path).isLiveMediaKind else { return nil }
        if let known = embeds[path] { return known }
        let found = views()?.viewTypes(for: Resource.file(path)).first
        embeds[path] = .some(found)
        return found
    }

    /// Writes a new mindmap note beside the board at `board`: the format the mindmap plugin reads (the Obsidian
    /// "Native Mindmap" plugin's: a flag in the frontmatter, the central topic as the title, topics as a nested list),
    /// named after the board. Returns its path.
    func createMindmap(near board: String, title: String) throws -> String {
        let folder = (board as NSString).deletingLastPathComponent
        let name = title + " mindmap"
        let base = folder.isEmpty ? name : folder + "/" + name
        var path = base + ".md"
        var number = 2
        while vault.exists(path) {
            path = "\(base) \(number).md"
            number += 1
        }
        try vault.write(path, "---\nmindmap-plugin: basic\n---\n\n# Central idea\n")
        embeds[path] = nil
        return path
    }

    /// The board a card shows, for its thumbnail; nil when it does not parse.
    func thumbnail(_ path: String) -> CanvasDocument? {
        if let known = thumbnails[path] { return known }
        let document = try? service.read(path)
        thumbnails[path] = .some(document)
        return document
    }

    // MARK: - Changes

    func fileChanged(_ path: String) {
        smalls.removeValue(forKey: path)
        let known = previews.removeValue(forKey: path) != nil || images.removeValue(forKey: path) != nil
        let shown = embeds.removeValue(forKey: path) != nil || thumbnails.removeValue(forKey: path) != nil
        if known || shown { previewVersion += 1 }
        if CanvasFile.isBoard(path) {
            for board in boards where board.path == path { board.reloadFromDisk() }
        }
    }

    func filesMoved(_ moves: [String: String]) {
        for path in moves.keys {
            previews.removeValue(forKey: path)
            embeds.removeValue(forKey: path)
            thumbnails.removeValue(forKey: path)
        }
        previewVersion += 1
        // The logic plugin rewrote the boards showing the moved files; open ones read them again.
        for board in boards { board.reloadFromDisk() }
    }

    // MARK: - Boards

    @discardableResult
    func createBoard(in folder: String, title: String? = nil) throws -> String {
        let path = try service.create(in: folder, title: title)
        if let template = try? vault.read(path) { drafts?.remember(path, template: template) }
        workspace()?.open(.file(path), placement: .replace)
        return path
    }

    /// The folder of the active file, for a new board; empty (the inbox) when none.
    func activeFolder() -> String {
        guard let active = workspace()?.activeResource, active.kind == .file else { return "" }
        return (active.path as NSString).deletingLastPathComponent
    }

    func open(_ path: String, placement: Placement) {
        workspace()?.open(.file(path), placement: placement)
    }

    /// The notes of the vault, for "Add note" (a popup like Cmd+O).
    func notes() -> [String] { (try? vault.markdownPaths()) ?? [] }

    private struct WeakBoard {
        weak var board: BoardModel?
    }
}

extension CardFile.Kind {
    var isLiveMediaKind: Bool { self == .pdf || self == .audio || self == .video }
}

/// A picture's small copy, or the fact that it has none.
struct SmallImage {
    let image: NSImage?
}
