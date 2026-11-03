import Foundation

/// Static description of a plugin. Plugins depend on services, not on each other:
/// `requires` names services another plugin `provides`, so any plugin can be replaced.
public struct PluginManifest: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let version: String
    /// What the plugin does, in one line, under its name in Settings > Plugins.
    public let description: String
    /// An SF Symbol name, drawn as the plugin's icon in Settings > Plugins (`checklist`, `calendar`). Nil, or a name
    /// the system does not know, shows the default icon.
    public let icon: String?
    /// Service ids this plugin registers during `activate`. The host checks that it does.
    public let provides: [String]
    /// Service ids this plugin needs. The host activates the providers first.
    public let requires: [String]
    /// Service ids this plugin uses when they exist. The host activates their providers first when they are
    /// enabled, and restarts this plugin when a provider comes back, so it can register its extras again.
    public let optionalRequires: [String]
    /// What the plugin does that a user should know before enabling it, as `PluginPermission` raw values
    /// (`vault.write`, `network`…). Declared, shown in the plugin manager, not enforced: see docs/PERMISSIONS.md.
    public let permissions: [String]
    /// Titles and help for the plugin's settings, in the order its page in Settings shows them. Optional: every
    /// setting the plugin reads with `context.settings.value(default:)` is shown anyway, named after its key.
    public let settings: [SettingDescription]

    public init(
        id: String,
        name: String,
        version: String,
        description: String = "",
        icon: String? = nil,
        provides: [String] = [],
        requires: [String] = [],
        optionalRequires: [String] = [],
        permissions: [String] = [],
        settings: [SettingDescription] = []
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.icon = icon
        self.provides = provides
        self.requires = requires
        self.optionalRequires = optionalRequires
        self.permissions = permissions
        self.settings = settings
    }

    /// `permissions` as the vocabulary knows them, riskiest first; unknown strings are kept.
    public var declaredPermissions: [DeclaredPermission] { DeclaredPermission.list(permissions) }

    private enum CodingKeys: String, CodingKey {
        case id, name, version, description, icon, provides, requires, optionalRequires, permissions, settings
    }

    /// Only `id`, `name` and `version` are required in a manifest file; a missing list is empty.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decode(String.self, forKey: .version)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
        provides = try container.decodeIfPresent([String].self, forKey: .provides) ?? []
        requires = try container.decodeIfPresent([String].self, forKey: .requires) ?? []
        optionalRequires = try container.decodeIfPresent([String].self, forKey: .optionalRequires) ?? []
        permissions = try container.decodeIfPresent([String].self, forKey: .permissions) ?? []
        settings = try container.decodeIfPresent([SettingDescription].self, forKey: .settings) ?? []
    }
}
