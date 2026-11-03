import AppKit
import AttachmentsPlugin
import Foundation
import PluginKit
import SwiftUI
import LoamCore
import XCTest
@testable import NotebookApp

private struct Marker {}

private extension ServiceKey where Service == Marker {
    static var base: ServiceKey<Marker> { ServiceKey<Marker>("test.base") }
}

/// Provides `test.base`.
private final class BasePlugin: Plugin {
    static let manifest = PluginManifest(id: "test.base", name: "Base", version: "1.0", provides: ["test.base"])
    required init() {}
    func activate(context: PluginContext) throws {
        try context.provide(.base, Marker())
    }
}

/// Requires `test.base`.
private final class UserPlugin: Plugin {
    static let manifest = PluginManifest(id: "test.user", name: "User", version: "1.0", requires: ["test.base"])
    required init() {}
    func activate(context: PluginContext) throws {}
}

/// Unrelated to the others.
private final class LonerPlugin: Plugin {
    static let manifest = PluginManifest(id: "test.loner", name: "Loner", version: "1.0")
    required init() {}
    func activate(context: PluginContext) throws {}
}

/// Always fails to start.
private final class BrokenPlugin: Plugin {
    struct Broken: Error, CustomStringConvertible { var description: String { "broken on purpose" } }
    static let manifest = PluginManifest(id: "test.broken", name: "Broken", version: "1.0")
    required init() {}
    func activate(context: PluginContext) throws { throw Broken() }
}

private let testPlugins: [Plugin.Type] = [BasePlugin.self, UserPlugin.self, LonerPlugin.self, BrokenPlugin.self]

/// Reads its settings with defaults, describes two of them, and says what it is.
private final class OptionsPlugin: Plugin {
    struct Settings: Codable, Equatable {
        var folder = "Daily"
        var showRecent = false
        var week = "monday"
        var count = 3
    }

    static let manifest = PluginManifest(
        id: "test.options", name: "Options", version: "1.0", description: "Has options.", icon: "gearshape",
        settings: [
            SettingDescription("week", title: "Week starts on", choices: [
                SettingChoice(.string("monday"), title: "Monday"), SettingChoice(.string("sunday"), title: "Sunday"),
            ]),
            SettingDescription("showRecent", title: "Show recent notes", help: "Above the folders."),
            SettingDescription("gone", title: "A key it no longer has"),
        ]
    )
    nonisolated(unsafe) static var seen: Settings?
    required init() {}
    func activate(context: PluginContext) throws {
        Self.seen = context.settings.value(default: Settings())
        context.on(PluginSettingsChanged.self) { [weak context] _ in
            Self.seen = context?.settings.value(default: Settings())
        }
    }
}

@MainActor
final class SettingsTests: ShellTestCase {
    private func makeSession(
        safeMode: Bool = false, allowlist: Set<String> = [], plugins: [Plugin.Type] = testPlugins, uiPlugins: [Plugin.Type] = []
    ) throws -> ShellSession {
        let session = try ShellSession(
            rootURL: root,
            configuration: ShellConfiguration(logicPlugins: plugins, uiPlugins: uiPlugins, safeModePlugins: allowlist),
            machineID: machineID,
            layoutSaveDelay: .seconds(60),
            safeMode: safeMode
        )
        addTeardownBlock { @MainActor in session.close() }
        return session
    }

    private func row(_ model: PluginManagerModel, _ id: String) throws -> PluginStatusRow {
        try XCTUnwrap(model.rows.first { $0.id == id }, id)
    }

    // MARK: Plugin manager

    /// The Attachments plugin's settings, as the plugin manager lists them: the folder and the switch that hides it.
    func testTheAttachmentsFolderAndItsHidingAreSettings() async throws {
        let session = try openSession(logic: [AttachmentsPlugin.self], ui: [])
        let model = PluginManagerModel(session: session)
        await model.refresh()
        XCTAssertEqual(model.settingFields(for: "attachments").map(\.key), ["attachmentsFolder", "hideAttachmentsFolder"])
        XCTAssertEqual(model.settingFields(for: "attachments").map(\.value), [.string("Attachments"), .bool(false)])
        model.updateSetting("hideAttachmentsFolder", to: .bool(true), for: "attachments")
        XCTAssertEqual(session.runtime.kernel.events.waterfall(HiddenFolders()).paths, ["Attachments"])
    }

