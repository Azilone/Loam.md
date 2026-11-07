import _CryptoExtras
import Crypto
import Foundation

/// Why a file could not be encrypted or decrypted, in words for "Sync needs attention".
public enum CryptError: Error, LocalizedError, Equatable {
    /// This device has no key with this id.
    case missingKey(String)
    /// The file was encrypted with another key than the one given.
    case wrongKey(file: String, given: String)
    /// The encrypted bytes were changed or cut: the authentication failed.
    case damaged
    /// A key id that is not 8 bytes of hex.
    case invalidKeyID(String)

    public var errorDescription: String? {
        switch self {
        case .missingKey(let id):
            return "This device does not have the vault's key (\(id)) yet. On a Mac that syncs it: Settings > Sync > "
                + "Connect another Mac, then paste the code here (or sync.key.import / sync.join)."
        case .wrongKey(let file, let given):
            return "This file was encrypted with the key \(file), not \(given)."
        case .damaged:
            return "An encrypted file is damaged: its bytes do not match its authentication tag."
        case .invalidKeyID(let id):
            return "The key id \(id) is not valid."
        }
    }
}

/// How a file looks on the remote:
///
///     "\0LOAMCRYPT" 01 00 | key id (8 bytes) | nonce (12 bytes) | ciphertext | tag (16 bytes)
///
/// AES-256-GCM-SIV with the header as authenticated data. The nonce is an HMAC of the plaintext, so the same file
/// always gives the same bytes: git sees an unchanged file as unchanged, and two devices encrypting the same merge
/// agree. That only shows which files are identical; GCM-SIV keeps it safe even if two plaintexts shared a nonce.
/// The leading NUL makes git treat the file as binary.
enum CryptCodec {
    static let magic = Data([0x00]) + Data("LOAMCRYPT".utf8) + Data([0x01, 0x00])
    static let keyIDSize = 8
    static let nonceSize = 12
    static let tagSize = 16
    static let headerSize = magic.count + keyIDSize

    /// Whether `data` starts like a file this codec wrote.
    static func isEncrypted(_ data: Data) -> Bool {
        data.count >= headerSize + nonceSize + tagSize && data.prefix(magic.count).elementsEqual(magic)
    }

    /// The id of the key `data` was encrypted with, nil for a plain file.
    static func keyID(of data: Data) -> String? {
        guard isEncrypted(data) else { return nil }
        let start = data.startIndex + magic.count
        return data[start..<start + keyIDSize].map { String(format: "%02x", $0) }.joined()
    }

    static func encrypt(_ plaintext: Data, with key: VaultKey) throws -> Data {
        let header = magic + (try idBytes(key.id))
        let mac = HMAC<SHA256>.authenticationCode(for: plaintext, using: key.nonce)
        let nonce = try AES.GCM._SIV.Nonce(data: Data(mac).prefix(nonceSize))
        let sealed = try AES.GCM._SIV.seal(plaintext, using: key.encryption, nonce: nonce, authenticating: header)
        return header + sealed.combined
    }

    /// The plaintext of `data`. A plain file (one from before the vault was encrypted) comes back as it is.
    static func decrypt(_ data: Data, with key: VaultKey?) throws -> Data {
        guard let fileKey = keyID(of: data) else { return data }
        guard let key else { throw CryptError.missingKey(fileKey) }
        guard key.id == fileKey else { throw CryptError.wrongKey(file: fileKey, given: key.id) }
        let start = data.startIndex
        let header = data[start..<start + headerSize]
        do {
            let box = try AES.GCM._SIV.SealedBox(combined: data[(start + headerSize)...])
            return try AES.GCM._SIV.open(box, using: key.encryption, authenticating: header)
        } catch {
            throw CryptError.damaged
        }
    }

    static func idBytes(_ id: String) throws -> Data {
        var bytes = Data(capacity: keyIDSize)
        var index = id.startIndex
        while index < id.endIndex, let next = id.index(index, offsetBy: 2, limitedBy: id.endIndex) {
            guard let byte = UInt8(id[index..<next], radix: 16) else { throw CryptError.invalidKeyID(id) }
            bytes.append(byte)
            index = next
        }
        guard bytes.count == keyIDSize, index == id.endIndex else { throw CryptError.invalidKeyID(id) }
        return bytes
    }
}
