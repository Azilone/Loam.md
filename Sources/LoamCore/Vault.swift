import Foundation
import PluginKit

/// A vault is a plain folder of `.md` files, plus whatever other files plugins and the user keep there (images,
/// `.canvas` boards). Hidden files and folders
/// (`.loam`, `.git`, `.trash`) are skipped when listing, but can be read and written by path.
/// Symbolic links are not checked: a link inside the vault can point outside it.
public struct Vault: VaultAccess {
    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    public func markdownPaths() throws -> [String] {
        try files(keys: []).filter { $0.path.lowercased().hasSuffix(".md") }.map(\.path).sorted()
    }

    /// One walk of the vault with each file's date and size fetched by the walk itself: asking each file for its
    /// attributes afterwards made 600 notes take 75 ms, which the kernel and every listener of a vault change paid.
    public func stamps() throws -> [String: FileStamp] {
        var stamps: [String: FileStamp] = [:]
        for (path, url) in try files(keys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]) {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
            // Folders are walked, not stamped: a folder's date changes with its content, which its files report.
            guard values.isRegularFile ?? true else { continue }
            stamps[path] = FileStamp(
                modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
                size: values.fileSize ?? 0
            )
        }
        return stamps
    }

    /// The files and folders under the root, outside hidden folders, with their vault-relative paths.
    private func files(keys: [URLResourceKey]) throws -> [(path: String, url: URL)] {
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let rootPath = rootURL.standardizedFileURL.path
        // The walk's URLs start with the root as the walk sees it (`/var` resolved to `/private/var`, say): the
        // folder of the first one. Cutting that prefix spares standardizing each URL, which checks the file on disk.
        var walkedRoot: String?
        var files: [(path: String, url: URL)] = []
        for case let url as URL in enumerator {
            let walked = walkedRoot ?? url.deletingLastPathComponent().path + "/"
            walkedRoot = walked
            let full = url.path
            if full.hasPrefix(walked) {
                files.append((String(full.dropFirst(walked.count)), url))
            } else {
                let standardized = url.standardizedFileURL.path
                guard standardized.hasPrefix(rootPath + "/") else { continue }
                files.append((String(standardized.dropFirst(rootPath.count + 1)), url))
            }
        }
        return files
    }

    public func exists(_ path: String) -> Bool {
        guard let url = try? url(for: path) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    public func read(_ path: String) throws -> String {
        let url = try url(for: path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw VaultError.notFound(path: path) }
        return try String(contentsOf: url, encoding: .utf8)
    }

    public func write(_ path: String, _ contents: String) throws {
        let url = try url(for: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    public func writeData(_ path: String, _ data: Data) throws {
        let url = try url(for: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    public func move(_ from: String, to: String) throws {
        let source = try url(for: from)
        let destination = try url(for: to)
        guard FileManager.default.fileExists(atPath: source.path) else { throw VaultError.notFound(path: from) }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw VaultError.alreadyExists(path: to)
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: source, to: destination)
    }

    public func list(_ folder: String) throws -> [VaultEntry] {
        let normalized = try VaultPath.normalize(folder)
        let url = normalized.isEmpty ? rootURL : try url(for: normalized)
        guard isFolder(url) else { throw VaultError.notFound(path: folder) }
        // Hidden names are filtered by hand: `.skipsHiddenFiles` is not honoured everywhere on Linux. Whether each
        // entry is a folder comes with the listing: asking each one afterwards made the file explorer's tree of a
        // large vault take tens of milliseconds after every save.
        let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])
        let entries = children.compactMap { child -> VaultEntry? in
            let name = child.lastPathComponent
            guard !name.hasPrefix(".") else { return nil }
            let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? nil
            return VaultEntry(
                path: normalized.isEmpty ? name : normalized + "/" + name,
                isFolder: isDirectory ?? isFolder(child)
            )
        }
        // Folders first, then ignoring case; the lowercased keys are made once rather than in each comparison.
        return entries.map { (key: $0.path.lowercased(), entry: $0) }.sorted { a, b in
            if a.entry.isFolder != b.entry.isFolder { return a.entry.isFolder }
            return a.key == b.key ? a.entry.path < b.entry.path : a.key < b.key
        }.map(\.entry)
    }

    public func createFolder(_ path: String) throws {
        let url = try url(for: path)
        if FileManager.default.fileExists(atPath: url.path), !isFolder(url) {
            throw VaultError.alreadyExists(path: path)
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    @discardableResult
    public func removeIfEmpty(_ path: String) throws -> Bool {
        let url = try url(for: path)
        guard !isFolder(url), FileManager.default.fileExists(atPath: url.path),
              let text = try? String(contentsOf: url, encoding: .utf8), NoteContent.isEmpty(text) else { return false }
        try FileManager.default.removeItem(at: url)
        return true
    }

    private func isFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func url(for path: String) throws -> URL {
        let normalized = try VaultPath.normalize(path)
        guard !normalized.isEmpty else { throw VaultError.outsideVault(path: path) }
        let url = rootURL.appendingPathComponent(normalized)
        guard leadsInside(normalized) else { throw VaultError.outsideVault(path: path) }
        return url
    }

    /// Whether `relative`, its symbolic links followed, stays in the vault: a link inside it never leads a read or a
    /// write out. Each part is checked without following it (one `lstat` each, cheap for a walk of the whole vault);
    /// only a part that is a link, even a broken one, is resolved.
    private func leadsInside(_ relative: String) -> Bool {
        var path = rootURL.path
        for part in relative.split(separator: "/") {
            path += "/" + part
            var info = stat()
            // What does not exist yet holds no link.
            guard lstat(path, &info) == 0 else { return true }
            if info.st_mode & S_IFMT == S_IFLNK { return linkLeadsInside(URL(fileURLWithPath: rootURL.path + "/" + relative)) }
        }
        return true
    }

    /// The slow check, once a link is on the way: the closest existing part, resolved, and where a broken link points.
    private func linkLeadsInside(_ url: URL) -> Bool {
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath().path
        func inside(_ path: String) -> Bool { path == root || path.hasPrefix(root + "/") }
        var existing = url.standardizedFileURL
        while (try? FileManager.default.attributesOfItem(atPath: existing.path)) == nil, existing.pathComponents.count > 1 {
            existing.deleteLastPathComponent()
        }
        guard inside(existing.resolvingSymlinksInPath().path) else { return false }
        // A broken link resolves to itself: where it points to must stay inside too.
        if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: existing.path) {
            return inside(URL(fileURLWithPath: target, relativeTo: existing.deletingLastPathComponent()).standardizedFileURL.path)
        }
        return true
    }
}
