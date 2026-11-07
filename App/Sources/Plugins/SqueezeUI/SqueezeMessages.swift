import Foundation
import PluginKit

/// The sentences the plugin shows, apart from the views so they can be checked.
enum SqueezeMessages {
    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    static func name(_ path: String) -> String { (path as NSString).lastPathComponent }

    static func optimized(_ path: String, before: Int, after: Int) -> String {
        "Optimized \(name(path)): \(bytes(before)) to \(bytes(after))"
    }

    static func started(_ path: String) -> String {
        "Optimizing \(name(path)) in the background"
    }

    static func progress(_ progress: MediaBatchProgress) -> String? {
        guard progress.done < progress.total, let current = progress.current else { return nil }
        return "Optimizing media: \(progress.done + 1) of \(progress.total), \(name(current))"
    }

    static func failed(_ failure: MediaOptimizationFailed) -> String {
        if failure.tool != nil { return failure.message + " The file was kept as it is." }
        return "Could not optimize \(name(failure.path)): \(failure.message)"
    }

    static func single(_ result: MediaOptimization) -> String {
        switch result.outcome {
        case .optimized: optimized(result.path, before: result.before, after: result.after)
        case .skipped: "\(name(result.path)) left as it is: \(result.reason ?? "nothing to gain")"
        @unknown default: "\(name(result.path)) left as it is"
        }
    }

    static func batch(_ report: MediaBatchReport) -> String {
        if report.analysed == 0 { return "No media to optimize." }
        var text = report.optimized == 0
            ? "Nothing to gain in \(report.analysed) files."
            : "Saved \(bytes(report.bytesSaved)) across \(report.optimized) of \(report.analysed) files."
        if report.failed > 0 { text += " \(report.failed) failed and were kept as they were." }
        return text
    }

    static func confirmation(files: Int, bytes total: Int, keepsOriginals: Bool) -> String {
        "\(files) media files (\(bytes(total))) will be looked at, and replaced by a smaller version when that saves enough. "
            + (keepsOriginals ? "Originals go to the vault's .trash folder." : "Originals are replaced without a copy.")
            + " PDFs keep only their pictures. This can take a while."
    }
}
