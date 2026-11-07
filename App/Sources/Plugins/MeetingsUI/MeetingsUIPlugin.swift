import AppKit
import MeetingsPlugin
import PluginKit
import PluginKitUI
import SwiftUI
import UniformTypeIdentifiers

/// The meeting recorder in the app: records the microphone and the Mac's sound into the `meetings` engine, with a
/// status bar item, a floating pill out of screen sharing, the speaker names to confirm, a setup screen for the key
/// and a sound test. Watches the inbox folder and Voice Memos, retries failed recordings and finishes the ones a
/// quit cut short.
public final class MeetingsUIPlugin: UIPlugin {
    public static let manifest = PluginManifest(
        id: "meetings-ui",
        name: "Meeting recorder in the app",
        version: "0.1.0",
        description: "Records the microphone and the Mac's sound, with a floating recorder.",
        icon: "record.circle",
        requires: ["meetings"],
        permissions: ["ui", "vault.read", "vault.write", "audio", "network"]
    )

    static let pageResource = Resource.virtual("meetings:")

    public init() {}

    @MainActor public func activateUI(context: PluginContext) throws {
        guard let meetings = context.service(.meetings) else { return }
        let model = RecorderModel(meetings: meetings, context: context)
        let actions = Actions(model: model, context: context)
        model.showSetup = { [weak actions] in actions?.setup() }
        meetings.askNames = { people, utterances in
            await SpeakerNames.ask(people, utterances)
        }
        context.effect {
            meetings.askNames = nil
            MainActor.assumeIsolated { model.shutDown() }
        }

        try context.registerView(ViewType(
            id: "meetings.page", title: "Meetings", canOpen: { $0 == Self.pageResource },
            makeView: { _ in AnyView(MeetingsPage(model: model, actions: actions)) }
        ))
        try context.addSidebarLink(SidebarLink(
            id: "meetings.link", title: "Meetings".uiLocalized, symbol: "waveform", resource: Self.pageResource, order: 27,
            count: { model.processing.isEmpty ? nil : model.processing.count }
        ))

        // The meetings folder shows the waveform of the sidebar's link, the voice notes a microphone.
        context.intercept(FolderIcons.self) { event, next in
            var event = event
            let settings = meetings.settings
            if let folder = try? VaultPath.normalize(settings.meetingsFolder), !folder.isEmpty { event.symbols[folder] = "waveform" }
            if let folder = try? VaultPath.normalize(settings.voiceFolder), !folder.isEmpty { event.symbols[folder] = "mic" }
            return next(event)
        }

        context.on(MeetingProgress.self) { @Sendable event in Task { @MainActor in model.progressed(event) } }
        context.on(MeetingFinished.self) { @Sendable event in Task { @MainActor in model.finished(event) } }
        context.on(MeetingFailed.self) { @Sendable event in Task { @MainActor in model.failed(event) } }
        context.on(DocumentTextChanged.self) { [weak context] event in
            Task { @MainActor in
                guard event.path == model.notesPath, let text = context?.editor?.text(of: event.path) else { return }
                model.notesChanged(text)
            }
        }
        // Events come on the thread that emitted them (a command's write, off the main thread): not the main actor's.
        context.on(VaultChanged.self) { @Sendable _ in Task { @MainActor in model.refreshRecordings() } }
        context.on(VaultChanged.self) { @Sendable event in
            let inbox = (try? VaultPath.normalize(meetings.settings.inboxFolder)) ?? ""
            guard !inbox.isEmpty, event.changes.contains(where: {
                VaultPath.directory(of: $0.path) == inbox && Meetings.isAudio($0.path) && actions.exists($0.path)
            }) else { return }
            Task.detached { await meetings.processInbox() }
        }

        try registerCommands(context, model: model, actions: actions)
        addResourceActions(context, actions: actions)
        actions.startBackgroundWork()
    }

