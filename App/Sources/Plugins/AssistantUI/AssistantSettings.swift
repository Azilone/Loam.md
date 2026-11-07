import AssistantPlugin
import PluginKitUI
import SwiftUI

/// Settings > Assistant, as Craft's: the agents on this Mac and their sign-in, Saved Prompts ("+ Add Prompt" and its
/// Create Custom Prompt dialog), and the user's instructions.
struct AgentsSettings: View {
    let model: AssistantModel
    @Environment(\.themeTokens) private var theme

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(AgentKind.allCases.enumerated()), id: \.element) { index, kind in
                if index > 0 { SettingsHairline() }
                let status = model.status(kind)
                HStack(spacing: 12) {
                    AgentIcon(kind: kind).frame(width: 20).foregroundStyle(theme.text)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(kind.name).font(.ui(size: 13)).foregroundStyle(theme.text.opacity(0.88))
                        Text(detail(kind, status))
                            .font(.ui(size: 12))
                            .foregroundStyle(theme.secondaryText)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if let usage = status?.usage, !usage.isEmpty {
                            UsageBars(windows: usage)
                        }
                    }
                    Spacer()
                    Circle()
                        .fill(status?.state == .ready ? Color.green : status?.state == .signedOut ? .orange : .gray.opacity(0.4))
                        .frame(width: 8, height: 8)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .frame(minHeight: 40)
            }
            SettingsHairline()
            Button("Check Again") { model.refreshAgents() }
                .buttonStyle(.plain)
                .font(.ui(size: 13))
                .foregroundStyle(theme.accent)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        }
        .onAppear { model.refreshAgents() }
    }

    private func detail(_ kind: AgentKind, _ status: AgentStatus?) -> String {
        guard let status else { return "Checking…" }
        switch status.state {
        case .missing: return "Not installed. In a terminal: \(kind.installHint)"
        case .signedOut: return "Signed out. In a terminal: \(kind.loginCommand)"
        case .ready:
            let isDefault = model.defaultAgentKind() == kind
            return ["Ready", status.account, isDefault ? "Default" : nil].compactMap { $0 }.joined(separator: " · ")
        }
    }
}

/// A plan's limits as Codex reports them (CodexBar's bars): the window, how much is used, when it starts again.
struct UsageBars: View {
    let windows: [UsageWindow]
    @Environment(\.themeTokens) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                HStack(spacing: 8) {
                    Text(window.name).frame(width: 56, alignment: .leading)
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(theme.separator)
                            Capsule().fill(window.usedPercent >= 90 ? Color.orange : theme.accent)
                                .frame(width: proxy.size.width * min(1, max(0, window.usedPercent / 100)))
                        }
                    }
                    .frame(width: 120, height: 5)
                    Text(Self.caption(window))
                }
                .font(.ui(size: 11))
                .foregroundStyle(theme.secondaryText)
            }
        }
        .padding(.top, 2)
    }

    static func caption(_ window: UsageWindow) -> String {
        var text = "\(Int(window.usedPercent.rounded())) % used"
        if let reset = window.resetsAt, reset > Date() {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            text += ", resets \(formatter.localizedString(for: reset, relativeTo: Date()))"
        }
        return text
    }
}

