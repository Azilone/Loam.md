# Roadmap

The features the vision asks for are built: the notebook, the plugin platform and its essential plugins, git sync,
the AI assistant, collections, the whiteboard, Excalidraw drawings and the command line for agents. See
[ARCHITECTURE.md](ARCHITECTURE.md) and the feature docs. This page lists what is not built yet.

- **iPhone shell.** The UI contracts are SwiftUI, but only the Mac shell exists ([ARCHITECTURE.md](ARCHITECTURE.md),
  "Platforms").
- **Community catalog checks.** The catalog pins each plugin to a commit and `check.py` validates tags and manifests.
  Automatic checks of a plugin's code are not built, and the catalog file is not signed ([UPDATES.md](UPDATES.md)).
- **Enforced permissions.** Plugin permissions are declared and shown before a plugin is enabled, not enforced
  ([PERMISSIONS.md](PERMISSIONS.md)).
- **An MCP server** (`loam mcp`) for agents without a terminal ([DEVELOPERS.md](DEVELOPERS.md)).
- **Reloading a rebuilt plugin** without relaunching the app ([DEVELOPERS.md](DEVELOPERS.md)).
- **Per-file view choice.** A tab remembers its view type; keeping the choice per file is not built
  ([ARCHITECTURE.md](ARCHITECTURE.md)).
- **One-click GitHub setup.** Git sync asks the user to create a private repository and paste its address
  ([GIT-SYNC.md](GIT-SYNC.md)).
- **Notarized builds.** Releases are signed with an Apple Development certificate and not notarized until a Developer
  ID certificate is available ([UPDATES.md](UPDATES.md)).
