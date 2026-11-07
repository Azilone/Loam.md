import AppKit
import Foundation
import MeetingsPlugin
import Observation
import PluginKit
import PluginKitUI

/// The recorder in the app: the recording in progress and its sound sources, the clock the status bar item and the
/// floating pill show, the guards (a long silence, the maximum duration), the notes' timestamps, and the recordings
/// being processed.
@MainActor
@Observable
final class RecorderModel {
    struct Processing: Equatable {
        var title: String
        var step: String
    }

    /// The question asked after a long silence, with when the recording stops by itself.
    struct IdleQuestion: Equatable {
        var minutes: Int
        var deadline: Date
    }

    private(set) var session: RecordingSession?
    private(set) var elapsed = 0.0
    private(set) var isPaused = false
    /// dBFS of the microphone and, in a call, the Mac's sound (nil when it could not be recorded).
    private(set) var levels: [Double?] = []
    private(set) var estimatedCost = 0.0
    private(set) var sentMinutes = 0
    private(set) var idle: IdleQuestion?
    private(set) var processing: [String: Processing] = [:]
    /// Every recording, newest first, for the Meetings page.
    private(set) var recordings: [MeetingState] = []

    @ObservationIgnored let meetings: Meetings
    @ObservationIgnored private weak var context: PluginContext?
    @ObservationIgnored private var sources: [AudioSource] = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var idleSnoozeUntil = 0.0
    @ObservationIgnored private var notes = RecorderNotes()
    @ObservationIgnored var overlay: OverlayWindow?
    @ObservationIgnored var showSetup: () -> Void = {}

    init(meetings: Meetings, context: PluginContext) {
        self.meetings = meetings
        self.context = context
    }

    var settings: MeetingsSettings { meetings.settings }
    var isRecording: Bool { session != nil }
    var notesPath: String? { session.map { $0.state.notesPath } }
    var title: String { session?.state.title ?? "" }
    var isVoiceNote: Bool { session?.state.kind == .voice }

    /// Minutes sent for transcription and their estimated price, for a tooltip.
    var costLine: String {
        let minutes = "\(sentMinutes) min sent"
        return estimatedCost >= 0.005 ? minutes + String(format: " · $%.2f", estimatedCost) : minutes
    }

    // MARK: Start and stop

    /// Starts a recording; a meeting opens its notes, ready to type in.
    func start(kind: MeetingKind, mode: MeetingMode? = nil) async {
        guard session == nil else { return }
        guard DeviceKeys().openRouterKey() != nil else {
            toast("OpenRouter key missing", error: true)
            showSetup()
            return
        }
        guard await MicrophoneSource.requestAccess() else {
            PrivacyPane.microphone.ask()
            return
        }
        let session: RecordingSession
        do {
            session = try meetings.start(kind: kind, mode: mode)
        } catch {
            toast(error.localizedDescription, error: true)
            return
        }
        let mic = MicrophoneSource { [session] in session.push(.mic, $0) }
        do {
            try mic.start()
        } catch {
            toast(error.localizedDescription, error: true)
            return
        }
        sources = [mic]
        if session.trackIDs.contains(.system) {
            let system = SystemAudioSource { [session] in session.push(.system, $0) }
            do {
                try system.start()
                sources.append(system)
            } catch {
                // Without the Mac's sound the call goes on with the microphone only.
                session.dropTrack(.system, reason: error.localizedDescription)
                if let pane = (error as? CaptureError)?.permission {
                    pane.ask()
                } else {
                    toast(error.localizedDescription, error: true)
                }
            }
        }
        self.session = session
        Sounds.play(.recordingStarted)
        refreshRecordings()
        idle = nil
        idleSnoozeUntil = 0
        notes = RecorderNotes()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
        if let notesPath, kind == .meeting {
            context?.workspace?.open(.file(notesPath), placement: .replace)
        }
        if settings.overlay { showOverlay() }
    }

    /// Stops the recording and processes it; the summary opens when it is ready.
    func stop(reason: String? = nil) {
        guard let session else { return }
        for source in sources { source.stop() }
        sources = []
        timer?.invalidate()
        timer = nil
        self.session = nil
        idle = nil
        overlay?.close()
        overlay = nil
        if let reason { toast(reason, error: false) }
        let state = session.state
        processing[state.folder] = Processing(title: state.title, step: "Audio…")
        Task { [meetings] in _ = try? await meetings.finish(session) }
    }

    /// Throws the recording away (it goes to the vault's trash); after a minute it asks first. False when kept.
    @discardableResult
    func cancel(confirm: Bool = true, toast showToast: Bool = true) async -> Bool {
        guard let session else { return false }
        if confirm, elapsed >= 60, !askToDiscard() { return false }
        for source in sources { source.stop() }
        sources = []
        timer?.invalidate()
        timer = nil
        self.session = nil
        idle = nil
        overlay?.close()
        overlay = nil
        await meetings.discard(session)
        refreshRecordings()
        if showToast { toast("Recording cancelled", error: false) }
        return true
    }

    /// Throws the recording away and starts a new one of the same kind.
    func restart() async {
        guard let state = session?.state else { return }
        guard await cancel(toast: false) else { return }
        await start(kind: state.kind, mode: state.mode)
    }

