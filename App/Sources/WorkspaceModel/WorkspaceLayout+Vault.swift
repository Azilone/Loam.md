import Foundation
import PluginKitUI

// Keeping tabs in step with the vault when notes move.
extension WorkspaceLayout {
    /// Follows moves reported by `NotesMoved` (old path to new path). A file or folder tab on a moved path takes
    /// the new path; a file or folder tab inside a moved folder follows it too. Virtual pages never move.
    public mutating func retarget(_ moves: [String: String]) {
        guard !moves.isEmpty else { return }
        for pane in panes {
            for tab in pane.tabs {
                guard let newPath = Self.movedPath(of: tab.resource, moves) else { continue }
                updateTab(tab.id) { $0.resource = Resource(kind: tab.resource.kind, path: newPath) }
            }
        }
    }

    private static func movedPath(of resource: Resource, _ moves: [String: String]) -> String? {
        guard resource.kind != .virtual else { return nil }
        if let exact = moves[resource.path] { return exact }
        // The longest moved folder that contains the resource wins, so nested moves resolve to the deepest one.
        let containing = moves.keys
            .filter { !$0.isEmpty && resource.path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
            .max { $0.count < $1.count }
        guard let old = containing, let new = moves[old] else { return nil }
        let oldPrefix = old.hasSuffix("/") ? old : old + "/"
        let newPrefix = new.hasSuffix("/") ? new : new + "/"
        return newPrefix + resource.path.dropFirst(oldPrefix.count)
    }
}
