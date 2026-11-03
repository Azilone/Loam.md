import Foundation
import PluginKit

public enum NoteGraphError: Error, Equatable {
    case notMarkdown(path: String)
    /// A folder cannot move into itself or one of its subfolders.
    case moveIntoItself(path: String)
    /// Two moves overlap: one source is inside another, or two files would land on one path.
    case conflictingMoves(path: String)
}

/// The `notes.rename` output, kept as it was before folder moves existed.
public struct RenameResult: Codable, Equatable {
    public let from: String
    public let to: String
    /// Paths (after the move) of every note whose text changed.
    public let updated: [String]
}

public final class NoteGraphIndex: NoteGraphService, NoteGraphLoading {
    let vault: VaultAccess
    let willMove: ([String: String]) -> Void
    let didMove: ([String: String]) -> Void
    private var infos: [String: NoteInfo] = [:]
    private var incoming: [String: [String]] = [:]
    /// False while `loadInBackground` reads the vault: readers wait for it, vault changes queue in `pending`.
    private var loaded = true
    private var pending: [VaultChange] = []
    private let loading = NSCondition()

    /// `willMove` and `didMove` get every file move, folders expanded: the plugin turns them into
    /// `NotesWillMove` and `NotesMoved` events.
    public init(
        vault: VaultAccess,
        willMove: @escaping ([String: String]) -> Void = { _ in },
        didMove: @escaping ([String: String]) -> Void = { _ in }
    ) {
        self.vault = vault
        self.willMove = willMove
        self.didMove = didMove
    }

    public var notes: [NoteInfo] {
        waitUntilLoaded()
        return infos.values.sorted { $0.path < $1.path }
    }

    public func note(at path: String) -> NoteInfo? {
        waitUntilLoaded()
        return infos[path]
    }

    public func backlinks(to path: String) -> [String] {
        waitUntilLoaded()
        return incoming[path] ?? []
    }

    public func notes(tagged tag: String) -> [NoteInfo] {
        waitUntilLoaded()
        let wanted = tag.hasPrefix("#") ? String(tag.dropFirst()) : tag
        // Filtered before sorting: sorting every note took most of the time.
        return infos.values
            .filter { $0.tags.contains { $0.caseInsensitiveCompare(wanted) == .orderedSame } }
            .sorted { $0.path < $1.path }
    }

    public func reindex() throws {
        waitUntilLoaded()
        (infos, incoming) = try Self.build(from: vault)
    }

    /// Builds the graph on a background queue, so a large vault does not hold the launch: the window shows
    /// while the notes are read. Readers that come before the end wait for it. The changes that came meanwhile, then
    /// `completion`, run on the main thread, where the kernel's events go.
    public func loadInBackground(completion: @escaping () -> Void) {
        loading.lock()
        loaded = false
        loading.unlock()
        let vault = vault
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let built = try? Self.build(from: vault)
            // Queued first, so whoever sees `isLoaded` and then queues its own work finds this done before it.
            DispatchQueue.main.async { [self] in
                waitUntilLoaded()
                completion()
            }
            loading.lock()
            (infos, incoming) = built ?? ([:], [:])
            loaded = true
            loading.broadcast()
            loading.unlock()
        }
    }

    public var isLoaded: Bool {
        loading.lock()
        defer { loading.unlock() }
        return loaded
    }

    /// Also applies the changes queued while loading when called on the main thread, where changes apply: a process
    /// that never runs its main queue (the `loam` command) would otherwise miss them.
    private func waitUntilLoaded() {
        loading.lock()
        while !loaded { loading.wait() }
        let queued = Thread.isMainThread ? pending : []
        if !queued.isEmpty { pending = [] }
        loading.unlock()
        if !queued.isEmpty { apply(queued) }
    }

    private static func build(from vault: VaultAccess) throws -> ([String: NoteInfo], [String: [String]]) {
        // Read and parsed on every core: each note is on its own, and this is the launch's longest work.
        let paths = try vault.markdownPaths()
        var parsed = [Result<NoteInfo, Error>?](repeating: nil, count: paths.count)
        parsed.withUnsafeMutableBufferPointer { results in
            nonisolated(unsafe) let results = results
            DispatchQueue.concurrentPerform(iterations: paths.count) { index in
                let path = paths[index]
                results[index] = Result { NoteParser.parse(path: path, text: try vault.read(path)) }
            }
        }
        var infos: [String: NoteInfo] = [:]
        infos.reserveCapacity(paths.count)
        for (path, result) in zip(paths, parsed) { infos[path] = try result!.get() }
        return (infos, incoming(of: infos))
    }

    /// Updates the graph for the notes that changed, without rereading the others. Other files are skipped.
    public func apply(_ changes: [VaultChange]) {
        let changes = changes.filter(\.isNote)
        guard !changes.isEmpty else { return }
        loading.lock()
        if !loaded {
            pending += changes
            loading.unlock()
            return
        }
        loading.unlock()
        for change in changes {
            let path = change.path
            removeIncoming(of: path)
            if change.kind != .removed, let text = try? vault.read(path) {
                infos[path] = NoteParser.parse(path: path, text: text)
                addIncoming(of: path)
            } else {
                infos[path] = nil
            }
        }
    }

    /// Takes the links of the note at `path` out of `incoming`, before the note changes.
    private func removeIncoming(of path: String) {
        guard let info = infos[path] else { return }
        for target in Set(info.links.map(\.target)) where target != path {
            incoming[target]?.removeAll { $0 == path }
            if incoming[target]?.isEmpty == true { incoming[target] = nil }
        }
    }

    /// Adds the links of the note at `path` to `incoming`, each list kept sorted as `incoming(of:)` makes it.
    private func addIncoming(of path: String) {
        guard let info = infos[path] else { return }
        for target in Set(info.links.map(\.target)) where target != path {
            var sources = incoming[target, default: []]
            let index = sources.firstIndex { $0 >= path } ?? sources.endIndex
            if index == sources.endIndex || sources[index] != path { sources.insert(path, at: index) }
            incoming[target] = sources
        }
    }

    private static func incoming(of infos: [String: NoteInfo]) -> [String: [String]] {
        var incoming: [String: [String]] = [:]
        for path in infos.keys.sorted() {
            for link in infos[path]!.links where link.target != path {
                if incoming[link.target, default: []].last != path { incoming[link.target, default: []].append(path) }
            }
        }
        return incoming
    }

    /// Moves a note and rewrites every link to it, plus the relative links inside it.
    public func rename(from: String, to: String) throws -> RenameResult {
        let from = try VaultPath.normalize(from)
        let to = try VaultPath.normalize(to)
        guard note(at: from) != nil else { throw VaultError.notFound(path: from) }
        let result = try move([from: to])
        return RenameResult(from: from, to: to, updated: result.updated)
    }
}
