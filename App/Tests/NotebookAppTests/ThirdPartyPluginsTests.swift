import Foundation
import PluginKit
import LoamCore
import XCTest
@testable import NotebookApp

/// The shell lists the vault's own plugins only when its configuration asks (the executable does), and never loads
/// them in safe mode. Loading itself is tested in the root package (`PluginLoaderTests`).
@MainActor
final class ThirdPartyPluginsTests: ShellTestCase {
    private func makeSession(thirdPartyPlugins: Bool, safeMode: Bool = false) throws -> ShellSession {
        let session = try ShellSession(
            rootURL: root,
            configuration: ShellConfiguration(logicPlugins: [], uiPlugins: [], thirdPartyPlugins: thirdPartyPlugins, pluginTrust: .everything),
            machineID: machineID,
            layoutSaveDelay: .seconds(60),
            safeMode: safeMode
        )
        addTeardownBlock { @MainActor in session.close() }
        return session
    }

    private func pluginRows(_ session: ShellSession) async throws -> [[String: Any]] {
        let output = try await session.runtime.kernel.commands.command(id: "plugins.list")!.handler([:])
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]])
    }

    override func setUp() async throws {
        try await super.setUp()
        try write(".loam/plugins/hello/plugin.json", #"{"id": "hello", "name": "Hello", "version": "0.1.0", "library": "HelloPlugin"}"#)
        try write(".loam/config.json", #"{"plugins": {"hello": {"enabled": true}}}"#)
    }

    func testOffUnlessTheConfigurationAsks() async throws {
        let rows = try await pluginRows(try makeSession(thirdPartyPlugins: false))
        XCTAssertTrue(rows.isEmpty)
    }

    func testListsTheVaultsPlugins() async throws {
        let rows = try await pluginRows(try makeSession(thirdPartyPlugins: true))
        XCTAssertEqual(rows.map { $0["id"] as? String }, ["hello"])
        XCTAssertEqual(rows.first?["source"] as? String, "vault")
        XCTAssertTrue((rows.first?["loadError"] as? String)?.hasPrefix("not built") == true)
    }

    func testSafeModeDoesNotLoadThem() async throws {
        let session = try makeSession(thirdPartyPlugins: true, safeMode: true)
        let rows = try await pluginRows(session)
        XCTAssertEqual(rows.first?["skipped"] as? String, "safe mode: plugins from the vault are not loaded")
        XCTAssertTrue(session.runtime.lastReport.activated.isEmpty)
    }
}
