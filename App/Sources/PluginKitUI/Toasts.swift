/// A short message along the bottom of the window for a few seconds: what a command's answer already uses, open to
/// plugins that finish work on their own (a video compressed in the background). The shell owns the toast; a plugin
/// only says what to show.
@MainActor
public protocol Toasts: AnyObject {
    /// Shows `text`, replacing the toast on screen, with a mark of the colour of its `kind`.
    func show(_ text: String, kind: ToastKind)
}

/// How a toast reads at a glance, before its words: the colour of the dot beside them.
public enum ToastKind: Sendable, Equatable {
    /// Something is going on or was left as it is (blue).
    case info
    /// Work that was asked for is done (green).
    case success
    /// Something failed (orange).
    case error
}

extension Toasts {
    /// Shows `text` as an error or as information.
    public func show(_ text: String, isError: Bool) {
        show(text, kind: isError ? .error : .info)
    }
}
