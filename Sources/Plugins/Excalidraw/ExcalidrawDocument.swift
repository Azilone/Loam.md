import Foundation

public enum ExcalidrawError: Error, Equatable, CustomStringConvertible {
    case invalid(String)

    public var description: String {
        switch self {
        case .invalid(let message): message
        }
    }
}

/// An image of a drawing kept as a file of the vault: a line of `## Embedded Files`, `id: [[assets/photo.png]]`.
public struct ExcalidrawEmbeddedFile: Equatable, Sendable {
    /// The `fileId` of the image elements showing it.
    public var id: String
    /// What follows `id: ` as written (`[[assets/photo.png]]{colorMap}`), kept when the line is written back.
    public var value: String

    public init(id: String, path: String) {
        self.id = id
        self.value = "[[\(path)]]"
    }

    init(id: String, value: String) {
        self.id = id
        self.value = value
    }

    /// The vault file it links to as written, without alias (`assets/photo.png`); nil for a formula or a URL.
    public var link: String? {
        guard let open = value.range(of: "[["), let close = value.range(of: "]]", range: open.upperBound..<value.endIndex)
        else { return nil }
        let inside = value[open.upperBound..<close.lowerBound]
        let target = inside.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return target.isEmpty ? nil : String(target)
    }

    /// Points the line at another file, keeping what follows the link.
    mutating func relink(to path: String) {
        guard let open = value.range(of: "[["), let close = value.range(of: "]]", range: open.upperBound..<value.endIndex)
        else { return }
        let alias = value[open.upperBound..<close.lowerBound].split(separator: "|", maxSplits: 1).dropFirst().first
        value.replaceSubrange(open.upperBound..<close.lowerBound, with: alias.map { "\(path)|\($0)" } ?? path)
    }
}

/// A drawing: an Excalidraw scene, in one of the two files that hold one.
///
/// - `Name.excalidraw.md`, written the way the Obsidian Excalidraw plugin writes it: a note flagged
///   `excalidraw-plugin: parsed`, then `# Excalidraw Data` with the text of the drawing (`## Text Elements`, one
///   `text ^id` each, so search and links see it), `## Element Links`, `## Embedded Files` (images as vault files),
///   and the scene in `## Drawing`, as ` ```json ` or lz-string ` ```compressed-json `. Loam writes JSON; it reads
///   both. What it does not know (the text above the data, other sections) is written back unchanged.
/// - `Name.excalidraw`: the scene's JSON alone, as excalidraw.com saves it, images inside.
///
/// The scene is the truth; the text and link sections are written from it. When they say something else (an agent
/// or a link rewrite edited them), they win on reading.
public struct ExcalidrawDocument {
    public enum Format: Sendable {
        case markdown, plain
    }

    public static let flag = "excalidraw-plugin"
    static let dataHeading = "# Excalidraw Data"
    static let newHeader = "---\n\(flag): parsed\ntags: [excalidraw]\n---\n\n"

    public var format: Format
    /// Excalidraw's scene: `type`, `version`, `source`, `elements`, `appState`, `files`.
    public var scene: [String: Any]
    /// The images kept as vault files (`.excalidraw.md` only).
    public var embeddedFiles: [ExcalidrawEmbeddedFile] = []
    /// Whether the scene is written lz-string compressed: kept from the file read, false for a new one.
    public var compressed = false
    /// Everything above `# Excalidraw Data`: the frontmatter and any text written there.
    var header = newHeader
    /// Whether a `%%` above `# Excalidraw Data` hides the whole data from reading view (a variant of the plugin).
    var dataCommented = false
    /// Sections of the data Loam does not know, in order, with their heading line.
    var otherSections: [String] = []
    /// Text after the drawing.
    var trailer = ""

    /// An empty drawing.
    public init(format: Format) {
        self.format = format
        self.scene = [
            "type": "excalidraw",
            "version": 2,
            "source": "loam",
            "elements": [Any](),
            "appState": ["gridSize": NSNull(), "viewBackgroundColor": "#ffffff"] as [String: Any],
            "files": [String: Any](),
        ]
    }

    public init(text: String, format: Format) throws {
        self.init(format: format)
        switch format {
        case .plain: scene = try Self.object(text)
        case .markdown: try parseMarkdown(text.replacingOccurrences(of: "\r\n", with: "\n"))
        }
    }

