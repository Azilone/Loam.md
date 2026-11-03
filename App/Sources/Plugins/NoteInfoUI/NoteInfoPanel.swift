import PluginKitUI
import SwiftUI

/// A note's "Stats" tab in the right sidebar, as Bear's: the counts as large figures, then when it was changed and
/// created. Its properties are not repeated here: the page shows them under the title.
struct NoteStatisticsSection: View {
    let model: NoteInfoModel

    var body: some View {
        if let info = model.info {
            let statistics = info.statistics
            VStack(alignment: .leading, spacing: InspectorStyle.tileSpacing) {
                InspectorTileGrid(columns: 2) {
                    InspectorFigure(statistics.words.formatted(), "Words", symbol: "text.bubble")
                    InspectorFigure(statistics.characters.formatted(), "Characters", symbol: "textformat")
                    InspectorFigure("\(statistics.readingMinutes)m", "Read time", symbol: "clock")
                    if let done = statistics.tasksDone, let total = statistics.tasksTotal, total > 0 {
                        InspectorFigure("\(done)/\(total)", "Tasks", symbol: "checkmark.circle")
                    }
                }
                InspectorCard {
                    if let modified = info.modified {
                        InspectorRow("Modified", symbol: "pencil") { Text(Self.relative(modified)) }
                    }
                    if let created = info.created {
                        InspectorRow("Created", symbol: "calendar") {
                            Text(created.formatted(date: .abbreviated, time: .omitted))
                        }
                    }
                }
            }
        }
    }

    /// "Just now" within a minute, "5 min ago" within a day, else the date: one short line.
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "Just now" }
        if seconds < 86_400 {
            return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: now)
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
