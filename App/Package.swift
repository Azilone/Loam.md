// swift-tools-version:6.2
import PackageDescription

// The macOS app. It is a separate package because it needs macOS 26 and a newer Swift than the root package,
// which must keep building on Linux. It uses the root package by path, so the repository folder keeps its name
// (`loam`, the package identity below).
//
// Every module here links the root package's one product, the dynamic `LoamRuntime` (PluginKit, the kernel,
// the logic plugins, swift-markdown), and nothing else from it: a static copy of PluginKit next to the runtime would
// give the process two copies of every type (docs/PLUGIN-LOADING.md). The modules a third-party UI plugin may import
// are the dynamic `LoamUIRuntime`. The executable is the package in `Executable/`, because an executable
// links the targets of its own package statically.
let runtime: Target.Dependency = .product(name: "LoamRuntime", package: "loam")

let package = Package(
    name: "LoamApp",
    platforms: [.macOS(.v26)],
    products: [
        // The UI runtime: the UI contracts, their test helpers, the editor, the workspace model, the shell and the
        // first-party UI plugins, in one shared library the app executable and third-party UI plugins link.
        .library(
            name: "LoamUIRuntime",
            type: .dynamic,
            targets: ["PluginKitUI", "PluginKitUITesting", "MarkdownEditor", "WorkspaceModel", "DebugProtocol", "NotebookApp", "BuiltinUIPlugins"]
        ),
    ],
    dependencies: [
        .package(name: "loam", path: ".."),
    ],
    targets: [
        // The UI contracts plugins build against: views, panels, workspace, quick pick, editor, theme. Built with
        // library evolution, like PluginKit, so UI plugins survive releases that only add API.
        .target(
            name: "PluginKitUI",
            dependencies: [runtime],
            swiftSettings: [.unsafeFlags(["-enable-library-evolution"])]
        ),
        // Test helpers for UI plugins: recording fakes of the UI services and a harness with the host services
        // in place. No XCTest, so any test framework can use it.
        .target(
            name: "PluginKitUITesting",
            dependencies: [
                "PluginKitUI",
                runtime,
            ]
        ),
        // The list of first-party UI plugins, registered by the app next to the logic `builtinPlugins`.
        .target(name: "BuiltinUIPlugins", dependencies: ["PluginKitUI", "MarkdownEditorUI", "QuickSwitcherUI", "FileExplorerUI", "BacklinksUI", "OutlineUI", "DailyNotesUI", "SearchUI", "HabitsUI", "GraphUI", "MindmapUI", "TasksUI", "NoteInfoUI", "DiagramsUI", "CollectionsUI", "CollectionTableUI", "CollectionKanbanUI", "CollectionCardsUI", "TagsUI", "CanvasUI", "GitSyncUI", "TrashUI", "AttachmentsUI", "SqueezeUI", "FileViewersUI", "HomeUI", "MeetingsUI", "ExcalidrawUI", "IntroUI", "SoundsUI", "AssistantUI", "ProjectsUI", "ImportUI", "CaptureUI"]),
        // The Markdown editor: the view for `.md` files, the shared documents and the `editor` service.
        .target(
            name: "MarkdownEditorUI",
            dependencies: ["PluginKitUI", "MarkdownEditor"],
            path: "Sources/Plugins/MarkdownEditorUI"
        ),
        // Cmd+O: open or create a note by fuzzy name.
        .target(name: "QuickSwitcherUI", dependencies: ["PluginKitUI"], path: "Sources/Plugins/QuickSwitcherUI"),
        // The Files panel: folder tree, recent notes, create, rename, move, trash. Uses its logic module.
        .target(
            name: "FileExplorerUI",
            dependencies: ["PluginKitUI", runtime],
            path: "Sources/Plugins/FileExplorerUI"
        ),
        // The Backlinks panel: notes linking to the open note, with context, and its unlinked mentions.
        .target(name: "BacklinksUI", dependencies: ["PluginKitUI"], path: "Sources/Plugins/BacklinksUI"),
        // The Outline panel: the headings of the active note, live from the editor.
        .target(
            name: "OutlineUI",
            dependencies: ["PluginKitUI", runtime],
            path: "Sources/Plugins/OutlineUI"
        ),
        // Daily notes: today's note (Cmd+D), previous and next, the month calendar (view type and panel).
        .target(name: "DailyNotesUI", dependencies: ["PluginKitUI"], path: "Sources/Plugins/DailyNotesUI"),
        // The Search panel and `search.focus`: names, content and meaning. Uses its logic module.
        .target(
            name: "SearchUI",
            dependencies: ["PluginKitUI", runtime],
            path: "Sources/Plugins/SearchUI"
        ),
        // The habits board: habits over the last two weeks, check-ins in one click. Uses its logic module.
        .target(
            name: "HabitsUI",
            dependencies: ["PluginKitUI", runtime],
            path: "Sources/Plugins/HabitsUI"
        ),
        // The graph view of the vault and the local graph of a note (`graph:` resources), on the note graph.
        .target(name: "GraphUI", dependencies: ["PluginKitUI"], path: "Sources/Plugins/GraphUI"),
        // The home page: four layouts over today's note, the tasks, the notes changed lately and the year's activity.
        .target(name: "HomeUI", dependencies: ["PluginKitUI", runtime], path: "Sources/Plugins/HomeUI"),
        // The mindmap of a note built from its headings (`mindmap:` resources), live from the editor.
        .target(
            name: "MindmapUI",
            dependencies: ["PluginKitUI", runtime],
            path: "Sources/Plugins/MindmapUI"
        ),
        // Collections: a `.base` file or a folder with its own opens as Craft's collection page; the registry of
        // collection view types (`collections.views`) and "Turn into Collection".
        .target(name: "CollectionsUI", dependencies: ["PluginKitUI"], path: "Sources/Plugins/CollectionsUI"),
        // The table view of collections (`type: table`).
        .target(name: "CollectionTableUI", dependencies: ["PluginKitUI"], path: "Sources/Plugins/CollectionTableUI"),
        // The board view of collections (`type: kanban`): columns from a select's options, cards dragged between them.
        .target(name: "CollectionKanbanUI", dependencies: ["PluginKitUI", runtime], path: "Sources/Plugins/CollectionKanbanUI"),
        // The gallery view of collections (`type: cards`): a grid of cards with a cover.
        .target(name: "CollectionCardsUI", dependencies: ["PluginKitUI"], path: "Sources/Plugins/CollectionCardsUI"),
        // The Tags panel: the vault's tags; a click opens a tag's notes as a collection.
        .target(name: "TagsUI", dependencies: ["PluginKitUI"], path: "Sources/Plugins/TagsUI"),
        // Tasks across notes: the list by date and project, the Tasks panel, quick add. Uses its logic module.
        .target(
            name: "TasksUI",
            dependencies: ["PluginKitUI", runtime],
            path: "Sources/Plugins/TasksUI"
        ),
        // Projects: the Projects collection view with progress, a project note's board and progress band.
        .target(name: "ProjectsUI", dependencies: ["PluginKitUI", runtime], path: "Sources/Plugins/ProjectsUI"),
        // Quick capture: ⌃⌥Space from any app adds a line to today's note.
        // The import page: a migration prompt for the user's agent; the onboarding's Obsidian import.
        .target(name: "ImportUI", dependencies: ["PluginKitUI", runtime], path: "Sources/Plugins/ImportUI"),
        // The intro over the desktop, replayed from Settings > About.
        // Resources/Brand/Fonts: the onboarding's serif, when shipped (see its README).
        .target(
            name: "IntroUI",
            dependencies: ["PluginKitUI", runtime],
            path: "Sources/Plugins/IntroUI",
            resources: [.copy("Resources/Brand")]
        ),
        // The Assistant's bubble and chat panel, as Craft's, on the `assistant` logic plugin. Its agents' logos are
        // Lobe Icons (MIT, Resources/Logos/LICENSE.md).
        .target(
            name: "AssistantUI",
            dependencies: ["PluginKitUI", "ThinkingOrbsKit", "BorderBeamKit", runtime],
            path: "Sources/Plugins/AssistantUI",
            exclude: ["Resources/Logos/LICENSE.md"],
            resources: [.copy("Resources/Logos")]
        ),
        // Libraries.dev's thinking orbs (MIT, LICENSE.md), copied in: the Assistant's "Thinking…" indicator.
        .target(
            name: "ThinkingOrbsKit",
            path: "Sources/ThinkingOrbsKit",
            exclude: ["LICENSE.md"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Libraries.dev's border beam (MIT, LICENSE.md), copied in: the composer's ring while the agent works. Its
        // Metal shader ships compiled (scripts/build-beam-shaders.sh), so the build needs no Metal Toolchain.
        .target(
            name: "BorderBeamKit",
            path: "Sources/BorderBeamKit",
            exclude: ["LICENSE.md", "BeamShaders.metal"],
            resources: [.copy("Resources/default.metallib"), .copy("Resources/beam-spec.json")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Recently Deleted: the vault's trash with dates, restore, delete for good; runs the purge. Uses its logic module.
        .target(
            name: "TrashUI",
            dependencies: ["PluginKitUI", runtime],
            path: "Sources/Plugins/TrashUI"
        ),
        // The sync's status bar item, and the app's focus and editor state passed to the `git-sync` logic plugin.
        .target(
            name: "GitSyncUI",
            dependencies: ["PluginKitUI", runtime],
            path: "Sources/Plugins/GitSyncUI"
        ),
        // Excalidraw drawings (`.excalidraw.md`, `.excalidraw`): the editor, vendored by scripts/vendor-excalidraw.sh,
        // in a web view served from these resources. Uses its logic module.
        .target(
            name: "ExcalidrawUI",
            dependencies: ["PluginKitUI", runtime],
            path: "Sources/Plugins/ExcalidrawUI",
            resources: [.copy("Resources/excalidraw")]
        ),
        // Interface sounds: the player behind `Sounds.play`, with the sounds it plays.
        .target(
            name: "SoundsUI",
            dependencies: ["PluginKitUI"],
            path: "Sources/Plugins/SoundsUI",
            resources: [.copy("Resources/Sounds")]
        ),
        // Mermaid diagrams: ` ```mermaid ` blocks drawn by Pele (vendored JavaScript) in an offscreen web view.
        .target(
            name: "DiagramsUI",
            dependencies: ["PluginKitUI"],
            path: "Sources/Plugins/DiagramsUI",
            resources: [.copy("Resources/pele.global.js"), .copy("Resources/PELE-LICENSE")]
        ),
        // Files in notes: drops and pastes go to the attachments folder (its logic module), and image links show as
        // pictures, players (AVKit) and PDF cards (PDFKit).
        .target(
            name: "AttachmentsUI",
            dependencies: ["PluginKitUI", runtime],
            path: "Sources/Plugins/AttachmentsUI"
        ),
        // Files that are not notes, shown in Loam: pictures, PDFs (PDFKit), videos and sounds (AVKit), anything else
        // with Quick Look.
        .target(
            name: "FileViewersUI",
            dependencies: ["PluginKitUI", runtime],
            path: "Sources/Plugins/FileViewersUI"
        ),
        // Media compression in the app: the PDF rasterizer (PDFKit), toasts for what the compressor does, and the
        // palette commands that pick a file or ask before optimizing the whole vault. Uses the Squeeze logic module's
        // contracts (PluginKit).
        .target(
            name: "SqueezeUI",
            dependencies: ["PluginKitUI", runtime],
            path: "Sources/Plugins/SqueezeUI"
        ),
        // The meeting recorder in the app: microphone and system audio capture (Core Audio process tap), the status
        // bar item, the floating recorder, speaker names and setup. Uses the Meetings logic module.
        // Quick capture in the app: the shortcut from any app (Carbon), the capture window and the line after it
        // (borderless panels), the menu-bar icon, PDF covers (PDFKit) and the agent's turn. Uses the Capture logic module.
        .target(
            name: "CaptureUI",
            dependencies: ["PluginKitUI", runtime],
            path: "Sources/Plugins/CaptureUI"
        ),
        .target(
            name: "MeetingsUI",
            dependencies: ["PluginKitUI", runtime],
            path: "Sources/Plugins/MeetingsUI"
        ),
        // The note inspector: properties, backlinks, location and statistics of the focused note. Uses the Tasks
        // logic module for its task counts.
        .target(
            name: "NoteInfoUI",
            dependencies: ["PluginKitUI", runtime],
            path: "Sources/Plugins/NoteInfoUI"
        ),
        // Boards: `.canvas` files as whiteboards of cards and arrows. Uses its logic module.
        .target(
            name: "CanvasUI",
            dependencies: ["PluginKitUI", runtime],
            path: "Sources/Plugins/CanvasUI"
        ),
        // The workspace layout (panes, tabs, splits, drops) as a pure value the shell renders. Foundation only.
        .target(name: "WorkspaceModel", dependencies: ["PluginKitUI"]),
        // The live-styled Markdown editor (TextKit 2) and its `/` menu. It only uses swift-markdown, which reaches it
        // through the runtime (one copy in the process).
        .target(
            name: "MarkdownEditor",
            dependencies: [runtime, "PluginKitUI"]
        ),
        // The agent debug channel's protocol: JSON lines over a Unix socket, the instance naming, the commands. Foundation
        // only, so the tests and a client tool can use it; the app side is in NotebookApp/Debug (debug builds only).
        .target(name: "DebugProtocol"),
        // The shell: the window, the workspace, the slots, the layout persistence, settings, safe mode and the
        // palette. No feature code and no plugin: the executable says which plugins it hosts. A library so it can be
        // tested.
        .target(
            name: "NotebookApp",
            dependencies: [
                "PluginKitUI",
                "WorkspaceModel",
                "DebugProtocol",
                runtime,
            ]
        ),
        .testTarget(name: "DebugProtocolTests", dependencies: ["DebugProtocol"]),
        .testTarget(name: "MarkdownEditorTests", dependencies: ["MarkdownEditor"]),
        .testTarget(
            name: "PluginKitUITests",
            dependencies: [
                "PluginKitUI",
                "PluginKitUITesting",
                runtime,
            ]
        ),
        .testTarget(
            name: "BuiltinUIPluginsTests",
            dependencies: [
                "BuiltinUIPlugins",
                "PluginKitUITesting",
                runtime,
            ]
        ),
        .testTarget(
            name: "QuickSwitcherUITests",
            dependencies: [
                "QuickSwitcherUI",
                "PluginKitUITesting",
                runtime,
            ],
            path: "Tests/Plugins/QuickSwitcherUITests"
        ),
        .testTarget(
            name: "MarkdownEditorUITests",
            dependencies: [
                "MarkdownEditorUI",
                "MarkdownEditor",
                "PluginKitUITesting",
                // Write safety end to end: a task toggled from the Tasks list on a note with unsaved typing.
                "TasksUI",
                runtime,
            ],
            path: "Tests/Plugins/MarkdownEditorUITests"
        ),
        .testTarget(
            name: "CollectionsUITests",
            dependencies: [
                "CollectionsUI",
                "CollectionTableUI",
                "CollectionKanbanUI",
                "CollectionCardsUI",
                "TagsUI",
                "FileExplorerUI",
                "PluginKitUITesting",
                runtime,
            ],
            path: "Tests/Plugins/CollectionsUITests"
        ),
        .testTarget(
            name: "FileExplorerUITests",
            dependencies: [
                "FileExplorerUI",
                "PluginKitUITesting",
                runtime,
            ],
            path: "Tests/Plugins/FileExplorerUITests"
        ),
        .testTarget(
            name: "BacklinksUITests",
            dependencies: [
                "BacklinksUI",
                "PluginKitUITesting",
                runtime,
            ],
            path: "Tests/Plugins/BacklinksUITests"
        ),
        .testTarget(
            name: "OutlineUITests",
            dependencies: ["OutlineUI", "PluginKitUITesting"],
            path: "Tests/Plugins/OutlineUITests"
        ),
        .testTarget(
            name: "DailyNotesUITests",
            dependencies: [
                "DailyNotesUI",
                "PluginKitUITesting",
                runtime,
            ],
            path: "Tests/Plugins/DailyNotesUITests"
        ),
        .testTarget(
            name: "SearchUITests",
            dependencies: [
                "SearchUI",
                "PluginKitUITesting",
                runtime,
            ],
            path: "Tests/Plugins/SearchUITests"
        ),
        .testTarget(
            name: "HabitsUITests",
            dependencies: [
                "HabitsUI",
                "PluginKitUITesting",
                runtime,
            ],
            path: "Tests/Plugins/HabitsUITests"
        ),
        .testTarget(
            name: "SoundsUITests",
            dependencies: ["SoundsUI", "PluginKitUITesting", runtime],
            path: "Tests/Plugins/SoundsUITests"
        ),
        .testTarget(
            name: "HomeUITests",
            dependencies: ["HomeUI", "PluginKitUITesting", runtime],
            path: "Tests/Plugins/HomeUITests"
        ),
        .testTarget(
            name: "GraphUITests",
            dependencies: ["GraphUI", "PluginKitUITesting", runtime],
            path: "Tests/Plugins/GraphUITests"
        ),
        .testTarget(
            name: "MindmapUITests",
            dependencies: ["MindmapUI", "PluginKitUITesting"],
            path: "Tests/Plugins/MindmapUITests"
        ),
        .testTarget(
            name: "CanvasUITests",
            dependencies: ["CanvasUI", "MindmapUI", "PluginKitUITesting", runtime],
            path: "Tests/Plugins/CanvasUITests"
        ),
        .testTarget(
            name: "ExcalidrawUITests",
            dependencies: ["ExcalidrawUI", "PluginKitUITesting", runtime],
            path: "Tests/Plugins/ExcalidrawUITests"
        ),
        .testTarget(
            name: "ProjectsUITests",
            dependencies: ["ProjectsUI", "PluginKitUITesting", runtime],
            path: "Tests/Plugins/ProjectsUITests"
        ),
        .testTarget(
            name: "TasksUITests",
            dependencies: [
                "TasksUI",
                "PluginKitUITesting",
                runtime,
            ],
            path: "Tests/Plugins/TasksUITests"
        ),
        .testTarget(
            name: "GitSyncUITests",
            dependencies: [
                "GitSyncUI",
                "PluginKitUITesting",
                runtime,
            ],
            path: "Tests/Plugins/GitSyncUITests"
        ),
        .testTarget(
            name: "NoteInfoUITests",
            dependencies: [
                "NoteInfoUI",
                "PluginKitUITesting",
                runtime,
            ],
            path: "Tests/Plugins/NoteInfoUITests"
        ),
        .testTarget(
            name: "DiagramsUITests",
            dependencies: ["DiagramsUI", "PluginKitUITesting", runtime],
            path: "Tests/Plugins/DiagramsUITests"
        ),
        .testTarget(
            name: "IntroUITests",
            dependencies: ["IntroUI", "PluginKitUITesting", runtime],
            path: "Tests/Plugins/IntroUITests"
        ),
        .testTarget(
            name: "ImportUITests",
            dependencies: ["ImportUI", "PluginKitUITesting", runtime],
            path: "Tests/Plugins/ImportUITests"
        ),
        .testTarget(
            name: "AssistantUITests",
            dependencies: ["AssistantUI", "PluginKitUITesting", runtime],
            path: "Tests/Plugins/AssistantUITests"
        ),
        .testTarget(
            name: "TrashUITests",
            dependencies: ["TrashUI", "PluginKitUITesting", runtime],
            path: "Tests/Plugins/TrashUITests"
        ),
        .testTarget(
            name: "AttachmentsUITests",
            dependencies: ["AttachmentsUI", "PluginKitUITesting", runtime],
            path: "Tests/Plugins/AttachmentsUITests"
        ),
        .testTarget(
            name: "FileViewersUITests",
            dependencies: ["FileViewersUI", "CanvasUI", "PluginKitUITesting", runtime],
            path: "Tests/Plugins/FileViewersUITests"
        ),
        .testTarget(
            name: "SqueezeUITests",
            dependencies: ["SqueezeUI", "PluginKitUITesting", runtime],
            path: "Tests/Plugins/SqueezeUITests"
        ),
        .testTarget(
            name: "CaptureUITests",
            dependencies: ["CaptureUI", "PluginKitUITesting", runtime],
            path: "Tests/Plugins/CaptureUITests"
        ),
        .testTarget(
            name: "MeetingsUITests",
            dependencies: ["MeetingsUI", "PluginKitUITesting", runtime],
            path: "Tests/Plugins/MeetingsUITests"
        ),
        .testTarget(name: "WorkspaceModelTests", dependencies: ["WorkspaceModel"]),
        .testTarget(
            name: "NotebookAppTests",
            dependencies: [
                "NotebookApp",
                "BuiltinUIPlugins",
                "PluginKitUI",
                "WorkspaceModel",
                "MarkdownEditorUI",
                runtime,
            ]
        ),
    ]
)
