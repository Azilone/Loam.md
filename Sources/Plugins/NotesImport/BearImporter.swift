import Foundation
import PluginKit
#if canImport(SQLite3)
import SQLite3
#endif

/// Reads Bear's own database (read only) and writes each note as Markdown: Bear already writes Markdown, with its
/// `#tags` inline; archived notes go in `Archive/`, trashed and locked ones stay behind, pictures and files come along
/// in `Attachments/` with their links.
public struct BearImporter {
    let vault: VaultAccess
    let folder: URL

    /// Bear's data folder, in its group container.
    public static var defaultFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/9K33E3U3T4.net.shinyfrog.bear/Application Data")
    }

    public init(vault: VaultAccess, folder: URL = BearImporter.defaultFolder) {
        self.vault = vault
        self.folder = folder
    }

    /// True when Bear's database is here, whether or not macOS lets Loam read it yet.
    public static func isInstalled(folder: URL = defaultFolder) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent("database.sqlite").path)
            || FileManager.default.fileExists(atPath: folder.path)
    }

    struct Note {
        let id: Int64
        let title: String
        let text: String
        let created: Date?
        let modified: Date?
        let archived: Bool
    }

    struct Attachment {
        let note: Int64
        let uuid: String
        let filename: String
        let isImage: Bool
    }

    public func run(into: String, dryRun: Bool) throws -> NotesImportReport {
        let (notes, attachments, locked) = try read()
        var writer = ImportWriter(vault: vault, into: try VaultPath.normalize(into), dryRun: dryRun)
        if locked > 0 { writer.report.warnings.append("\(locked) locked notes left in Bear: unlock them there to bring them.") }
        let byNote = Dictionary(grouping: attachments, by: \.note)
        for note in notes {
            var text = note.text
            for attachment in byNote[note.id] ?? [] {
                let source = folder.appendingPathComponent(attachment.isImage ? "Local Files/Note Images" : "Local Files/Note Files")
                    .appendingPathComponent(attachment.uuid).appendingPathComponent(attachment.filename)
                guard let data = try? Data(contentsOf: source) else {
                    writer.report.warnings.append("\(note.title): \(attachment.filename) not found")
                    continue
                }
                let name = (attachment.filename as NSString).deletingPathExtension
                let ext = (attachment.filename as NSString).pathExtension
                let target = writer.path(folder: "Attachments", name: ImportWriter.safeName(name), ext: ext.isEmpty ? "bin" : ext)
                try writer.file(target, data)
                text = Self.relink(text, filename: attachment.filename, to: "../" + String(target.dropFirst(writer.into.isEmpty ? 0 : writer.into.count + 1)), archived: note.archived)
            }
            var properties: [(String, String)] = []
            if let created = note.created { properties.append(("created", frontmatterDate(created))) }
            if let modified = note.modified { properties.append(("modified", frontmatterDate(modified))) }
            let path = writer.path(folder: note.archived ? "Archive" : "", name: ImportWriter.safeName(note.title), ext: "md")
            try writer.note(path, withFrontmatter(properties, Self.bearMarkup(text)))
        }
        return writer.report
    }

    /// Bear 1's own image syntax (`[image:UUID/name.png]`) as standard Markdown.
    static func bearMarkup(_ text: String) -> String {
        let pattern = try! NSRegularExpression(pattern: "\\[(image|file):([^\\]]+)\\]")
        let range = NSRange(text.startIndex..., in: text)
        return pattern.stringByReplacingMatches(in: text, range: range, withTemplate: "![]($2)")
    }

    /// The note's links to `filename` pointed at the copied file. A note at the root links `Attachments/x`, one in
    /// `Archive/` links `../Attachments/x`.
    static func relink(_ text: String, filename: String, to target: String, archived: Bool) -> String {
        let link = archived ? target : String(target.dropFirst(3))
        let encoded = link.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? link
        var result = text
        for form in [filename, filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename] {
            result = result.replacingOccurrences(of: "](\(form))", with: "](\(encoded))")
            result = result.replacingOccurrences(of: "/\(form)]", with: "/\(encoded)]")
        }
        return result
    }

    /// The notes, their attachments, and how many are locked. Opens the database read only, with no lock taken.
    func read() throws -> ([Note], [Attachment], Int) {
        #if canImport(SQLite3)
        let path = folder.appendingPathComponent("database.sqlite").path
        guard FileManager.default.fileExists(atPath: folder.path) else { throw NotesImportError.missing("Bear") }
        var db: OpaquePointer?
        let uri = "file:\(path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)?mode=ro&immutable=1"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw NotesImportError.denied("Bear's notes")
        }
        defer { sqlite3_close(db) }
        let columns = Set(try rows(db, "PRAGMA table_info(ZSFNOTE)") { text($0, 1) })
        guard columns.contains("ZTEXT") else { throw NotesImportError.denied("Bear's notes") }
        let deleted = columns.contains("ZPERMANENTLYDELETED") ? " AND IFNULL(ZPERMANENTLYDELETED, 0) = 0" : ""
        let encrypted = columns.contains("ZENCRYPTED") ? "IFNULL(ZENCRYPTED, 0)" : "0"
        let all = try rows(db, """
            SELECT Z_PK, IFNULL(ZTITLE, ''), IFNULL(ZTEXT, ''), ZCREATIONDATE, ZMODIFICATIONDATE,
                   IFNULL(ZARCHIVED, 0), \(encrypted)
            FROM ZSFNOTE WHERE IFNULL(ZTRASHED, 0) = 0\(deleted) ORDER BY ZCREATIONDATE
            """) { row -> (Note, Bool) in
            let note = Note(
                id: sqlite3_column_int64(row, 0), title: text(row, 1), text: text(row, 2),
                created: date(row, 3), modified: date(row, 4), archived: sqlite3_column_int(row, 5) != 0
            )
            return (note, sqlite3_column_int(row, 6) != 0)
        }
        let attachments = (try? rows(db, """
            SELECT ZNOTE, IFNULL(ZUNIQUEIDENTIFIER, ''), IFNULL(ZFILENAME, ''), IFNULL(Z_ENT, 0) FROM ZSFNOTEFILE
            WHERE IFNULL(ZPERMANENTLYDELETED, 0) = 0
            """) { row in
            Attachment(note: sqlite3_column_int64(row, 0), uuid: text(row, 1), filename: text(row, 2),
                       isImage: ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff"].contains((text(row, 2) as NSString).pathExtension.lowercased()))
        }) ?? []
        return (all.filter { !$0.1 }.map(\.0), attachments, all.filter(\.1).count)
        #else
        throw NotesImportError.missing("Bear")
        #endif
    }

    #if canImport(SQLite3)
    private func rows<T>(_ db: OpaquePointer, _ sql: String, _ make: (OpaquePointer) -> T) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw NotesImportError.denied("Bear's notes")
        }
        defer { sqlite3_finalize(statement) }
        var result: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW { result.append(make(statement)) }
        return result
    }

    private func text(_ row: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(row, column).map { String(cString: $0) } ?? ""
    }

    /// Core Data's dates count seconds from 2001.
    private func date(_ row: OpaquePointer, _ column: Int32) -> Date? {
        sqlite3_column_type(row, column) == SQLITE_NULL ? nil : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(row, column))
    }
    #endif
}
