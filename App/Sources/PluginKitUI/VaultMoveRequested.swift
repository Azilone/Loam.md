import Foundation
import PluginKit

/// Asks the app to put the vault in `path` instead: during the first launch's onboarding, before anything is in the
/// vault Loam made, so it opens the chosen folder in its place. The onboarding then resumes on `resumeAt` (a card's
/// name, `intro.onboard`'s `at`), on its welcome page without one.
public struct VaultMoveRequested: PluginEvent, Sendable {
    public let path: String
    public let resumeAt: String?

    public init(path: String) {
        self.init(path: path, resumeAt: nil)
    }

    public init(path: String, resumeAt: String?) {
        self.path = path
        self.resumeAt = resumeAt
    }
}

/// Asks the app to take the demo vault's notes out of the open vault, when nothing in them changed: the onboarding
/// sends it before the user's own notes move in, so they do not land among the tour's.
public struct DemoVaultRemovalRequested: PluginEvent, Sendable {
    public init() {}
}
