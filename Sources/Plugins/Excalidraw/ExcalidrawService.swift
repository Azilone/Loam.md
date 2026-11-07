import Foundation
import PluginKit

/// Drawings in the vault, for the plugin's own UI module (`ExcalidrawUI`), which may import this logic module.
/// Other plugins, the CLI and agents reach the same behaviour through the `excalidraw.*` commands.
public protocol ExcalidrawService: AnyObject, Sendable {
    /// Every drawing of the vault (`.excalidraw` files and flagged notes), sorted.
    func drawings() throws -> [String]
    /// Whether the file holds a drawing: a `.excalidraw` file, or a note flagged `excalidraw-plugin`. Cached until a
    /// vault change reaches the file, so views can ask it often.
    func isDrawing(_ path: String) -> Bool
    func read(_ path: String) throws -> ExcalidrawDocument
    /// Writes the drawing, unless the file already holds exactly this text. Writes to the vault.
    func write(_ path: String, _ document: ExcalidrawDocument) throws
    /// The scene for the editor as JSON, with the bytes of each image read from the vault into `files`.
    func scene(_ path: String) throws -> String
    /// Saves a scene from the editor (`serializeAsJSON`). In a note, an image not yet in the vault goes into the
    /// attachments folder and is listed in `## Embedded Files`. Writes to the vault.
    func save(_ path: String, scene: String) async throws
    /// Creates an empty drawing note, `<title>.excalidraw.md`, in `folder` (the inbox when empty), numbered if the
    /// name is taken, and returns its path. Writes to the vault.
    func create(in folder: String, title: String?) throws -> String
}

public extension ServiceKey where Service == ExcalidrawService {
    static var excalidraw: ServiceKey<ExcalidrawService> { ServiceKey<ExcalidrawService>("excalidraw") }
}

public enum ExcalidrawFile {
    /// What a new drawing's name ends with: `Plan.excalidraw.md`, as the Obsidian plugin names them.
    public static let suffix = ".excalidraw.md"

    /// The name to show: `Plan` for `Ideas/Plan.excalidraw.md` or `Plan.excalidraw`.
    public static func title(of path: String) -> String {
        var name = (path as NSString).lastPathComponent
        for ending in [suffix, ".excalidraw", ".md"] where name.lowercased().hasSuffix(ending) {
            name.removeLast(ending.count)
            break
        }
        return name
    }

    static let mimeTypes: [String: String] = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp",
        "svg": "image/svg+xml", "bmp": "image/bmp", "avif": "image/avif",
    ]

    static func mimeType(of path: String) -> String {
        mimeTypes[(path as NSString).pathExtension.lowercased()] ?? "application/octet-stream"
    }

    static func pathExtension(ofMimeType type: String) -> String {
        if type == "image/jpeg" { return "jpg" }
        return mimeTypes.first { $0.value == type }?.key ?? "png"
    }

    /// The bytes and type of a `data:` URL.
    static func decode(dataURL: String) -> (data: Data, mimeType: String)? {
        guard dataURL.hasPrefix("data:"), let comma = dataURL.firstIndex(of: ",") else { return nil }
        let meta = dataURL[dataURL.index(dataURL.startIndex, offsetBy: 5)..<comma]
        let parts = meta.split(separator: ";")
        let type = parts.first.map(String.init) ?? "application/octet-stream"
        let payload = String(dataURL[dataURL.index(after: comma)...])
        if parts.contains("base64") {
            guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) else { return nil }
            return (data, type)
        }
        return (Data((payload.removingPercentEncoding ?? payload).utf8), type)
    }
}

/// The standard `ExcalidrawService`, on a plugin's vault.
public final class ExcalidrawDrawings: ExcalidrawService, @unchecked Sendable {
    private let vault: VaultAccess
    private let attachments: () -> AttachmentsService?
    private let lock = NSLock()
    /// Whether each note is a drawing, since it last changed.
    private var flags: [String: Bool] = [:]
    /// Every file of the vault by name, for the links the Obsidian plugin writes as a bare name (`[[photo.png]]`).
    private var byName: [String: String]?

    public init(vault: VaultAccess, attachments: @escaping () -> AttachmentsService? = { nil }) {
        self.vault = vault
        self.attachments = attachments
    }

    /// Forgets what a vault change may have made stale.
    public func vaultChanged(_ changes: [VaultChange]) {
        lock.lock()
        defer { lock.unlock() }
        for change in changes { flags[change.path] = nil }
        if changes.contains(where: { $0.kind != .modified }) { byName = nil }
    }

    public func drawings() throws -> [String] {
        var found: [String] = []
        var folders = [""]
        while let folder = folders.popLast() {
            for entry in try vault.list(folder) {
                if entry.isFolder {
                    folders.append(entry.path)
                } else if isDrawing(entry.path) {
                    found.append(entry.path)
                }
            }
        }
        return found.sorted()
    }

    public func isDrawing(_ path: String) -> Bool {
        switch ExcalidrawDocument.format(of: path) {
        case .plain: return true
        case nil: return false
        case .markdown: break
        }
        // Known until the file changes (`vaultChanged`): the view registry asks for every note it shows, several
        // times per note opened, and a disk query each time cost more than the rest of the lookup.
        lock.lock()
        if let known = flags[path] {
            lock.unlock()
            return known
        }
        lock.unlock()
        let flagged = Self.head(of: vault.rootURL.appendingPathComponent(path)).map(ExcalidrawDocument.hasFlag) ?? false
        lock.lock()
        flags[path] = flagged
        lock.unlock()
        return flagged
    }

