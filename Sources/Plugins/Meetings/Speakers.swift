import Foundation

/// One real person behind one or more speaker labels.
public struct Person: Sendable, Equatable {
    public var name: String
    public var labels: [String]
    /// Why the model thinks so ("thanks Paul…").
    public var evidence: String?

    public init(name: String, labels: [String], evidence: String? = nil) {
        self.name = name
        self.labels = labels
        self.evidence = evidence
    }
}

public enum Speakers {
    /// Checks the model's grouping: every label belongs to exactly one person, unknown labels are dropped and missing
    /// ones become a person of their own. `me` is not a person here. Ordered by who speaks first.
    static func people(from json: Any?, utterances: [Utterance]) -> [Person] {
        var labels: [String] = []
        for utterance in utterances where utterance.label != "me" && !labels.contains(utterance.label) {
            labels.append(utterance.label)
        }
        let known = Set(labels)
        var seen = Set<String>()
        var people: [Person] = []
        for item in ((json as? [String: Any])?["people"] as? [[String: Any]]) ?? [] {
            let mine = ((item["labels"] as? [Any]) ?? []).compactMap { $0 as? String }
                .filter { known.contains($0) && !seen.contains($0) }
            guard !mine.isEmpty else { continue }
            mine.forEach { seen.insert($0) }
            people.append(Person(
                name: ((item["name"] as? String) ?? "").trimmed, labels: mine, evidence: item["evidence"] as? String
            ))
        }
        for label in labels where !seen.contains(label) { people.append(Person(name: "", labels: [label])) }
        func first(_ person: Person) -> Double {
            utterances.filter { person.labels.contains($0.label) }.map(\.start).min() ?? .infinity
        }
        return people.sorted { first($0) < first($1) }
    }

    /// Label → name; an unnamed person is "Speaker N".
    static func names(_ people: [Person], me: String, unnamed: (Int) -> String) -> [String: String] {
        var map = ["me": me]
        var n = 0
        for person in people {
            var name = person.name
            if name.isEmpty {
                n += 1
                name = unnamed(n)
            }
            for label in person.labels { map[label] = name }
        }
        return map
    }

    /// A person's longest lines, to help the user tell who it is.
    public static func samples(_ person: Person, _ utterances: [Utterance], count: Int = 2) -> [String] {
        utterances.filter { person.labels.contains($0.label) }
            .sorted { $0.text.count > $1.text.count }
            .prefix(count)
            .map { $0.text.count > 160 ? String($0.text.prefix(157)) + "…" : $0.text }
    }
}
