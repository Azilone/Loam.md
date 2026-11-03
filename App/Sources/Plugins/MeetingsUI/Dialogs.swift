import AppKit
import MeetingsPlugin
import PluginKit
import PluginKitUI
import SwiftUI

/// A small window with a SwiftUI form, kept until it is closed.
@MainActor
final class DialogWindow: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private var onClose: (() -> Void)?
    private static var open: [DialogWindow] = []

    init(title: String, width: CGFloat, content: some View, onClose: (() -> Void)? = nil) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 200),
                          styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        self.onClose = onClose
        super.init()
        window.title = title
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.level = .floating
        let host = NSHostingView(rootView: content.frame(width: width))
        host.sizingOptions = [.intrinsicContentSize]
        window.contentView = host
        window.delegate = self
    }

    func show() {
        Self.open.append(self)
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        let action = onClose
        onClose = nil
        action?()
        Self.open.removeAll { $0 === self }
    }
}

// MARK: Speaker names

/// Who is who: the names the model found, with a few lines each, to confirm or fix before the summary is written.
@MainActor
enum SpeakerNames {
    static func ask(_ people: [Person], _ utterances: [Utterance]) async -> [Person] {
        guard !people.isEmpty else { return people }
        return await withCheckedContinuation { continuation in
            let form = SpeakerNamesForm(people: people, utterances: utterances)
            var resumed = false
            let finish = { (result: [Person]) in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: result)
            }
            var window: DialogWindow?
            let view = SpeakerNamesView(form: form) {
                finish(form.result)
                window?.close()
            }
            window = DialogWindow(title: "", width: 420, content: view) {
                finish(form.result)
            }
            window?.show()
        }
    }
}

@MainActor
@Observable
final class SpeakerNamesForm {
    var names: [String]
    let people: [Person]
    let samples: [[String]]

    init(people: [Person], utterances: [Utterance]) {
        self.people = people
        names = people.map(\.name)
        samples = people.map { Speakers.samples($0, utterances) }
    }

    /// The people with the names typed; two with the same name become one.
    var result: [Person] {
        var out: [Person] = []
        for (i, person) in people.enumerated() {
            let name = names[i].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, let same = out.firstIndex(where: { $0.name == name }) {
                out[same].labels += person.labels
            } else {
                out.append(Person(name: name, labels: person.labels, evidence: person.evidence))
            }
        }
        return out
    }
}

struct SpeakerNamesView: View {
    @Environment(\.themeTokens) private var theme
    @Bindable var form: SpeakerNamesForm
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Who is speaking?").font(.ui(.section))
            ScrollView {
                SetupGroup {
                    ForEach(form.people.indices, id: \.self) { i in
                        if i > 0 { Divider() }
                        HStack(spacing: 10) {
                            Avatar(name: form.names[i], index: i)
                            VStack(alignment: .leading, spacing: 3) {
                                TextField("Speaker \(i + 1)", text: $form.names[i])
                                    .textFieldStyle(.plain).font(.ui(.body, weight: .medium))
                                if let line = form.samples[i].first {
                                    Text("« \(line) »").font(.ui(.caption)).foregroundStyle(theme.secondaryText).lineLimit(1)
                                }
                            }
                        }
                        .padding(.vertical, 9)
                    }
                }
            }
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("OK", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .padding(.top, 14)
    }
}

/// A person's initial on a coloured circle.
struct Avatar: View {
    let name: String
    let index: Int
    static let colors: [Color] = [.blue, .orange, .purple, .green, .pink, .teal]

    var body: some View {
        Circle()
            .fill(Self.colors[index % Self.colors.count].gradient)
            .frame(width: 28, height: 28)
            .overlay(Text(name.first.map { String($0).uppercased() } ?? "\(index + 1)").font(.ui(size: 12, weight: .semibold)).foregroundStyle(.white))
    }
}

// MARK: Setup

/// The first-run screen, also the `meetings.setup` command: the OpenRouter key (checked, kept in the Keychain), the
/// Claude key when a Claude model is chosen, your name, and a sound test that shows both levels move.
@MainActor
@Observable
final class SetupModel {
    var openRouterKey = ""
    var anthropicKey = ""
    var keyStatus = ""
    var keyOK: Bool?
    var checking = false
    @ObservationIgnored private var pendingCheck: Task<Void, Never>?
    var name: String
    var levels: [Double?] = [nil, nil]
    var testing = false
    var testError = ""
    /// The permission macOS refused during the sound test, for a button to its pane.
    var testPermission: PrivacyPane?
    @ObservationIgnored private var sources: [AudioSource] = []
    @ObservationIgnored private let save: (MeetingsSettings) -> Void
    @ObservationIgnored private var settings: MeetingsSettings
    let hasStoredKey: Bool

    init(settings: MeetingsSettings, save: @escaping (MeetingsSettings) -> Void) {
        self.settings = settings
        self.save = save
        name = settings.myName
        hasStoredKey = DeviceKeys().openRouterKey() != nil
        if hasStoredKey { keyOK = true }
    }

    var needsClaudeKey: Bool { !settings.llmModel.contains("/") || (!settings.classifyModel.isEmpty && !settings.classifyModel.contains("/")) }

