#if canImport(Security)
import Foundation
import Security

/// Keys in the user's login Keychain, one generic password per key ("Loam vault key", account = the key id). They
/// stay on this Mac: each device gets the key once (`sync.key.import`).
struct KeychainKeyStore: VaultKeyStore {
    static let service = "Loam vault key"

    func load(id: String) throws -> VaultKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: id,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Self.error("read", status) }
        guard let data = result as? Data, let key = VaultKey(exported: String(decoding: data, as: UTF8.self)),
              key.id == id else {
            throw KeyStoreError(message: "The Keychain item \"\(Self.service)\" \(id) is damaged.")
        }
        return key
    }

    func save(_ key: VaultKey) throws {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key.id,
        ]
        let secret = Data(key.exported.utf8)
        var item = identity
        item[kSecValueData as String] = secret
        item[kSecAttrLabel as String] = "\(Self.service) \(key.id)"
        item[kSecAttrDescription as String] = "Encrypts a Loam vault's git sync"
        var status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(identity as CFDictionary, [kSecValueData as String: secret] as CFDictionary)
        }
        guard status == errSecSuccess else { throw Self.error("save", status) }
    }

    private static func error(_ verb: String, _ status: OSStatus) -> KeyStoreError {
        let reason = SecCopyErrorMessageString(status, nil).map { $0 as String } ?? "error \(status)"
        return KeyStoreError(message: "Could not \(verb) the vault key in the Keychain: \(reason).")
    }
}
#endif
