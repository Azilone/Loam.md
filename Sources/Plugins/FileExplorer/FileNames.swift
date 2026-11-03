import Foundation
import PluginKit

/// Name checks and "Name 2" collision handling, kept apart from the disk changes.
enum FileNames {
    /// A trimmed name, or `invalidName` when it would hide the file or reach another folder.
    static func validName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.hasPrefix(".") else {
            throw FilesError.invalidName(name)
        }
        return trimmed
    }

    /// A normalized path with no hidden part, so nothing lands in `.trash`, `.loam` or a dotfile by accident.
    static func visiblePath(_ path: String) throws -> String {
        let normalized = try VaultPath.normalize(path)
        guard !normalized.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else {
            throw FilesError.hiddenPath(path)
        }
        return normalized
    }

    static func join(_ folder: String, _ name: String) -> String {
        folder.isEmpty ? name : folder + "/" + name
    }

    /// `base + ext`, or `base 2 + ext`, `base 3 + ext`... whichever is free first.
    /// `isTaken` adds paths that are not on disk but not free either, such as a note still being written.
    static func unique(
        base: String, extension ext: String, in vault: VaultAccess, isTaken: (String) -> Bool = { _ in false }
    ) -> String {
        var number = 1
        while true {
            let candidate = number == 1 ? base + ext : "\(base) \(number)\(ext)"
            if !vault.exists(candidate), !isTaken(candidate) { return candidate }
            number += 1
        }
    }

    /// Splits `path` before its extension (`a/b.md` -> `a/b`, `.md`), so a suffix goes before it.
    /// Folders and files without an extension keep the whole path as base.
    static func splitExtension(_ path: String, isFolder: Bool) -> (base: String, ext: String) {
        let nameStart = path.lastIndex(of: "/").map { path.index(after: $0) } ?? path.startIndex
        guard !isFolder, let dot = path[nameStart...].lastIndex(of: "."), dot > nameStart else { return (path, "") }
        return (String(path[..<dot]), String(path[dot...]))
    }
}
