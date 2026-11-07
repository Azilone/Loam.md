import AppKit
import BuiltinPlugins
import BuiltinUIPlugins
import PluginKitUI
import PluginKitUITesting
import SwiftUI
import XCTest

/// Stands in for real UI plugins while `builtinUIPlugins` is empty, so every check below runs on something.
private final class ProbeUIPlugin: UIPlugin {
    static let manifest = PluginManifest(id: "probe.ui", name: "Probe", version: "1.0", optionalRequires: ["editor"])

    init() {}

    @MainActor func activateUI(context: PluginContext) throws {
        try context.registerView(ViewType(
            id: "probe.page",
            title: "Probe page",
            canOpen: { $0.path.hasPrefix("probe:") },
            makeView: { context in AnyView(Text(context.resource.name)) }
        ))
        try context.registerPanel(Panel(id: "probe.status", title: "Probe", symbol: "circle", slot: .statusBar) {
            AnyView(Text("probe"))
        })
        try context.registerCommand(Command(
            id: "probe.ping",
            title: "Ping",
            summary: "Answers pong; checks that a UI plugin's commands reach the command center."
        ) { _ in "pong" })
    }
}

/// Every first-party UI plugin, with the logic plugins available: each activates alone and with the others,
/// unloading leaves nothing behind, every view and panel renders, and commands are usable by agents.
@MainActor
final class BuiltinUIPluginsTests: XCTestCase {
    private let uiPlugins: [Plugin.Type] = builtinUIPlugins + [ProbeUIPlugin.self]
    private let files = ["Welcome.md": "# Welcome\n\nHello.\n", "Projects/Plan.md": "# Plan\n",
                         "Maps/Ideas.md": "---\nmindmap-plugin: basic\n---\n\n# Ideas\n\n- One\n",
                         "Reading/Reading.base": "filters: file.inFolder(\"Reading\")\nviews:\n  - type: table\n    name: Table\n",
                         "Reading/Book.md": "---\nstatus: reading\n---\n# Book\n",
                         "Boards/Example.canvas": #"{"nodes":[{"id":"a","type":"file","file":"Welcome.md","x":0,"y":0,"width":400,"height":400}]}"#,
                         "Drawings/Sketch.excalidraw.md": "---\nexcalidraw-plugin: parsed\n---\n"]

    /// Every view type must open at least one of these, so it can be rendered here. Add one when a view type
    /// opens a new kind of resource.
    private let sampleResources: [Resource] = [
        .file("Welcome.md"), .file("Projects/Plan.md"), .file("Maps/Ideas.md"), .folder(""), .folder("Projects"), .virtual("probe:sample"),
        .virtual("calendar:"), .virtual("habits:"), .virtual("meetings:"), .virtual("graph:"), .virtual("mindmap:Welcome.md"),
        .virtual("tasks:"), .virtual("collection:#project"), .virtual("trash:Recently Deleted"),
        .file("Reading/Reading.base"), .folder("Reading"),
        .file("Boards/Example.canvas"), .file("Drawings/Sketch.excalidraw.md"), .virtual("home:"), .virtual("home:activity"), .virtual("home:today"), .virtual("home:overview"), .virtual("import:"),
        .file("Attachments/photo.png"), .file("Attachments/paper.pdf"), .file("Attachments/clip.mp4"),
    ]

    private func harness(_ plugins: [Plugin.Type]) throws -> UIPluginHarness {
        try UIPluginHarness(logicPlugins: builtinPlugins, uiPlugins: plugins, files: files)
    }

    func testEachUIPluginActivatesAlone() throws {
        for plugin in uiPlugins {
            let harness = try harness([plugin])
            defer { harness.close() }
            let id = plugin.manifest.id
            XCTAssertTrue(harness.host.isActive(id), "\(id): \(harness.report)")
        }
    }

    func testEveryPluginActivatesTogetherWithoutConflicts() throws {
        let harness = try harness(uiPlugins)
        defer { harness.close() }
        XCTAssertEqual(harness.report.failed, [:])
        XCTAssertEqual(harness.report.skipped, [:])
        XCTAssertEqual(Set(harness.host.activeIDs), Set((builtinPlugins + uiPlugins).map { $0.manifest.id }))
    }

    func testUnloadingEverythingLeavesNoCommandViewOrPanel() throws {
        let harness = try harness(uiPlugins)
        defer { harness.close() }
        XCTAssertFalse(harness.views.all.isEmpty)
        harness.host.deactivateAll()
        XCTAssertEqual(harness.host.activeIDs, [])
        XCTAssertEqual(harness.kernel.commands.all.map(\.id), [])
        XCTAssertEqual(harness.views.all.map(\.id), [])
        XCTAssertEqual(harness.panels.all.map(\.id), [])
    }