struct SavedPromptsSettings: View {
    let model: AssistantModel
    @State private var editing: SavedPrompt?
    @State private var creating = false
    @Environment(\.themeTokens) private var theme

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.prompts.enumerated()), id: \.element.id) { index, prompt in
                if index > 0 { SettingsHairline() }
                HStack(spacing: 12) {
                    Image(symbol: "text.bubble").frame(width: 20).foregroundStyle(theme.secondaryText)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(prompt.label).font(.ui(size: 13)).foregroundStyle(theme.text.opacity(0.88))
                        Text(prompt.prompt).font(.ui(size: 12)).foregroundStyle(theme.secondaryText).lineLimit(1)
                    }
                    Spacer()
                    Button("Edit") { editing = prompt }.buttonStyle(.plain).foregroundStyle(theme.accent)
                    Button {
                        try? model.engine.prompts.delete(prompt.id)
                        model.refreshPrompts()
                    } label: {
                        Image(symbol: "trash")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.secondaryText)
                    .help("Delete")
                }
                .font(.ui(size: 13))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .frame(minHeight: 40)
            }
            if !model.prompts.isEmpty { SettingsHairline() }
            Button {
                creating = true
            } label: {
                HStack(spacing: 8) {
                    Image(symbol: "plus.square")
                    Text("Add Prompt")
                }
                .font(.ui(size: 13))
                .foregroundStyle(theme.accent)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.prompts.count >= PromptStore.maxPrompts)
        }
        .onAppear { model.refreshPrompts() }
        .sheet(isPresented: $creating) {
            PromptEditor(title: "", prompt: "") { title, prompt in
                try model.engine.prompts.save(title: title, prompt: prompt)
                model.refreshPrompts()
            }
        }
        .sheet(item: $editing) { prompt in
            PromptEditor(title: prompt.title, prompt: prompt.prompt, isNew: false) { title, text in
                try model.engine.prompts.save(title: title, prompt: text, id: prompt.id)
                model.refreshPrompts()
            }
        }
    }
}

/// Craft's "Create Custom Prompt": a title (optional), the prompt, Create.
private struct PromptEditor: View {
    @State var title: String
    @State var prompt: String
    var isNew = true
    let save: (String, String) throws -> Void
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themeTokens) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(isNew ? "Create Custom Prompt" : "Edit Prompt").font(.ui(size: 13, weight: .semibold))
                Spacer()
                Button { dismiss() } label: { Image(symbol: "xmark.circle.fill").font(.ui(size: 15)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.secondaryText)
                    .keyboardShortcut(.cancelAction)
            }
            Text("Title").font(.ui(size: 12)).foregroundStyle(theme.secondaryText)
            TextField("Optional", text: $title)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $prompt)
                .font(.ui(size: 13))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 120)
                .background(RoundedRectangle(cornerRadius: Corners.r(8)).fill(theme.text.opacity(0.05)))
            HStack {
                Text("\(prompt.count)/\(PromptStore.maxLength)")
                    .font(.ui(size: 11))
                    .foregroundStyle(prompt.count > PromptStore.maxLength ? theme.danger : theme.secondaryText)
                if let error { Text(error).font(.ui(size: 11)).foregroundStyle(theme.danger) }
            }
            Button {
                do {
                    try save(title, prompt)
                    dismiss()
                } catch {
                    self.error = error.localizedDescription
                }
            } label: {
                Text(isNew ? "Create" : "Save").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || prompt.count > PromptStore.maxLength)
        }
        .padding(16)
        .frame(width: 340)
    }
}

/// The user's instructions, `.loam/ai/instructions.md`, added to every chat.
struct InstructionsSettings: View {
    let model: AssistantModel
    @State private var text = ""
    @State private var saved = ""
    @Environment(\.themeTokens) private var theme

    private var url: URL { model.engine.vault.appendingPathComponent(AssistantInstructions.userFile) }

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            TextEditor(text: $text)
                .font(.ui(size: 13))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 90, maxHeight: 160)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("For example: answer in French, keep my notes short, put tasks in today's daily note.")
                            .font(.ui(size: 13))
                            .foregroundStyle(theme.secondaryText)
                            .padding(.top, 1)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
            Button("Save") {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? text.write(to: url, atomically: true, encoding: .utf8)
                saved = text
            }
            .disabled(text == saved)
        }
        .padding(12)
        .onAppear {
            text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            saved = text
        }
    }
}

private struct SettingsHairline: View {
    @Environment(\.themeTokens) private var theme
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle()
            .fill(theme.text.opacity(0.08))
            .frame(height: 1 / max(displayScale, 1))
            .padding(.leading, 14)
    }
}
