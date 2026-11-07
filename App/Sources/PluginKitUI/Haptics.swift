import AppKit

/// The trackpad's taps (a Force Touch trackpad; nothing elsewhere), kept for moments when the hand is already on it
/// and something gives way under the pointer: a block or a card picked up, a slot or a heading passed while dragging
/// or scrubbing, an edge or a guide caught. Never for a plain click: the trackpad already answers that.
///
/// `alignment` is the light tick of passing or catching something; `levelChange` the firmer one of picking up or
/// crossing into another place. Ticks closer together than `minimumGap` are dropped, so sweeping fast across many
/// slots feels like a few clicks and not a buzz.
@MainActor package enum Haptics {
    /// Something passed or caught: a drop slot, a heading, a snap guide, a split position.
    package static func alignment() { perform(.alignment) }
    /// Something picked up, or a drop that changes its level (into a folder, into another pane).
    package static func levelChange() { perform(.levelChange) }

    static let minimumGap: TimeInterval = 0.04
    private static var last: TimeInterval = 0

    private static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - last >= minimumGap else { return }
        last = now
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}