    func testRowsComeFromPluginsList() async throws {
        let model = PluginManagerModel(session: try makeSession())
        await model.refresh()
        XCTAssertEqual(model.rows.map(\.id), ["test.base", "test.broken", "test.loner", "test.user"])
        XCTAssertEqual(try row(model, "test.base").state, .active)
        XCTAssertEqual(try row(model, "test.base").provides, ["test.base"])
        XCTAssertEqual(try row(model, "test.user").requires, ["test.base"])
        guard case .failed(let reason) = try row(model, "test.broken").state else { return XCTFail("not failed") }
        XCTAssertTrue(reason.contains("broken on purpose"), reason)
        XCTAssertNil(model.notice)
    }

    func testTurningOffAPluginWithoutDependentsDisablesItAtOnce() async throws {
        let session = try makeSession()
        let model = PluginManagerModel(session: session)
        await model.refresh()
        await model.setEnabled(false, id: "test.loner")
        XCTAssertNil(model.confirmation)
        XCTAssertEqual(try row(model, "test.loner").state, .disabled)
        XCTAssertFalse(session.runtime.config.config.isEnabled("test.loner"))
        XCTAssertFalse(session.runtime.host.isActive("test.loner"))
    }

    func testTurningOffAProviderAsksFirstThenStopsItsDependents() async throws {
        let session = try makeSession()
        let model = PluginManagerModel(session: session)
        await model.refresh()

        await model.setEnabled(false, id: "test.base")
        let confirmation = try XCTUnwrap(model.confirmation)
        XCTAssertEqual(confirmation.dependents, ["test.user"])
        XCTAssertEqual(confirmation.dependentNames, ["User"])
        XCTAssertTrue(session.runtime.host.isActive("test.base"), "nothing changes before the confirmation")

        await model.confirm(confirmation)
        XCTAssertNil(model.confirmation)
        XCTAssertEqual(try row(model, "test.base").state, .disabled)
        XCTAssertFalse(try row(model, "test.user").active)
        XCTAssertTrue(try row(model, "test.user").enabled, "dependents stay enabled in the config")
        guard case .skipped = try row(model, "test.user").state else { return XCTFail("user should be skipped") }
    }

    func testCancellingLeavesThePluginOn() async throws {
        let session = try makeSession()
        let model = PluginManagerModel(session: session)
        await model.refresh()
        await model.setEnabled(false, id: "test.base")
        model.cancelConfirmation()
        XCTAssertNil(model.confirmation)
        XCTAssertTrue(session.runtime.host.isActive("test.base"))
        XCTAssertTrue(session.runtime.config.config.isEnabled("test.base"))
    }

    func testEnablingAPluginThatCannotStartSaysWhy() async throws {
        let session = try makeSession()
        let model = PluginManagerModel(session: session)
        await model.refresh()
        await model.setEnabled(false, id: "test.broken")
        await model.setEnabled(true, id: "test.broken")
        XCTAssertTrue(try row(model, "test.broken").enabled)
        let notice = try XCTUnwrap(model.notice)
        XCTAssertTrue(notice.contains("Broken did not start"), notice)
        XCTAssertTrue(notice.contains("broken on purpose"), notice)

        await model.setEnabled(false, id: "test.loner")
        await model.setEnabled(true, id: "test.loner")
        XCTAssertNil(model.notice)
        XCTAssertEqual(try row(model, "test.loner").state, .active)
    }

    // MARK: Settings

