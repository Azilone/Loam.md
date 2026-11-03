import Foundation

/// The package `plugins.new` writes in `.loam/plugins/<id>/`: a working plugin to start from.
///
/// - Logic (`ui: false`): swift-tools 5.10, macOS 13, builds on Linux; links `LoamRuntime` only.
/// - UI (`ui: true`): swift-tools 6.2, macOS 26; links `LoamRuntime` and `LoamUIRuntime` only.
///
/// Both find the SDK through `$LOAM_SDK` (set by `loam plugin build`), defaulting to the app in /Applications so the
/// package also opens in Xcode. Linking only the runtime products keeps one copy of every type in the process.
public struct PluginTemplate: Equatable {
    public let id: String
    public let name: String
    public let ui: Bool

    /// `hello-world` -> `HelloWorld`: the module; the plugin class is `<module>Plugin`, the library too.
    public let module: String

    public init(id: String, name: String? = nil, ui: Bool) throws {
        guard Self.isValidID(id) else { throw PluginPackageError.invalidID(id) }
        let module = id.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        guard !Self.reservedModules.contains(module), !Self.reservedModules.contains(module + "Plugin") else {
            throw PluginPackageError.reservedName(id)
        }
        self.id = id
        self.module = module
        let given = name?.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces) ?? ""
        let words = id.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }
        self.name = given.isEmpty ? words.joined(separator: " ") : given
        self.ui = ui
    }

    public var library: String { module + "Plugin" }
    var pluginClass: String { module + "Plugin" }

    /// kebab-case starting with a letter: it names a folder and, in PascalCase, a Swift module.
    public static func isValidID(_ id: String) -> Bool {
        let parts = id.split(separator: "-", omittingEmptySubsequences: false)
        guard let first = id.first, first.isASCII, first.isLowercase, !id.hasSuffix("-") else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber) }
        }
    }

    /// Module names of the SDK and its dependencies, which a plugin's module or library must not reuse.
    static let reservedModules: Set<String> = [
        "PluginKit", "PluginKitTesting", "LoamCore", "LoamCLI", "BuiltinPlugins", "PluginKitUI",
        "PluginKitUITesting", "MarkdownEditor", "WorkspaceModel", "NotebookApp", "BuiltinUIPlugins", "Markdown",
        "Yams", "CAtomic", "LoamRuntime", "LoamUIRuntime", "Foundation", "SwiftUI", "XCTest",
        "NoteGraphPlugin", "DailyNotesPlugin", "HabitTrackerPlugin", "ObsidianImportPlugin", "TruffleSearchPlugin",
        "FileExplorerPlugin", "NoteQueryPlugin", "TasksPlugin",
    ]

    /// What the template's code touches: it counts the vault's notes, and a panel needs `ui`.
    private var permissionsJSON: String {
        ui ? #"["ui", "vault.read"]"# : #"["vault.read"]"#
    }

    var manifestJSON: String {
        """
        {
          "id": "\(id)",
          "name": "\(name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))",
          "version": "0.1.0",
          "description": "",
          "icon": "puzzlepiece.extension",
          "library": "\(library)",
          "permissions": \(permissionsJSON)
        }

        """
    }

    /// Vault-relative paths (inside the plugin folder) and their contents.
    public var files: [String: String] {
        [
            "plugin.json": manifestJSON,
            "Package.swift": ui ? uiPackage : logicPackage,
            "Sources/\(module)/\(pluginClass).swift": ui ? uiSource : logicSource,
            "Tests/\(module)Tests/\(pluginClass)Tests.swift": ui ? uiTest : logicTest,
            "README.md": readme,
            ".gitignore": ".build/\n.swiftpm/\n",
        ]
    }

    private var sdkLine: String {
        """
        // The Loam SDK: the sources of the app this plugin runs in. `loam plugin build` sets LOAM_SDK; the default
        // is the SDK inside the app, so the package also opens in Xcode.
        let sdk = ProcessInfo.processInfo.environment["LOAM_SDK"]
            ?? "/Applications/Loam.app/Contents/Resources/SDK/loam"
        """
    }

    private var logicPackage: String {
        """
        // swift-tools-version:5.10
        import Foundation
        import PackageDescription

        \(sdkLine)

        // A Loam plugin: a dynamic library the app loads from .loam/cache/plugins/\(id)/. It links the app's
        // runtime library and nothing else from the SDK, so the process holds one copy of every type.
        let package = Package(
            name: "\(module)",
            platforms: [.macOS(.v13)],
            products: [
                .library(name: "\(library)", type: .dynamic, targets: ["\(module)"]),
            ],
            dependencies: [
                .package(name: "loam", path: sdk),
            ],
            targets: [
                .target(
                    name: "\(module)",
                    dependencies: [.product(name: "LoamRuntime", package: "loam")]
                ),
                .testTarget(
                    name: "\(module)Tests",
                    dependencies: ["\(module)", .product(name: "LoamRuntime", package: "loam")]
                ),
            ]
        )

        """
    }

    private var uiPackage: String {
        """
        // swift-tools-version:6.2
        import Foundation
        import PackageDescription

        \(sdkLine)

        // A Loam UI plugin: a dynamic library the app loads from .loam/cache/plugins/\(id)/. It links the app's
        // two runtime libraries and nothing else from the SDK, so the process holds one copy of every type.
        let runtime: Target.Dependency = .product(name: "LoamRuntime", package: "loam")
        let uiRuntime: Target.Dependency = .product(name: "LoamUIRuntime", package: "App")

        let package = Package(
            name: "\(module)",
            platforms: [.macOS(.v26)],
            products: [
                .library(name: "\(library)", type: .dynamic, targets: ["\(module)"]),
            ],
            dependencies: [
                .package(name: "loam", path: sdk),
                .package(path: sdk + "/App"),
            ],
            targets: [
                .target(name: "\(module)", dependencies: [runtime, uiRuntime]),
                .testTarget(name: "\(module)Tests", dependencies: ["\(module)", runtime, uiRuntime]),
            ]
        )

        """
    }

    private var logicSource: String {
        """
        import PluginKit

        /// \(name): a Loam plugin. Its command reaches the palette, the CLI (`loam \(id).hello`) and agents.
        public final class \(pluginClass): Plugin {
            public static var manifest: PluginManifest {
                PluginManifest(id: "\(id)", name: "\(swiftString(name))", version: "0.1.0")
            }

            public required init() {}

            public func activate(context: PluginContext) throws {
                let vault = context.vault
                try context.registerCommand(Command(
                    id: "\(id).hello",
                    title: "\(swiftString(name)): say hello",
                    summary: "Says hello and how many notes the vault has. No arguments; optional: name."
                ) { arguments in
                    let notes = try vault.markdownPaths().count
                    return "Hello \\(arguments["name"] ?? "from \(swiftString(name))"). Notes in this vault: \\(notes)."
                })
            }
        }

        /// The entry the app looks for. `PluginEntry(plugins:)` records the runtime build this plugin is compiled
        /// against, so the app refuses it once it changes ("rebuild it with `loam plugin build`").
        @_cdecl("loam_plugin_entry")
        public func loamPluginEntry() -> UnsafeMutableRawPointer {
            Unmanaged.passRetained(PluginEntry(plugins: [\(pluginClass).self])).toOpaque()
        }

        """
    }

    private var uiSource: String {
        """
        import PluginKit
        import PluginKitUI
        import SwiftUI

        /// \(name): a Loam UI plugin. It adds a panel to the right sidebar and a command that reaches the
        /// palette, the CLI (`loam \(id).hello`) and agents.
        public final class \(pluginClass): UIPlugin {
            public static var manifest: PluginManifest {
                PluginManifest(id: "\(id)", name: "\(swiftString(name))", version: "0.1.0")
            }

            public required init() {}

            @MainActor
            public func activateUI(context: PluginContext) throws {
                let counter = NoteCounter(vault: context.vault)
                try context.registerPanel(Panel(
                    id: "\(id).panel",
                    title: "\(swiftString(name))",
                    symbol: "hand.wave",
                    slot: .trailing
                ) {
                    AnyView(\(module)Panel(notes: counter.count()))
                })
                try context.registerCommand(Command(
                    id: "\(id).hello",
                    title: "\(swiftString(name)): say hello",
                    summary: "Says hello and how many notes the vault has. No arguments."
                ) { _ in
                    await MainActor.run { "Hello from \(swiftString(name)). Notes in this vault: \\(counter.count())." }
                })
            }
        }

        /// Reads the vault on the main actor, where the app's plugins run, so commands and views can share it.
        @MainActor
        final class NoteCounter {
            private let vault: any VaultAccess

            init(vault: any VaultAccess) {
                self.vault = vault
            }

            func count() -> Int {
                (try? vault.markdownPaths().count) ?? 0
            }
        }

        /// Drawn with the app's design system (docs/UI-RULES.md): theme colours, the type scale (`.ui(.body)`), the
        /// spacing scale (`Space`). A page of its own would start from `PageScaffold`.
        struct \(module)Panel: View {
            let notes: Int
            @Environment(\\.themeTokens) private var theme

            var body: some View {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Hello from \(swiftString(name))")
                        .font(.ui(.emphasis))
                        .foregroundStyle(theme.text)
                    Text("Notes in this vault: \\(notes)")
                        .font(.ui(.body))
                        .foregroundStyle(theme.secondaryText)
                }
                .padding(Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }

        /// The entry the app looks for. `PluginEntry(plugins:)` records the runtime build this plugin is compiled
        /// against, so the app refuses it once it changes ("rebuild it with `loam plugin build`").
        @_cdecl("loam_plugin_entry")
        public func loamPluginEntry() -> UnsafeMutableRawPointer {
            Unmanaged.passRetained(PluginEntry(plugins: [\(pluginClass).self])).toOpaque()
        }

        """
    }

    private var logicTest: String {
        """
        import PluginKitTesting
        import XCTest
        @testable import \(module)

        final class \(pluginClass)Tests: XCTestCase {
            func testSaysHelloWithTheNoteCount() async throws {
                let harness = try PluginTestHarness([\(pluginClass).self], files: ["one.md": "# One", "two.md": "# Two"])
                let output = try await harness.run("\(id).hello", ["name": "Ada"])
                XCTAssertEqual(output, "Hello Ada. Notes in this vault: 2.")
            }
        }

        """
    }

    private var uiTest: String {
        """
        import PluginKitUITesting
        import XCTest
        @testable import \(module)

        @MainActor
        final class \(pluginClass)Tests: XCTestCase {
            func testAddsItsPanelAndCommand() async throws {
                let harness = try UIPluginHarness(uiPlugins: [\(pluginClass).self], files: ["one.md": "# One"])
                defer { harness.close() }
                XCTAssertTrue(harness.report.failed.isEmpty, "\\(harness.report.failed)")
                let panel = try XCTUnwrap(harness.panels.all.first { $0.id == "\(id).panel" })
                _ = harness.render(panel.makeView())
                let output = try await harness.run("\(id).hello")
                XCTAssertEqual(output, "Hello from \(swiftString(name)). Notes in this vault: 1.")
            }
        }

        """
    }

    private var readme: String {
        """
        # \(name)

        A \(ui ? "UI " : "")plugin for Loam, made with `loam plugin new \(id)\(ui ? " --ui" : "")`.

        ```bash
        loam plugin build \(id)              # compiles it into .loam/cache/plugins/\(id)/
        loam plugins.enable id=\(id)         # or enable it in Settings > Plugins
        loam \(id).hello                     # runs its command
        ```

        - `plugin.json`: id, name, version, the library (`\(library)`), and the permissions the plugin manager shows
          before it is enabled.
        - `Sources/\(module)/\(pluginClass).swift`: the plugin. Edit it, then `loam plugin build \(id)` again and relaunch
          the app (a loaded library is not reloaded).
        - Tests: `LOAM_SDK=<sdk> swift test`, where the SDK is `Loam.app/Contents/Resources/SDK/loam`.

        The plugin must be built by the `swift` the app was built with, against the app's SDK; `loam plugin build` does
        that. A plugin built for another version of the app is refused until it is rebuilt.

        """
    }

    private func swiftString(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
