import Foundation
import PluginKit

/// Boards in the vault, for the canvas plugin's own UI module (`CanvasUI`), which may import this logic module.
/// Other plugins, the CLI and agents reach the same behaviour through the `canvas.*` commands.
public protocol CanvasService: NoteBoardsService {
    /// Every `.canvas` file in the vault, sorted.
    func boards() throws -> [String]
    func read(_ path: String) throws -> CanvasDocument
    /// Writes the board, unless the file already holds exactly this text. Writes to the vault.
    func write(_ path: String, _ document: CanvasDocument) throws
    /// Reads a board, applies `change` and writes it back if it changed. Writes to the vault.
    func update<T>(_ path: String, _ change: (inout CanvasDocument) throws -> T) throws -> T
    /// Creates an empty board in `folder` (the inbox when empty) named `title` (or "Board"), numbered if the name
    /// is taken, and returns its path. Writes to the vault.
    func create(in folder: String, title: String?) throws -> String
}

public extension ServiceKey where Service == CanvasService {
    static var canvas: ServiceKey<CanvasService> { ServiceKey<CanvasService>("canvas") }
}

public enum CanvasFile {
    public static let pathExtension = "canvas"

    public static func isBoard(_ path: String) -> Bool {
        (path as NSString).pathExtension.lowercased() == pathExtension
    }
}

/// The standard `CanvasService`, on a plugin's vault.
public final class CanvasBoards: CanvasService {
    private let vault: VaultAccess
    /// The files each board shows, until the board changes (`vaultChanged`, `write`): asking which boards show a note
    /// reads only the boards that changed since, without asking the disk about the others.
    private var shown: [String: Set<String>] = [:]
    private let lock = NSLock()
    /// The boards found by the last walk, until a vault change may have added or removed one: the Info and
    /// Backlinks panels ask on every note switch, and a walk of a big vault costs hundreds of milliseconds.
    private var known: [String]?

    public init(vault: VaultAccess) {
        self.vault = vault
    }

    /// Forgets what the boards show for the boards that changed, and the boards found when a file or folder was
    /// added or removed.
    public func vaultChanged(_ changes: [VaultChange]) {
        lock.lock()
        for change in changes { shown[change.path] = nil }
        lock.unlock()
        guard changes.contains(where: { $0.kind != .modified }) else { return }
        forget()
    }

    private func forget() {
        lock.lock()
        known = nil
        lock.unlock()
    }

    public func boards() throws -> [String] {
        lock.lock()
        let cached = known
        lock.unlock()
        if let cached { return cached }
        var found: [String] = []
        var folders = [""]
        while let folder = folders.popLast() {
            for entry in try vault.list(folder) {
                if entry.isFolder {
                    folders.append(entry.path)
                } else if CanvasFile.isBoard(entry.path) {
                    found.append(entry.path)
                }
            }
        }
        found.sort()
        lock.lock()
        known = found
        lock.unlock()
        return found
    }

    public func read(_ path: String) throws -> CanvasDocument {
        let path = try VaultPath.normalize(path)
        guard CanvasFile.isBoard(path) else { throw CanvasError.invalid("\(path) is not a .canvas file.") }
        guard vault.exists(path) else { throw VaultError.notFound(path: path) }
        return try CanvasDocument(text: try vault.read(path))
    }

    public func write(_ path: String, _ document: CanvasDocument) throws {
        let path = try VaultPath.normalize(path)
        guard CanvasFile.isBoard(path) else { throw CanvasError.invalid("\(path) is not a .canvas file.") }
        let text = document.text
        let exists = vault.exists(path)
        if exists, (try? vault.read(path)) == text { return }
        try vault.write(path, text)
        lock.lock()
        shown[path] = nil
        lock.unlock()
        if !exists { forget() }
    }

    public func update<T>(_ path: String, _ change: (inout CanvasDocument) throws -> T) throws -> T {
        var document = try read(path)
        let before = document
        let result = try change(&document)
        if document != before { try write(path, document) }
        return result
    }

    public func create(in folder: String, title: String?) throws -> String {
        let folder = try VaultPath.normalize(folder.isEmpty ? VaultPath.inbox : folder)
        let name = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let base = name.isEmpty ? "Board" : name
        guard !base.contains("/"), !base.hasPrefix(".") else { throw CanvasError.invalid("Invalid board name: \(base)") }
        var path = "\(folder)/\(base).\(CanvasFile.pathExtension)"
        var number = 2
        while vault.exists(path) {
            path = "\(folder)/\(base) \(number).\(CanvasFile.pathExtension)"
            number += 1
        }
        try vault.write(path, CanvasDocument().text)
        forget()
        return path
    }

    public func boards(showing path: String) throws -> [String] {
        let path = try VaultPath.normalize(path)
        return try boards().filter { files(of: $0).contains(path) }
    }

    private func files(of board: String) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        if let known = shown[board] { return known }
        let files = Set((try? read(board))?.files ?? [])
        shown[board] = files
        return files
    }

    /// Follows moved files in every board. Returns the boards that changed. A board that does not parse is left
    /// alone.
    @discardableResult
    public func follow(moves: [String: String]) -> [String] {
        guard !moves.isEmpty else { return [] }
        forget()
        guard let boards = try? boards() else { return [] }
        return boards.filter { board in
            guard var document = try? read(board), document.follow(moves: moves) else { return false }
            return (try? write(board, document)) != nil
        }
    }
}