    func testSettingsFormShowsStoredValuesAndWritesConfig() async throws {
        try write(".loam/config.json", """
        {"plugins": {"test.loner": {"settings": {"folder": "Daily", "count": 3, "on": true, "tags": ["a"]}}}}
        """)
        let session = try makeSession()
        let model = PluginManagerModel(session: session)
        XCTAssertEqual(model.settingFields(for: "test.loner").map(\.key), ["count", "folder", "on", "tags"])
        XCTAssertEqual(model.settingFields(for: "test.base"), [])

        var changed: [String] = []
        let remove = session.runtime.kernel.events.on(PluginSettingsChanged.self) { changed.append($0.pluginID) }
        defer { remove() }

        model.updateSetting("folder", to: .string("Journal"), for: "test.loner")
        model.updateSetting("on", to: .bool(false), for: "test.loner")
        model.updateSetting("count", to: .number(5), for: "test.loner")
        XCTAssertEqual(changed, ["test.loner", "test.loner", "test.loner"])
        XCTAssertNil(model.notice)

        let stored = try ConfigStore(vault: Vault(rootURL: root)).config.settings(for: "test.loner")
        XCTAssertEqual(stored, .map([
            "folder": .string("Journal"), "count": .number(5), "on": .bool(false), "tags": .list([.string("a")]),
        ]))
        XCTAssertEqual(model.settingFields(for: "test.loner").first { $0.key == "folder" }?.value, .string("Journal"))
        XCTAssertTrue(try read(".loam/config.json").contains("\"Journal\""))
    }

    func testSettingFieldsShowEveryDefaultWithTheDescribedOnesFirst() async throws {
        let session = try makeSession(plugins: [OptionsPlugin.self])
        let model = PluginManagerModel(session: session)
        await model.refresh()

        let fields = model.settingFields(for: "test.options")
        XCTAssertEqual(fields.map(\.key), ["week", "showRecent", "count", "folder"], "described first, then by key")
        XCTAssertEqual(fields.map(\.title), ["Week starts on", "Show recent notes", "Count", "Folder"])
        XCTAssertEqual(fields.map(\.value), [.string("monday"), .bool(false), .number(3), .string("Daily")])
        XCTAssertTrue(fields.allSatisfy(\.isDefault))
        XCTAssertEqual(fields[0].choices.map(\.title), ["Monday", "Sunday"])
        XCTAssertEqual(fields[1].help, "Above the folders.")

        // Only the changed key is written, so the others keep following the plugin's defaults.
        model.updateSetting("showRecent", to: .bool(true), for: "test.options")
        XCTAssertEqual(session.runtime.config.config.settings(for: "test.options"), .map(["showRecent": .bool(true)]))
        let after = model.settingFields(for: "test.options")
        XCTAssertEqual(after.first { $0.key == "showRecent" }?.value, .bool(true))
        XCTAssertEqual(after.first { $0.key == "showRecent" }?.isDefault, false)
        XCTAssertEqual(after.first { $0.key == "folder" }?.isDefault, true)
    }

    func testAValueThePluginCannotReadIsRefusedWithANotice() async throws {
        let session = try makeSession(plugins: [OptionsPlugin.self])
        let model = PluginManagerModel(session: session)
        await model.refresh()
        let count = try XCTUnwrap(model.settingFields(for: "test.options").first { $0.key == "count" })
        XCTAssertTrue(count.isWholeNumber, "the plugin reads an Int")
        XCTAssertEqual(count.kind, .number(3))

        model.updateSetting("count", to: .number(7.5), for: "test.options")
        model.updateSetting("folder", to: .bool(true), for: "test.options")
        XCTAssertNil(session.runtime.config.config.settings(for: "test.options"), "nothing written")
        let notice = try XCTUnwrap(model.notice)
        XCTAssertTrue(notice.contains("\"folder\" of test.options takes text"), notice)

        model.updateSetting("count", to: .number(7), for: "test.options")
        XCTAssertNil(model.notice, "the next saved setting clears it")
        XCTAssertEqual(session.runtime.config.config.settings(for: "test.options"), .map(["count": .number(7)]))
    }

