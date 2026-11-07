import Foundation

/// What `PluginHost.apply(enabled:)` changed. A plugin restarted because an optional service came
/// back is listed in `activated` only. Reasons are short English sentences for the plugin manager.
public struct ActivationReport: Equatable {
    /// Plugins started by this call, in activation order.
    public var activated: [String]
    /// Plugins active before this call and inactive after it, in deactivation order.
    public var deactivated: [String]
    /// Enabled plugins not started because a required service is missing, with the reason.
    public var skipped: [String: String]
    /// Enabled plugins whose activation threw or did not provide what they promised, with the error.
    public var failed: [String: String]

    public init(
        activated: [String] = [],
        deactivated: [String] = [],
        skipped: [String: String] = [:],
        failed: [String: String] = [:]
    ) {
        self.activated = activated
        self.deactivated = deactivated
        self.skipped = skipped
        self.failed = failed
    }
}
