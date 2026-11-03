/// The file a "Create" row writes, from what the user typed.
enum NoteName {
    /// `<name>.md` at the vault root, or nil when nothing usable is left. Slashes become dashes (the switcher
    /// creates a note, not folders), leading dots are dropped (they would hide the file) and a typed `.md` is
    /// not doubled.
    static func sanitize(_ query: String) -> String? {
        var name = query.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        if name.lowercased().hasSuffix(".md") { name = String(name.dropLast(3)) }
        name = String(name.drop { $0 == "." }).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name + ".md"
    }
}
