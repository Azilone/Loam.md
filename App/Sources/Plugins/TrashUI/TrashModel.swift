import Foundation
import Observation
import PluginKit
import PluginKitUI

/// The state of the Recently Deleted page, shared by every `trash:` tab: the items of the vault's `.trash/`, read
/// and changed through the `trash` service only (the same one the `trash.*` commands use).
@MainActor
@Observable
final class TrashModel {
    /// What a confirmation is about.
    enum Pending: Equatable {
        case delete(TrashedItem)
        case empty
    }

    /// Retentions offered in the menu; 0 is "never".
    static let retentionChoices = [7, 14, 30, 60, 90, 0]

    @ObservationIgnored let service: TrashService
    @ObservationIgnored private let setRetention: (Int) -> Void
    @ObservationIgnored private let now: () -> Date
    private(set) var items: [TrashedItem] = []
    var pending: Pending?
    /// A line about what just happened or failed; replaced by the next one.
    var message: String?
    private(set) var retentionDays: Int
    /// Opens the page in a new tab; set by the plugin.
    @ObservationIgnored var openPage: @MainActor () -> Void = {}
    /// Reads a file of the vault (a trashed note, for its preview line); set by the plugin.
    @ObservationIgnored var readText: (String) -> String? = { _ in nil }

    init(service: TrashService, setRetention: @escaping (Int) -> Void, now: @escaping () -> Date = Date.init) {
        self.service = service
        self.setRetention = setRetention
        self.now = now
        retentionDays = service.retentionDays
    }

    func refresh() {
        retentionDays = service.retentionDays
        do {
            items = try service.items()
        } catch {
            message = "Could not read the trash: \(error)"
        }
    }

    /// Deletes what expired, then refreshes. Run when the vault opens and every hour.
    func purgeExpired() {
        _ = try? service.purgeExpired()
        refresh()
    }

    func restore(_ item: TrashedItem) {
        do {
            let path = try service.restore(item.path)
            message = "Restored to \(path)"
            Sounds.play(.restored)
        } catch {
            message = "Could not restore “\(Self.name(of: item))”: \(error)"
        }
        refresh()
    }

    /// Restores every item of a group, in one message.
    func restoreAll(_ items: [TrashedItem]) {
        var restored = 0
        for item in items where (try? service.restore(item.path)) != nil { restored += 1 }
        if restored > 0 { Sounds.play(.restored) }
        message = restored == 1 ? "Restored 1 item" : "Restored \(restored) items"
        refresh()
    }

    func confirm() {
        guard let pending else { return }
        self.pending = nil
        do {
            switch pending {
            case .delete(let item):
                try service.deleteForever(item.path)
                message = "Deleted “\(Self.name(of: item))” for good"
                Sounds.play(.emptied)
            case .empty:
                let count = try service.empty()
                message = count == 1 ? "Deleted 1 item for good" : "Deleted \(count) items for good"
                if count > 0 { Sounds.play(.emptied) }
            }
        } catch {
            message = "Could not delete: \(error)"
        }
        refresh()
    }

    func chooseRetention(_ days: Int) {
        setRetention(days)
        refresh()
    }

    // MARK: Groups

    /// Items grouped by when they were trashed ("Today", "Yesterday", "3 days ago", "2 weeks ago"…), most recent
    /// group first, as the service already sorts them.
    var groups: [(title: String, items: [TrashedItem])] {
        var result: [(title: String, items: [TrashedItem])] = []
        for item in items {
            let title = groupTitle(item)
            if result.last?.title == title { result[result.count - 1].items.append(item) } else { result.append((title, [item])) }
        }
        return result
    }

    func groupTitle(_ item: TrashedItem) -> String {
        guard let date = Self.date(item.trashedAt) else { return "Earlier" }
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now())).day ?? 0
        switch days {
        case ..<1: return "Today"
        case 1: return "Yesterday"
        case 2..<7: return "\(days) days ago"
        case 7..<14: return "Last week"
        case 14..<31: return "\(days / 7) weeks ago"
        default: return days < 60 ? "Last month" : "\(days / 30) months ago"
        }
    }

    /// The first line of text of a trashed note, without Markdown marks or frontmatter; "" for a folder or an empty note.
    func preview(_ item: TrashedItem) -> String {
        guard !item.isFolder, let text = readText(item.path) else { return "" }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---", let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            lines.removeSubrange(0...end)
        }
        for line in lines {
            let plain = line.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: #"^(#+|[-*+]( \[.\])?|>|\d+\.)\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"[*_`]|\[\[|\]\]"#, with: "", options: .regularExpression)
            if !plain.isEmpty, plain != Self.name(of: item) { return plain }
        }
        return ""
    }

    /// The fraction of the retention still left, for the countdown ring; nil when the retention is off.
    func remaining(_ item: TrashedItem) -> Double? {
        guard let days = item.daysLeft, retentionDays > 0 else { return nil }
        return min(1, max(0, Double(days) / Double(retentionDays)))
    }

    // MARK: Text

    static func name(of item: TrashedItem) -> String {
        let name = (item.originalPath as NSString).lastPathComponent
        return name.lowercased().hasSuffix(".md") ? String(name.dropLast(3)) : name
    }

    /// The folder it came from, "" at the vault's root.
    static func folder(of item: TrashedItem) -> String {
        (item.originalPath as NSString).deletingLastPathComponent
    }

    func daysLeftText(_ item: TrashedItem) -> String {
        guard let days = item.daysLeft else { return "" }
        switch days {
        case 0: return "Deleted soon"
        case 1: return "1 day left"
        default: return "\(days) days left"
        }
    }

    static func retentionLabel(_ days: Int) -> String {
        days == 0 ? "Never" : days == 1 ? "1 day" : "\(days) days"
    }

    var disclaimer: String {
        retentionDays == 0
            ? "kept until you delete them"
            : "kept \(retentionDays) days, then deleted for good"
    }

    var summary: String {
        let count = items.count == 1 ? "1 item" : "\(items.count) items"
        return "\(count) · \(disclaimer)"
    }

    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
