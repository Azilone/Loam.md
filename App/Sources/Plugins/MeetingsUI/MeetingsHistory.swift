import MeetingsPlugin
import PluginKitUI
import SwiftUI

/// How the history names an origin and a time.
enum HistoryLabels {
    static func origin(_ origin: MeetingOrigin) -> String {
        switch origin {
        case .call: "Call"
        case .room: "In person"
        case .voiceNote: "Voice note"
        case .voiceMemos: "Voice Memos"
        case .inbox: "Inbox"
        case .file: "Imported file"
        }
    }

    static func symbol(_ origin: MeetingOrigin) -> String {
        switch origin {
        case .call: "phone.fill"
        case .room: "person.2.fill"
        case .voiceNote: "waveform"
        case .voiceMemos: "iphone"
        case .inbox: "tray.and.arrow.down.fill"
        case .file: "doc.fill"
        }
    }

    /// The start tiles' colours for what was recorded here; brought-in audio in quieter ones.
    static func color(_ origin: MeetingOrigin) -> Color {
        switch origin {
        case .call: .blue
        case .room: .orange
        case .voiceNote: .pink
        case .voiceMemos: .purple
        case .inbox: .teal
        case .file: .gray
        }
    }

    /// `Today 14:30`, `Yesterday 09:05`, `Oct 21 18:00`, with the year when it is not this one.
    static func when(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let locale = Locale(identifier: "en_US")
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.timeZone = calendar.timeZone
        clock.dateFormat = "HH:mm"
        let time = clock.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return "Today " + time }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday " + time
        }
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).day().month(.abbreviated)
        if !calendar.isDate(date, equalTo: now, toGranularity: .year) { style = style.year() }
        return date.formatted(style) + " " + time
    }
}

/// One line of the history: where it came from, its title, when; on the right how it went (a spinner and its step,
/// a check, or the reason it failed with a retry). A click opens the note it made.
struct HistoryRow: View {
    let model: RecorderModel
    let actions: Actions
    let state: MeetingState
    @State private var hovered = false
    @Environment(\.themeTokens) private var theme

    private var entry: HistoryEntry { Meetings.entry(state, settings: model.settings) }

    var body: some View {
        let entry = entry
        let color = HistoryLabels.color(entry.origin)
        Button { model.open(state) } label: {
            HStack(spacing: 12) {
                Image(symbol: HistoryLabels.symbol(entry.origin))
                    .font(.ui(size: 12, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(color.opacity(0.14)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title).font(.ui(size: 14, weight: .medium)).foregroundStyle(theme.text).lineLimit(1)
                    subtitle(entry).font(.ui(size: 12)).lineLimit(1).truncationMode(.tail)
                }
                .layoutPriority(1)
                Spacer(minLength: 12)
                outcome(entry)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: Corners.r(10), style: .continuous).fill(theme.separator.opacity(hovered ? 0.25 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { over in withAnimation(Motion.hover) { hovered = over } }
        .contextMenu {
            Button("Re-process") { actions.reprocess(state.folder) }
        }
    }

    /// Origin · when · length; a failure says why instead of how long, in red.
    private func subtitle(_ entry: HistoryEntry) -> Text {
        let head = Text(HistoryLabels.origin(entry.origin) + " · " + HistoryLabels.when(entry.date))
            .foregroundColor(theme.secondaryText)
        if case .failed(let reason) = entry.outcome {
            let why = reason.isEmpty ? "Failed" : reason
            return head + Text(" · ").foregroundColor(theme.secondaryText) + Text(why).foregroundColor(theme.danger)
        }
        guard entry.duration >= 1 else { return head }
        return head + Text(" · \(max(1, Int((entry.duration / 60).rounded()))) min").foregroundColor(theme.secondaryText)
    }

    @ViewBuilder private func outcome(_ entry: HistoryEntry) -> some View {
        if let step = model.processing[state.folder]?.step {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(step).font(.ui(size: 12)).foregroundColor(theme.secondaryText)
            }
            .transition(.opacity)
        } else {
            switch entry.outcome {
            case .working:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(state.status == .recording ? "Recording" : "Waiting")
                        .font(.ui(size: 12)).foregroundColor(theme.secondaryText)
                }
            case .done:
                Image(symbol: "checkmark.circle.fill")
                    .font(.ui(size: 13))
                    .foregroundStyle(Color.green.opacity(0.8))
                    .help("Done")
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            case .failed:
                IconButton(symbol: "arrow.clockwise", help: "Retry") { actions.reprocess(state.folder) }
                    .help(entry.error ?? "")
                    .transition(.opacity)
            }
        }
    }
}
