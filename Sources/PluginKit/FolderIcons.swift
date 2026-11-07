/// Asked, as a waterfall, by a file browser before it draws its folders: a plugin that owns a folder gives it an
/// icon (the meetings plugin a waveform on its folder, the daily notes a calendar). A folder the user gave an icon
/// keeps theirs. Asked again when any plugin's settings change, so a renamed folder follows.
public struct FolderIcons: PluginEvent, Sendable, Equatable {
    /// SF Symbol names, by vault-relative folder path.
    public var symbols: [String: String]

    public init(symbols: [String: String] = [:]) {
        self.symbols = symbols
    }
}

