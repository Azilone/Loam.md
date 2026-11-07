import DebugProtocol
import Foundation

/// Whether this build carries the agent debug channel, and which instance this process was asked to be.
///
/// The channel (`DebugBridge`) exists only in debug builds, or in a build made with `-Xswiftc -DLOAM_AGENT_BRIDGE`
/// (`scripts/agent-run.sh --release`). A release build has none of it: `isCompiledIn` is false and
/// `current` is always nil, whatever the environment says.
public enum AgentInstance {
    #if DEBUG || LOAM_AGENT_BRIDGE
    public static let isCompiledIn = true
    /// The instance named by `LOAM_INSTANCE` or `--instance`, nil for a normal run.
    public static let current: DebugInstance? = DebugInstance.requested()
    #else
    public static let isCompiledIn = false
    public static let current: DebugInstance? = nil
    #endif

    /// The main window's title: "Loam", or "Loam [name]" for an instance, so a window list tells instances apart.
    public static var windowTitle: String {
        current.map { "Loam [\($0.name)]" } ?? "Loam"
    }

    /// True when the process should not take the focus when it starts: an agent's instance runs in the background.
    public static var startsInBackground: Bool { current != nil }
}
