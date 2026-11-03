import PluginKitUI

/// A `Workspace` that records what plugins open instead of showing it. Opening a resource also makes it the
/// active one, as a real shell would, so a plugin that opens then reads `activeResource` sees its own choice.
@MainActor
public final class RecordingWorkspace: Workspace {
    public private(set) var opened: [(resource: Resource, placement: Placement)] = []
    /// The origin given with each open, in the same order as `opened`.
    public private(set) var openedOrigins: [OpenOrigin?] = []
    /// Set it to simulate the user focusing a tab.
    public var activeResource: Resource?
    /// How many times a plugin asked for the inspector.
    public private(set) var inspectorRequests = 0

    public init(activeResource: Resource? = nil) {
        self.activeResource = activeResource
    }

    public func open(_ resource: Resource, placement: Placement, from origin: OpenOrigin?) {
        opened.append((resource, placement))
        openedOrigins.append(origin)
        activeResource = resource
    }

    public func showInspector() {
        inspectorRequests += 1
    }
}
