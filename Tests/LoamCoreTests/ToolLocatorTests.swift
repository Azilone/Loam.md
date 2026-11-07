import XCTest
import PluginKit
@testable import LoamCore

final class ToolLocatorTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// An executable called `name` in the test folder.
    private func install(_ name: String, executable: Bool = true) {
        FileManager.default.createFile(
            atPath: folder.appendingPathComponent(name).path, contents: Data("#!/bin/sh\n".utf8),
            attributes: [.posixPermissions: executable ? 0o755 : 0o644]
        )
    }

    func testFindsAnExecutableInTheFolders() {
        install("tool")
        let locator = ToolLocator(folders: [folder.path], developerTools: { false })
        XCTAssertEqual(locator.locate("tool")?.path, folder.appendingPathComponent("tool").path)
    }

    func testSkipsAFileThatIsNotExecutable() {
        install("tool", executable: false)
        XCTAssertNil(ToolLocator(folders: [folder.path], developerTools: { false }).locate("tool"))
    }

    func testAnswersAreKeptUntilRefresh() {
        let locator = ToolLocator(folders: [folder.path], developerTools: { false })
        XCTAssertNil(locator.locate("tool"))
        install("tool")
        XCTAssertNil(locator.locate("tool"), "a missing answer is kept until refresh")
        locator.refresh()
        XCTAssertNotNil(locator.locate("tool"))
    }

    /// Apple's git in /usr/bin is a stub that opens an installer until the developer tools are installed: a git from
    /// Homebrew further down the folders must still be found.
    func testAppleStubIsSkippedWithoutTheDeveloperTools() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/git"))
        install("git")
        let locator = ToolLocator(folders: ["/usr/bin", folder.path], developerTools: { false })
        XCTAssertEqual(locator.locate("git")?.path, folder.appendingPathComponent("git").path)
    }

    func testAppleStubCountsWithTheDeveloperTools() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/git"))
        XCTAssertNil(ToolLocator(folders: ["/usr/bin"], developerTools: { false }).locate("git"))
        XCTAssertNotNil(ToolLocator(folders: ["/usr/bin"], developerTools: { true }).locate("git"))
    }

    func testSystemToolsOutsideTheStubListNeedNoDeveloperTools() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/sqlite3"))
        XCTAssertNotNil(ToolLocator(folders: ["/usr/bin"], developerTools: { false }).locate("sqlite3"))
    }

    func testCatalogNamesTheFormulaThatInstallsEachTool() {
        XCTAssertEqual(ToolCatalog.formula(for: "git"), "git")
        XCTAssertEqual(ToolCatalog.formula(for: "ffprobe"), "ffmpeg")
        XCTAssertEqual(ToolCatalog.formula(for: "cwebp"), "webp")
        XCTAssertNil(ToolCatalog.formula(for: "swift"), "swift comes with the developer tools")
        XCTAssertEqual(ToolCatalog.formulas(for: ["ffmpeg", "ffprobe", "cwebp", "swift"]), ["ffmpeg", "webp"])
    }
}
