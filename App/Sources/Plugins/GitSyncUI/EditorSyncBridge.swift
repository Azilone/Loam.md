import Foundation
import GitSyncPlugin
import PluginKit
import PluginKitUI

/// What the sync asks the editor: which incoming notes are being typed in, save them, show the merged text. The
/// sync calls it on the main thread only.
final class EditorSyncBridge: SyncEditorBridge, @unchecked Sendable {
    private let root: URL
    private let pluginID: String
    private let editor: @MainActor () -> (any EditorService)?
    private let emit: @MainActor (any PluginEvent) -> Void
    /// When each open note was last typed in. Main thread only.
    private var lastTyped: [String: Date] = [:]

    init(root: URL, pluginID: String, editor: @escaping @MainActor () -> (any EditorService)?,
         emit: @escaping @MainActor (any PluginEvent) -> Void) {
        self.root = root
        self.pluginID = pluginID
        self.editor = editor
        self.emit = emit
    }

    @MainActor func typed(_ path: String, at date: Date = Date()) {
        lastTyped[path] = date
    }

    func busyPaths(_ paths: [String], quiet: TimeInterval) -> [String] {
        MainActor.assumeIsolated {
            guard let editor = editor() else { return [] }
            let now = Date()
            return paths.filter { path in
                guard let text = editor.text(of: path) else { return false }
                if let typed = lastTyped[path], now.timeIntervalSince(typed) < quiet { return true }
                return text != disk(path)
            }
        }
    }

    func flush(_ paths: [String]) {
        MainActor.assumeIsolated {
            for path in paths { emit(NoteWillRead(path: path, pluginID: pluginID)) }
        }
    }

    func reload(_ paths: [String]) -> [String] {
        MainActor.assumeIsolated {
            for path in paths { emit(NoteDidChange(path: path, pluginID: pluginID)) }
            guard let editor = editor() else { return [] }
            return paths.filter { path in
                guard let text = editor.text(of: path), let disk = disk(path) else { return false }
                return text != disk
            }
        }
    }

    /// The note as saved. Read around the vault: a read through `context.vault` would make the editor save first.
    private func disk(_ path: String) -> String? {
        try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
}