    private func askToDiscard() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Cancel this recording?"
        alert.informativeText = "It goes to the vault's trash: you can get it back."
        alert.addButton(withTitle: "Cancel recording")
        alert.addButton(withTitle: "Keep recording")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func togglePause() {
        guard let session else { return }
        session.setPaused(!session.isPaused)
        tick()
    }

    /// Drops `==⏱ mm:ss==` into the notes: at the caret when they have the focus, else at their end.
    func markMoment() {
        guard let session, let notesPath else { return }
        let stamp = "==⏱ \(clock(session.elapsed))== "
        if context?.workspace?.activeResource == .file(notesPath), context?.editor?.insertAtCaret(stamp) == true { return }
        guard let vault = context?.vault, let text = try? vault.read(notesPath) else { return }
        try? vault.write(notesPath, text.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) + "\n\(stamp)\n")
    }

    func continueMeeting() {
        if let session { idleSnoozeUntil = session.elapsed + max(1, settings.idleMinutes) * 60 }
        idle = nil
    }

    // MARK: The clock

    private func tick() {
        guard let session else { return }
        elapsed = session.elapsed
        isPaused = session.isPaused
        levels = session.state.mode == .call
            ? [session.level(.mic), session.systemAudioProblem == nil ? session.level(.system) : nil]
            : [session.level(.mic)]
        estimatedCost = session.estimatedCost
        sentMinutes = Int((session.sentSeconds / 60).rounded())
        overlay?.refresh()
        guard !isPaused else { return }
        let s = settings
        if s.maxMinutes > 0, elapsed >= s.maxMinutes * 60 {
            return stop(reason: "Stopped: \(Int(s.maxMinutes)) min reached")
        }
        guard s.idleMinutes > 0 else { return }
        let silence = session.idleSeconds
        if let idle {
            if silence < 20 {
                self.idle = nil // Someone spoke again.
            } else if Date() >= idle.deadline {
                stop(reason: "Stopped: \(Int(silence / 60)) min of silence")
            }
        } else if silence >= s.idleMinutes * 60, elapsed >= idleSnoozeUntil {
            idle = IdleQuestion(minutes: Int(silence / 60), deadline: Date().addingTimeInterval(max(0.5, s.idleGraceMinutes) * 60))
            if overlay == nil, s.overlay { showOverlay() }
        }
    }

    /// Remembers when each line of the notes was started, so the summary lines notes and talk up.
    func notesChanged(_ text: String) {
        guard let session else { return }
        if notes.changed(text, at: session.elapsed) { session.setNoteTimes(notes.starts) }
    }

    // MARK: Processing

    func refreshRecordings() {
        let all = meetings.recordings()
        if all.map(\.folder) != recordings.map(\.folder) || all.map(\.status) != recordings.map(\.status)
            || all.map(\.error) != recordings.map(\.error) { recordings = all }
    }

    /// Opens a recording's summary (or its notes while it is not processed).
    func open(_ state: MeetingState) {
        guard let note = meetings.note(of: state) else { return }
        context?.workspace?.open(.file(note), placement: .replace)
    }

    func progressed(_ event: MeetingProgress) {
        if event.step.isEmpty {
            processing[event.folder] = nil
        } else {
            processing[event.folder] = Processing(title: event.title, step: event.step)
        }
        // A folder renamed mid-way (the title) leaves its old entry behind.
        processing = processing.filter { folder, _ in context?.vault.exists(folder) ?? true }
        refreshRecordings()
    }

    func finished(_ event: MeetingFinished) {
        processing[event.folder] = nil
        let cost = event.cost >= 0.005 ? String(format: " · $%.2f", event.cost) : ""
        toast("✓ \(event.title)" + cost, error: false)
        Sounds.play(.recordingFinished)
        if !event.background { context?.workspace?.open(.file(event.note), placement: .replace) }
    }

    func failed(_ event: MeetingFailed) {
        processing[event.folder] = nil
        toast("\(event.title) : \(event.message)", error: true)
    }

    // MARK: Pill

    func showOverlay() {
        guard isRecording else { return }
        if overlay == nil { overlay = OverlayWindow(model: self, hiddenFromCapture: settings.overlayHiddenFromCapture) }
        overlay?.show()
    }

    func toast(_ text: String, error: Bool) {
        context?.toasts?.show(text, isError: error)
    }

    /// Lets go of the sound sources when the plugin unloads; what was recorded is processed.
    func shutDown() {
        if isRecording { stop() }
        overlay?.close()
        overlay = nil
    }
}

/// When each line of the meeting notes was started, keyed by its current text: a line keeps the time of its first
/// letter while it is typed.
final class RecorderNotes {
    private var lines: [String] = []
    private(set) var starts: [String: Double] = [:]

    /// Takes the notes' new text; true when the times changed.
    @discardableResult
    func changed(_ text: String, at now: Double) -> Bool {
        let new = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        var times: [String: Double] = [:]
        for (i, line) in new.enumerated() where !line.isEmpty {
            if let known = starts[line] {
                times[line] = known
            } else if i < lines.count, !lines[i].isEmpty, let previous = starts[lines[i]],
                      line.hasPrefix(lines[i]) || lines[i].hasPrefix(line) {
                times[line] = previous // The same line, still being typed.
            } else {
                times[line] = now
            }
        }
        lines = new
        guard times != starts else { return false }
        starts = times
        return true
    }
}
