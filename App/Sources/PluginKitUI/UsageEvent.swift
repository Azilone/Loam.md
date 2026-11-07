import Foundation
import PluginKit

/// Tells the app that something worth counting happened, for the anonymous usage statistics (Settings > About >
/// Send anonymous analytics). The app keeps only the names it knows (`AppAnalytics.allowedEvents`) and only plain
/// identifiers and numbers as properties: a note, a path or any free text never leaves the Mac. Nothing is sent
/// when the user turned the statistics off or in a development build.
public struct UsageEvent: PluginEvent, Sendable {
    public let name: String
    public let properties: [String: String]

    public init(_ name: String, _ properties: [String: String] = [:]) {
        self.name = name
        self.properties = properties
    }
}
