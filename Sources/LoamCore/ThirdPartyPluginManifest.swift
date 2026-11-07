import Foundation
import PluginKit

/// `.loam/plugins/<id>/plugin.json`: what the app knows about a third-party plugin before loading any of its code.
///
///     { "id": "hello", "name": "Hello", "version": "0.1.0", "library": "HelloPlugin", "permissions": ["vault.read"],
///       "description": "Says hello.", "icon": "hand.wave", "iconFile": "icon.png" }
///
/// `library` names the compiled library in `.loam/cache/plugins/<id>/` (`libHelloPlugin.dylib`, `.so` on Linux).
/// `permissions` are stored as written; `declaredPermissions` reads them with the `PluginPermission` vocabulary (an
/// unknown string is kept as `.unknown`), and the plugin manager shows them before the user enables the plugin.
/// `description`, `icon` (an SF Symbol name) and `iconFile` (an image in the plugin's folder, drawn instead of the
/// symbol when it can be read) are optional: Settings > Plugins shows them before the plugin's code is ever loaded.
/// `minSDK` (`"1.12"`) is the oldest plugin SDK the plugin builds against: an update that needs a newer app is refused
/// before anything changes.
public struct ThirdPartyPluginManifest: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var version: String
    public var library: String
    public var permissions: [String]
    public var description: String?
    public var icon: String?
    /// A path relative to the plugin's folder (`icon.png`); one that leaves the folder is ignored.
    public var iconFile: String?
    public var minSDK: String?

    public init(
        id: String, name: String, version: String, library: String, permissions: [String] = [],
        description: String? = nil, icon: String? = nil, iconFile: String? = nil, minSDK: String? = nil
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.library = library
        self.permissions = permissions
        self.description = description
        self.icon = icon
        self.iconFile = iconFile
        self.minSDK = minSDK
    }

    /// `minSDK` read as a version; nil when there is none or it cannot be read.
    public var requiredSDK: PluginSDKVersion? { minSDK.flatMap(PluginSDKVersion.parse) }

    /// `iconFile` inside `folder`, the plugin's folder; nil when there is none or it would leave the folder.
    public func iconFileURL(in folder: URL) -> URL? {
        guard let iconFile, !iconFile.isEmpty, !iconFile.hasPrefix("/"), !iconFile.hasPrefix("~") else { return nil }
        let parts = iconFile.split(separator: "/")
        guard !parts.contains(".."), !parts.isEmpty else { return nil }
        return parts.reduce(folder) { $0.appendingPathComponent(String($1)) }
    }

    /// `permissions` as the vocabulary knows them, riskiest first; unknown strings are kept, as high risk.
    public var declaredPermissions: [DeclaredPermission] { DeclaredPermission.list(permissions) }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decode(String.self, forKey: .version)
        library = try container.decode(String.self, forKey: .library)
        permissions = try container.decodeIfPresent([String].self, forKey: .permissions) ?? []
        description = (try? container.decodeIfPresent(String.self, forKey: .description)) ?? nil
        icon = (try? container.decodeIfPresent(String.self, forKey: .icon)) ?? nil
        iconFile = (try? container.decodeIfPresent(String.self, forKey: .iconFile)) ?? nil
        minSDK = (try? container.decodeIfPresent(String.self, forKey: .minSDK)) ?? nil
    }

    /// Why this manifest cannot be used from the folder `folderName`, nil when it can. The id names folders and the
    /// library names a file, so both are restricted to characters that cannot leave their folder.
    func problem(folderName: String) -> String? {
        if id.isEmpty || !id.allSatisfy(Self.isIDCharacter) || id.first == "." {
            return "plugin.json: \"id\" must be lowercase letters, digits, \"-\" and \".\""
        }
        if id != folderName {
            return "plugin.json: \"id\" is \"\(id)\" but the folder is \"\(folderName)\""
        }
        if library.isEmpty || !library.allSatisfy(Self.isLibraryCharacter) {
            return "plugin.json: \"library\" must be a product name (letters, digits, \"_\")"
        }
        return nil
    }

    private static func isIDCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLowercase || character.isNumber || character == "-" || character == ".")
    }

    private static func isLibraryCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || character == "_")
    }
}
