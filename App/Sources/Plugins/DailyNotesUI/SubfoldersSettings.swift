import DailyNotesPlugin
import Observation
import PluginKitUI
import SwiftUI

/// The subfolder setting's own field: the pattern new daily notes are sorted by, the presets it replaces, and the
/// path it gives today's note, which follows the field. It shows on the daily notes plugin's page; the generic
/// field it stands in for stays under "Advanced settings".
@MainActor
@Observable
final class SubfoldersSettings {
    /// What the field shows.
    private(set) var pattern: String
    /// Where a new note would go with this pattern.
    private(set) var preview: String
    @ObservationIgnored private let daily: DailyNotes
    @ObservationIgnored private let commands: () -> (any CommandLauncher)?
    @ObservationIgnored private var saving: Task<Void, Never>?
    /// The value the settings hold, as the field last wrote it: a change from elsewhere is the only one that
    /// replaces what is being typed.
    @ObservationIgnored private var lastSaved: String

    init(daily: DailyNotes, commands: @escaping () -> (any CommandLauncher)?) {
        self.daily = daily
        self.commands = commands
        pattern = daily.subfolderPattern
        preview = (try? daily.newNotePath(for: nil)) ?? ""
        lastSaved = pattern
    }

    /// Reads the setting again, for a change made elsewhere (the CLI, the generic field): the field keeps what is
    /// being typed when the saved value is the one it already wrote.
    func refresh() {
        let current = daily.subfolderPattern
        if current != lastSaved {
            lastSaved = current
            pattern = current
        }
        preview = (try? daily.newNotePath(for: nil)) ?? ""
    }

    /// Follows the field; the value is written once typing pauses, as a settings field saves.
    func typing(_ text: String) {
        pattern = text
        saving?.cancel()
        saving = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await self?.save()
        }
    }

    /// A preset: written at once.
    func choose(_ text: String) {
        saving?.cancel()
        pattern = text
        Task { [weak self] in await self?.save() }
    }

    private func save() async {
        guard let commands = commands() else { return }
        _ = try? await commands.run("plugins.set-setting", arguments: [
            "id": "daily-notes", "key": "subfolders", "value": pattern,
        ])
        // The service has the new layout once its plugin has been told, so the preview reads it back.
        lastSaved = daily.subfolderPattern
        preview = (try? daily.newNotePath(for: nil)) ?? ""
    }
}

/// The card the page shows for it: a field, the presets the setting had before patterns, and the path today's
/// note would get, above the tokens the pattern reads.
struct SubfoldersSettingsView: View {
    let model: SubfoldersSettings
    @Environment(\.themeTokens) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            TextField("yyyy/MM MMMM", text: Binding(get: { model.pattern }, set: { model.typing($0) }))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: UIType.body.size, design: .monospaced))
            presets
            preview
            Text("yyyy 2026 · yy 26 · MM 11 · MMM Nov · MMMM November · dd 07")
                .font(.ui(.caption))
                .foregroundStyle(theme.secondaryText)
        }
        .padding(Space.m)
        .onAppear { model.refresh() }
    }

    private var presets: some View {
        HStack(spacing: Space.s) {
            preset("None", "")
            preset("Year", "yyyy")
            preset("Year and month", "yyyy/MM MMMM")
        }
    }

    private func preset(_ title: String, _ pattern: String) -> some View {
        Button(title.uiLocalized) { model.choose(pattern) }
            .buttonStyle(.press)
            .font(.ui(.label))
    }

    private var preview: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Text("Preview".uiLocalized)
                .font(.ui(.label))
                .foregroundStyle(theme.secondaryText)
            Text(model.preview)
                .font(.system(size: UIType.label.size, design: .monospaced))
                .foregroundStyle(theme.text)
                .textSelection(.enabled)
        }
    }
}
