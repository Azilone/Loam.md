import Foundation
import PluginKit

/// The `media-compression` service: applies `MediaOptimizer` to files arriving in the vault and to files already in it.
///
/// Thread-safe. Everything slow runs off the main thread, in the caller's task; videos and PDFs, which take seconds
/// to minutes, go one at a time through a lane so several drops never start several encoders at once. Events go out
/// on the main thread, as the event bus expects.
public final class MediaCompressor: MediaCompressionService, @unchecked Sendable {
    private let vault: VaultAccess
    private let settings: () -> SqueezeSettings
    private let attachments: () -> AttachmentsService?
    private let rasterizer: () -> PDFRasterizing?
    private let locate: (String) -> String?
    private let announce: (any PluginEvent) -> Void
    private let lane = Lane()
    private let ledger: OptimizedLedger
    private let lock = NSLock()
    private var reportedTools: Set<String> = []

    /// - Parameters:
    ///   - settings: the plugin's settings now, read at each file.
    ///   - attachments: the `attachments` service, which writes and replaces files.
    ///   - rasterizer: the PDF rasterizer if the app provides one now.
    ///   - locate: the path of an installed tool (`ffmpeg`, `cwebp`), nil when it is missing.
    ///   - announce: sends an event; called on the main thread.
    public init(
        vault: VaultAccess,
        settings: @escaping () -> SqueezeSettings,
        attachments: @escaping () -> AttachmentsService?,
        rasterizer: @escaping () -> PDFRasterizing? = { nil },
        locate: @escaping (String) -> String? = { _ in nil },
        announce: @escaping (any PluginEvent) -> Void = { _ in }
    ) {
        self.vault = vault
        self.settings = settings
        self.attachments = attachments
        self.rasterizer = rasterizer
        self.locate = locate
        self.announce = announce
        self.ledger = OptimizedLedger(vault: vault)
    }

    /// The optimizer for the settings now; an empty tool path is looked up on disk.
    func optimizer() -> MediaOptimizer {
        let current = settings()
        let tools = MediaTools(
            ffmpeg: current.ffmpegPath.isEmpty ? (locate("ffmpeg") ?? "") : current.ffmpegPath,
            cwebp: current.cwebpPath.isEmpty ? (locate("cwebp") ?? "") : current.cwebpPath
        )
        return MediaOptimizer(settings: current, tools: tools, rasterizer: rasterizer())
    }

    // MARK: Service

    public var keepsOriginals: Bool { settings().keepOriginals }

    public func candidates() throws -> [MediaCandidate] {
        let current = settings()
        var found: [MediaCandidate] = []
        func walk(_ folder: String) throws {
            for entry in try vault.list(folder) {
                if current.isExcluded(entry.path) { continue }
                if entry.isFolder { try walk(entry.path); continue }
                guard let family = MediaOptimizer.family(ofExtension: (entry.path as NSString).pathExtension),
                      optimizer().isOn(family) else { continue }
                let size = (try? MediaOptimizer.size(of: vault.rootURL.appendingPathComponent(entry.path))) ?? 0
                found.append(MediaCandidate(path: entry.path, kind: AttachmentKind(path: entry.path), size: size))
            }
        }
        try walk("")
        return found
    }

    public func optimize(_ path: String) async throws -> MediaOptimization {
        try await optimize(path, force: true)
    }

    public func optimizeVault() async -> MediaBatchReport {
        var report = MediaBatchReport()
        let files = (try? candidates()) ?? []
        await send(MediaBatchProgress(done: 0, total: files.count, current: files.first?.path))
        for (index, file) in files.enumerated() {
            report.analysed += 1
            do {
                let result = try await optimize(file.path, force: false)
                if result.outcome == .optimized {
                    report.optimized += 1
                    report.bytesSaved += result.saved
                }
            } catch {
                report.failed += 1
                if let missing = error as? ToolMissing { await reportMissing(missing, path: file.path) }
            }
            let next = index + 1 < files.count ? files[index + 1].path : nil
            await send(MediaBatchProgress(done: index + 1, total: files.count, current: next))
        }
        return report
    }

    // MARK: Files already in the vault

