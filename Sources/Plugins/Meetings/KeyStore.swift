import Foundation
#if canImport(Security)
import Security
#endif

/// The OpenRouter and Claude API keys of this device. On a Mac they are in the login Keychain ("Loam OpenRouter key",
/// "Loam Claude API key"), never in the vault or its settings, which may be synced; the environment
/// (`OPENROUTER_API_KEY`, `ANTHROPIC_API_KEY`) is read when the Keychain has none, for the command line and Linux.
public struct DeviceKeys: MeetingKeys {
    public enum Provider: String, Sendable, CaseIterable {
        case openRouter = "openrouter"
        case anthropic

        var service: String { self == .openRouter ? "Loam OpenRouter key" : "Loam Claude API key" }
        /// The name before the app was called Loam: a key saved then is still read.
        var legacyService: String { self == .openRouter ? "Faro OpenRouter key" : "Faro Claude API key" }
        var environment: String { self == .openRouter ? "OPENROUTER_API_KEY" : "ANTHROPIC_API_KEY" }
    }

    public init() {}

    public func openRouterKey() -> String? { key(.openRouter) }
    public func anthropicKey() -> String? { key(.anthropic) }

    public func key(_ provider: Provider) -> String? {
        if let stored = Self.load(provider), !stored.isEmpty { return stored }
        let value = ProcessInfo.processInfo.environment[provider.environment]?.trimmed ?? ""
        return value.isEmpty ? nil : value
    }

    /// Saves a key, or removes it when `value` is empty.
    public func set(_ provider: Provider, _ value: String) throws {
        #if canImport(Security)
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: provider.service,
            kSecAttrAccount as String: "default",
        ]
        SecItemDelete(identity as CFDictionary)
        guard !value.isEmpty else { return }
        var item = identity
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrLabel as String] = provider.service
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AIError("Could not save the key in the Keychain (error \(status)).", status: 0)
        }
        #else
        throw AIError("No Keychain here: set \(provider.environment) in the environment.", status: 0)
        #endif
    }

    static func load(_ provider: Provider) -> String? {
        #if canImport(Security)
        // An agent's test instance (scripts/agent-run.sh) has its own bundle id: reading the user's key would ask for
        // the login Keychain password on every start. It uses the environment instead.
        guard ProcessInfo.processInfo.environment["LOAM_INSTANCE"] == nil else { return nil }
        // Tests never read the user's key either: each test run would ask for the login Keychain password.
        guard NSClassFromString("XCTestCase") == nil else { return nil }
        return load(service: provider.service) ?? load(service: provider.legacyService)
        #else
        return nil
        #endif
    }

    #if canImport(Security)
    private static func load(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "default",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
    #endif
}
