import Foundation
import Markdown
import PluginKit

/// Reads one note: frontmatter properties, title, `#tags` and links to other notes.
public enum NoteParser {
    public static func parse(path: String, text: String) -> NoteInfo {
        let (_, yaml, body) = MarkdownFrontmatter.split(text)
        let properties = yaml.map(Frontmatter.properties(from:)) ?? [:]

        var collector = Collector(notePath: path)
        collector.visit(Document(parsing: body))

        // A note is named by its file, as its tab and the editor's title show it; a first `# heading` is its text.
        var title = fileTitle(path)
        if case .string(let value)? = properties["title"], !value.isEmpty {
            title = value
        } else if properties["excalidraw-plugin"] != nil, title.lowercased().hasSuffix(".excalidraw") {
            // A drawing of the Obsidian Excalidraw plugin: `Plan.excalidraw.md` is "Plan".
            title = String(title.dropLast(".excalidraw".count))
        }

        var tags: [String] = []
        for tag in propertyTags(properties) + collector.hashtags where !tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
            tags.append(tag)
        }
        return NoteInfo(path: path, title: title, properties: properties, tags: tags, links: collector.links)
    }

    private static func fileTitle(_ path: String) -> String {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return name.hasSuffix(".md") ? String(name.dropLast(3)) : name
    }

    private static func propertyTags(_ properties: [String: PropertyValue]) -> [String] {
        let raw: [String]
        switch properties["tags"] {
        case .string(let value)?:
            raw = value.split { $0 == "," || $0 == " " }.map(String.init)
        case .list(let values)?:
            raw = values.compactMap { if case .string(let value) = $0 { return value } else { return nil } }
        default:
            raw = []
        }
        return raw.map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 }.filter { !$0.isEmpty }
    }

    private struct Collector: MarkupWalker {
        let notePath: String
        var links: [NoteLink] = []
        var hashtags: [String] = []

        private static let hashtag = try! NSRegularExpression(
            pattern: "(?<![\\p{L}\\p{N}_/&#])#([\\p{L}\\p{N}_][\\p{L}\\p{N}_/-]*)"
        )

        init(notePath: String) {
            self.notePath = notePath
        }

        mutating func visitLink(_ link: Link) {
            if let destination = link.destination, let local = LocalLink(destination: destination),
               let target = try? VaultPath.resolve(local.path, from: notePath) {
                links.append(NoteLink(text: link.plainText, target: target))
            }
            descendInto(link)
        }

        mutating func visitText(_ text: Text) {
            let string = text.string
            let range = NSRange(string.startIndex..., in: string)
            for match in Self.hashtag.matches(in: string, range: range) {
                if let tag = Range(match.range(at: 1), in: string) { hashtags.append(String(string[tag])) }
            }
        }
    }
}
