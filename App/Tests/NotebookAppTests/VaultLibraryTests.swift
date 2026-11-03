import Foundation
import XCTest
@testable import NotebookApp

/// The list of vaults opened on this Mac, and the vault the user makes from the switcher.
@MainActor
final class VaultLibraryTests: ShellTestCase {
    private let domain = "loam.tests.vault-library"
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        defaults = UserDefaults(suiteName: domain)
        defaults.removePersistentDomain(forName: domain)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: domain)
        try await super.tearDown()
    }

    private func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testTheLatestVaultComesFirstAndIsKeptOnce() throws {
        let library = VaultLibrary(defaults: defaults)
        let (a, b) = (try folder("A"), try folder("B"))
        library.remember(a)
        library.remember(b)
        library.remember(a)
        XCTAssertEqual(library.entries.map(\.name), ["A", "B"])
        XCTAssertEqual(VaultLibrary(defaults: defaults).entries.map(\.name), ["A", "B"], "saved for the next launch")
    }

    func testAForgottenVaultLeavesTheListButItsFolderStays() throws {
        let library = VaultLibrary(defaults: defaults)
        let a = try folder("A")
        library.remember(a)
        library.forget(a)
        XCTAssertTrue(library.entries.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
    }

    func testAFolderThatIsGoneIsSkipped() throws {
        let library = VaultLibrary(defaults: defaults)
        let (a, b) = (try folder("A"), try folder("B"))
        library.remember(a)
        library.remember(b)
        try FileManager.default.removeItem(at: a)
        XCTAssertEqual(library.entries.map(\.name), ["B"])
    }

    func testTheLastVaultOfOlderVersionsJoinsTheList() throws {
        let a = try folder("A")
        defaults.set(a.path, forKey: AppModel.lastVaultKey)
        XCTAssertEqual(VaultLibrary(defaults: defaults).entries.map(\.name), ["A"])
    }

    func testNamesThatCannotMakeOneFolderAreRefused() {
        for name in ["", "  ", ".", "..", "a/b", "a:b"] { XCTAssertFalse(VaultLibrary.isValidName(name), name) }
        XCTAssertTrue(VaultLibrary.isValidName("2nd Cerveau"))
    }

    func testCreatingAVaultMakesAnEmptyFolderOpensAndRemembersIt() throws {
        let library = VaultLibrary(defaults: defaults)
        let model = AppModel(configuration: ShellConfiguration(logicPlugins: [], uiPlugins: []), library: library)
        defer { model.closeVault() }
        let parent = try folder("Parent")
        model.createVault(named: " Journal ", in: parent)
        let made = parent.appendingPathComponent("Journal", isDirectory: true)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.session?.rootURL.standardizedFileURL.path, made.standardizedFileURL.path)
        let names = try FileManager.default.contentsOfDirectory(atPath: made.path).filter { $0 != ".loam" && $0 != ".DS_Store" }
        XCTAssertEqual(names, [], "no demo notes in a vault made on purpose")
        XCTAssertEqual(library.entries.map(\.name), ["Journal"])
    }

    func testCreatingWithABadNameReportsItAndOpensNothing() throws {
        let model = AppModel(
            configuration: ShellConfiguration(logicPlugins: [], uiPlugins: []), library: VaultLibrary(defaults: defaults)
        )
        model.createVault(named: "a/b", in: try folder("Parent"))
        XCTAssertNil(model.session)
        XCTAssertNotNil(model.errorMessage)
    }

    func testSwitchingVaultsReplacesTheSession() throws {
        let model = AppModel(
            configuration: ShellConfiguration(logicPlugins: [], uiPlugins: []), library: VaultLibrary(defaults: defaults)
        )
        defer { model.closeVault() }
        let (a, b) = (try folder("A"), try folder("B"))
        model.openVault(a)
        model.openVault(b)
        XCTAssertEqual(model.session?.name, "B")
        XCTAssertTrue(model.session?.host === model)
        XCTAssertEqual(model.library.entries.map(\.name), ["B", "A"])
    }
}
