import Foundation

/// What installs each program plugins run: a Homebrew formula, or the developer tools for the ones Homebrew does not
/// ship. A program not listed here is installed by the formula of its own name.
public enum ToolCatalog {
    /// The formula that provides a program, when it is not the program's own name.
    static let formulas: [String: String] = ["ffprobe": "ffmpeg", "cwebp": "webp"]
    /// Programs that come with the developer tools (Command Line Tools), not from Homebrew.
    static let developerToolPrograms: Set<String> = ["swift"]
    /// The programs Loam's own plugins use, listed in Settings even when no plugin needs them yet.
    public static let known = ["git", "ffmpeg", "ffprobe", "cwebp", "swift"]

    /// The Homebrew formula to install for a program, or nil when it comes with the developer tools.
    public static func formula(for name: String) -> String? {
        if developerToolPrograms.contains(name) { return nil }
        return formulas[name] ?? name
    }

    /// The formulas to install for these programs, each once, in order.
    public static func formulas(for names: [String]) -> [String] {
        var seen: Set<String> = []
        return names.compactMap { formula(for: $0) }.filter { seen.insert($0).inserted }
    }
}
