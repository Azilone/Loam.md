import XCTest
@testable import NotebookApp

/// The language chosen in Settings: written to the app's own preferences for the next launch, nil follows the system.
final class AppLanguageTests: XCTestCase {
    private let domain = "loam.tests.app-language"
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: domain)
        defaults.removePersistentDomain(forName: domain)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: domain)
    }

    func testChoosingWritesTheLanguageAndSystemRemovesIt() {
        XCTAssertNil(AppLanguage.chosen(in: defaults, domain: domain))
        AppLanguage.choose("fr", in: defaults)
        XCTAssertEqual(defaults.stringArray(forKey: AppLanguage.key), ["fr"])
        XCTAssertEqual(AppLanguage.chosen(in: defaults, domain: domain), "fr")
        AppLanguage.choose(nil, in: defaults)
        XCTAssertNil(AppLanguage.chosen(in: defaults, domain: domain))
    }

    func testEveryLanguageHasItsTranslationsAndItsOwnName() throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Resources").standardized
        for code in AppLanguage.codes {
            XCTAssertTrue(FileManager.default.fileExists(atPath: resources.appendingPathComponent("\(code).lproj").path), code)
        }
        XCTAssertEqual(AppLanguage.name(of: "fr"), "Français")
        XCTAssertEqual(AppLanguage.name(of: "de"), "Deutsch")
    }
}
