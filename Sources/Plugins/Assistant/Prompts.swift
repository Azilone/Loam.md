import Foundation
import PluginKit

/// A prompt the user saved, as Craft's "Saved Prompts": a title (optional) and the prompt. One Markdown file per
/// prompt in `.loam/ai/prompts/`, the title in frontmatter and the prompt as body, so it travels with the vault and an
/// agent can write one too.
public struct SavedPrompt: Codable, Equatable, Sendable, Identifiable {
    /// The file's name without `.md`.
    public let id: String
    public var title: String
    public var prompt: String

    public init(id: String, title: String, prompt: String) {
        self.id = id
        self.title = title
        self.prompt = prompt
    }

    /// The title, or the prompt's first words when it has none.
    public var label: String {
        if !title.isEmpty { return title }
        let line = prompt.split(separator: "\n").first.map(String.init) ?? prompt
        return line.count > 40 ? String(line.prefix(39)) + "…" : line
    }
}

public final class PromptStore: @unchecked Sendable {
    /// Craft's limits.
    public static let maxPrompts = 20
    public static let maxLength = 1000
    public static let folderPath = ".loam/ai/prompts"

    private let folder: URL
    private let lock = StateLock()

    public init(vault: URL) {
        folder = vault.appendingPathComponent(Self.folderPath)
    }

    /// Every saved prompt, by title.
    public func all() -> [SavedPrompt] {
        lock.lock()
        defer { lock.unlock() }
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "md" }.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let (title, body) = Self.parse(text)
            return SavedPrompt(id: url.deletingPathExtension().lastPathComponent, title: title, prompt: body)
        }
        .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    /// Saves a new prompt, or replaces `id`'s.
    @discardableResult
    public func save(title: String, prompt: String, id: String? = nil) throws -> SavedPrompt {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw AgentError("A prompt needs some text.") }
        guard prompt.count <= Self.maxLength else {
            throw AgentError("A prompt holds up to \(Self.maxLength) characters.")
        }
        let existing = all()
        if id == nil, existing.count >= Self.maxPrompts {
            throw AgentError("Up to \(Self.maxPrompts) prompts can be saved.")
        }
        lock.lock()
        defer { lock.unlock() }
        let taken = Set(existing.map(\.id))
        let id = id ?? Self.slug(title.isEmpty ? prompt : title, avoiding: taken)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var text = ""
        if !title.isEmpty { text += "---\ntitle: \(Self.yamlString(title))\n---\n\n" }
        text += prompt + "\n"
        try text.write(to: folder.appendingPathComponent(id + ".md"), atomically: true, encoding: .utf8)
        return SavedPrompt(id: id, title: title, prompt: prompt)
    }

    public func delete(_ id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try FileManager.default.removeItem(at: folder.appendingPathComponent(id + ".md"))
    }

    static func parse(_ text: String) -> (title: String, body: String) {
        guard text.hasPrefix("---\n"), let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex) else {
            return ("", text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let front = text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound]
        var title = ""
        for line in front.split(separator: "\n") where line.hasPrefix("title:") {
            title = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            if title.count >= 2, let first = title.first, first == "\"" || first == "'", title.last == first {
                title = String(title.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
            }
        }
        let body = text[end.upperBound...].drop { $0 == "\n" || $0 == "-" }
        return (title, String(body).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func slug(_ text: String, avoiding taken: Set<String>) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        let words = folded.split { !$0.isLetter && !$0.isNumber }.prefix(6)
        let base = words.isEmpty ? "prompt" : words.joined(separator: "-")
        var candidate = base
        var number = 2
        while taken.contains(candidate) {
            candidate = "\(base)-\(number)"
            number += 1
        }
        return candidate
    }

    static func yamlString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// What every chat starts with: how the vault works, and the user's own instructions from
/// `.loam/ai/instructions.md`.
public enum AssistantInstructions {
    public static let userFile = ".loam/ai/instructions.md"

    public static func make(vault: URL, mode: AgentMode, cli: String?) -> String {
        var text = """
        You are the assistant inside Loam, a Markdown notebook. Your working folder is the user's vault: every note \
        is a plain Markdown file (CommonMark and GitHub Flavored Markdown, YAML frontmatter for properties, \
        [[wikilinks]] between notes). Folders are folders. Daily notes, tasks (`- [ ]` lines) and collections \
        (Obsidian Bases `.base` files) are plain files too. Never touch `.loam/cache/`, `.git/` or `.trash/`.

        The app shows every change you make to a file at once, and the user can undo your whole turn.
        Keep notes in the user's language and style. Answer briefly, in Markdown; refer to notes as [[Note name]].
        """
        if let cli {
            text += """


            Loam's own commands run with its command line, in this folder: `\(cli) <command> key=value …`. Use them \
            for what they cover rather than writing the files by hand:

            \(AgentRecipes.text(cli: cli))
            """
        }
        switch mode {
        case .readOnly: text += "\n\nThis chat is read only: answer, never change a file."
        case .ask: text += "\n\nAsk before changing anything the user did not ask for."
        case .auto: break
        }
        let own = (try? String(contentsOf: vault.appendingPathComponent(userFile), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !own.isEmpty { text += "\n\nThe user's instructions:\n\(own)" }
        return text
    }

    /// The `loam` command line shipped in the app, or the one on the PATH.
    public static func cliPath(environment: ShellEnvironment = .shared) -> String? {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/loam")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled.path }
        return environment.find("loam")?.path
    }
}
