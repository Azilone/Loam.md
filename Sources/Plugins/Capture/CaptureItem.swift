import Foundation
import PluginKit

/// What a capture holds, decided once from the clipboard (or the command line): the richest thing wins.
public enum CaptureKind: String, Codable, Sendable, CaseIterable {
    case link, image, pdf, text, file

    /// The kind of a file, by its extension.
    public init(fileName: String) {
        switch AttachmentKind(path: fileName) {
        case .image: self = .image
        case .pdf: self = .pdf
        default: self = .file
        }
    }
}

/// One thing to save. Files carry their bytes or a path on disk; links their URL and the title the source gave.
public enum CaptureContent: Sendable, Equatable {
    case link(url: String, title: String?)
    case text(String)
    case file(name: String, contents: AttachmentContents)

    public var kind: CaptureKind {
        switch self {
        case .link: .link
        case .text: .text
        case .file(let name, _): CaptureKind(fileName: name)
        }
    }

    /// The title to start with, before the page or the agent gives a better one.
    public func provisionalTitle(now: Date = Date()) -> String {
        switch self {
        case let .link(url, title):
            if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { return title }
            return URL(string: url)?.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? url
        case .text(let text):
            let line = text.split(whereSeparator: \.isNewline).lazy
                .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
            if line.isEmpty { return "Note \(CaptureContent.stamp(now))" }
            return line.count > 60 ? String(line.prefix(59)) + "…" : line
        case .file(let name, _):
            let base = (name as NSString).deletingPathExtension
            // Screenshots and pasted pictures come with a meaningless name.
            if base.isEmpty || base.lowercased().hasPrefix("image") || base.lowercased() == "pasted" {
                return "Image \(CaptureContent.stamp(now))"
            }
            return base
        }
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return formatter.string(from: date)
    }
}

/// Where a capture went. Returned by `capture.add` and shown in the pill.
public struct CaptureOutcome: Codable, Sendable, Equatable {
    /// The note, vault-relative.
    public var path: String
    public var title: String
    public var kind: CaptureKind
    /// True when the item was already saved: `path` is the existing note, nothing new was written.
    public var duplicate: Bool
    /// Files imported for it (the attachment, its cover), for Undo.
    public var files: [String]

    public init(path: String, title: String, kind: CaptureKind, duplicate: Bool, files: [String] = []) {
        self.path = path
        self.title = title
        self.kind = kind
        self.duplicate = duplicate
        self.files = files
    }
}

public enum CaptureError: Error, LocalizedError, Equatable {
    case empty
    case tooLarge(bytes: Int)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .empty: "Nothing to save."
        case .tooLarge(let bytes): "\(bytes / 1_000_000) MB is over the \(CaptureStore.maxBytes / 1_000_000) MB limit."
        case .unsupported(let what): "Loam can't capture this yet (\(what))."
        }
    }
}
