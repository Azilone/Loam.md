import XCTest
@testable import GitSyncPlugin

final class CryptTests: XCTestCase {
    private let key = VaultKey(bytes: Data(repeating: 7, count: 32))!

    // MARK: - Codec

    func testEncryptionRoundTripsAndIsDeterministic() throws {
        let note = Data("# Plan\nship on friday\n".utf8)
        let sealed = try CryptCodec.encrypt(note, with: key)
        XCTAssertTrue(CryptCodec.isEncrypted(sealed))
        XCTAssertEqual(CryptCodec.keyID(of: sealed), key.id)
        XCTAssertEqual(sealed.count, note.count + CryptCodec.headerSize + CryptCodec.nonceSize + CryptCodec.tagSize)
        XCTAssertNil(sealed.range(of: Data("friday".utf8)))
        XCTAssertEqual(try CryptCodec.decrypt(sealed, with: key), note)
        XCTAssertEqual(try CryptCodec.encrypt(note, with: key), sealed, "the same file gives the same bytes")
        XCTAssertNotEqual(try CryptCodec.encrypt(Data("# Plan\nship on monday\n".utf8), with: key).dropFirst(20).prefix(12),
                          sealed.dropFirst(20).prefix(12), "another text gets another nonce")
        XCTAssertNotEqual(try CryptCodec.encrypt(note, with: .generate()), sealed)
    }

    func testEmptyAndBinaryFilesRoundTrip() throws {
        for data in [Data(), Data([0, 1, 2, 0xFF, 0]), Data(repeating: 0xAB, count: 200_000)] {
            let sealed = try CryptCodec.encrypt(data, with: key)
            XCTAssertTrue(CryptCodec.isEncrypted(sealed))
            XCTAssertEqual(try CryptCodec.decrypt(sealed, with: key), data)
        }
    }

    func testAPlainFileComesBackAsItIs() throws {
        let plain = Data("committed before encryption\n".utf8)
        XCTAssertFalse(CryptCodec.isEncrypted(plain))
        XCTAssertEqual(try CryptCodec.decrypt(plain, with: nil), plain)
        XCTAssertEqual(try CryptCodec.decrypt(plain, with: key), plain)
    }

    func testAMissingWrongOrTamperedKeyIsAnError() throws {
        let sealed = try CryptCodec.encrypt(Data("secret".utf8), with: key)
        XCTAssertThrowsError(try CryptCodec.decrypt(sealed, with: nil)) {
            XCTAssertEqual($0 as? CryptError, .missingKey(key.id))
        }
        let other = VaultKey.generate()
        XCTAssertThrowsError(try CryptCodec.decrypt(sealed, with: other)) {
            XCTAssertEqual($0 as? CryptError, .wrongKey(file: key.id, given: other.id))
        }
        var tampered = sealed
        tampered[tampered.count - 20] ^= 1
        XCTAssertThrowsError(try CryptCodec.decrypt(tampered, with: key)) { XCTAssertEqual($0 as? CryptError, .damaged) }
        var renamed = sealed
        renamed[CryptCodec.magic.count] ^= 1
        XCTAssertThrowsError(try CryptCodec.decrypt(renamed, with: key), "the key id is authenticated")
    }

    // MARK: - Keys

    func testAnExportedKeyComesBack() throws {
        let generated = VaultKey.generate()
        XCTAssertTrue(generated.exported.hasPrefix("loam-key:"))
        XCTAssertEqual(VaultKey(exported: "  \(generated.exported)\n"), generated)
        XCTAssertEqual(VaultKey(exported: generated.exported)?.id, generated.id)
        XCTAssertEqual(generated.id.count, 16)
        XCTAssertNil(VaultKey(exported: "loam-key:short"))
        XCTAssertNil(VaultKey(exported: generated.exported.replacingOccurrences(of: "loam-key:", with: "")))
        XCTAssertEqual(key.id, VaultKey(bytes: Data(repeating: 7, count: 32))?.id, "the id comes from the key")
    }

