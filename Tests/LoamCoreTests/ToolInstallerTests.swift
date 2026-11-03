import XCTest
@testable import LoamCore

final class ToolInstallerTests: XCTestCase {
    func testNothingMissingIsNothingToDo() {
        XCTAssertEqual(ToolInstaller.plan(missing: [], hasDeveloperTools: false, hasHomebrew: false), .nothing)
    }

    func testTheDeveloperToolsComeFirstForGitAndSwift() {
        XCTAssertEqual(ToolInstaller.plan(missing: ["git", "ffmpeg"], hasDeveloperTools: false, hasHomebrew: true),
                       .developerTools)
        XCTAssertEqual(ToolInstaller.plan(missing: ["swift"], hasDeveloperTools: false, hasHomebrew: false),
                       .developerTools)
    }

    func testFormulasNeedHomebrew() {
        XCTAssertEqual(ToolInstaller.plan(missing: ["ffmpeg"], hasDeveloperTools: false, hasHomebrew: false), .homebrew)
        XCTAssertEqual(ToolInstaller.plan(missing: ["ffmpeg", "ffprobe", "cwebp"], hasDeveloperTools: true, hasHomebrew: true),
                       .brew(["ffmpeg", "webp"]))
    }

    func testSwiftIsNeverABrewFormula() {
        XCTAssertEqual(ToolInstaller.plan(missing: ["swift"], hasDeveloperTools: true, hasHomebrew: true), .nothing)
    }
}
