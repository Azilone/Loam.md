import Foundation
import PluginKit

/// File names in the attachments folder and the links to them, kept apart from the disk changes.
public enum AttachmentNames {
    /// `name` as a file name that stays in its folder and in sight: no `/` or `:`, no control characters, no leading
    /// dot; "file" before the extension when nothing else is left.
    public static func sanitized(_ name: String) -> String {
        var cleaned = String(name.unicodeScalars.map { scalar -> Character in
            if CharacterSet.controlCharacters.contains(scalar) || scalar == "/" || scalar == ":" || scalar == "\\" {
                return "-"
            }
            return Character(scalar)
        })
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        // A bare extension (`.png`) is a file with no name; any other leading dot would hide the file.
        if cleaned.hasPrefix("."), cleaned.dropFirst().allSatisfy({ $0 != "." }), cleaned.count > 1 { return "file" + cleaned }
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        let split = splitExtension(cleaned)
        if split.base.trimmingCharacters(in: .whitespaces).isEmpty { return "file" + split.ext }
        return cleaned
    }

    /// The name a pasted image gets, from the moment it was pasted: `Pasted image 2026-10-20 at 14.32.05.png`, as
    /// macOS names a screenshot.
    public static func pasted(extension ext: String, at date: Date = Date(), timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Pasted image \(formatter.string(from: date)).\(ext.isEmpty ? "png" : ext.lowercased())"
    }

    /// `folder/name`, or `folder/base 2.ext`, `folder/base 3.ext`... whichever is free first, not counting `taken`.
    public static func unique(_ name: String, in folder: String, vault: VaultAccess, taken: Set<String> = []) -> String {
        let split = splitExtension(name)
        let base = folder.isEmpty ? split.base : folder + "/" + split.base
        var number = 1
        while true {
            let candidate = number == 1 ? base + split.ext : "\(base) \(number)\(split.ext)"
            if !taken.contains(candidate), !vault.exists(candidate) { return candidate }
            number += 1
        }
    }

    /// `photo.png` -> (`photo`, `.png`); a name without an extension, or a dotfile, keeps it all as base.
    static func splitExtension(_ name: String) -> (base: String, ext: String) {
        guard let dot = name.lastIndex(of: "."), dot > name.startIndex else { return (name, "") }
        return (String(name[..<dot]), String(name[dot...]))
    }

    /// The Markdown linking the file at `path`: an image link for media (shown in place by the editor and other
    /// viewers), a plain link named after the file otherwise. The destination is written from the vault's root
    /// (`assets/photo.png`) and percent-encoded, so moving the note does not break it; the editor reads both this and
    /// links relative to the note.
    public static func markdownLink(to path: String) -> String {
        let destination = VaultPath.relativeDestination(fromDirectory: "", to: path)
        if AttachmentKind(path: path).isMedia { return "![](\(destination))" }
        return "[\(linkText((path as NSString).lastPathComponent))](\(destination))"
    }

    /// `name` as link text: brackets that pair up need no escape (`a[b].zip`); unpaired ones get a backslash.
    static func linkText(_ name: String) -> String {
        var depth = 0
        var balanced = true
        for character in name {
            if character == "[" { depth += 1 }
            if character == "]" {
                depth -= 1
                if depth < 0 { balanced = false }
            }
        }
        if balanced, depth == 0 { return name }
        return name.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
    }
}
