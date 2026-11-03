import Foundation
import Observation
import PluginKitUI
import PluginKit

/// Runs commands for the UI (the palette, keyboard shortcuts) and says how it went in a toast: a short message
/// along the bottom of the window for a few seconds. Commands run as everywhere else (off the main actor; a handler
/// that touches the UI hops there itself); only their answer comes back here.
@MainActor
@Observable
public final class CommandRunner {
    public struct Toast: Identifiable, Equatable, Sendable {
        public let id = UUID()
        public let text: String
        public let kind: ToastKind
        public var isError: Bool { kind == .error }
    }

    /// The message on screen, if any.
    public private(set) var toast: Toast?
    /// The commands run lately, most recent first, for the palette's "Recent" section. Kept for this window only.
    public private(set) var recent: [String] = []
    static let recentLimit = 3
    /// Told the id of every command about to run, so the popup knows which of its tabs a command opens.
    @ObservationIgnored var willRun: (@MainActor (String) -> Void)?

    /// How long a toast stays.
    @ObservationIgnored let toastDuration: Duration
    /// The least a toast stays after the pointer that held it leaves: enough to see it is going.
    @ObservationIgnored let toastGrace: Duration
    @ObservationIgnored private let lookup: (String) -> Command?
    /// The timer that takes the toast down, and what is left of it while the pointer holds the toast.
    @ObservationIgnored private var toastTimer: Task<Void, Never>?
    @ObservationIgnored private var toastDeadline: ContinuousClock.Instant?
    @ObservationIgnored private var toastRemaining: Duration

    /// - Parameter lookup: finds a command by id (`kernel.commands.command(id:)`).
    init(
        toastDuration: Duration = .seconds(3),
        toastGrace: Duration = .seconds(1),
        lookup: @escaping (String) -> Command?
    ) {
        self.toastDuration = toastDuration
        self.toastGrace = toastGrace
        self.toastRemaining = toastDuration
        self.lookup = lookup
    }

    /// Runs a command by id with no arguments. The task is returned for tests; the UI does not wait for it.
    @discardableResult
    public func run(_ commandID: String) -> Task<Void, Never> {
        guard let command = lookup(commandID) else {
            show("No command “\(commandID)”.", isError: true)
            return Task {}
        }
        return run(command)
    }

    @discardableResult
    public func run(_ command: Command) -> Task<Void, Never> {
        willRun?(command.id)
        let handler = command.handler
        let title = command.title
        return Task { [weak self] in
            do {
                let output = try await handler([:])
                if let message = Self.message(for: output) { self?.show(message, kind: .success) }
            } catch {
                self?.show(Self.message(for: error, title: title), isError: true)
            }
        }
    }

    /// Remembers a command chosen in the palette, first in `recent`.
    func remember(_ commandID: String) {
        recent = Array(([commandID] + recent.filter { $0 != commandID }).prefix(Self.recentLimit))
    }

    /// Shows a message for `toastDuration`, replacing the current one.
    public func show(_ text: String, kind: ToastKind) {
        let toast = Toast(text: text, kind: kind)
        self.toast = toast
        toastRemaining = toastDuration
        startToastTimer(for: toast)
        if kind == .error { Sounds.play(.failed) }
        if kind == .success { Sounds.play(.succeeded) }
    }

    public func show(_ text: String, isError: Bool) {
        show(text, kind: isError ? .error : .info)
    }

    public func dismissToast() {
        toastTimer?.cancel()
        toastTimer = nil
        toast = nil
    }

    /// The pointer is over the toast (`true`): its timer stops, so a message can be read as long as needed. When it
    /// leaves (`false`) the timer goes on with what was left, but for at least `toastGrace`.
    public func holdToast(_ held: Bool) {
        guard let toast else { return }
        if held {
            guard toastTimer != nil, let deadline = toastDeadline else { return }
            toastTimer?.cancel()
            toastTimer = nil
            toastRemaining = max(ContinuousClock.now.duration(to: deadline), toastGrace)
        } else if toastTimer == nil {
            startToastTimer(for: toast)
        }
    }

    private func startToastTimer(for toast: Toast) {
        toastTimer?.cancel()
        let remaining = toastRemaining
        toastDeadline = .now + remaining
        toastTimer = Task { [weak self] in
            try? await Task.sleep(for: remaining)
            guard !Task.isCancelled, let self, self.toast?.id == toast.id else { return }
            self.toast = nil
            self.toastTimer = nil
        }
    }

    /// What a command's output is worth showing: a short sentence, not an empty string or a JSON blob meant for
    /// the CLI and agents. A JSON object with a `message` (`sync.status`, `search.status`) shows that message.
    static func message(for output: String) -> String? {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("{"), let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = object["message"] as? String {
            text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !text.isEmpty, text.count <= 200, !text.hasPrefix("{"), !text.hasPrefix("[") else { return nil }
        guard text.split(separator: "\n", omittingEmptySubsequences: false).count <= 3 else { return nil }
        return text
    }

    static func message(for error: Error, title: String) -> String {
        if case CommandError.missingArgument(let name) = error {
            return "“\(title)” needs arguments (\(name)); run it from the loam command line."
        }
        let description = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        return "“\(title)” failed: \(description)"
    }
}

/// The `ui.toasts` service: plugins show their messages in the `CommandRunner`'s toast. The runner is made after the
/// plugins' host services are listed, so it is set right after.
@MainActor
final class ToastBridge: Toasts {
    weak var runner: CommandRunner?

    func show(_ text: String, kind: ToastKind) {
        runner?.show(text, kind: kind)
    }
}

/// The `ui.commands` service: a plugin's button runs a command through the `CommandRunner`, as the palette does. Set
/// up like `ToastBridge`, once the runner and the kernel exist.
@MainActor
final class CommandBridge: CommandLauncher {
    weak var runner: CommandRunner?
    /// The registered commands and the shortcut overrides of `.loam/config.json`, read at each call so both follow
    /// plugins being turned on and off.
    var commands: () -> [Command] = { [] }
    var overrides: () -> [String: String] = { [:] }
    /// Changes when a command comes or goes (`CommandCenter.revision`).
    var revision: () -> Int = { 0 }
    /// The commands' ids and shortcuts, kept while the commands and the overrides stay the same: a home page asks
    /// for several shortcuts each time it draws, and each answer listed, sorted and mapped every command.
    private var known: (revision: Int, overrides: [String: String], ids: Set<String>, table: ShortcutTable)?

    private var current: (ids: Set<String>, table: ShortcutTable) {
        let revision = revision(), overrides = overrides()
        if let known, known.revision == revision, known.overrides == overrides { return (known.ids, known.table) }
        let commands = commands()
        let made = (revision: revision, overrides: overrides, ids: Set(commands.map(\.id)),
                    table: ShortcutTable(commands: commands, overrides: overrides))
        known = made
        return (made.ids, made.table)
    }

    func isAvailable(_ id: String) -> Bool { current.ids.contains(id) }

    func run(_ id: String) { _ = runner?.run(id) }

    func run(_ id: String, arguments: [String: String]) async throws -> String {
        guard let command = commands().first(where: { $0.id == id }) else { throw ShellError.unknownCommand(id) }
        return try await command.handler(arguments)
    }

    func shortcut(for id: String) -> String? {
        current.table.shortcut(for: id)?.displayString
    }
}
