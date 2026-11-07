import Foundation

/// Files a plugin just made from a template (a new board, a new mindmap) and that the user may leave without
/// touching. Once the focus moves away and the file still holds exactly its template, it goes to Recently Deleted,
/// so an abandoned "Board 3" or "Mindmap 2" does not stay in the vault. A file that changed is forgotten and kept.
@MainActor
public final class UntouchedDrafts {
    private let read: (String) -> String?
    private let discard: (String) -> Void
    private var drafts: [String: String] = [:]

    /// - Parameters:
    ///   - read: the file's text now (nil when it is gone).
    ///   - discard: moves an untouched file away (to the trash).
    public init(read: @escaping (String) -> String?, discard: @escaping (String) -> Void) {
        self.read = read
        self.discard = discard
    }

    /// Remembers a file just written with `template`.
    public func remember(_ path: String, template: String) {
        drafts[path] = template
    }

    /// After the focus moved to `active`: every remembered file other than it is discarded when untouched, forgotten
    /// otherwise.
    public func focusMoved(to active: Resource?) {
        for (path, template) in drafts where active?.path != path {
            drafts[path] = nil
            if let text = read(path), text == template { discard(path) }
        }
    }

    /// Follows a remembered file that moved (a rename keeps it a draft only if its text is still the template).
    public func moved(_ moves: [String: String]) {
        for (old, new) in moves {
            if let template = drafts.removeValue(forKey: old) { drafts[new] = template }
        }
    }
}
