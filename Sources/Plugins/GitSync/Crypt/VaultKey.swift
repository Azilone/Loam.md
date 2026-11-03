import Crypto
import Foundation

/// A vault's encryption key: 32 random bytes, the same on every device that syncs the vault. Only a key store (the
/// Keychain) and the environment of the git commands the sync runs ever hold it: never the vault, never its settings.
/// Immutable; `SymmetricKey` is only missing its `Sendable` mark on Linux.
public struct VaultKey: @unchecked Sendable {
    public let bytes: Data
    /// 16 hex digits derived from the key. It names the key in the Keychain, in `.gitattributes` and in every
    /// encrypted file, and says nothing about the key itself.
    public let id: String
    /// AES-256-GCM-SIV.
    let encryption: SymmetricKey
    /// HMAC-SHA256 of the plaintext, for the nonce.
    let nonce: SymmetricKey

    static let byteCount = 32
    private static let exportPrefix = "loam-key:"

    public init?(bytes: Data) {
        guard bytes.count == Self.byteCount else { return nil }
        self.bytes = bytes
        let master = SymmetricKey(data: bytes)
        func derive(_ info: String, _ count: Int) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: master, salt: Data("loam-crypt".utf8), info: Data(info.utf8),
                                   outputByteCount: count)
        }
        encryption = derive("encryption", 32)
        nonce = derive("nonce", 32)
        id = derive("key id", 8).withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() }
    }

    /// A new random key.
    public static func generate() -> VaultKey {
        let random = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        return VaultKey(bytes: random)!
    }

    /// `loam-key:<base64url>`, what `sync.key.export` gives and `sync.key.import` takes.
    public var exported: String {
        let base64 = bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return Self.exportPrefix + base64
    }

    /// Reads `exported`, ignoring spaces and line breaks around it (a pasted key).
    public init?(exported text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(Self.exportPrefix) else { return nil }
        var base64 = String(trimmed.dropFirst(Self.exportPrefix.count))
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let bytes = Data(base64Encoded: base64) else { return nil }
        self.init(bytes: bytes)
    }
}

extension VaultKey: Equatable {
    public static func == (a: VaultKey, b: VaultKey) -> Bool { a.bytes == b.bytes }
}
