import Foundation

/// How each path left in conflict by a merge is settled, without ever losing a version: when both sides changed a
/// file, the note keeps this device's version and the other one is saved next to it as a conflict copy.
enum ConflictPlan {
    enum Step: Equatable {
        /// Both sides changed (or both added) the file: keep ours, write theirs (`oid`) to `copy`.
        case keepOursWithCopy(path: String, oid: String, copy: String)
        /// Only our side still has the file (the other deleted it), or theirs is not a plain file.
        case keepOurs(path: String)
        /// Only their side still has the file (we deleted it).
        case keepTheirs(path: String)
        /// Both sides deleted it.
        case remove(path: String)

        var path: String {
            switch self {
            case .keepOursWithCopy(let path, _, _), .keepOurs(let path), .keepTheirs(let path), .remove(let path):
                return path
            }
        }
    }

    /// A symlink or a submodule: never copied, ours wins.
    private static let specialModes: Set<String> = ["120000", "160000"]

    /// - Parameters:
    ///   - taken: whether a path is already used, so two copies never share a name.
    static func steps(for entries: [Git.UnmergedEntry], device: String, day: String,
                      taken: (String) -> Bool) -> [Step] {
        var byPath: [String: [Int: Git.UnmergedEntry]] = [:]
        for entry in entries { byPath[entry.path, default: [:]][entry.stage] = entry }
        var reserved: Set<String> = []
        return byPath.keys.sorted().map { path in
            let stages = byPath[path] ?? [:]
            switch (stages[2], stages[3]) {
            case let (ours?, theirs?):
                if specialModes.contains(ours.mode) || specialModes.contains(theirs.mode) || ours.oid == theirs.oid {
                    return .keepOurs(path: path)
                }
                let copy = copyPath(for: path, device: device, day: day) { taken($0) || reserved.contains($0) }
                reserved.insert(copy)
                return .keepOursWithCopy(path: path, oid: theirs.oid, copy: copy)
            case (_?, nil):
                return .keepOurs(path: path)
            case (nil, _?):
                return .keepTheirs(path: path)
            case (nil, nil):
                return .remove(path: path)
            }
        }
    }

    /// `Ideas/Plan.md` → `Ideas/Plan (conflict MacBook 2026-10-20).md`, then ` 2`, ` 3`… if taken.
    static func copyPath(for path: String, device: String, day: String, taken: (String) -> Bool) -> String {
        let folder = path.contains("/") ? String(path[...path.lastIndex(of: "/")!]) : ""
        let name = String(path.split(separator: "/").last ?? "")
        let dot = name.lastIndex(of: ".").flatMap { $0 == name.startIndex ? nil : $0 }
        let base = dot.map { String(name[..<$0]) } ?? name
        let ext = dot.map { String(name[$0...]) } ?? ""
        let label = "conflict \(clean(device)) \(day)"
        var candidate = "\(folder)\(base) (\(label))\(ext)"
        var number = 2
        while taken(candidate) {
            candidate = "\(folder)\(base) (\(label) \(number))\(ext)"
            number += 1
        }
        return candidate
    }

    /// Whether `path` is a conflict copy made by `copyPath`.
    static func isCopy(_ path: String) -> Bool {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return name.range(of: #" \(conflict .+ \d{4}-\d{2}-\d{2}( \d+)?\)(\.[^.]+)?$"#, options: .regularExpression) != nil
    }

    /// The note a copy was made from: `Ideas/Plan (conflict A 2026-10-20 2).md` → `Ideas/Plan.md`; nil if not a copy.
    static func original(of path: String) -> String? {
        guard let range = path.range(of: #" \(conflict .+ \d{4}-\d{2}-\d{2}( \d+)?\)(?=(\.[^./]+)?$)"#,
                                     options: .regularExpression),
              !path[range].contains("/") else { return nil }
        return path.replacingCharacters(in: range, with: "")
    }

    /// The conflict copies among `paths`: only those whose note is there too, so a note the user titled like a copy
    /// is not one.
    static func copies(in paths: [String]) -> [String] {
        let all = Set(paths)
        return paths.filter { isCopy($0) && original(of: $0).map(all.contains) == true }
    }

    /// Loam's own settings files (`.loam/*.json`): merged key by key instead of copied, so a device joining with
    /// its own defaults never leaves a conflict copy of the settings.
    static func isSettings(_ path: String) -> Bool {
        path.hasPrefix(".loam/") && path.hasSuffix(".json")
    }

    /// A three-way merge of two JSON objects: what only one side changed from `base` is taken; where both changed a
    /// value, ours wins. Without a base (both added the file: a device joining), theirs is the vault's and wins,
    /// and ours only adds keys theirs lacks. Nil when a side is not a JSON object.
    static func mergeJSON(base: Data?, ours: Data, theirs: Data) -> Data? {
        guard let mine = (try? JSONSerialization.jsonObject(with: ours)) as? [String: Any],
              let other = (try? JSONSerialization.jsonObject(with: theirs)) as? [String: Any] else { return nil }
        let original = base.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        let merged = original.map { merge(base: $0, ours: mine, theirs: other) } ?? overlay(mine, with: other)
        return try? JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private static func merge(base: [String: Any], ours: [String: Any], theirs: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for key in Set(ours.keys).union(theirs.keys).union(base.keys) {
            let (b, o, t) = (base[key], ours[key], theirs[key])
            if let o = o as? [String: Any], let t = t as? [String: Any] {
                result[key] = merge(base: b as? [String: Any] ?? [:], ours: o, theirs: t)
            } else if same(o, b) {
                if let t { result[key] = t }
            } else if same(t, b) {
                if let o { result[key] = o }
            } else if let o {
                result[key] = o
            } else if let t {
                result[key] = t
            }
        }
        return result
    }

    /// `ours` with every value of `theirs` on top: keys only ours has stay.
    private static func overlay(_ ours: [String: Any], with theirs: [String: Any]) -> [String: Any] {
        var result = ours
        for (key, value) in theirs {
            if let mine = ours[key] as? [String: Any], let other = value as? [String: Any] {
                result[key] = overlay(mine, with: other)
            } else {
                result[key] = value
            }
        }
        return result
    }

    private static func same(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        // Compared as JSON text with sorted keys: works the same on Linux, where values do not bridge to NSObject.
        case let (a?, b?):
            let options: JSONSerialization.WritingOptions = [.sortedKeys, .fragmentsAllowed]
            return (try? JSONSerialization.data(withJSONObject: [a], options: options))
                == (try? JSONSerialization.data(withJSONObject: [b], options: options))
        default: return false
        }
    }

    /// A device name that fits in a file name.
    static func clean(_ device: String) -> String {
        let parts = device.components(separatedBy: CharacterSet(charactersIn: "/:\\()\n\r\t"))
        let joined = parts.joined(separator: " ").split(separator: " ").joined(separator: " ")
        return joined.isEmpty ? "device" : String(joined.prefix(40))
    }
}