    @MainActor private func registerCommands(_ context: PluginContext, model: RecorderModel, actions: Actions) throws {
        try context.registerCommand(Command(
            id: "meetings.start",
            title: "Record a meeting or a voice note…",
            summary: "Asks what to record (a call: microphone and the Mac's sound; a meeting in person: microphone only; "
                + "or a voice note for the journal), then starts recording with the floating recorder. In the app only.",
            shortcut: KeyShortcut("r", [.command, .shift])
        ) { _ in
            await MainActor.run { actions.chooseAndStart() }
            return ""
        })
        try context.registerCommand(Command(
            id: "meetings.open",
            title: "Open meetings",
            summary: "Opens the Meetings page: buttons to record a call, a meeting in person or a voice note, and every recording."
        ) { _ in
            await MainActor.run { actions.openPage() }
            return ""
        })
        try context.registerCommand(Command(
            id: "meetings.record-call",
            title: "Record a call",
            summary: "Starts recording a call at once: your microphone and the Mac's sound, with the notes open. In the app only."
        ) { _ in
            await model.start(kind: .meeting, mode: .call)
            return await MainActor.run { model.isRecording ? "Recording \(model.title)." : "Not recording." }
        })
        try context.registerCommand(Command(
            id: "meetings.voice-note",
            title: "Record a voice note",
            summary: "Starts a voice note at once (microphone only); when stopped it becomes an entry in today's note. In the app only."
        ) { _ in
            await model.start(kind: .voice)
            return await MainActor.run { model.isRecording ? "Recording a voice note." : "Not recording." }
        })
        try context.registerCommand(Command(
            id: "meetings.stop",
            title: "Stop recording",
            summary: "Stops the recording in progress and turns it into notes (the summary opens when ready)."
        ) { _ in
            await MainActor.run {
                guard model.isRecording else { return "Nothing is being recorded." }
                model.stop()
                return "Stopped; processing."
            }
        })
        try context.registerCommand(Command(
            id: "meetings.cancel",
            title: "Cancel recording",
            summary: "Throws the recording in progress away (it goes to the vault's trash) without making notes."
        ) { _ in
            await MainActor.run { model.isRecording } ? (await model.cancel(confirm: false) ? "Cancelled." : "Kept.") : "Nothing is being recorded."
        })
        try context.registerCommand(Command(
            id: "meetings.restart",
            title: "Restart recording",
            summary: "Throws the recording in progress away and starts a new one of the same kind."
        ) { _ in
            guard await MainActor.run(body: { model.isRecording }) else { return "Nothing is being recorded." }
            await model.restart()
            return "Restarted."
        })
        try context.registerCommand(Command(
            id: "meetings.pause",
            title: "Pause or resume recording",
            summary: "Pauses the recording in progress, or resumes it."
        ) { _ in
            await MainActor.run {
                model.togglePause()
                return model.isPaused ? "Paused." : "Recording."
            }
        })
        try context.registerCommand(Command(
            id: "meetings.mark",
            title: "Mark this moment in the meeting notes",
            summary: "Adds a ==⏱ mm:ss== marker to the meeting's notes, at the caret when they have the focus; the summary pays attention to it."
        ) { _ in
            await MainActor.run { model.markMoment() }
            return ""
        })
        try context.registerCommand(Command(
            id: "meetings.show-recorder",
            title: "Show the floating recorder",
            summary: "Shows the floating recorder pill again while recording."
        ) { _ in
            await MainActor.run { model.showOverlay() }
            return ""
        })
        try context.registerCommand(Command(
            id: "meetings.import-file",
            title: "Import an audio recording…",
            summary: "Picks an audio file anywhere on disk and turns it into a meeting or a voice note. Opens a dialog; "
                + "from the command line or an agent use meetings.import with a path."
        ) { _ in
            await MainActor.run { actions.pickFile() }
            return ""
        })
        try context.registerCommand(Command(
            id: "meetings.setup",
            title: "Set up the meeting recorder…",
            summary: "Opens the setup: OpenRouter key (kept in the Keychain), your name and a sound test. In the app only."
        ) { _ in
            await MainActor.run { actions.setup() }
            return ""
        })
    }

    @MainActor private func addResourceActions(_ context: PluginContext, actions: Actions) {
        context.addResourceAction(ResourceAction(
            id: "meetings.from-audio", title: "Create a meeting from this audio", symbol: "waveform", order: 40,
            appliesTo: { $0.kind == .file && Meetings.isAudio($0.path) && !(($0.path as NSString).lastPathComponent.hasPrefix("audio.")) },
            perform: { actions.importAudio($0.path) }
        ))
        context.addResourceAction(ResourceAction(
            id: "meetings.reprocess", title: "Re-process this meeting", symbol: "arrow.clockwise", order: 41,
            appliesTo: { actions.isRecordingFolder($0) },
            perform: { actions.reprocess($0.kind == .folder ? $0.path : VaultPath.directory(of: $0.path)) }
        ))
    }
}

/// What the commands and menus do, on the main actor.
@MainActor
final class Actions {
    private let model: RecorderModel
    private weak var context: PluginContext?
    private var timers: [Timer] = []

    init(model: RecorderModel, context: PluginContext) {
        self.model = model
        self.context = context
    }

    deinit {
        MainActor.assumeIsolated { for timer in timers { timer.invalidate() } }
    }

