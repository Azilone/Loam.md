import BuiltinPlugins
import ObsidianImportPlugin
import PluginKit
import PluginKitUI
import PluginKitUITesting
import XCTest
@testable import ImportUI

@MainActor
final class ImportUITests: XCTestCase {
    private let logic = builtinPlugins.filter { $0.manifest.id == "obsidian-import" }
    private var source: URL!

    override func setUpWithError() throws {
        source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("Brain")
        for (path, text) in [
            "Home.md": "# Home\n[[Plan]]\n",
            "Plan.md": "# Plan\n",
            ".obsidian/community-plugins.json": "[\"dataview\"]",
        ] {
            let url = source.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
    }

    private func model(_ harness: UIPluginHarness) throws -> ImportModel {
        try XCTUnwrap(harness.kernel.services.service(ImportUIPlugin.modelKey))
    }

    func testRegistersThePageAndUnloadsCleanly() throws {
        let harness = try UIPluginHarness(logicPlugins: logic, uiPlugins: [ImportUIPlugin.self])
        defer { harness.close() }
        XCTAssertTrue(harness.host.isActive("import-ui"), "\(harness.report)")
        XCTAssertEqual(harness.views.viewTypes(for: ImportUIPlugin.resource).map(\.id), ["import.page"])
        XCTAssertNotNil(harness.kernel.commands.command(id: "import.open"))
        harness.host.deactivateAll()
        XCTAssertEqual(harness.views.all.map(\.id), [])
        XCTAssertNil(harness.kernel.commands.command(id: "import.open"))
    }

    func testThePromptSendsTheAgentToTheMigrationGuide() {
        let prompt = ImportModel.migrationPrompt(cli: "/Applications/Loam.app/Contents/Helpers/loam")
        XCTAssertTrue(prompt.contains("\"/Applications/Loam.app/Contents/Helpers/loam\" guide migrate"))
        XCTAssertTrue(prompt.contains("three questions"))
    }

    func testImportsIntoItsOwnFolderWithAReport() async throws {
        let harness = try UIPluginHarness(logicPlugins: logic, uiPlugins: [ImportUIPlugin.self])
        defer { harness.close() }
        let model = try model(harness)
        let vault = ObsidianVaults.vault(at: source)
        XCTAssertEqual(vault.notes, 2)

        // No assistant here: the import stays plain.
        await model.start(vault)
        guard case .done(_, _, let reportPath) = model.step else { return XCTFail("\(model.step)") }
        XCTAssertEqual(try harness.kernel.vault.read("Imported/Brain/Home.md"), "# Home\n[Plan](Plan.md)\n")
        XCTAssertEqual(reportPath, "Imported/Brain/Import report.md")
        XCTAssertTrue(try harness.kernel.vault.read(reportPath).contains("2 notes converted"))
    }

    func testTheOnboardingsRequestImportsAtOnce() async throws {
        let harness = try UIPluginHarness(logicPlugins: logic, uiPlugins: [ImportUIPlugin.self])
        defer { harness.close() }
        let model = try model(harness)
        harness.kernel.events.emit(ObsidianImportRequested(path: source.path))
        for _ in 0..<50 {
            if case .done = model.step { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard case .done(_, _, let reportPath) = model.step else { return XCTFail("\(model.step)") }
        XCTAssertTrue(harness.kernel.vault.exists("Home.md"), "without an agent, the converter writes at the vault's root")
        XCTAssertEqual(reportPath, "Import report.md")
    }

    func testTheBriefAsksOnlyForWhatWasLost() {
        let vault = ObsidianVault(name: "Brain", path: "/x/Brain", notes: 1, opened: nil)
        var report = ImportReport(dryRun: false)
        XCTAssertFalse(ImportModel.needsAgent(report))
        report.communityPlugins = ["dataview", "calendar"]
        XCTAssertTrue(ImportModel.needsAgent(report))
        let brief = ImportModel.brief(vault, report)
        XCTAssertTrue(brief.contains("Dataview"))
        XCTAssertFalse(brief.contains("Templater"))
        XCTAssertTrue(brief.contains("calendar"))
        XCTAssertTrue(brief.contains("Never touch the original vault at /x/Brain"))
        XCTAssertTrue(brief.contains("never create another `.loam` folder"))
    }
}