    func testAFileStoreKeepsKeysForTheUserOnly() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("loam-keys-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FileKeyStore(directory: folder)
        XCTAssertNil(try store.load(id: key.id))
        try store.save(key)
        XCTAssertEqual(try store.load(id: key.id), key)
        let attributes = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(key.id).path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertTrue(VaultKeyStores.system(environment: ["LOAM_KEY_DIR": folder.path]) is FileKeyStore)
    }

    // MARK: - .gitattributes

    func testTheAttributesNameTheKey() {
        let block = CryptAttributes.block(keyID: key.id)
        XCTAssertEqual(CryptAttributes.declaredKey(in: block), key.id)
        XCTAssertTrue(block.contains("* filter=loam-crypt diff=loam-crypt merge=loam-crypt -text"))
        XCTAssertTrue(block.contains(".gitattributes !filter !diff !merge !text"))
        XCTAssertNil(CryptAttributes.declaredKey(in: "*.png filter=lfs diff=lfs merge=lfs -text\n"))
        XCTAssertNil(CryptAttributes.declaredKey(in: "# * filter=loam-crypt\n"))
        XCTAssertEqual(CryptAttributes.declaredKey(in: "* filter=loam-crypt\n"), "")

        let existing = "*.md text eol=lf\n"
        let added = CryptAttributes.adding(keyID: key.id, to: existing)
        XCTAssertTrue(added.hasPrefix(existing + "\n"))
        XCTAssertEqual(CryptAttributes.declaredKey(in: added), key.id)
        let other = VaultKey.generate().id
        let replaced = CryptAttributes.adding(keyID: other, to: added)
        XCTAssertEqual(CryptAttributes.declaredKey(in: replaced), other)
        XCTAssertEqual(replaced.components(separatedBy: "filter=loam-crypt").count, 2, "one block only")
    }

    // MARK: - git's filter protocol

    private func packets(_ items: [String?]) -> Data {
        var data = Data()
        for item in items {
            guard let item else {
                data.append(Data("0000".utf8))
                continue
            }
            data.append(Data(String(format: "%04x", item.utf8.count + 4).utf8) + Data(item.utf8))
        }
        return data
    }

    private func serve(_ input: Data, keys: VaultKey?) throws -> (output: PacketReader, log: [String]) {
        var remaining = input
        let reader = PacketReader {
            let chunk = remaining.prefix(7)
            remaining = remaining.dropFirst(7)
            return Data(chunk)
        }
        var written = Data()
        let writer = PacketWriter { written.append($0) }
        var log: [String] = []
        try FilterProcess.serve(
            reader: reader, writer: writer,
            clean: { content, _ in
                guard let keys else { throw CryptError.missingKey("abc") }
                return try CryptCodec.encrypt(content, with: keys)
            },
            smudge: { content, _ in try CryptCodec.decrypt(content, with: keys) },
            log: { log.append($0) })
        var output = written
        let outputReader = PacketReader {
            let chunk = output
            output = Data()
            return chunk
        }
        return (outputReader, log)
    }

    func testTheFilterAnswersGitsHandshakeAndConvertsFiles() throws {
        let note = "# Note\n"
        let input = packets(["git-filter-client\n", "version=2\n", nil,
                             "capability=clean\n", "capability=smudge\n", "capability=delay\n", nil,
                             "command=clean\n", "pathname=Note.md\n", nil, note, nil,
                             "command=clean\n", "pathname=Empty.md\n", nil, nil])
        let (reply, log) = try serve(input, keys: key)
        XCTAssertEqual(log, [])
        XCTAssertEqual(try reply.lines(), ["git-filter-server", "version=2"])
        XCTAssertEqual(try reply.lines(), ["capability=clean", "capability=smudge"], "no delay")
        XCTAssertEqual(try reply.lines(), ["status=success"])
        let sealed = try reply.content()
        XCTAssertEqual(try CryptCodec.decrypt(sealed, with: key), Data(note.utf8))
        XCTAssertEqual(try reply.lines(), [], "the status stays success")
        XCTAssertEqual(try reply.lines(), ["status=success"])
        XCTAssertEqual(try CryptCodec.decrypt(try reply.content(), with: key), Data())
        XCTAssertEqual(try reply.lines(), [])
        XCTAssertNil(try reply.next())
    }

