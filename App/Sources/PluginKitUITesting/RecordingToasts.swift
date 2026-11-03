import PluginKitUI

/// A `Toasts` that keeps every message a plugin showed, so a test can check what the user would have read.
@MainActor
public final class RecordingToasts: Toasts {
    public struct Message: Equatable, Sendable {
        public let text: String
        public let kind: ToastKind
        public var isError: Bool { kind == .error }

        public init(text: String, kind: ToastKind) {
            self.text = text
            self.kind = kind
        }

        public init(text: String, isError: Bool) {
            self.init(text: text, kind: isError ? .error : .info)
        }
    }

    public private(set) var messages: [Message] = []

    public init() {}

    public func show(_ text: String, kind: ToastKind) {
        messages.append(Message(text: text, kind: kind))
    }
}
