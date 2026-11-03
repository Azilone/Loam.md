// swift-tools-version:5.10
import PackageDescription

// To add a first-party plugin: put it in Sources/Plugins/<Name> and Tests/Plugins/<Name>, add <Name> to
// `plugins` below, and list its type in Sources/BuiltinPlugins/BuiltinPlugins.swift.
let plugins = ["NoteGraph", "DailyNotes", "HabitTracker", "ObsidianImport", "TruffleSearch", "FileExplorer", "NoteQuery", "Tasks", "Canvas", "Collections", "GitSync", "Trash", "Attachments", "Squeeze", "Meetings", "Excalidraw", "Assistant", "Projects", "NotesImport"]

// Extra dependencies a plugin needs beyond PluginKit.
let pluginDependencies: [String: [Target.Dependency]] = [
    "NoteGraph": [
        .product(name: "Markdown", package: "swift-markdown"),
        .product(name: "Yams", package: "Yams"),
    ],
    // AES-GCM-SIV (deterministic encryption of what goes to the remote) lives in _CryptoExtras, on BoringSSL.
    // SwiftASN1 comes with it; listed here only so its version limit below applies.
    "GitSync": [
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "_CryptoExtras", package: "swift-crypto"),
        .product(name: "SwiftASN1", package: "swift-asn1"),
    ],
    "Collections": [.product(name: "Yams", package: "Yams")],
]

// Extra modules a plugin's tests use, such as another plugin for an integration test. Only tests may do
// this: plugin targets never import each other.
let pluginTestDependencies: [String: [Target.Dependency]] = [
    "FileExplorer": ["NoteGraphPlugin"],
    "NoteQuery": ["NoteGraphPlugin"],
    "Trash": ["FileExplorerPlugin"],
    "Attachments": ["NoteGraphPlugin"],
    "Squeeze": ["NoteGraphPlugin", "AttachmentsPlugin"],
    "GitSync": ["GitCryptTool"],
    "Collections": ["NoteGraphPlugin", "NoteQueryPlugin"],
    "Excalidraw": ["AttachmentsPlugin"],
    "Projects": ["NoteGraphPlugin", "NoteQueryPlugin", "CollectionsPlugin"],
]

let pluginTargets: [Target] = plugins.flatMap { name -> [Target] in
    [
        .target(
            name: "\(name)Plugin",
            dependencies: ["PluginKit"] + (pluginDependencies[name] ?? []),
            path: "Sources/Plugins/\(name)"
        ),
        .testTarget(
            name: "\(name)PluginTests",
            dependencies: [.byName(name: "\(name)Plugin"), "LoamCore", "PluginKit", "PluginKitTesting"]
                + (pluginTestDependencies[name] ?? []),
            path: "Tests/Plugins/\(name)",
            // Recorded agent transcripts, read from the source folder.
            exclude: name == "Assistant" ? ["Fixtures"] : []
        ),
    ]
}

let package = Package(
    name: "Loam",
    platforms: [.macOS(.v13)],
    products: [
        // The runtime: one shared library holding the SDK, the kernel, the test helpers, the CLI's logic and every
        // first-party logic plugin. The `loam` command line (CLI/), the app (App/) and every third-party plugin link
        // it dynamically, so a process holds exactly one copy of each PluginKit type: a plugin loaded at run time
        // shares the app's protocols and services. Nothing may link these modules statically next to it (see
        // docs/PLUGIN-LOADING.md), which is why this is the package's only product.
        .library(
            name: "LoamRuntime",
            type: .dynamic,
            targets: ["PluginKit", "LoamCore", "PluginKitTesting", "LoamCLI", "BuiltinPlugins"]
                + plugins.map { "\($0)Plugin" }
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.5.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
        // 3.x: 4.0 needs swift-tools 6.0, and the root package must keep building with the Linux container's Swift.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.15.1"..<"4.0.0"),
        // swift-crypto's own dependency, below 1.7 (which needs swift-tools 6.1) for the same reason.
        .package(url: "https://github.com/apple/swift-asn1.git", "1.2.0"..<"1.7.0"),
    ],
    targets: [
        // The SDK plugins build against: protocols and types only, no implementation. Built with library evolution
        // on Apple platforms, so a plugin compiled against one version keeps running when the SDK only gains API
        // (docs/PLUGIN-LOADING.md, "Plugin SDK version"). Linux has no stable ABI: there plugins match the build id.
        .target(
            name: "PluginKit",
            swiftSettings: [.unsafeFlags(["-enable-library-evolution"], .when(platforms: [.macOS, .iOS]))]
        ),
        // The minimal core: kernel, vault, registries, event bus, plugin host.
        .target(name: "LoamCore", dependencies: ["PluginKit"]),
        // Test helpers for plugins: a temporary vault and a kernel with plugins active. No XCTest, so any
        // test framework can use it.
        .target(name: "PluginKitTesting", dependencies: ["PluginKit", "LoamCore"]),
        // The `loam` command line's logic; its executable is the package in CLI/, on the runtime library.
        .target(name: "LoamCLI", dependencies: ["PluginKit", "LoamCore"]),
        // The list of first-party plugins, shared by the CLI and the app.
        .target(
            name: "BuiltinPlugins",
            dependencies: ["PluginKit"] + plugins.map { Target.Dependency.target(name: "\($0)Plugin") }
        ),
        .testTarget(
            name: "LoamCoreTests",
            dependencies: ["LoamCore", "PluginKit", "PluginKitTesting"]
        ),
        .testTarget(
            name: "LoamCLITests",
            dependencies: ["LoamCLI", "DailyNotesPlugin", "LoamCore", "PluginKit"]
        ),
        .testTarget(
            name: "BuiltinPluginsTests",
            dependencies: ["BuiltinPlugins", "LoamCore", "PluginKit"]
        ),
        // `make perf`: times the vault-wide work (walk, index, search, tasks) on a big generated vault.
        .executableTarget(
            name: "LoamBench",
            dependencies: ["LoamCore", "PluginKit", "NoteGraphPlugin", "TasksPlugin", "TruffleSearchPlugin"],
            path: "Tests/LoamBench"
        ),
        // `loam crypt` for the git sync's tests: git runs it as the encryption filter and merge driver, without
        // building CLI/. A separate process that loads no plugin, so its static copy of the modules is harmless.
        .executableTarget(
            name: "GitCryptTool",
            dependencies: ["GitSyncPlugin"],
            path: "Tests/GitCryptTool"
        ),
    ] + pluginTargets
)
