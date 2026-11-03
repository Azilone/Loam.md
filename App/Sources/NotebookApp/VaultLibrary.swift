import Foundation
import Observation

/// The vaults this Mac has opened, the latest first, kept in the app's defaults: it is about every vault, so none
/// of them holds it. The vault switcher and Settings > Vaults list it.
@MainActor
@Observable
public final class VaultLibrary {
    /// A vault of the list.
    public struct Entry: Identifiable, Equatable, Sendable {
        public let url: URL
        public var id: String { url.path }
        public var name: String { url.lastPathComponent }
    }

    static let key = "knownVaults"
    /// How many vaults the list keeps.
    static let limit = 30

    @ObservationIgnored private let defaults: UserDefaults
    private var paths: [String]

    /// Starts from the saved list, plus the last vault of the versions that kept only that one.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var paths = defaults.stringArray(forKey: Self.key) ?? []
        if let last = defaults.string(forKey: AppModel.lastVaultKey), !paths.contains(last) { paths.append(last) }
        self.paths = paths
    }

    /// The vaults whose folder is still there (a deleted or unmounted one is skipped, not forgotten).
    public var entries: [Entry] {
        paths.filter { Self.isFolder($0) }.map { Entry(url: URL(fileURLWithPath: $0, isDirectory: true)) }
    }

    /// Puts the vault first, as the one opened last.
    public func remember(_ url: URL) {
        let path = Self.path(of: url)
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        if paths.count > Self.limit { paths.removeLast(paths.count - Self.limit) }
        save()
    }

    /// Takes the vault off the list; its folder is left alone.
    public func forget(_ url: URL) {
        let path = Self.path(of: url)
        paths.removeAll { $0 == path }
        save()
    }

    private func save() {
        defaults.set(paths, forKey: Self.key)
    }

    static func path(of url: URL) -> String {
        url.standardizedFileURL.path
    }

    static func isFolder(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// True for a name that makes one folder: not empty, no separator, not "." or "..".
    static func isValidName(_ name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains(":")
    }
}