    /// Checks a pasted key half a second after the last change, and keeps it when it works.
    func keyChanged() {
        pendingCheck?.cancel()
        let key = openRouterKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        pendingCheck = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            checking = true
            let result = await OpenRouterClient.check(openRouterKey: key)
            guard !Task.isCancelled else { return }
            checking = false
            keyOK = result.ok
            keyStatus = result.message
            if result.ok { try? DeviceKeys().set(.openRouter, key) }
        }
    }

    func saveRest() {
        let claude = anthropicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !claude.isEmpty { try? DeviceKeys().set(.anthropic, claude) }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, trimmed != settings.myName {
            settings.myName = trimmed
            save(settings)
        }
        stopTest()
    }

    /// Ten seconds of both sources' levels: macOS asks for the microphone and the Mac's sound the first time.
    func soundTest() async {
        guard !testing else { return }
        testError = ""
        testPermission = nil
        guard await MicrophoneSource.requestAccess() else {
            testError = "No access to the microphone."
            testPermission = .microphone
            return
        }
        testing = true
        let meters = Meters()
        let mic = MicrophoneSource { meters.set(0, $0) }
        let system = SystemAudioSource { meters.set(1, $0) }
        do { try mic.start(); sources.append(mic) } catch { testError = error.localizedDescription }
        do {
            try system.start()
            sources.append(system)
        } catch {
            testError = error.localizedDescription
            testPermission = (error as? CaptureError)?.permission
        }
        while testing {
            try? await Task.sleep(nanoseconds: 200_000_000)
            levels = meters.get()
        }
        stopTest()
    }

    func stopTest() {
        for source in sources { source.stop() }
        sources = []
        testing = false
    }

    final class Meters: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Double?] = [nil, nil]

        func set(_ i: Int, _ samples: [Int16]) {
            var sum = 0.0
            for s in samples { sum += Double(s) * Double(s) }
            let rms = (sum / Double(max(1, samples.count))).squareRoot() / 32768
            lock.lock()
            values[i] = rms > 0 ? 20 * log10(rms) : -120
            lock.unlock()
        }

        func get() -> [Double?] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }
}

struct SetupView: View {
    @Environment(\.themeTokens) private var theme
    @Bindable var model: SetupModel
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Recorder", symbol: "waveform.badge.mic")
                .font(.ui(.section))
            SetupGroup {
                SetupRow("OpenRouter key") {
                    SecureField(model.hasStoredKey ? "Saved" : "sk-or-v1-…", text: $model.openRouterKey)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .onChange(of: model.openRouterKey) { model.keyChanged() }
                    KeyStatus(model: model)
                }
                if model.needsClaudeKey {
                    Divider()
                    SetupRow("Claude key") {
                        SecureField("sk-ant-…", text: $model.anthropicKey).textFieldStyle(.plain).multilineTextAlignment(.trailing)
                    }
                }
                Divider()
                SetupRow("Your name") {
                    TextField("", text: $model.name).textFieldStyle(.plain).multilineTextAlignment(.trailing)
                }
            }
            SetupGroup {
                SetupRow("Microphone") { LevelBar(level: model.levels[0]) }
                Divider()
                SetupRow("Mac's sound") { LevelBar(level: model.levels[1]) }
            }
            if !model.testError.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    Text(model.testError).font(.ui(.caption)).foregroundStyle(theme.danger).fixedSize(horizontal: false, vertical: true)
                    if let pane = model.testPermission {
                        Spacer()
                        Button("Open System Settings") { NSWorkspace.shared.open(pane.url) }
                            .controlSize(.small)
                    }
                }
            }
            HStack {
                Link(destination: URL(string: "https://openrouter.ai/keys")!) {
                    Label("Get a key", symbol: "arrow.up.right").font(.ui(.caption))
                }
                Spacer()
                Button("OK", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .padding(.top, 14)
        .task { await model.soundTest() }
    }
}

/// Craft's settings group: rows on a white rounded card.
struct SetupGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: Corners.r(10)).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: Corners.r(10)).strokeBorder(.separator.opacity(0.5)))
    }
}

struct SetupRow<Trailing: View>: View {
    let title: String
    @ViewBuilder let trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(title.uiLocalized)
            Spacer(minLength: 12)
            trailing
        }
        .frame(minHeight: 38)
    }
}

struct KeyStatus: View {
    @Environment(\.themeTokens) private var theme
    let model: SetupModel

    var body: some View {
        Group {
            if model.checking {
                ProgressView().controlSize(.small)
            } else if let ok = model.keyOK {
                Image(symbol: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(ok ? theme.success : theme.danger)
                    .help(model.keyStatus)
            }
        }
        .frame(width: 16)
    }
}

/// A horizontal sound level, for the sound test.
struct LevelBar: View {
    let level: Double?

    var body: some View {
        let fill = level.map { max(0, min(1, ($0 + 60) / 50)) } ?? 0
        ThemeCapsule().fill(.quaternary)
            .frame(width: 120, height: 6)
            .overlay(alignment: .leading) { ThemeCapsule().fill(.green).frame(width: 120 * fill) }
            .animation(.linear(duration: 0.12), value: fill)
    }
}
