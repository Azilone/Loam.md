import Foundation

/// Finds the programs a plugin runs (`git`, `ffmpeg`…). The host provides it as the `tools` service, and it is the
/// same answer the host uses to keep a plugin whose `requiresTools` are missing from starting.
public protocol ToolLocating: AnyObject, Sendable {
    /// The executable `name`, as a Terminal would find it, or nil when it is not installed. Apple's stubs for the
    /// developer tools (git, swift) only count once those are installed.
    func locate(_ name: String) -> URL?
}

public extension ServiceKey where Service == ToolLocating {
    /// The host's tool locator.
    static let tools = ServiceKey("tools")
}
