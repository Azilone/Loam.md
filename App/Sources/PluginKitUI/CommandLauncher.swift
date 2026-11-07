/// Runs the window's commands from a plugin's view: a button on a page that does what a palette entry does (the home
/// page's "New note", "Today's note"). The shell runs it as the palette would, its answer in the toast; a plugin only
/// names the command, so it never depends on the plugin that registered it.
@MainActor
public protocol CommandLauncher: AnyObject {
    /// True when a command with this id is registered (its plugin is on).
    func isAvailable(_ id: String) -> Bool
    /// Runs the command, without arguments.
    func run(_ id: String)
    /// Runs the command with `arguments` and returns its answer, quietly: no toast. For a plugin that drives
    /// another's command as part of its own flow (the onboarding applying a theme).
    func run(_ id: String, arguments: [String: String]) async throws -> String
    /// The shortcut the command has now, as menus print it (`⌘O`), its override from `.loam/config.json` included;
    /// nil when it has none.
    func shortcut(for id: String) -> String?
}

/// A home page has this resource: a plugin registering a view type for it becomes what the house button, a new tab
/// (Cmd+T) and an empty window show. Without one, the shell falls back on the first link of the left sidebar.
public extension Resource {
    static let home = Resource.virtual("home:")
}

public extension CommandLauncher {
    /// By default, as `run(_:)`, with the arguments dropped.
    func run(_ id: String, arguments: [String: String]) async throws -> String {
        run(id)
        return ""
    }
}
