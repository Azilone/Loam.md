import Foundation
import PluginKit

/// The iPhone's Voice Memos as they sync to this Mac over iCloud, in a protected folder: reading it needs Full Disk
/// Access for Loam. Titles and durations come from the Voice Memos database (`/usr/bin/sqlite3`) when it can be read.
public enum VoiceMemos {
    public struct NoAccess: Error, LocalizedError {
        public init() {}

        public var errorDescription: String? {
            "Loam needs Full Disk Access to read Voice Memos: System Settings › Privacy & Security › Full Disk Access."
        }
    }

    public struct Memo: Sendable, Equatable {
        /// The file name, the memo's stable id.
        public var name: String
        public var path: String
        /// The title given in Voice Memos (often a place name), empty when unknown.
        public var title: String
        public var recordedAt: Date

        /// A memo titled like a meeting is one; the others are decided from what is said.
        var looksLikeMeeting: Bool {
            title.range(of: #"r[ée]union|meeting|call|rdv|entretien|1:1"#, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    /// `20261013 192233-1A2B3C4D.m4a` → that local date and time.
    static func date(fromName name: String) -> Date? {
        guard let match = name.range(of: #"^\d{8} \d{6}"#, options: .regularExpression) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd HHmmss"
        return formatter.date(from: String(name[match]))
    }

    /// Memos recorded after `since` and not `seen`, oldest first. One still syncing (changed in the last minute) waits.
    static func newMemos(in folder: String, since: Date, seen: Set<String>, now: Date) throws -> [Memo] {
        let root = (folder as NSString).expandingTildeInPath
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: root)
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError { throw NoAccess() }
            if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return [] }
            if (error.userInfo[NSUnderlyingErrorKey] as? NSError)?.code == Int(EPERM) { throw NoAccess() }
            throw error
        }
        // `.qta`: Voice Memos' QuickTime format (iOS 18 and later).
        let fresh = names.filter { ["m4a", "qta"].contains(($0 as NSString).pathExtension.lowercased()) && !seen.contains($0) }
        guard !fresh.isEmpty else { return [] }
        let titles = database(root)
        var out: [Memo] = []
        for name in fresh {
            let path = root + "/" + name
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = (attributes[.size] as? NSNumber)?.intValue, size > 0,
                  let modified = attributes[.modificationDate] as? Date else { continue }
            let recorded = date(fromName: name) ?? (attributes[.creationDate] as? Date) ?? modified
            guard recorded >= since, now.timeIntervalSince(modified) >= 60 else { continue }
            out.append(Memo(name: name, path: path, title: titles[name] ?? "", recordedAt: recorded))
        }
        return out.sorted { $0.recordedAt < $1.recordedAt }
    }

    /// File name → title, from `CloudRecordings.db`; empty when it cannot be read.
    static func database(_ root: String) -> [String: String] {
        let db = root + "/CloudRecordings.db"
        guard FileManager.default.fileExists(atPath: db), FileManager.default.isExecutableFile(atPath: "/usr/bin/sqlite3") else { return [:] }
        func run(_ sql: String) -> Any? {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            process.arguments = ["-readonly", "-json", db, sql]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return data.isEmpty ? [] : try? JSONSerialization.jsonObject(with: data)
        }
        let columns = ((run("PRAGMA table_info(ZCLOUDRECORDING)") as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
        guard columns.contains("ZPATH") else { return [:] }
        let titleColumns = ["ZENCRYPTEDTITLE", "ZCUSTOMLABEL"].filter(columns.contains)
        let title = titleColumns.isEmpty ? "''" : "COALESCE(\(titleColumns.joined(separator: ", ")), '')"
        var out: [String: String] = [:]
        for row in (run("SELECT ZPATH AS path, \(title) AS title FROM ZCLOUDRECORDING") as? [[String: Any]]) ?? [] {
            guard let path = row["path"] as? String else { continue }
            out[(path as NSString).lastPathComponent] = (row["title"] as? String)?.trimmed ?? ""
        }
        return out
    }

    /// Which memos were handled, in `.loam/meetings-voice-memos.json`: this Mac's own bookkeeping, not a note.
    struct Ledger {
        struct Contents: Codable {
            var since: Date?
            var names: [String] = []
        }

        let vault: VaultAccess
        var url: URL { vault.rootURL.appendingPathComponent(".loam/meetings-voice-memos.json") }

        func load() -> Contents {
            (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Contents.self, from: $0) } ?? Contents()
        }

        func save(_ contents: Contents) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(contents).write(to: url, options: .atomic)
        }
    }
}