    func testASettingChangedOutsideTheAppReachesThePluginAndTheOpenPage() async throws {
        let session = try makeSession(plugins: [OptionsPlugin.self])
        let model = PluginManagerModel(session: session)
        await model.refresh()
        XCTAssertEqual(model.settingFields(for: "test.options").first { $0.key == "folder" }?.value, .string("Daily"))

        // What `loam plugins.set-setting` does, from another process.
        try write(".loam/config.json", #"{"plugins": {"test.options": {"settings": {"folder": "Journal"}}}}"#)
        session.vaultDidChange()
        XCTAssertEqual(OptionsPlugin.seen?.folder, "Journal", "the plugin was told")
        XCTAssertEqual(model.settingFields(for: "test.options").first { $0.key == "folder" }?.value, .string("Journal"))
    }

    func testCmdWNeverClosesATabFromASheetOrAnotherWindow() {
        let notebook = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        notebook.identifier = NSUserInterfaceItemIdentifier("main-AppWindow-1")
        let settings = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        XCTAssertEqual(AppModel.closeTarget(for: notebook), .tab)
        XCTAssertEqual(AppModel.closeTarget(for: settings), .window)
        let alert = NSPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        settings.beginSheet(alert)
        XCTAssertEqual(AppModel.closeTarget(for: alert), .nothing)
        settings.endSheet(alert)
    }

    func testTheSidebarKeepsTheOpenPluginOnceItIsTurnedOff() async throws {
        let session = try makeSession(plugins: [OptionsPlugin.self, LonerPlugin.self])
        let model = PluginManagerModel(session: session)
        await model.refresh()
        XCTAssertEqual(model.sidebarPluginIDs(), ["test.options"], "the plugins with settings")

        await model.setEnabled(false, id: "test.options")
        XCTAssertEqual(model.sidebarPluginIDs(), [])
        XCTAssertEqual(model.sidebarPluginIDs(keeping: "test.options"), ["test.options"], "while its page is open")
    }

    func testSettingTitlesAreMadeFromKeys() {
        XCTAssertEqual(SettingField.title(forKey: "showRecent"), "Show recent")
        XCTAssertEqual(SettingField.title(forKey: "trash_retention_days"), "Trash retention days")
        XCTAssertEqual(SettingField.title(forKey: "attachments-folder"), "Attachments folder")
        XCTAssertEqual(SettingField.title(forKey: "imageURL"), "Image URL")
        XCTAssertEqual(SettingField.title(forKey: "URLScheme"), "URL scheme")
        XCTAssertEqual(SettingField.title(forKey: "maxWidth2x"), "Max width2x")
        XCTAssertEqual(SettingField.title(forKey: "folder"), "Folder")
        XCTAssertEqual(SettingField.title(forKey: ""), "Value")
    }

    func testRowsAreFeaturesOrServicesAndSayWhatThePluginIs() async throws {
        let model = PluginManagerModel(session: try makeSession(
            plugins: [BasePlugin.self, UserPlugin.self], uiPlugins: [OptionsPlugin.self, LonerPlugin.self]
        ))
        await model.refresh()
        XCTAssertEqual(model.featureRows.map(\.name), ["Loner", "Options"], "by name")
        XCTAssertEqual(model.serviceRows.map(\.name), ["Base", "User"])
        XCTAssertEqual(try row(model, "test.options").description, "Has options.")
        XCTAssertEqual(try row(model, "test.options").icon, "gearshape")
        XCTAssertEqual(try row(model, "test.loner").description, "")
        XCTAssertNil(try row(model, "test.loner").icon)
    }

    func testRequirementsNameThePluginsOnTheOtherSide() async throws {
        let model = PluginManagerModel(session: try makeSession())
        await model.refresh()
        XCTAssertEqual(model.requirements(of: "test.user"), [
            PluginRequirement(kind: .needs, service: "test.base", peers: [.init(id: "test.base", name: "Base")]),
        ])
        XCTAssertEqual(model.requirements(of: "test.base"), [
            PluginRequirement(kind: .provides, service: "test.base", peers: [.init(id: "test.user", name: "User")]),
        ])
        XCTAssertEqual(model.requirements(of: "test.loner"), [])

        XCTAssertEqual(model.disabledProviders(of: "test.user"), [])
        await model.setEnabled(false, id: "test.base")
        if let confirmation = model.confirmation { await model.confirm(confirmation) }
        XCTAssertEqual(model.disabledProviders(of: "test.user"), ["Base"])
        let status = PluginStatusText(model: model, row: try row(model, "test.user"))
        XCTAssertEqual(status.text, "Needs Base, which is off.")
    }

    func testNavigationOpensPanesPluginPagesAndGoesBack() {
        let navigation = SettingsNavigation()
        XCTAssertTrue(navigation.open(path: "plugins/test.user"))
        XCTAssertEqual(navigation.pane, .plugins)
        XCTAssertEqual(navigation.pluginID, "test.user")
        navigation.openPlugin("test.base")
        XCTAssertEqual(navigation.pluginID, "test.base")
        navigation.back()
        XCTAssertEqual(navigation.pluginID, "test.user", "Back returns to the page it came from")
        navigation.back()
        XCTAssertNil(navigation.pluginID, "then to the list")

        XCTAssertTrue(navigation.open(path: "appearance"))
        XCTAssertEqual(navigation.pane, .appearance)
        XCTAssertNil(navigation.pluginID)
        XCTAssertFalse(navigation.open(path: "nowhere"))
        XCTAssertEqual(navigation.pane, .appearance)
    }

    func testPluginIconsFallBackToTheDefault() {
        XCTAssertEqual(PluginIcon.symbol("calendar"), "calendar")
        XCTAssertEqual(PluginIcon.symbol("not.a.symbol.anywhere"), PluginIcon.defaultSymbol)
        XCTAssertEqual(PluginIcon.symbol(nil), PluginIcon.defaultSymbol)
        XCTAssertEqual(PluginIcon.symbol(""), PluginIcon.defaultSymbol)
        XCTAssertNil(PluginIcon.image(at: root.appendingPathComponent("missing.png")))
    }

    /// The list, a plugin's page with its settings and the other panes, rendered offscreen. Set
    /// `LOAM_SNAPSHOT_DIR` to keep the images.
    func testThePanesRender() async throws {
        let session = try makeSession(plugins: [OptionsPlugin.self] + testPlugins)
        let model = PluginManagerModel(session: session)
        await model.refresh()
        let navigation = SettingsNavigation()
        let panes: [(String, AnyView)] = [
            ("list", AnyView(PluginList(model: model) { _ in })),
            ("options", AnyView(PluginPage(model: model, id: "test.options", back: {}, open: { _ in }))),
            ("user", AnyView(PluginPage(model: model, id: "test.user", back: {}, open: { _ in }))),
            ("pane", AnyView(PluginsPane(model: model, navigation: navigation))),
            ("sidebars", AnyView(SidebarsPane(session: session))),
            ("shortcuts", AnyView(ShortcutsPane(session: session))),
        ]
        for (name, view) in panes {
            try snapshot(view, name: "settings-\(name)")
        }
    }

    private func snapshot(_ view: AnyView, name: String) throws {
        let size = CGSize(width: 680, height: 900)
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 0, name)
        if let dir = ProcessInfo.processInfo.environment["LOAM_SNAPSHOT_DIR"] {
            try bitmap.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    // MARK: Safe mode

    func testSafeModeOnlyStartsTheAllowlistAndWhatItRequires() async throws {
        let session = try makeSession(safeMode: true, allowlist: ["test.user"])
        XCTAssertTrue(session.isSafeMode)
        XCTAssertEqual(Set(session.runtime.host.activeIDs), ["test.base", "test.user"])

        let model = PluginManagerModel(session: session)
        await model.refresh()
        guard case .skipped(let reason) = try row(model, "test.loner").state else { return XCTFail("not skipped") }
        XCTAssertTrue(reason.contains("safe mode"), reason)
    }

    func testOutsideSafeModeEverythingEnabledStarts() throws {
        let session = try makeSession(safeMode: false, allowlist: ["test.user"])
        XCTAssertFalse(session.isSafeMode)
        XCTAssertEqual(Set(session.runtime.host.activeIDs), ["test.base", "test.user", "test.loner"])
    }

    func testTheAppOpensInSafeModeWithOptionAndRestartsNormally() throws {
        let suite = "SettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(
            configuration: ShellConfiguration(logicPlugins: testPlugins, uiPlugins: [], safeModePlugins: ["test.loner"]),
            launchGuard: LaunchGuard(defaults: defaults)
        )
        defer { model.closeVault() }

        model.openInitialVault(arguments: ["app", "--vault", root.path], optionHeld: true)
        XCTAssertTrue(model.isSafeMode)
        XCTAssertEqual(model.session?.runtime.host.activeIDs, ["test.loner"])

        model.restartNormally()
        XCTAssertFalse(model.isSafeMode)
        XCTAssertEqual(Set(model.session?.runtime.host.activeIDs ?? []), ["test.base", "test.user", "test.loner"])
    }

    func testTheAppConfirmsALaunchOnceTheWindowHasBeenUp() async throws {
        let suite = "SettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(
            configuration: ShellConfiguration(logicPlugins: [], uiPlugins: []),
            launchGuard: LaunchGuard(defaults: defaults),
            launchConfirmationDelay: .milliseconds(10)
        )
        defer { model.closeVault() }
        model.openInitialVault(arguments: ["app", "--vault", root.path], optionHeld: false)
        let key = AppModel.guardKey(root)
        XCTAssertEqual(LaunchGuard(defaults: defaults).pendingLaunches(vault: key), 1)
        model.windowDidAppear()
        try await waitUntil { LaunchGuard(defaults: defaults).pendingLaunches(vault: key) == 0 }
    }
}