    func optimize(
        _ path: String, force: Bool, started: (@Sendable () async -> Void)? = nil
    ) async throws -> MediaOptimization {
        let path = try VaultPath.normalize(path)
        guard !path.isEmpty, vault.exists(path) else { throw VaultError.notFound(path: path) }
        guard let attachments = attachments() else { throw ToolMissing(tool: "attachments") }
        let name = (path as NSString).lastPathComponent
        let source = vault.rootURL.appendingPathComponent(path)
        let optimizer = optimizer()
        let ledger = ledger
        let heavy = [.video, .pdf].contains(MediaOptimizer.family(ofExtension: (name as NSString).pathExtension))

        let work: @Sendable () async throws -> MediaOptimization = {
            let folder = Self.workFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let optimized: OptimizedFile
            do {
                // Lossy video, sound and PDF output carries no marker: a second pass would only lose quality.
                if !force, ledger.contains(source) { throw Skip.alreadyOptimized }
                optimized = try await optimizer.optimize(source, name: name, force: force, workFolder: folder, started: started)
            } catch let skip as Skip {
                let size = (try? MediaOptimizer.size(of: source)) ?? 0
                return MediaOptimization(outcome: .skipped, path: path, before: size, after: size, reason: skip.reason)
            }
            let replacement = try await attachments.replace(
                path, with: .file(optimized.url), name: optimized.name == name ? nil : optimized.name
            )
            if !self.settings().keepOriginals {
                try? FileManager.default.removeItem(at: self.vault.rootURL.appendingPathComponent(replacement.trashed))
            }
            ledger.insert(self.vault.rootURL.appendingPathComponent(replacement.path))
            return MediaOptimization(outcome: .optimized, path: replacement.path, before: optimized.before, after: optimized.after)
        }
        return heavy ? try await lane.run(work) : try await work()
    }

    // MARK: Files arriving

    /// The attachments processor: images and sounds are made smaller before they are written, so their link has the
    /// final name. Anything it cannot or need not shrink comes out as it went in.
    func process(_ file: AttachmentImport) async -> AttachmentImport {
        let current = settings()
        guard current.optimizeNewFiles,
              let family = MediaOptimizer.family(ofExtension: (file.name as NSString).pathExtension),
              family == .image || family == .audio,
              !current.isExcluded(attachments()?.folder ?? "") else { return file }
        let optimizer = optimizer()
        guard optimizer.isOn(family) else { return file }

        let folder = Self.workFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            let input: URL
            switch file.contents {
            case .file(let url):
                input = url
            case .data(let data):
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                input = folder.appendingPathComponent("original." + (file.name as NSString).pathExtension)
                try data.write(to: input)
            }
            let optimized = try await optimizer.optimize(input, name: file.name, force: false, workFolder: folder)
            let data = try Data(contentsOf: optimized.url)
            // A pasted picture exists nowhere else: the original keeps a copy in the trash when the setting says so.
            if current.keepOriginals, case .data(let original) = file.contents {
                try? keepOriginal(original, named: file.name)
            }
            await send(MediaOptimized(path: optimized.name, before: optimized.before, after: optimized.after))
            return AttachmentImport(name: optimized.name, contents: .data(data), notePath: file.notePath)
        } catch is Skip {
            return file
        } catch {
            await report(error, path: file.name)
            return file
        }
    }

    /// A video or PDF just written into the vault: optimized in the background, then replaced; its links follow.
    func processImported(_ path: String) async {
        let current = settings()
        guard current.optimizeNewFiles, !current.isExcluded(path),
              let family = MediaOptimizer.family(ofExtension: (path as NSString).pathExtension),
              family == .video || family == .pdf, optimizer().isOn(family) else { return }
        do {
            // The message comes once the file is known to need the encoder, not for a small or compact one.
            let result = try await optimize(path, force: false, started: { [self] in await send(MediaOptimizationStarted(path: path)) })
            if result.outcome == .optimized { await send(MediaOptimized(path: result.path, before: result.before, after: result.after)) }
        } catch {
            await report(error, path: path)
        }
    }

    // MARK: Private

    private static func workFolder() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("loam-squeeze", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func keepOriginal(_ data: Data, named name: String) throws {
        var path = ".trash/" + name
        var number = 2
        while vault.exists(path) {
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            path = ".trash/\(base) \(number)" + (ext.isEmpty ? "" : "." + ext)
            number += 1
        }
        try vault.writeData(path, data)
    }

    /// Tells the app a conversion failed; a missing tool only the first time, since every file would say it again.
    private func report(_ error: Error, path: String) async {
        if let missing = error as? ToolMissing {
            await reportMissing(missing, path: path)
        } else {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            await send(MediaOptimizationFailed(path: path, message: message))
        }
    }

    private func reportMissing(_ missing: ToolMissing, path: String) async {
        if firstReport(of: missing.tool) {
            await send(MediaOptimizationFailed(path: path, message: missing.errorDescription ?? "", tool: missing.tool))
        }
    }

    private func firstReport(of tool: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return reportedTools.insert(tool).inserted
    }

    private func send(_ event: any PluginEvent) async {
        let announce = announce
        await MainActor.run { announce(event) }
    }
}

/// Runs jobs one at a time, in the order they ask.
actor Lane {
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ job: @Sendable () async throws -> T) async throws -> T {
        if busy {
            await withCheckedContinuation { waiting.append($0) }
        } else {
            busy = true
        }
        defer {
            if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
        }
        return try await job()
    }
}
