import Foundation
import XCTest
@testable import LoamCore

/// The theme catalog: `themes.json` and the `themes/<id>.json` files next to it, read from a folder.
final class ThemeCatalogTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("so-themes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch.appendingPathComponent("themes"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func writeCatalog() throws -> URL {
        let text = #"""
        {"themes": [
          {"id": "paper", "name": "Paper", "author": "loam", "description": "Warm paper", "version": "1.0.0", "appearance": "auto"},
          {"id": "night", "name": "Night", "appearance": "dark", "unknown": true}
        ]}
        """#
        let url = scratch.appendingPathComponent("themes.json")
        try text.write(to: url, atomically: true, encoding: .utf8)
        try #"{"name": "Paper"}"#.write(to: scratch.appendingPathComponent("themes/paper.json"), atomically: true, encoding: .utf8)
        return url
    }

    func testFetchReadsTheEntries() async throws {
        let catalog = try await ThemeCatalog.fetch(try writeCatalog())
        XCTAssertEqual(catalog.themes.map(\.id), ["paper", "night"])
        XCTAssertEqual(catalog.entry("paper")?.author, "loam")
        XCTAssertEqual(catalog.entry("night")?.appearance, "dark")
        XCTAssertNil(catalog.entry("night")?.author)
    }

    func testAThemeIsNextToTheCatalog() async throws {
        let catalog = try writeCatalog()
        XCTAssertEqual(ThemeCatalog.themeURL(id: "paper", catalog: catalog).path, scratch.appendingPathComponent("themes/paper.json").path)
        XCTAssertEqual(
            ThemeCatalog.themeURL(id: "ink", catalog: URL(string: "https://example.com/c/main/themes.json")!).absoluteString,
            "https://example.com/c/main/themes/ink.json"
        )
        let data = try await ThemeCatalog.fetchTheme(id: "paper", catalog: catalog)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"name": "Paper"}"#)
    }

    func testAMissingThemeOrCatalogThrows() async throws {
        let catalog = try writeCatalog()
        do {
            _ = try await ThemeCatalog.fetchTheme(id: "moss", catalog: catalog)
            XCTFail("read a theme that is not there")
        } catch is ThemeCatalogError {}
        do {
            _ = try await ThemeCatalog.fetch(scratch.appendingPathComponent("themes/paper.json"))
            XCTFail("read a theme as a catalog")
        } catch is ThemeCatalogError {}
    }

    func testIDsCannotLeaveTheThemesFolder() async throws {
        XCTAssertTrue(ThemeCatalog.isValidID("paper"))
        XCTAssertTrue(ThemeCatalog.isValidID("solarized-dark_2"))
        for id in ["", "../config", "a/b", "Paper", "night.json", "é"] {
            XCTAssertFalse(ThemeCatalog.isValidID(id), id)
        }
        do {
            _ = try await ThemeCatalog.fetchTheme(id: "../themes", catalog: try writeCatalog())
            XCTFail("fetched an id with a path in it")
        } catch is ThemeCatalogError {}
    }

    func testMatches() {
        let entry = ThemeCatalog.Entry(id: "moss", name: "Moss", author: "kevin", description: "Green and calm")
        XCTAssertTrue(entry.matches(""))
        XCTAssertTrue(entry.matches("green"))
        XCTAssertTrue(entry.matches("kev"))
        XCTAssertFalse(entry.matches("blue"))
    }

    func testTheCatalogsAreTheCommunityRepository() {
        guard ProcessInfo.processInfo.environment["LOAM_THEME_CATALOG"] == nil,
              ProcessInfo.processInfo.environment["LOAM_PLUGIN_CATALOG"] == nil else { return }
        XCTAssertEqual(ThemeCatalog.defaultURL.absoluteString, "https://raw.githubusercontent.com/Azilone/loam-community/main/themes.json")
        XCTAssertTrue(PluginCatalog.defaultURL.absoluteString.contains("/Azilone/loam-community/"))
    }
}
