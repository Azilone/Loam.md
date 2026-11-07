import Foundation
import PluginKit
import PluginKitTesting
import XCTest
@testable import LoamCore

/// `plugins.install` from release tags and the catalog, `plugins.outdated`, `plugins.update`, `plugins.rollback` and
/// `plugins.catalog`, against local git repositories and without compiling (`build=false`).
final class PluginUpdatesTests: XCTestCase {
    private var vault: TemporaryVault!
    private var runtime: Runtime!
    private var scratch: URL!

    override func setUpWithError() throws {
        vault = try TemporaryVault()
        try vault.write("note.md", "# Note\n")
        runtime = try Runtime(rootURL: vault.rootURL, plugins: [], thirdPartyPlugins: true, pluginTrust: .everything)
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("so-updates-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        runtime.close()
        runtime = nil
        vault = nil
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: Helpers

    private func run(_ id: String, _ arguments: [String: String] = [:]) async throws -> String {
        let command = try XCTUnwrap(runtime.kernel.commands.command(id: id), "no command \(id)")
        return try await command.handler(arguments)
    }

    private func object(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func array(_ text: String) throws -> [[String: Any]] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
    }

    private func manifest(_ version: String, permissions: [String] = ["vault.read"], minSDK: String? = nil) -> String {
        let list = permissions.map { "\"\($0)\"" }.joined(separator: ", ")
        let sdk = minSDK.map { #", "minSDK": "\#($0)""# } ?? ""
        return #"{"id": "share", "name": "Share", "version": "\#(version)", "library": "SharePlugin", "permissions": [\#(list)]\#(sdk)}"#
    }

    /// A repository with one commit per release, each tagged when `tag` is set. Returns its path.
    private func repository() throws -> URL {
        let repository = scratch.appendingPathComponent("share-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], in: repository)
        return repository
    }

    @discardableResult
    private func release(_ repository: URL, _ manifest: String, tag: String?) throws -> String {
        try manifest.write(to: repository.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
        try UUID().uuidString.write(to: repository.appendingPathComponent("Sources.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: repository)
        try git(["-c", "user.email=t@example.com", "-c", "user.name=T", "commit", "-q", "-m", "release"], in: repository)
        if let tag { try git(["tag", tag], in: repository) }
        return try gitOutput(["rev-parse", "HEAD"], in: repository)
    }

    private func git(_ arguments: [String], in directory: URL) throws {
        _ = try gitOutput(arguments, in: directory)
    }

    private func gitOutput(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = directory
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw XCTSkip("git is not available")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus == 127 { throw XCTSkip("git is not available") }
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments)")
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func installedVersion() throws -> String? {
        PluginLoader.manifest(in: vault.url(".loam/plugins/share"))?.version
    }

    // MARK: Versions

    func testReleaseVersionsCompareNumberByNumber() {
        XCTAssertLessThan(ReleaseVersion("1.2.0")!, ReleaseVersion("v1.10")!)
        XCTAssertEqual(ReleaseVersion("v1.2")!, ReleaseVersion("1.2.0")!)
        XCTAssertLessThan(ReleaseVersion("1.3.0-beta")!, ReleaseVersion("1.3.0")!)
        XCTAssertNil(ReleaseVersion("latest"))
        XCTAssertNil(ReleaseVersion("1..2"))
        let listing = "a\trefs/tags/v1.2.0\nb\trefs/tags/v1.10.0\nc\trefs/tags/v2.0.0-rc1\nd\trefs/tags/nightly\n"
        XCTAssertEqual(GitRemote.latestTag(inListing: listing)?.tag, "v1.10.0")
        XCTAssertNil(GitRemote.latestTag(inListing: ""))
    }

    func testAPluginNeedingANewerSDKIsRefused() throws {
        let sdk = PluginSDKVersion.current
        let newer = ThirdPartyPluginManifest(id: "x", name: "X", version: "1", library: "X",
                                             minSDK: "\(sdk.major).\(sdk.minor + 1)")
        XCTAssertThrowsError(try Runtime.requireBuildable(newer))
        let same = ThirdPartyPluginManifest(id: "x", name: "X", version: "1", library: "X", minSDK: sdk.description)
        XCTAssertNoThrow(try Runtime.requireBuildable(same))
        let nextMajor = ThirdPartyPluginManifest(id: "x", name: "X", version: "1", library: "X", minSDK: "\(sdk.major + 1).0")
        XCTAssertThrowsError(try Runtime.requireBuildable(nextMajor))
    }

    // MARK: Install, outdated, update, rollback

    func testInstallTakesTheHighestTagAndRemembersWhereItCameFrom() async throws {
        let repository = try repository()
        let first = try release(repository, manifest("1.0.0"), tag: "v1.0.0")
        try release(repository, manifest("1.1.0-dev"), tag: nil)

        _ = try await run("plugins.install", ["url": repository.path, "build": "false"])
        XCTAssertEqual(try installedVersion(), "1.0.0")
        let origin = try XCTUnwrap(PluginOrigin.read(in: vault.url(".loam/plugins/share")))
        XCTAssertEqual(origin, PluginOrigin(source: repository.path, ref: "v1.0.0", commit: first))
    }

    func testOutdatedThenUpdateThenRollback() async throws {
        let repository = try repository()
        try release(repository, manifest("1.0.0"), tag: "v1.0.0")
        _ = try await run("plugins.install", ["url": repository.path, "build": "false"])
        try runtime.config.mutate { $0.setEnabled(true, "share") }

        var rows = try array(try await run("plugins.outdated"))
        XCTAssertEqual(rows.first?["updateAvailable"] as? Bool, false)

        let second = try release(repository, manifest("1.1.0"), tag: "v1.1.0")
        rows = try array(try await run("plugins.outdated"))
        XCTAssertEqual(rows.first?["id"] as? String, "share")
        XCTAssertEqual(rows.first?["installed"] as? String, "1.0.0")
        XCTAssertEqual(rows.first?["latest"] as? String, "1.1.0")
        XCTAssertEqual(rows.first?["updateAvailable"] as? Bool, true)

        let updated = try object(try await run("plugins.update", ["id": "share", "build": "false"]))
        XCTAssertEqual(updated["updated"] as? Bool, true)
        XCTAssertEqual(updated["to"] as? String, "1.1.0")
        XCTAssertEqual(updated["disabled"] as? Bool, false)
        XCTAssertEqual(try installedVersion(), "1.1.0")
        XCTAssertEqual(PluginOrigin.read(in: vault.url(".loam/plugins/share"))?.commit, second)
        XCTAssertTrue(runtime.config.config.isExplicitlyEnabled("share"), "same permissions: stays enabled")

        let again = try object(try await run("plugins.update", ["id": "share", "build": "false"]))
        XCTAssertEqual(again["updated"] as? Bool, false)
        XCTAssertEqual(again["reason"] as? String, "up to date")

        _ = try await run("plugins.rollback", ["id": "share", "build": "false"])
        XCTAssertEqual(try installedVersion(), "1.0.0")
        _ = try await run("plugins.rollback", ["id": "share", "build": "false"])
        XCTAssertEqual(try installedVersion(), "1.1.0", "a second rollback goes forward again")
    }

    func testAnUpdateAskingForNewPermissionsDisablesThePlugin() async throws {
        let repository = try repository()
        try release(repository, manifest("1.0.0"), tag: "v1.0.0")
        _ = try await run("plugins.install", ["url": repository.path, "build": "false"])
        try runtime.config.mutate { $0.setEnabled(true, "share") }
        try release(repository, manifest("2.0.0", permissions: ["vault.read", "network"]), tag: "v2.0.0")

        let skipped = try object(try await run("plugins.update", ["id": "share", "build": "false", "same-permissions": "true"]))
        XCTAssertEqual(skipped["updated"] as? Bool, false)
        XCTAssertEqual(skipped["addedPermissions"] as? [String], ["network"])
        XCTAssertEqual(try installedVersion(), "1.0.0")

        let updated = try object(try await run("plugins.update", ["id": "share", "build": "false"]))
        XCTAssertEqual(updated["updated"] as? Bool, true)
        XCTAssertEqual(updated["disabled"] as? Bool, true)
        XCTAssertFalse(runtime.config.config.isExplicitlyEnabled("share"))
    }

    func testAnUpdateNeedingANewerAppChangesNothing() async throws {
        let repository = try repository()
        try release(repository, manifest("1.0.0"), tag: "v1.0.0")
        _ = try await run("plugins.install", ["url": repository.path, "build": "false"])
        let sdk = PluginSDKVersion.current
        try release(repository, manifest("1.1.0", minSDK: "\(sdk.major).\(sdk.minor + 1)"), tag: "v1.1.0")
        do {
            _ = try await run("plugins.update", ["id": "share", "build": "false"])
            XCTFail("updated to a version that needs a newer app")
        } catch let error as PluginPackageError {
            XCTAssertEqual(error, .needsNewerApp("share", "\(sdk.major).\(sdk.minor + 1)"))
        }
        XCTAssertEqual(try installedVersion(), "1.0.0")
    }

    func testAPluginWithoutTagsFollowsItsBranch() async throws {
        let repository = try repository()
        try release(repository, manifest("0.1.0"), tag: nil)
        _ = try await run("plugins.install", ["url": repository.path, "build": "false"])
        XCTAssertNil(PluginOrigin.read(in: vault.url(".loam/plugins/share"))?.ref)

        let head = try release(repository, manifest("0.1.0"), tag: nil)
        let rows = try array(try await run("plugins.outdated", ["id": "share"]))
        XCTAssertEqual(rows.first?["kind"] as? String, "commit")
        XCTAssertEqual(rows.first?["latest"] as? String, String(head.prefix(7)))
        XCTAssertEqual(rows.first?["updateAvailable"] as? Bool, true)
        _ = try await run("plugins.update", ["id": "share", "build": "false"])
        XCTAssertEqual(PluginOrigin.read(in: vault.url(".loam/plugins/share"))?.commit, head)
    }

    func testAutoUpdateIsKeptInTheOrigin() async throws {
        let repository = try repository()
        try release(repository, manifest("1.0.0"), tag: "v1.0.0")
        _ = try await run("plugins.install", ["url": repository.path, "build": "false"])
        _ = try await run("plugins.auto-update", ["id": "share", "on": "true"])
        XCTAssertEqual(PluginOrigin.read(in: vault.url(".loam/plugins/share"))?.autoUpdate, true)
    }

    // MARK: Catalog

    private func writeCatalog(repo: String, versions: [(String, String, String)]) throws -> URL {
        let list = versions.map { #"{"version": "\#($0.0)", "tag": "\#($0.1)", "commit": "\#($0.2)", "permissions": ["vault.read"]}"# }
        let text = #"{"plugins": [{"id": "share", "name": "Share", "description": "Shares notes", "repo": "\#(repo)", "versions": [\#(list.joined(separator: ", "))]}]}"#
        let url = scratch.appendingPathComponent("index-\(UUID().uuidString).json")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testInstallFromTheCatalogChecksThePinnedCommit() async throws {
        let repository = try repository()
        let commit = try release(repository, manifest("1.0.0"), tag: "v1.0.0")

        let good = try writeCatalog(repo: repository.path, versions: [("1.0.0", "v1.0.0", commit)])
        let rows = try array(try await run("plugins.catalog", ["catalog": good.path, "query": "notes"]))
        XCTAssertEqual(rows.first?["id"] as? String, "share")
        XCTAssertEqual(rows.first?["latest"] as? String, "1.0.0")

        let bad = try writeCatalog(repo: repository.path, versions: [("1.0.0", "v1.0.0", String(repeating: "0", count: 40))])
        do {
            _ = try await run("plugins.install", ["id": "share", "catalog": bad.path, "build": "false"])
            XCTFail("installed a commit the catalog did not pin")
        } catch let error as PluginPackageError {
            guard case .badSource(let message) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("refused"), message)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.url(".loam/plugins/share").path))

        _ = try await run("plugins.install", ["id": "share", "catalog": good.path, "build": "false"])
        XCTAssertEqual(PluginOrigin.read(in: vault.url(".loam/plugins/share"))?.catalog, true)
        XCTAssertEqual(try installedVersion(), "1.0.0")
    }

    func testCatalogPicksTheNewestBuildableVersion() throws {
        let sdk = PluginSDKVersion.current
        let entry = PluginCatalog.Entry(id: "x", name: "X", description: nil, author: nil, repo: "r", versions: [
            .init(version: "1.0.0", tag: "v1.0.0", commit: "a", minSDK: nil, permissions: nil),
            .init(version: "1.2.0", tag: "v1.2.0", commit: "b", minSDK: sdk.description, permissions: nil),
            .init(version: "2.0.0", tag: "v2.0.0", commit: "c", minSDK: "\(sdk.major).\(sdk.minor + 1)", permissions: nil),
        ])
        XCTAssertEqual(entry.latest()?.version, "1.2.0")
        XCTAssertEqual(entry.newest?.version, "2.0.0")
    }
}
