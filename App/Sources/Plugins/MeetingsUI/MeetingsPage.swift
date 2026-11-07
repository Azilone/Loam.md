import MeetingsPlugin
import PluginKitUI
import SwiftUI

/// The Meetings page (`meetings:`), from the sidebar: three ways to record, the recording in progress, then the
/// history of every recording, newest first; a click opens the note it made.
struct MeetingsPage: View {
    let model: RecorderModel
    let actions: Actions
    @Environment(\.themeTokens) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader("Meetings", subtitle: model.recordings.isEmpty ? nil : countLabel)
                .pageColumn(.reading)
                .padding(.bottom, PageMetrics.headerGap)
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    if model.isRecording {
                        LiveCard(model: model)
                            .transition(.opacity.combined(with: .scale(scale: Motion.Metrics.enterScale)))
                    } else {
                        startTiles
                    }
                    list
                }
                .pageColumn(.reading, top: 0)
                .padding(.bottom, Space.xxl)
                .animation(Motion.Spring.standard.animation, value: model.isRecording)
                .animation(Motion.Spring.standard.animation, value: model.recordings.map(\.folder))
            }
            .softScrollEdges()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.background)
        .onAppear { model.refreshRecordings() }
    }

    private var countLabel: String {
        let count = model.recordings.count
        return count == 1 ? "1 recording" : "\(count) recordings"
    }

    private var startTiles: some View {
        HStack(spacing: Space.m) {
            StartTile(title: "Call", symbol: "phone.fill") {
                Task { await model.start(kind: .meeting, mode: .call) }
            }
            StartTile(title: "In person", symbol: "person.2.fill") {
                Task { await model.start(kind: .meeting, mode: .room) }
            }
            StartTile(title: "Voice note", symbol: "waveform") {
                Task { await model.start(kind: .voice) }
            }
            StartTile(title: "Import", symbol: "square.and.arrow.down") {
                actions.pickFile()
            }
        }
    }

    @ViewBuilder private var list: some View {
        let recordings = model.recordings
        if recordings.isEmpty {
            EmptyState("No recordings yet", message: "Calls, meetings and voice notes you record show here.") {
                PrintIllustration(.voice).frame(width: 72, height: 72).opacity(0.85)
            }
        } else {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("History")
                    .themeLabel(size: UIType.label.size, weight: .semibold)
                    .foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, Space.s)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    ForEach(recordings, id: \.folder) { state in
                        HistoryRow(model: model, actions: actions, state: state)
                            .motionTransition(.opacity.combined(with: .offset(y: -4)))
                    }
                }
            }
        }
    }
}

/// A big square button: a picture and a word.
private struct StartTile: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.themeTokens) private var theme

    var body: some View {
        Button(action: action) {
            VStack(spacing: Space.s) {
                // The print look draws each way to record.
                PrintIllustration(symbol: symbol)
                    .frame(width: 52, height: 52)
                    .scaleEffect(hovered ? 1.06 : 1)
                Text(title.uiLocalized)
                    .font(.ui(.body, weight: .medium))
                    .foregroundStyle(theme.text)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Space.l)
            .background(RoundedRectangle(cornerRadius: Radius.l, style: .continuous).fill(hovered ? theme.fillHover : theme.fillSubtle))
            .contentShape(RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
        }
        .buttonStyle(.press)
        .onHover { over in withAnimation(Motion.hover) { hovered = over } }
    }
}

/// The recording in progress: dot, title, clock, levels, controls.
private struct LiveCard: View {
    let model: RecorderModel
    @Environment(\.themeTokens) private var theme

    var body: some View {
        HStack(spacing: Space.m) {
            RecordingDot(paused: model.isPaused)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title).font(.ui(.emphasis)).foregroundStyle(theme.text)
                Text(clock(model.elapsed)).font(.ui(.body).monospacedDigit()).foregroundStyle(theme.secondaryText)
            }
            Spacer(minLength: 12)
            HStack(spacing: 3) {
                ForEach(Array(model.levels.enumerated()), id: \.offset) { LevelMeter(level: $0.element, height: 18) }
            }
            IconButton(symbol: model.isPaused ? "play.fill" : "pause.fill", help: "Pause", action: model.togglePause)
            if !model.isVoiceNote {
                IconButton(symbol: "bookmark.fill", help: "Mark this moment", action: model.markMoment)
            }
            IconButton(symbol: "arrow.counterclockwise", help: "Restart") { Task { await model.restart() } }
            IconButton(symbol: "xmark", help: "Cancel recording") { Task { await model.cancel() } }
            Button { model.stop() } label: {
                Label("Stop", symbol: "stop.fill")
                    .font(.ui(.label, weight: .semibold))
                    .padding(.horizontal, Space.m)
                    .frame(height: 28)
                    .background(ThemeCapsule().fill(theme.danger))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(Space.l)
        .background(RoundedRectangle(cornerRadius: Radius.l, style: .continuous).fill(theme.danger.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: Radius.l, style: .continuous).strokeBorder(theme.danger.opacity(0.25)))
    }
}
