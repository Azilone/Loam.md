import Foundation

/// Asked, as a waterfall, by a file browser before it sorts a folder: a plugin that owns a folder says how its
/// children are ordered (the daily notes newest first). The order of a folder applies to its children and, unless a
/// folder below it gives its own, to the folders under it too. Folders stay before files, and a row the user put in
/// place by hand keeps its place.
public struct FolderOrder: PluginEvent, Sendable, Equatable {
    /// How a folder's children are listed.
    public enum Order: Sendable, Equatable {
        /// By name, A to Z: how the disk lists them.
        case nameAscending
        /// By name, Z to A: for names that start with a day (`2026-11-08`), the newest first.
        case nameDescending
    }

    /// Vault-relative folder paths (empty for the vault's root) to the order of their children.
    public var orders: [String: Order]

    public init(orders: [String: Order] = [:]) {
        self.orders = orders
    }

    /// The order for the children of `folder`: its own, else the one of the closest folder above it that gave one,
    /// else `nameAscending`.
    public func order(for folder: String) -> Order {
        var path = folder
        while true {
            if let order = orders[path] { return order }
            guard let slash = path.lastIndex(of: "/") else { return orders[""] ?? .nameAscending }
            path = String(path[..<slash])
        }
    }
}

/// Sent when a plugin's answer to `FolderOrder` changed (its folder setting), so a browser sorts again.
public struct FolderOrderChanged: PluginEvent, Sendable, Equatable {
    public init() {}
}