    /// The start of a file, enough for its frontmatter.
    private static func head(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public func read(_ path: String) throws -> ExcalidrawDocument {
        let path = try VaultPath.normalize(path)
        guard let format = ExcalidrawDocument.format(of: path) else {
            throw ExcalidrawError.invalid("\(path) is not a drawing.")
        }
        guard vault.exists(path) else { throw VaultError.notFound(path: path) }
        let text = try vault.read(path)
        if format == .markdown, !ExcalidrawDocument.hasFlag(text) {
            throw ExcalidrawError.invalid("\(path) is not a drawing (no `excalidraw-plugin` in its frontmatter).")
        }
        return try ExcalidrawDocument(text: text, format: format)
    }

    public func write(_ path: String, _ document: ExcalidrawDocument) throws {
        let path = try VaultPath.normalize(path)
        let text = document.text
        if vault.exists(path), (try? vault.read(path)) == text { return }
        try vault.write(path, text)
    }

    public func scene(_ path: String) throws -> String {
        let document = try read(path)
        var scene = document.scene
        if document.format == .markdown {
            var files: [String: Any] = [:]
            for file in document.embeddedFiles {
                guard let link = file.link, let found = resolve(link),
                      let data = try? Data(contentsOf: vault.rootURL.appendingPathComponent(found)) else { continue }
                let type = ExcalidrawFile.mimeType(of: found)
                files[file.id] = [
                    "id": file.id, "mimeType": type, "created": 0,
                    "dataURL": "data:\(type);base64,\(data.base64EncodedString())",
                ] as [String: Any]
            }
            scene["files"] = files
        }
        return ExcalidrawDocument.json(scene, pretty: false)
    }

    public func save(_ path: String, scene text: String) async throws {
        let path = try VaultPath.normalize(path)
        guard let format = ExcalidrawDocument.format(of: path) else {
            throw ExcalidrawError.invalid("\(path) is not a drawing.")
        }
        var document = vault.exists(path) ? try read(path) : ExcalidrawDocument(format: format)
        document.scene = try ExcalidrawDocument.object(text)
        if format == .markdown {
            let files = document.scene["files"] as? [String: Any] ?? [:]
            let known = Set(document.embeddedFiles.map(\.id))
            for id in document.imageFileIDs.sorted() where !known.contains(id) {
                guard let file = files[id] as? [String: Any], let url = file["dataURL"] as? String,
                      let (data, type) = ExcalidrawFile.decode(dataURL: url) else { continue }
                let name = "\(ExcalidrawFile.title(of: path)) \(id.prefix(8)).\(ExcalidrawFile.pathExtension(ofMimeType: type))"
                let stored = try await store(data, name: name, drawing: path)
                document.embeddedFiles.append(ExcalidrawEmbeddedFile(id: id, path: stored))
            }
        }
        try write(path, document)
    }

    /// Writes an image of a drawing into the attachments folder and returns its path.
    private func store(_ data: Data, name: String, drawing: String) async throws -> String {
        if let attachments = attachments() {
            return try await attachments.importFile(AttachmentImport(name: name, contents: .data(data), notePath: drawing)).path
        }
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var path = "Attachments/\(name)", number = 2
        while vault.exists(path) {
            path = "Attachments/\(base) \(number).\(ext)"
            number += 1
        }
        try vault.writeData(path, data)
        return path
    }

    public func create(in folder: String, title: String?) throws -> String {
        let folder = try VaultPath.normalize(folder.isEmpty ? VaultPath.inbox : folder)
        let name = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let base = name.isEmpty ? "Drawing" : name
        guard !base.contains("/"), !base.hasPrefix(".") else {
            throw ExcalidrawError.invalid("Invalid drawing name: \(base)")
        }
        var path = "\(folder)/\(base)\(ExcalidrawFile.suffix)"
        var number = 2
        while vault.exists(path) {
            path = "\(folder)/\(base) \(number)\(ExcalidrawFile.suffix)"
            number += 1
        }
        try vault.write(path, ExcalidrawDocument(format: .markdown).text)
        return path
    }

    /// The vault file a `[[link]]` of `## Embedded Files` names: a path from the vault's root, or a bare name.
    func resolve(_ link: String) -> String? {
        guard let path = try? VaultPath.normalize(link) else { return nil }
        if vault.exists(path) { return path }
        guard !path.contains("/") else { return nil }
        lock.lock()
        if let byName {
            lock.unlock()
            return byName[path]
        }
        lock.unlock()
        var names: [String: String] = [:]
        var folders = [""]
        while let folder = folders.popLast() {
            for entry in (try? vault.list(folder)) ?? [] {
                if entry.isFolder {
                    folders.append(entry.path)
                } else {
                    let name = (entry.path as NSString).lastPathComponent
                    if names[name] == nil { names[name] = entry.path }
                }
            }
        }
        lock.lock()
        byName = names
        lock.unlock()
        return names[path]
    }

    /// Points the images of every drawing note at the files' new paths. Returns the drawings that changed. A drawing
    /// that does not parse is left alone.
    @discardableResult
    public func follow(moves: [String: String]) -> [String] {
        guard !moves.isEmpty, let drawings = try? drawings() else { return [] }
        return drawings.filter { path in
            guard ExcalidrawDocument.format(of: path) == .markdown, var document = try? read(path) else { return false }
            var changed = false
            for index in document.embeddedFiles.indices {
                guard let link = document.embeddedFiles[index].link, let target = moves[link] else { continue }
                document.embeddedFiles[index].relink(to: target)
                changed = true
            }
            return changed && (try? write(path, document)) != nil
        }
    }
}
