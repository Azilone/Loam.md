// The Ed25519 key that signs app releases (docs/UPDATES.md). Run with `swift scripts/update-key.swift`:
//
//   generate <private key file>   writes a new private key (mode 600) and prints the public key, base64
//   public <private key file>     prints the public key of an existing private key
//   sign <private key file> <zip> prints the signature of the file, base64
//   verify <public key> <zip> <signature>   exits 0 when the signature is valid
//
// The public key goes into App/Resources/update-public-key.txt, built into every release; the private key never
// leaves the release machine.
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("update-key: \(message)\n".utf8))
    exit(1)
}

func privateKey(_ path: String) -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8),
          let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else { fail("cannot read the private key at \(path)") }
    return key
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch (arguments.first, arguments.count) {
case ("generate", 2):
    let path = arguments[1]
    if FileManager.default.fileExists(atPath: path) { fail("\(path) exists: refusing to replace a release key") }
    let key = Curve25519.Signing.PrivateKey()
    try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    guard FileManager.default.createFile(atPath: path, contents: Data(key.rawRepresentation.base64EncodedString().utf8),
                                         attributes: [.posixPermissions: 0o600]) else { fail("cannot write \(path)") }
    print(key.publicKey.rawRepresentation.base64EncodedString())
case ("public", 2):
    print(privateKey(arguments[1]).publicKey.rawRepresentation.base64EncodedString())
case ("sign", 3):
    guard let data = FileManager.default.contents(atPath: arguments[2]) else { fail("cannot read \(arguments[2])") }
    print(try privateKey(arguments[1]).signature(for: data).base64EncodedString())
case ("verify", 4):
    guard let keyData = Data(base64Encoded: arguments[1]), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
          let data = FileManager.default.contents(atPath: arguments[2]),
          let signature = Data(base64Encoded: arguments[3]) else { fail("bad arguments") }
    exit(key.isValidSignature(signature, for: data) ? 0 : 1)
default:
    fail("usage: generate <key> | public <key> | sign <key> <file> | verify <public key> <file> <signature>")
}
