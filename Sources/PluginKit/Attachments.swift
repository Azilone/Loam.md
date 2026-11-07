import Foundation

/// What a file attached to a note is, from its extension: how its link is written and how the editor shows it.
public enum AttachmentKind: String, Codable, Sendable, CaseIterable {
    case image, audio, video, pdf, file

    public init(pathExtension: String) {
        switch pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp": self = .image
        case "mp3", "m4a", "wav", "aac", "flac", "aif", "aiff", "caf": self = .audio
        case "mp4", "mov", "m4v": self = .video
        case "pdf": self = .pdf
        default: self = .file
        }
    }

    /// The kind of the file at `path`, from its extension.
    public init(path: String) {
        self.init(pathExtension: (path as NSString).pathExtension)
    }

    /// Whether its link is an image link, `![](…)`, which Markdown viewers and the editor show in place; other files
    /// get a plain link, `[report.zip](…)`.
    public var isMedia: Bool { self != .file }
}

/// The bytes of a file being imported: in memory (a pasted screenshot), or in a file outside the vault (a dropped
/// file, a processor's output in a temporary folder), read only when it is written.
public enum AttachmentContents: Sendable, Equatable {
    case data(Data)
    case file(URL)

    /// The bytes; a file's are mapped rather than read when the system allows it.
    public func data() throws -> Data {
        switch self {
        case .data(let data): data
        case .file(let url): try Data(contentsOf: url, options: .mappedIfSafe)
        }
    }
}

/// A file on its way into the attachments folder. Each `AttachmentProcessor` receives it and returns it, changed or
/// not, before it is written.
public struct AttachmentImport: Sendable, Equatable {
    /// The file name it is written under, extension included (`IMG_0042.heic`); the service makes it free in the
    /// folder (`IMG_0042 2.heic`). A processor that converts the file changes the extension too (`IMG_0042.jpg`).
    public var name: String
    public var contents: AttachmentContents
    /// The note its link goes into, vault-relative; nil when imported without a note (links are then written from
    /// the vault's root).
    public var notePath: String?

    public init(name: String, contents: AttachmentContents, notePath: String? = nil) {
        self.name = name
        self.contents = contents
        self.notePath = notePath
    }

    public var kind: AttachmentKind { AttachmentKind(path: name) }
}

/// Changes files before they are written into the vault, such as a compressor that turns a HEIC photo into a
/// smaller JPEG. The service runs every processor on every import whose kind it handles, in the order they were
/// added, each on the previous one's output.
public struct AttachmentProcessor: Identifiable, Sendable {
    /// Dotted and owned by the plugin, such as `compress.images`.
    public let id: String
    /// The kinds it handles, by the name's extension when it reaches it; empty for every file.
    public let kinds: Set<AttachmentKind>
    /// The file to write: `file` unchanged, or new contents, name or both. One that throws is skipped: the file goes
    /// on as it came to it, so a broken processor never loses what the user dropped.
    public let process: @Sendable (AttachmentImport) async throws -> AttachmentImport

    public init(
        id: String,
        kinds: Set<AttachmentKind> = [],
        process: @escaping @Sendable (AttachmentImport) async throws -> AttachmentImport
    ) {
        self.id = id
        self.kinds = kinds
        self.process = process
    }
}

/// A file written into the attachments folder.
public struct ImportedAttachment: Codable, Sendable, Equatable {
    /// Vault-relative (`assets/photo.png`).
    public let path: String
    public let kind: AttachmentKind
    /// The Markdown linking it from the note it was imported for: `![](../assets/photo.png)`, or
    /// `[report.zip](../assets/report.zip)` for a file that is not media.
    public let markdown: String

    public init(path: String, kind: AttachmentKind, markdown: String) {
        self.path = path
        self.kind = kind
        self.markdown = markdown
    }
}