    /// The format of the file at `path`, from its extension; nil for a file that cannot hold a drawing.
    public static func format(of path: String) -> Format? {
        switch (path as NSString).pathExtension.lowercased() {
        case "excalidraw": .plain
        case "md": .markdown
        default: nil
        }
    }

    /// Whether a note's frontmatter has the `excalidraw-plugin` flag.
    public static func hasFlag(_ text: String) -> Bool {
        guard text.hasPrefix("---") else { return false }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" || trimmed == "..." { return false }
            if trimmed.hasPrefix(flag + ":") { return true }
        }
        return false
    }

    // MARK: - Elements

    public var elements: [[String: Any]] {
        get { (scene["elements"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? [] }
        set { scene["elements"] = newValue }
    }

    private var liveElements: [[String: Any]] {
        elements.filter { ($0["isDeleted"] as? Bool) != true }
    }

    /// The text of each text element, as typed (links included).
    public var texts: [(id: String, text: String)] {
        liveElements.compactMap { element in
            guard element["type"] as? String == "text", let id = element["id"] as? String else { return nil }
            return (id, Self.rawText(of: element))
        }
    }

    /// The link of each element that has one, text aside (their links are in their text).
    public var links: [(id: String, link: String)] {
        liveElements.compactMap { element in
            guard element["type"] as? String != "text", let id = element["id"] as? String,
                  let link = element["link"] as? String, !link.isEmpty else { return nil }
            return (id, link)
        }
    }

    /// The `fileId` of every image element.
    public var imageFileIDs: Set<String> {
        Set(liveElements.compactMap { $0["type"] as? String == "image" ? $0["fileId"] as? String : nil })
    }

    static func rawText(of element: [String: Any]) -> String {
        (element["rawText"] as? String) ?? (element["originalText"] as? String) ?? (element["text"] as? String) ?? ""
    }

    // MARK: - Writing

    public var text: String {
        switch format {
        case .plain: return Self.json(scene, pretty: true) + "\n"
        case .markdown: return markdown
        }
    }

    private var markdown: String {
        var out = header
        if dataCommented { out += "%%\n" }
        out += Self.dataHeading + "\n\n## Text Elements\n"
        for (id, text) in texts { out += "\(text) ^\(id)\n\n" }
        let links = links
        if !links.isEmpty {
            out += "## Element Links\n"
            for (id, link) in links { out += "\(id): \(link)\n" }
            out += "\n"
        }
        let used = imageFileIDs
        let files = embeddedFiles.filter { used.contains($0.id) }
        if !files.isEmpty {
            out += "## Embedded Files\n"
            for file in files { out += "\(file.id): \(file.value)\n" }
            out += "\n"
        }
        for section in otherSections { out += section.hasSuffix("\n\n") ? section : section + "\n" }
        var stored = scene
        stored["files"] = [String: Any]()
        if !dataCommented { out += "%%\n" }
        out += "## Drawing\n"
        if compressed {
            let packed = LZString.compressToBase64(Self.json(stored, pretty: false))
            var chunks: [Substring] = []
            var rest = packed[...]
            while !rest.isEmpty {
                chunks.append(rest.prefix(256))
                rest = rest.dropFirst(256)
            }
            out += "```compressed-json\n" + chunks.joined(separator: "\n\n") + "\n```\n"
        } else {
            out += "```json\n" + Self.json(stored, pretty: true) + "\n```\n"
        }
        out += "%%\n" + trailer
        return out
    }

    // MARK: - Reading

    private mutating func parseMarkdown(_ text: String) throws {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == Self.dataHeading })
            ?? lines.firstIndex(where: Self.isDrawingHeading)
        else {
            // A flagged note with no drawing yet: an empty scene under its text.
            header = text.hasSuffix("\n") || text.isEmpty ? text : text + "\n"
            return
        }
        var headerEnd = start
        if let previous = lines[..<start].lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           lines[previous].trimmingCharacters(in: .whitespaces) == "%%",
           lines[start].trimmingCharacters(in: .whitespaces) == Self.dataHeading {
            dataCommented = true
            headerEnd = previous
        }
        header = lines[..<headerEnd].map { $0 + "\n" }.joined()

        // The sections of the data, each from its heading to the next; lone `%%` lines are the plugin's.
        var sections: [(heading: String, lines: [String])] = []
        var index = lines[start].trimmingCharacters(in: .whitespaces) == Self.dataHeading ? start + 1 : start
        var drawingFound = false
        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("## ") || Self.isDrawingHeading(line) {
                sections.append((line, []))
                if Self.isDrawingHeading(line) {
                    drawingFound = true
                    index += 1
                    break
                }
            } else if line.trimmingCharacters(in: .whitespaces) != "%%", !sections.isEmpty {
                sections[sections.count - 1].lines.append(line)
            }
            index += 1
        }

        var textOverrides: [String: String] = [:]
        var linkOverrides: [String: String] = [:]
        for (heading, body) in sections.dropLast(drawingFound ? 1 : 0) {
            let name = heading.dropFirst(3).trimmingCharacters(in: .whitespaces)
            let content = body.joined(separator: "\n")
            switch name {
            case "Text Elements":
                for (id, text) in Self.textElements(content) { textOverrides[id] = text }
            case "Element Links":
                for (id, value) in Self.keyedLines(body) { linkOverrides[id] = value }
            case "Embedded Files":
                embeddedFiles = Self.keyedLines(body).map { ExcalidrawEmbeddedFile(id: $0.key, value: $0.value) }
            default:
                otherSections.append(([heading] + body).joined(separator: "\n") + "\n")
            }
        }

        if drawingFound {
            // The fenced block after `## Drawing`, then whatever follows it.
            guard let open = lines[index...].firstIndex(where: { $0.hasPrefix("```") }) else {
                throw ExcalidrawError.invalid("The drawing has no ```json block.")
            }
            let language = lines[open].dropFirst(3).trimmingCharacters(in: .whitespaces)
            guard let close = lines[(open + 1)...].firstIndex(where: { $0.hasPrefix("```") }) else {
                throw ExcalidrawError.invalid("The drawing's block is not closed.")
            }
            let body = lines[(open + 1)..<close].joined(separator: "\n")
            switch language {
            case "compressed-json":
                compressed = true
                guard let json = LZString.decompressFromBase64(body) else {
                    throw ExcalidrawError.invalid("The compressed drawing does not decompress.")
                }
                scene = try Self.object(json)
            case "json", "":
                scene = try Self.object(body.replacingOccurrences(of: "&#91;", with: "["))
            default:
                throw ExcalidrawError.invalid("Unknown drawing block: \(language)")
            }
            var rest = Array(lines[(close + 1)...])
            if let first = rest.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
               rest[first].trimmingCharacters(in: .whitespaces) == "%%" {
                rest.removeSubrange(...first)
            }
            trailer = rest.joined(separator: "\n")
        }
        apply(texts: textOverrides, links: linkOverrides)
    }

    /// Puts the text and links the sections hold into the elements, where they differ.
    private mutating func apply(texts: [String: String], links: [String: String]) {
        guard !texts.isEmpty || !links.isEmpty else { return }
        elements = elements.map { element in
            guard let id = element["id"] as? String else { return element }
            var element = element
            if element["type"] as? String == "text", let text = texts[id], text != Self.rawText(of: element) {
                element["text"] = text
                element["originalText"] = text
                if element["rawText"] != nil { element["rawText"] = text }
            }
            if element["type"] as? String != "text", let link = links[id], link != element["link"] as? String {
                element["link"] = link
            }
            return element
        }
    }

    private static func isDrawingHeading(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed == "## Drawing" || trimmed == "# Drawing"
    }

    /// `text ^id` blocks, separated by blank lines; a text may span lines.
    static func textElements(_ content: String) -> [(id: String, text: String)] {
        let pattern = try! NSRegularExpression(pattern: "\\s\\^([A-Za-z0-9_-]{1,64})(?:\\n+|$)")
        let string = content as NSString
        var result: [(String, String)] = []
        var cursor = 0
        for match in pattern.matches(in: content, range: NSRange(location: 0, length: string.length)) {
            var text = string.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            while text.hasPrefix("\n") { text.removeFirst() }
            result.append((string.substring(with: match.range(at: 1)), text))
            cursor = match.range.location + match.range.length
        }
        return result
    }

    /// `id: value` lines.
    static func keyedLines(_ lines: [String]) -> [(key: String, value: String)] {
        lines.compactMap { line in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !key.contains(" ") else { return nil }
            return (key, line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
    }

    // MARK: - JSON

    static func object(_ text: String) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw ExcalidrawError.invalid("The drawing is not a JSON object.")
        }
        return object
    }

    /// Keys sorted, so writing the same scene twice gives the same text.
    static func json(_ object: [String: Any], pretty: Bool) -> String {
        var options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        if pretty { options.insert(.prettyPrinted) }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: options) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
