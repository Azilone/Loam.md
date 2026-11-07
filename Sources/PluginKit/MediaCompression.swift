import Foundation

/// Turns a PDF into one made of JPEG pages. The Media compression plugin needs it for PDFs and cannot draw one
/// itself (its logic builds on Linux, PDFKit does not), so the app's UI side provides it.
public protocol PDFRasterizing: AnyObject, Sendable {
    /// Writes to `output` a PDF with the pages of `input` as JPEG pictures of `dpi` dots per inch and `jpegQuality`
    /// (1 to 100), at the pages' size. The text of the original is gone from the result. Throws when `input` cannot
    /// be read or drawn.
    func rasterize(_ input: URL, to output: URL, dpi: Int, jpegQuality: Int) async throws
}

public extension ServiceKey where Service == PDFRasterizing {
    static var pdfRasterizer: ServiceKey<PDFRasterizing> { ServiceKey<PDFRasterizing>("pdf-rasterizer") }
}

/// What optimizing one file did.
public struct MediaOptimization: Codable, Sendable, Equatable {
    public enum Outcome: String, Codable, Sendable {
        /// The file was replaced by a smaller one.
        case optimized
        /// Left as it is: already small or compact, too little gain, a kind that is off, or an excluded folder.
        case skipped
    }

    public let outcome: Outcome
    /// Where the file is now (the new name when its extension changed).
    public let path: String
    /// Bytes before and after; equal when skipped.
    public let before: Int
    public let after: Int
    /// Why it was left alone, when skipped.
    public let reason: String?

    public init(outcome: Outcome, path: String, before: Int, after: Int, reason: String? = nil) {
        self.outcome = outcome
        self.path = path
        self.before = before
        self.after = after
        self.reason = reason
    }

    public var saved: Int { before - after }
}

/// What `MediaCompressionService.optimizeVault` did.
public struct MediaBatchReport: Codable, Sendable, Equatable {
    /// Files looked at.
    public var analysed = 0
    public var optimized = 0
    /// Files that failed (a tool missing, a conversion that errored); they were left as they were.
    public var failed = 0
    public var bytesSaved = 0

    public init(analysed: Int = 0, optimized: Int = 0, failed: Int = 0, bytesSaved: Int = 0) {
        self.analysed = analysed
        self.optimized = optimized
        self.failed = failed
        self.bytesSaved = bytesSaved
    }
}

/// A media file in the vault that optimizing would look at.
public struct MediaCandidate: Codable, Sendable, Equatable {
    public let path: String
    public let kind: AttachmentKind
    /// In bytes.
    public let size: Int

    public init(path: String, kind: AttachmentKind, size: Int) {
        self.path = path
        self.kind = kind
        self.size = size
    }
}

/// The `media-compression` service, provided by the Media compression plugin: it shrinks images, sounds, videos and
/// PDFs, on the way into the vault (through the `attachments` service) and on demand. Work runs off the main thread,
/// one heavy file (video, PDF) at a time.
public protocol MediaCompressionService: AnyObject, Sendable {
    /// The media files in the vault (outside dot folders and the excluded folders) whose kind is switched on.
    func candidates() throws -> [MediaCandidate]
    /// Whether replaced originals go to `.trash/` (the plugin's setting), for the confirmation text.
    var keepsOriginals: Bool { get }
    /// Optimizes the file at `path` now, whatever its size; replaces it only when that gains enough (see the plugin's
    /// docs). The original goes to `.trash/` when the setting says so. Throws when a tool is missing or fails.
    func optimize(_ path: String) async throws -> MediaOptimization
    /// Optimizes every candidate, one after the other, skipping what is too small; never throws for one file's
    /// failure.
    func optimizeVault() async -> MediaBatchReport
}

public extension ServiceKey where Service == MediaCompressionService {
    static var mediaCompression: ServiceKey<MediaCompressionService> { ServiceKey<MediaCompressionService>("media-compression") }
}

/// Sent on the main thread when the plugin starts on a slow file that just arrived (a video, a PDF), so the app can
/// say so.
public struct MediaOptimizationStarted: PluginEvent, Sendable, Equatable {
    public let path: String

    public init(path: String) {
        self.path = path
    }
}

/// Sent on the main thread after a file that just arrived in the vault was replaced by a smaller one. `path` is the
/// vault path, or only the file name when the file is not written yet (an image optimized on its way in). The
/// service's own calls (`optimize`, `optimizeVault`) do not send it: they return what they did.
public struct MediaOptimized: PluginEvent, Sendable, Equatable {
    public let path: String
    public let before: Int
    public let after: Int

    public init(path: String, before: Int, after: Int) {
        self.path = path
        self.before = before
        self.after = after
    }
}

/// Sent on the main thread after each file of `optimizeVault`, and before the first, so the app can show progress.
public struct MediaBatchProgress: PluginEvent, Sendable, Equatable {
    /// Files done, out of `total`; `current` is the one starting now (nil at the end).
    public let done: Int
    public let total: Int
    public let current: String?

    public init(done: Int, total: Int, current: String?) {
        self.done = done
        self.total = total
        self.current = current
    }
}

/// Sent on the main thread when optimizing a file failed; the file stays as it was. A missing tool is reported once
/// per run of the app, with `tool` set.
public struct MediaOptimizationFailed: PluginEvent, Sendable, Equatable {
    public let path: String
    public let message: String
    public let tool: String?

    public init(path: String, message: String, tool: String? = nil) {
        self.path = path
        self.message = message
        self.tool = tool
    }
}