/// What `AttachmentsService.replace` did.
public struct AttachmentReplacement: Codable, Sendable, Equatable {
    /// Where the new file is: the old path, or a new one when the name changed.
    public let path: String
    /// Where the old file went, in `.trash/`.
    public let trashed: String
    /// The notes whose links were rewritten, sorted.
    public let updated: [String]

    public init(path: String, trashed: String, updated: [String]) {
        self.path = path
        self.trashed = trashed
        self.updated = updated
    }
}

/// The `attachments` service, provided by the Attachments plugin: the one folder at the vault's root (`Attachments` by
/// default) that receives every file dropped or pasted into a note, unsorted, linked from the note with plain
/// Markdown. Other plugins change files on their way in (`addProcessor`) or later (`replace`).
public protocol AttachmentsService: AnyObject, Sendable {
    /// The folder, vault-relative, from the plugin's settings.
    var folder: String { get }
    /// Runs the processors, writes the file into `folder` under a free name, and returns where it went with the link
    /// to write in `file.notePath`. Sends `AttachmentImported`.
    func importFile(_ file: AttachmentImport) async throws -> ImportedAttachment
    /// The Markdown linking the file at `path`, written from the vault's root (`assets/photo.png`, each part
    /// percent-encoded) so the link survives the note moving. `notePath` is the note it goes into, for a service
    /// that would write it differently.
    func markdownLink(to path: String, from notePath: String?) -> String
    /// Adds a processor for the next imports; the returned function removes it.
    func addProcessor(_ processor: AttachmentProcessor) -> @Sendable () -> Void
    /// Puts new contents in place of the attachment at `path`, as a compressor that runs after the import does: the
    /// old file goes to `.trash/`, recoverable. When `name` gives another file name (a new extension), the file
    /// moves and every link to it is rewritten (with the note graph on). Sends `AttachmentReplaced`.
    func replace(_ path: String, with contents: AttachmentContents, name: String?) async throws -> AttachmentReplacement
}

public extension ServiceKey where Service == AttachmentsService {
    static var attachments: ServiceKey<AttachmentsService> { ServiceKey<AttachmentsService>("attachments") }
}

public extension PluginContext {
    /// Adds a processor to the `attachments` service, removed when the plugin unloads. Does nothing without the
    /// service: list `attachments` in `optionalRequires`.
    func addAttachmentProcessor(_ processor: AttachmentProcessor) {
        guard let attachments = service(.attachments) else { return }
        let remove = attachments.addProcessor(processor)
        effect { remove() }
    }
}

/// Sent on the main thread after a file was written into the attachments folder, so a plugin can work on it later
/// (compress a video, then `replace` it).
public struct AttachmentImported: PluginEvent, Sendable, Equatable {
    public let path: String
    public let kind: AttachmentKind
    /// The note it was imported for, if any.
    public let notePath: String?

    public init(path: String, kind: AttachmentKind, notePath: String?) {
        self.path = path
        self.kind = kind
        self.notePath = notePath
    }
}

/// Sent on the main thread after `AttachmentsService.replace` put new contents in place of an attachment.
public struct AttachmentReplaced: PluginEvent, Sendable, Equatable {
    public let oldPath: String
    public let newPath: String

    public init(oldPath: String, newPath: String) {
        self.oldPath = oldPath
        self.newPath = newPath
    }
}

/// Asked, as a waterfall, by a file browser before it lists the vault: a plugin that keeps a folder out of sight
/// adds it (the Attachments plugin its folder, when its settings say so). The files stay on disk, in links and in
/// every other listing (`VaultAccess.list`, `files.tree`).
public struct HiddenFolders: PluginEvent, Sendable, Equatable {
    /// Vault-relative folder paths.
    public var paths: Set<String>

    public init(paths: Set<String> = []) {
        self.paths = paths
    }
}

/// Sent when the answer to `HiddenFolders` changed, so a file browser lists the vault again.
public struct HiddenFoldersChanged: PluginEvent, Sendable, Equatable {
    public init() {}
}
