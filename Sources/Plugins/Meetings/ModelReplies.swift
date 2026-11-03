import Foundation

/// Reading what the language model answered: JSON, a type, a journal entry, a mind map. Pure, so it is tested alone.
enum ModelReplies {
    /// The JSON object in a reply, tolerating code fences and text around it.
    static func json(_ text: String) -> Any? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8))
    }

    struct Classification: Equatable {
        var type: NoteType
        /// 0 to 1, as the model reports it.
        var confidence: Double
        var reason: String
    }

    /// Below this the answer is ignored and the number of voices decides.
    static let minimumConfidence = 0.5

    /// Sent as a strict `json_schema`: the reply cannot leave this shape.
    static let classificationSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "type": ["type": "string", "enum": NoteType.allCases.map(\.rawValue)],
            "confidence": ["type": "number"],
            "reason": ["type": "string"],
        ],
        "required": ["type", "confidence", "reason"],
        "additionalProperties": false,
    ]

    static func classification(_ text: String) -> Classification? {
        guard let object = json(text) as? [String: Any],
              let raw = (object["type"] ?? object["kind"]) as? String, let type = NoteType(rawValue: raw) else { return nil }
        let confidence = (object["confidence"] as? NSNumber)?.doubleValue ?? 1
        return Classification(type: type, confidence: min(1, max(0, confidence)), reason: object["reason"] as? String ?? "")
    }

    /// A voice note as a bullet-journal entry.
    struct JournalEntry: Equatable {
        var title = ""
        var tldr = ""
        var tasks: [(text: String, done: Bool)] = []
        var events: [String] = []
        var notes: [String] = []

        static func == (a: JournalEntry, b: JournalEntry) -> Bool {
            a.title == b.title && a.tldr == b.tldr && a.events == b.events && a.notes == b.notes
                && a.tasks.map(\.text) == b.tasks.map(\.text) && a.tasks.map(\.done) == b.tasks.map(\.done)
        }
    }

    /// Strips the list markers and Markdown the model may still add, so the block is a clean list.
    static func clean(_ value: Any?) -> String {
        let text = (value as? String) ?? (value as? NSNumber)?.stringValue ?? ""
        return text.replacingOccurrences(of: #"^\s*(?:[-*•–—]|\[[ xX]\])\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmed
    }

    static func journalEntry(_ text: String) -> JournalEntry {
        guard let object = json(text) as? [String: Any] else {
            // Not JSON: the text becomes notes rather than being lost.
            return JournalEntry(notes: text.split(separator: "\n").map { clean(String($0)) }.filter { !$0.isEmpty })
        }
        let list = { (key: String) in ((object[key] as? [Any]) ?? []).map { clean($0) }.filter { !$0.isEmpty } }
        let tasks: [(text: String, done: Bool)] = ((object["tasks"] as? [Any]) ?? []).compactMap { item in
            if let task = item as? [String: Any] {
                let text = clean(task["text"])
                return text.isEmpty ? nil : (text, (task["done"] as? Bool) ?? false)
            }
            let text = clean(item)
            return text.isEmpty ? nil : (text, false)
        }
        return JournalEntry(title: clean(object["title"]), tldr: clean(object["tldr"]), tasks: tasks,
                            events: list("events"), notes: list("notes"))
    }

    /// The model's `==text==` highlights as `<mark>` elements: `==` is not CommonMark or GFM, `<mark>` is the
    /// highlight the editor draws.
    static func highlighted(_ text: String) -> String {
        text.replacingOccurrences(of: #"==(?=\S)(.+?)(?<=\S)=="#, with: "<mark>$1</mark>", options: .regularExpression)
    }

    /// The block added to the daily note: a natural title, a one-line gist, one list, then the links.
    static func journalBlock(time: String, fallbackTitle: String, entry: JournalEntry, links: String) -> String {
        var lines = ["### 🎙️ \(time) · \(entry.title.isEmpty ? fallbackTitle : entry.title)"]
        if !entry.tldr.isEmpty { lines.append("*\(highlighted(entry.tldr.replacingOccurrences(of: "*", with: "")))*") }
        let items = entry.tasks.map { "- [\($0.done ? "x" : " ")] \(highlighted($0.text))" }
            + entry.events.map { "- \(highlighted($0))" } + entry.notes.map { "- \(highlighted($0))" }
        if !items.isEmpty { lines += [""] + items }
        if !links.isEmpty { lines += ["", links] }
        return lines.joined(separator: "\n")
    }

    static let journalHeadingPrefix = "### 🎙️"

    /// A mind map note for the Mindmap plugin: `mindmap-plugin: basic`, the title as the central topic, the model's
    /// bullets rebuilt as a clean tab-indented tree (at most 60 items, 4 levels). Empty when there is too little.
    static func mindmap(title: String, reply: String) -> String {
        var items: [(depth: Int, text: String)] = []
        var stack: [Int] = []
        let bullet = try! NSRegularExpression(pattern: #"^(\s*)(?:[-*•+]|\d+[.)])\s+(.*\S)\s*$"#)
        for line in reply.replacingOccurrences(of: "\r", with: "").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(line)
            guard let match = bullet.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let indentRange = Range(match.range(at: 1), in: line),
                  let textRange = Range(match.range(at: 2), in: line) else { continue }
            let text = String(line[textRange])
                .replacingOccurrences(of: #"^\[[ xX]\]\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmed
            guard !text.isEmpty else { continue }
            let indent = line[indentRange].replacingOccurrences(of: "\t", with: "    ").count
            // Depth follows the nesting and never jumps more than one level.
            while let top = stack.last, top >= indent { stack.removeLast() }
            let depth = stack.count
            stack.append(indent)
            if depth < 4 { items.append((depth, text)) }
        }
        let kept = items.prefix(60)
        guard kept.count >= 2 else { return "" }
        var center = title.replacingOccurrences(of: #"[\r\n#]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmed
        if center.isEmpty { center = "Mindmap" }
        let tree = kept.map { String(repeating: "\t", count: $0.depth) + "- " + $0.text }.joined(separator: "\n")
        return "---\nmindmap-plugin: basic\n---\n\n# \(center)\n\n\(tree)\n"
    }

    /// A title from the model's reply: first line, without quotes, hashes or a final full stop.
    static func title(_ reply: String) -> String {
        let first = reply.split(separator: "\n").first.map(String.init) ?? ""
        return first.replacingOccurrences(of: #"^["«\s#*]+|["»\s.*]+$"#, with: "", options: .regularExpression)
    }
}