    func testAFileTheFilterCannotConvertIsAnErrorForThatFileOnly() throws {
        let input = packets(["git-filter-client\n", "version=2\n", nil, "capability=clean\n", nil,
                             "command=clean\n", "pathname=Note.md\n", nil, "text", nil])
        let (reply, log) = try serve(input, keys: nil)
        _ = try reply.lines()
        _ = try reply.lines()
        XCTAssertEqual(try reply.lines(), ["status=error"])
        XCTAssertNil(try reply.next())
        XCTAssertEqual(log.count, 1)
        XCTAssertTrue(log[0].hasPrefix("Note.md: "), log[0])
    }

    func testLargeFilesAreCutIntoPackets() throws {
        let big = Data(repeating: 0x41, count: PacketWriter.maxPayload * 2 + 10)
        var written = Data()
        let writer = PacketWriter { written.append($0) }
        writer.content(big)
        writer.flushPacket()
        try writer.send()
        var output = written
        let reader = PacketReader {
            let chunk = output
            output = Data()
            return chunk
        }
        XCTAssertEqual(try reader.content(), big)
        XCTAssertEqual(written.count, big.count + 3 * 4 + 4)
    }

    func testTheToolCommandIsQuotedForGitsShell() {
        XCTAssertEqual(GitCrypt.quote("/Applications/Loam.app/Contents/Helpers/loam"),
                       "'/Applications/Loam.app/Contents/Helpers/loam'")
        XCTAssertEqual(GitCrypt.quote("/tmp/it's/loam"), #"'/tmp/it'\''s/loam'"#)
        XCTAssertEqual(GitCrypt.locateTool(environment: ["LOAM_CRYPT_TOOL": "x crypt"]), "x crypt")
        let config = Dictionary(uniqueKeysWithValues: GitCrypt.config(tool: "'f' crypt").map { ($0.key, $0.value) })
        XCTAssertEqual(config["filter.loam-crypt.process"], "'f' crypt filter")
        XCTAssertEqual(config["filter.loam-crypt.required"], "true")
        XCTAssertEqual(config["merge.loam-crypt.driver"], "'f' crypt merge %O %A %B %L %P")
    }

    func testAKeyFromTheEnvironmentComesFirstAndIsKeptWhenSaved() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("keys-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = VaultKey.generate()
        let other = VaultKey.generate()
        let store = VaultKeyStores.system(environment: ["LOAM_KEY_DIR": folder.path,
                                                        VaultKeyStores.environmentKey: "  \(key.exported)\n"])
        XCTAssertEqual(try store.load(id: key.id), key)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(key.id).path),
                       "reading it writes nothing")
        try store.save(key)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(key.id).path),
                      "joining keeps it for the next run")
        try store.save(other)
        XCTAssertEqual(try store.load(id: other.id), other, "other keys still go to the store under it")
        let plain = VaultKeyStores.system(environment: ["LOAM_KEY_DIR": folder.path, VaultKeyStores.environmentKey: "junk"])
        XCTAssertNil(try plain.load(id: VaultKey.generate().id), "a value that is not a key is ignored")
    }

    func testSetupTakesAKeyArgument() throws {
        XCTAssertEqual(try GitSyncPlugin.keyArgument(["key": "loam-key:abc"]), "loam-key:abc")
        XCTAssertNil(try GitSyncPlugin.keyArgument(["url": "x"]))
    }
}
