import Foundation
import PluginKit

/// The files Loam already optimized, so "optimize all media" does not encode a lossy video or sound a second time (an
/// H.264 or AAC file has no marker of its own, and every pass would degrade it a little more). A file is known by its
/// size and a checksum of its first and last bytes, not by its path, so it is still known after a move or a rename.
/// Kept in `.loam/squeeze-optimized.json`; a file edited by another program no longer matches and is looked at again.
final class OptimizedLedger: @unchecked Sendable {
    static let path = ".loam/squeeze-optimized.json"

    private let vault: VaultAccess
    private let lock = NSLock()
    private var keys: Set<String>?

    init(vault: VaultAccess) {
        self.vault = vault
    }

    func contains(_ url: URL) -> Bool {
        guard let key = Self.fingerprint(of: url) else { return false }
        lock.lock()
        defer { lock.unlock() }
        return load().contains(key)
    }

    func insert(_ url: URL) {
        guard let key = Self.fingerprint(of: url) else { return }
        lock.lock()
        defer { lock.unlock() }
        var known = load()
        guard known.insert(key).inserted else { return }
        keys = known
        if let data = try? JSONEncoder().encode(known.sorted()), let text = String(data: data, encoding: .utf8) {
            try? vault.write(Self.path, text)
        }
    }

    private func load() -> Set<String> {
        if let keys { return keys }
        var loaded: Set<String> = []
        if vault.exists(Self.path), let text = try? vault.read(Self.path),
           let list = try? JSONDecoder().decode([String].self, from: Data(text.utf8)) {
            loaded = Set(list)
        }
        keys = loaded
        return loaded
    }

    /// `size-checksum` of the file, nil when it cannot be read.
    static func fingerprint(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url), let size = try? handle.seekToEnd() else { return nil }
        defer { try? handle.close() }
        let window: UInt64 = 64 * 1024
        var hash: UInt64 = 14_695_981_039_346_656_037
        func feed(_ data: Data) {
            for byte in data {
                hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
            }
        }
        try? handle.seek(toOffset: 0)
        feed((try? handle.read(upToCount: Int(window))) ?? Data())
        if size > window {
            try? handle.seek(toOffset: size - min(window, size - window))
            feed((try? handle.read(upToCount: Int(window))) ?? Data())
        }
        return "\(size)-\(String(hash, radix: 16))"
    }
}
