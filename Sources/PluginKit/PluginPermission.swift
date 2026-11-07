import Foundation

/// What a plugin says it does, in words a user can judge before enabling it. See docs/PERMISSIONS.md.
///
/// Permissions are declared and shown, not enforced: a plugin runs in the app's process with the app's access. The
/// list exists for informed consent, and so a catalog can later check that a plugin's code matches what it declares.
public enum PluginPermission: String, Codable, CaseIterable, Sendable {
    case vaultRead = "vault.read"
    case vaultWrite = "vault.write"
    /// Files outside the open vault (an importer reading another folder).
    case diskRead = "disk.read"
    /// A program on the same Mac, over a local socket or port (a search daemon).
    case localService = "local-service"
    case network
    case shell
    case audio
    case clipboard
    case ui

    /// One short sentence a user can judge.
    public var summary: String {
        switch self {
        case .vaultRead: return "Read your notes"
        case .vaultWrite: return "Change your notes"
        case .diskRead: return "Read files outside this vault"
        case .localService: return "Talk to programs running on your Mac"
        case .network: return "Talk to servers on the internet"
        case .shell: return "Run programs on your Mac"
        case .audio: return "Record or play sound"
        case .clipboard: return "Read and change the clipboard"
        case .ui: return "Add views, panels and commands to the window"
        }
    }

    public var risk: PermissionRisk {
        switch self {
        case .vaultRead, .ui: return .low
        case .vaultWrite, .diskRead, .localService, .audio, .clipboard: return .medium
        case .network, .shell: return .high
        }
    }
}

/// How much harm a permission allows if the plugin misbehaves.
public enum PermissionRisk: Int, Comparable, Sendable {
    case low
    case medium
    case high

    public static func < (lhs: PermissionRisk, rhs: PermissionRisk) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One entry of a manifest's `permissions`, as written: a known permission, or a string this app does not know,
/// which is kept, shown as "Unknown permission: …" and treated as high risk (it may come from a newer SDK).
/// Frozen: a declared permission is known or not, nothing else.
@frozen
public enum DeclaredPermission: Hashable, Sendable, Codable, Identifiable {
    case known(PluginPermission)
    case unknown(String)

    public init(_ rawValue: String) {
        self = PluginPermission(rawValue: rawValue).map(DeclaredPermission.known) ?? .unknown(rawValue)
    }

    public init(from decoder: Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var rawValue: String {
        switch self {
        case .known(let permission): return permission.rawValue
        case .unknown(let value): return value
        }
    }

    public var id: String { rawValue }

    public var summary: String {
        switch self {
        case .known(let permission): return permission.summary
        case .unknown(let value): return "Unknown permission: \(value)"
        }
    }

    public var risk: PermissionRisk {
        switch self {
        case .known(let permission): return permission.risk
        case .unknown: return .high
        }
    }

    /// `permissions` strings as declared, without duplicates, riskiest first, then in the vocabulary's order.
    public static func list(_ rawValues: [String]) -> [DeclaredPermission] {
        var seen: Set<String> = []
        let order = Dictionary(uniqueKeysWithValues: PluginPermission.allCases.enumerated().map { ($1.rawValue, $0) })
        return rawValues.filter { seen.insert($0).inserted }.map(DeclaredPermission.init).sorted { a, b in
            if a.risk != b.risk { return a.risk > b.risk }
            return (order[a.rawValue] ?? Int.max, a.rawValue) < (order[b.rawValue] ?? Int.max, b.rawValue)
        }
    }
}