final class LaunchGuardTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suite = "LaunchGuardTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testAFirstLaunchIsNormal() {
        var launchGuard = LaunchGuard(defaults: defaults)
        XCTAssertFalse(launchGuard.willLaunch(vault: "/v", optionHeld: false))
    }

    func testHoldingOptionAsksForSafeMode() {
        var launchGuard = LaunchGuard(defaults: defaults)
        XCTAssertTrue(launchGuard.willLaunch(vault: "/v", optionHeld: true))
    }

    func testTwoUnconfirmedLaunchesInARowTriggerSafeMode() {
        var launchGuard = LaunchGuard(defaults: defaults)
        XCTAssertFalse(launchGuard.willLaunch(vault: "/v", optionHeld: false))
        XCTAssertFalse(launchGuard.willLaunch(vault: "/v", optionHeld: false))
        XCTAssertTrue(launchGuard.willLaunch(vault: "/v", optionHeld: false))
        // Persisted: a new process reads the same counter.
        var next = LaunchGuard(defaults: defaults)
        XCTAssertTrue(next.willLaunch(vault: "/v", optionHeld: false))
    }

    func testASuccessfulLaunchResetsTheCount() {
        var launchGuard = LaunchGuard(defaults: defaults)
        _ = launchGuard.willLaunch(vault: "/v", optionHeld: false)
        _ = launchGuard.willLaunch(vault: "/v", optionHeld: false)
        launchGuard.didLaunchSuccessfully(vault: "/v")
        XCTAssertEqual(launchGuard.pendingLaunches(vault: "/v"), 0)
        XCTAssertFalse(launchGuard.willLaunch(vault: "/v", optionHeld: false))
    }

    func testCountsArePerVault() {
        var launchGuard = LaunchGuard(defaults: defaults)
        _ = launchGuard.willLaunch(vault: "/a", optionHeld: false)
        _ = launchGuard.willLaunch(vault: "/a", optionHeld: false)
        XCTAssertFalse(launchGuard.willLaunch(vault: "/b", optionHeld: false))
        XCTAssertTrue(launchGuard.willLaunch(vault: "/a", optionHeld: false))
    }
}
