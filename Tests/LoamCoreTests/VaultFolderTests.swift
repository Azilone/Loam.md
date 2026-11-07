import XCTest
import PluginKit
import LoamCore

final class VaultFolderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vault-folder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testAnOldVaultFolderIsRenamedWhenTheVaultOpens() throws {
        try write(".so/config.json", #"{"version":1,"plugins":{"truffle-search":{"enabled":false}}}"#)
        let runtime = try Runtime(rootURL: root, plugins: [])
        defer { runtime.close() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".so").path))
        XCTAssertFalse(runtime.config.config.isEnabled("truffle-search"))
    }

    func testBothFoldersAreLeftAsTheyAre() throws {
        try write(".so/config.json", "old")
        try write(".loam/config.json", "{}")
        try VaultFolder.migrate(rootURL: root)
        XCTAssertEqual(try read(".so/config.json"), "old")
        XCTAssertEqual(try read(".loam/config.json"), "{}")
    }
}
