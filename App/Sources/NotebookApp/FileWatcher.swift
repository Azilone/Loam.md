import CoreServices
import Foundation

/// Calls `onChange` on the main thread when anything changes under a folder (FSEvents), at most every `latency`.
/// Changes inside a `.git` folder or under `.loam/cache` are not reported: a git command writes there many times, the
/// app saves its own layout and scroll positions in the cache, and nothing under a hidden folder reaches the vault's
/// index anyway. Other `.loam` files (the config, the themes) are still reported.
@MainActor
public final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: @MainActor () -> Void

    public init(url: URL, latency: TimeInterval = 0.3, onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            guard FileWatcher.shouldNotify(paths: list, flags: Array(UnsafeBufferPointer(start: flags, count: count)))
            else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.onChange() }
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes
        )
        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    /// Whether a batch of events is worth a refresh: yes unless every path is inside a `.git` folder or `.loam/cache`.
    /// Always yes when
    /// FSEvents lost events or the watched folder itself changed, since the paths then say nothing.
    nonisolated static func shouldNotify(paths: [String], flags: [FSEventStreamEventFlags]) -> Bool {
        let rescan = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged
        )
        if paths.isEmpty || flags.contains(where: { $0 & rescan != 0 }) { return true }
        return paths.contains { !isIgnored($0) }
    }

    nonisolated private static func isIgnored(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        if parts.contains(".git") { return true }
        guard let loam = parts.lastIndex(of: ".loam"), loam + 1 < parts.count else { return false }
        return parts[loam + 1] == "cache"
    }

    /// The stream calls back with an unretained pointer to the watcher, so it must stop before the watcher goes.
    isolated deinit {
        stop()
    }

    /// Stops watching. Safe to call more than once.
    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