    func testEveryViewAndPanelRendersOffscreen() throws {
        let harness = try harness(uiPlugins)
        defer { harness.close() }
        let size = CGSize(width: 480, height: 320)
        for type in harness.views.all {
            let openable = sampleResources.filter(type.canOpen)
            XCTAssertFalse(openable.isEmpty, "\(type.id) opens none of the sample resources: add one")
            for resource in openable {
                let view = harness.render(type.makeView(ViewContext(resource: resource)), size: size)
                XCTAssertEqual(view.frame.size, size, "\(type.id) on \(resource.path)")
            }
        }
        for slot in Slot.allCases {
            for panel in harness.panels.panels(in: slot) {
                XCTAssertEqual(harness.render(panel.makeView(), size: size).frame.size, size, panel.id)
            }
        }
    }

    func testCommandsViewsAndPanelsHaveAgentFriendlyNames() throws {
        let harness = try harness(uiPlugins)
        defer { harness.close() }
        XCTAssertFalse(harness.kernel.commands.all.isEmpty)
        for command in harness.kernel.commands.all {
            XCTAssertFalse(command.title.isEmpty, command.id)
            XCTAssertGreaterThan(command.summary.count, 20, "\(command.id) needs a summary an agent can act on")
            XCTAssertTrue(command.id.contains("."), "\(command.id) should look like area.action")
        }
        // The palette lists commands by title: two identical titles cannot be told apart.
        let titles = Dictionary(grouping: harness.kernel.commands.all, by: \.title).filter { $0.value.count > 1 }
        XCTAssertTrue(titles.isEmpty, "commands sharing a title: \(titles.mapValues { $0.map(\.id) })")
        for id in harness.views.all.map(\.id) + harness.panels.all.map(\.id) {
            XCTAssertTrue(id.contains("."), "\(id) should be dotted and start with its plugin's area")
        }
    }

    /// The UI plugins that change notes (directly or through a service). Add one here when it starts writing.
    private let writers: Set<String> = [
        "markdown-editor", "file-explorer", "quick-switcher", "daily-notes-ui", "habits-ui", "tasks-ui",
        "mindmap", "trash-ui", "attachments-ui", "squeeze-ui", "meetings-ui",
        "collections-ui", "collection-table", "collection-kanban", "canvas-ui", "git-sync-ui", "home-ui",
        "excalidraw-ui", "projects-ui", "import-ui", "capture-ui",
    ]

    /// Every first-party UI plugin declares `ui` and what it does to notes, with known permissions only.
    func testEveryUIPluginDeclaresItsPermissions() {
        for plugin in builtinUIPlugins {
            let manifest = plugin.manifest
            XCTAssertTrue(manifest.permissions.contains("ui"), manifest.id)
            XCTAssertTrue(manifest.permissions.contains("vault.read"), manifest.id)
            XCTAssertEqual(manifest.permissions.contains("vault.write"), writers.contains(manifest.id), manifest.id)
            for permission in manifest.declaredPermissions {
                guard case .known = permission else { return XCTFail("\(manifest.id): unknown \(permission.rawValue)") }
            }
        }
    }

    /// Every first-party plugin says what it does in one line and has an icon this system can draw, so its row in
    /// Settings > Plugins never falls back to the default.
    func testEveryPluginHasADescriptionAndAnIcon() {
        for plugin in builtinPlugins + builtinUIPlugins {
            let manifest = plugin.manifest
            XCTAssertFalse(manifest.description.isEmpty, manifest.id)
            XCTAssertFalse(manifest.description.contains("\n"), manifest.id)
            let icon = try? XCTUnwrap(manifest.icon, manifest.id)
            XCTAssertNotNil(icon.flatMap { NSImage.symbol($0, accessibilityDescription: nil) },
                            "\(manifest.id): \(icon ?? "no icon") is not an SF Symbol nor one of Loam's")
            for setting in manifest.settings {
                XCTAssertFalse(setting.title.isEmpty, "\(manifest.id).\(setting.key)")
            }
        }
    }

    /// Every setting a first-party plugin describes is a key it reads, with the default it reads it with: a typo in
    /// a key, or a default that drifted from the plugin's `Codable` one, would show a setting that does nothing.
    func testDescribedSettingsAreTheKeysAndDefaultsThePluginsRead() throws {
        let harness = try harness(builtinUIPlugins)
        defer { harness.close() }
        for plugin in builtinPlugins + builtinUIPlugins where !plugin.manifest.settings.isEmpty {
            let id = plugin.manifest.id
            XCTAssertTrue(harness.host.isActive(id), "\(id): \(harness.report)")
            guard case .map(let read)? = harness.kernel.settingsDefault(for: id) else {
                XCTFail("\(id) describes settings but never reads them")
                continue
            }
            for setting in plugin.manifest.settings {
                XCTAssertNotNil(read[setting.key], "\(id) does not read \(setting.key)")
                if let described = setting.defaultValue {
                    XCTAssertEqual(described, read[setting.key], "\(id).\(setting.key): the described default drifted")
                }
            }
        }
    }
}
