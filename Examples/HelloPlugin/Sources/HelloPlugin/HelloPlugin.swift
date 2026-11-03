import PluginKit

/// Counts the notes of the vault through the `note-graph` service: proof that a plugin loaded at run time shares the
/// app's services (a second copy of PluginKit in the process would make `context.service` return nil).
public final class HelloPlugin: Plugin {
    public static var manifest: PluginManifest {
        PluginManifest(id: "hello", name: "Hello", version: "0.1.0", requires: ["note-graph"])
    }

    public required init() {}

    public func activate(context: PluginContext) throws {
        let graph = context.service(.noteGraph)
        try context.registerCommand(Command(
            id: "hello.count",
            title: "Hello: count notes",
            summary: "Says how many notes the note graph knows; an example of a plugin loaded from the vault."
        ) { _ in
            guard let graph else { return "Hello: the note graph is not available." }
            return "Hello from a plugin loaded from the vault: \(graph.notes.count) notes."
        })
    }
}

/// The entry the app looks for. `PluginEntry(plugins:)` records the runtime build this plugin is compiled against.
@_cdecl("loam_plugin_entry")
public func loamPluginEntry() -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(PluginEntry(plugins: [HelloPlugin.self])).toOpaque()
}