    private var meetings: Meetings { model.meetings }

    nonisolated func exists(_ path: String) -> Bool {
        MainActor.assumeIsolated { context?.vault.exists(path) ?? false }
    }

    func openPage() {
        context?.workspace?.open(MeetingsUIPlugin.pageResource, placement: .newTab)
    }

    /// The three kinds of recording, in a popup.
    func chooseAndStart() {
        guard !model.isRecording else { return model.showOverlay() }
        let items = [
            QuickPickItem(id: "call", title: "Call", symbol: "phone"),
            QuickPickItem(id: "room", title: "In person", symbol: "person.2"),
            QuickPickItem(id: "voice", title: "Voice note", symbol: "waveform"),
        ]
        let defaultFirst = model.settings.defaultMode == "room" ? [items[1], items[0], items[2]] : items
        context?.quickPick?.show(placeholder: "Record", items: { query in
            Fuzzy.rank(defaultFirst, query: query) { $0.title + " " + ($0.subtitle ?? "") }
        }, choose: { [model] item in
            Task {
                switch item.id {
                case "voice": await model.start(kind: .voice)
                case "room": await model.start(kind: .meeting, mode: .room)
                default: await model.start(kind: .meeting, mode: .call)
                }
            }
        })
    }

    func pickFile() {
        let panel = NSOpenPanel()
        panel.title = "Import a recording"
        panel.allowedContentTypes = [.audio, .mpeg4Audio, .mp3, .wav, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let root = (context?.vault.rootURL.standardizedFileURL.path ?? "") + "/"
        let path = url.standardizedFileURL.path
        importAudio(path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path)
    }

    /// Asks what the file is (a meeting or a voice note, or let the content decide), then imports it.
    func importAudio(_ path: String) {
        guard DeviceKeys().openRouterKey() != nil else { return setup() }
        let items = [
            QuickPickItem(id: "auto", title: "Automatic", symbol: "sparkles"),
            QuickPickItem(id: "meeting", title: "Meeting", symbol: "person.2"),
            QuickPickItem(id: "voice", title: "Voice note", symbol: "waveform"),
        ]
        context?.quickPick?.show(placeholder: (path as NSString).lastPathComponent, items: { _ in items }, choose: { [meetings] item in
            let kind = MeetingKind(rawValue: item.id) ?? .auto
            Task.detached { _ = try? await meetings.importAudio(path, options: .init(kind: kind), background: false) }
        })
    }

    func reprocess(_ folder: String) {
        Task.detached { [meetings] in _ = try? await meetings.reprocess(folder) }
    }

    func isRecordingFolder(_ resource: Resource) -> Bool {
        guard let vault = context?.vault else { return false }
        let folder = resource.kind == .folder ? resource.path : VaultPath.directory(of: resource.path)
        guard !folder.isEmpty, model.session?.state.folder != folder, model.processing[folder] == nil else { return false }
        return FileManager.default.fileExists(atPath: vault.rootURL.appendingPathComponent("\(folder)/.raw/meeting.json").path)
    }

    func setup() {
        let model = SetupModel(settings: self.model.settings) { [weak context] settings in
            try? context?.settings.update(settings)
        }
        var window: DialogWindow?
        window = DialogWindow(title: "", width: 400, content: SetupView(model: model) { window?.close() }) { model.saveRest() }
        window?.show()
    }

    /// On launch: finish what a quit cut short, retry failures, take what waits in the inbox; then every 2 minutes
    /// retry failures and look for new Voice Memos.
    func startBackgroundWork() {
        let meetings = meetings
        Task.detached {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard DeviceKeys().openRouterKey() != nil else { return }
            for state in meetings.interrupted() { _ = try? await meetings.reprocess(state.folder, background: true) }
            await meetings.retryFailed()
            await meetings.processInbox()
            try? await meetings.checkVoiceMemos()
        }
        let timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.periodic() }
        }
        timers.append(timer)
    }

    private var warnedNoAccess = false

    private func periodic() {
        guard DeviceKeys().openRouterKey() != nil else { return }
        let meetings = meetings
        let working = Set(model.processing.keys).union(model.session.map { [$0.state.folder] } ?? [])
        Task.detached { [weak self] in
            await meetings.retryFailed(skipping: working)
            do {
                try await meetings.checkVoiceMemos()
            } catch is VoiceMemos.NoAccess {
                await MainActor.run {
                    guard let self, !self.warnedNoAccess else { return }
                    self.warnedNoAccess = true
                    PrivacyPane.fullDisk.ask()
                }
            } catch {}
        }
    }
}
