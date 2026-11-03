/// Sent by the editor plugin when the text selected in an open note changes: the
/// Assistant takes a selection as context. `text` is empty when the selection was cleared.
public struct EditorSelectionChanged: PluginEvent, Sendable, Equatable {
    public let path: String
    public let text: String

    public init(path: String, text: String) {
        self.path = path
        self.text = text
    }
}
