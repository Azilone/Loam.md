import LoamCore
import PluginKit
import PluginKitUI
import SwiftUI

/// One setting of a plugin, as a row of its page: a switch for a bool, a picker when the plugin gives choices, a
/// field for a string or a number (saved as you type, as System Settings does), and indented JSON for a list or an
/// object (read only). The control follows the type of the plugin's default, not of what is stored. Writes go through
/// `PluginManagerModel.updateSetting`, which tells the plugin.
struct SettingFieldRow: View {
    let model: PluginManagerModel
    let pluginID: String
    let field: SettingField
    @Environment(\.themeTokens) private var theme

    var body: some View {
        if !field.choices.isEmpty {
            SettingsRow(title: field.title, detail: field.help) {
                // By position: a setting's values are JSON, which a picker cannot tag.
                Picker(field.title, selection: Binding(
                    get: { field.choices.firstIndex { $0.value == field.value } ?? -1 },
                    set: { index in
                        guard field.choices.indices.contains(index) else { return }
                        model.updateSetting(field.key, to: field.choices[index].value, for: pluginID)
                    }
                )) {
                    ForEach(Array(field.choices.enumerated()), id: \.offset) { index, choice in
                        Text(choice.title.uiLocalized).tag(index)
                    }
                    // A stored value the plugin does not offer stays visible rather than blank.
                    if !field.choices.contains(where: { $0.value == field.value }) {
                        Text(PluginManagerModel.json(field.value)).tag(-1)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
        } else {
            switch field.kind {
            case .bool:
                SettingsRow(title: field.title, detail: field.help) {
                    SettingsSwitch(title: field.title, isOn: Binding(
                        get: { field.value == .bool(true) },
                        set: { newValue in model.updateSetting(field.key, to: .bool(newValue), for: pluginID) }
                    ))
                }
            case .string:
                SettingsRow(title: field.title, detail: field.help) {
                    SettingTextField(initial: Self.text(of: field.value)) { text in
                        model.updateSetting(field.key, to: .string(text), for: pluginID)
                    }
                    .frame(width: 240)
                }
            case .number:
                SettingsRow(title: field.title, detail: field.help) {
                    SettingNumberField(initial: Self.number(of: field.value), wholeNumber: field.isWholeNumber) { number in
                        model.updateSetting(field.key, to: .number(number), for: pluginID)
                    }
                    .frame(width: 100)
                }
            case .null:
                SettingsRow(title: field.title, detail: field.help) {
                    Text("Not set").font(.ui(size: SettingsStyle.detailSize)).foregroundStyle(theme.secondaryText)
                }
            case .list, .map:
                VStack(alignment: .leading, spacing: 6) {
                    SettingsRow(title: field.title, detail: field.help)
                    Text(PluginManagerModel.json(field.value))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.secondaryText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, SettingsStyle.rowPadding)
                        .padding(.bottom, 10)
                }
            }
        }
    }

    private static func text(of value: JSONValue) -> String {
        if case .string(let text) = value { return text }
        return value == .null ? "" : PluginManagerModel.json(value)
    }

    private static func number(of value: JSONValue) -> Double {
        if case .number(let number) = value { return number }
        return 0
    }
}

/// Saves what is typed in a settings field: after a short pause, on Return, when the field loses focus, and when it
/// goes away (Back, another pane, the window closing), so leaving a page never loses what was typed.
private struct DeferredSave {
    static let pause: Duration = .milliseconds(500)

    /// Saves after `pause`, unless typing goes on.
    static func schedule(_ task: inout Task<Void, Never>?, _ save: @escaping @MainActor @Sendable () -> Void) {
        task?.cancel()
        task = Task { @MainActor in
            try? await Task.sleep(for: pause)
            guard !Task.isCancelled else { return }
            save()
        }
    }
}

/// A text setting: saved as you type, after a pause, and whenever the field is left (`DeferredSave`).
struct SettingTextField: View {
    let initial: String
    let commit: (String) -> Void
    @State private var text: String
    @State private var pending: Task<Void, Never>?
    @FocusState private var isFocused: Bool

    init(initial: String, commit: @escaping (String) -> Void) {
        self.initial = initial
        self.commit = commit
        _text = State(initialValue: initial)
    }

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .focused($isFocused)
            .onSubmit { save() }
            .onChange(of: text) { _, value in
                if value == initial { pending?.cancel() } else { DeferredSave.schedule(&pending) { save() } }
            }
            .onChange(of: isFocused) { _, focused in if !focused { save() } }
            // A change made elsewhere (the CLI, another window) shows, unless it is being typed over.
            .onChange(of: initial) { _, value in if !isFocused { text = value } }
            .onDisappear { save() }
    }

    private func save() {
        pending?.cancel()
        pending = nil
        if text != initial { commit(text) }
    }
}

/// A number setting, saved as `SettingTextField` is. Text that is not a number, or a fraction where the plugin reads
/// a whole number, is not saved, and is put back when the field is left.
struct SettingNumberField: View {
    let initial: Double
    let wholeNumber: Bool
    let commit: (Double) -> Void
    @State private var text: String
    @State private var pending: Task<Void, Never>?
    @Environment(\.themeTokens) private var theme
    @FocusState private var isFocused: Bool
    /// Set when the field was left holding something the plugin cannot take; cleared by the next keystroke.
    @State private var refused = false

    init(initial: Double, wholeNumber: Bool, commit: @escaping (Double) -> Void) {
        self.initial = initial
        self.wholeNumber = wholeNumber
        self.commit = commit
        _text = State(initialValue: Self.format(initial))
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            field
            if refused || (number == nil && !text.isEmpty) {
                Text(wholeNumber ? "Enter a whole number" : "Enter a number")
                    .font(.ui(size: 11))
                    .foregroundStyle(theme.danger)
            }
        }
    }

    private var field: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .focused($isFocused)
            .onSubmit { leave() }
            .onChange(of: text) { _, _ in
                if text != Self.format(initial) { refused = false }
                if number == initial { pending?.cancel() } else { DeferredSave.schedule(&pending) { save() } }
            }
            .onChange(of: isFocused) { _, focused in if !focused { leave() } }
            .onChange(of: initial) { _, value in if !isFocused { text = Self.format(value) } }
            .onDisappear { save() }
    }

    /// What is typed, when the plugin can take it.
    private var number: Double? {
        guard let number = Self.parse(text) else { return nil }
        return wholeNumber && number.rounded() != number ? nil : number
    }

    private func save() {
        pending?.cancel()
        pending = nil
        if let number, number != initial { commit(number) }
    }

    /// Return or leaving the field: saves, else puts back the value in effect.
    private func leave() {
        save()
        if number == nil {
            refused = true
            text = Self.format(initial)
        }
    }

    static func parse(_ text: String) -> Double? {
        try? Double(text.trimmingCharacters(in: .whitespaces), format: .number)
    }

    static func format(_ number: Double) -> String {
        number.formatted(.number.grouping(.never))
    }
}
