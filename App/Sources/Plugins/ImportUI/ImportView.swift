import AppKit
import ObsidianImportPlugin
import PluginKitUI
import SwiftUI

/// The import page: one screen per step, each sliding in over the last.
struct ImportView: View {
    let model: ImportModel
    @Environment(\.themeTokens) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                content
                    .id(stepKey)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: 16)),
                        removal: .opacity
                    ))
            }
            .pageColumn(.reading)
            .padding(.bottom, Space.xxxl)
        }
        .background(theme.background)
        .motion(Motion.Spring.smooth, value: stepKey)
        .task { await model.load() }
    }

    private var stepKey: String {
        switch model.step {
        case .choose: "choose"
        case .importing, .finishing: "working"
        case .done: "done"
        case .failed: "failed"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .choose: choose
        case .importing(let vault, let progress):
            working(String(localized: "Importing \(vault.name)…"), detail: progress.total > 0 ? "\(progress.done) / \(progress.total)" : nil)
        case .finishing(_, _, let status): working(String(localized: "Finishing with \(model.agent?.name ?? "")…"), detail: status)
        case .done(let vault, let report, _): done(vault, report)
        case .failed(let message, _): failed(message)
        }
    }

    // MARK: Steps

    @ViewBuilder
    private var choose: some View {
        ImportHeader(
            title: "Bring your notes from any app",
            subtitle: "Notion, Obsidian, Roam, Craft, Bear, Evernote… Your agent moves them into a new vault. "
                + "The originals stay untouched."
        )
        VStack(alignment: .leading, spacing: Space.m) {
            ImportStep(number: 1, text: "Copy the prompt.")
            ImportStep(number: 2, text: "Paste it into your agent: Claude Code, Codex, Cursor…")
            ImportStep(number: 3, text: "Answer its three questions. It does the rest, then opens the new vault here.")
        }
        PromptCard(prompt: model.migrationPrompt)
    }

    @ViewBuilder
    private func working(_ title: String, detail: String?) -> some View {
        HStack(spacing: 14) {
            ProgressView().controlSize(.small)
            Text(title).font(.ui(.section)).foregroundStyle(theme.text)
        }
        if let detail {
            Text(detail)
                .font(.ui(size: 13))
                .foregroundStyle(theme.secondaryText)
                .contentTransition(.opacity)
                .animation(Motion.crossfade, value: detail)
        }
    }

    @ViewBuilder
    private func done(_ vault: ObsidianVault, _ report: ImportReport) -> some View {
        Image(symbol: "checkmark.circle.fill")
            .font(.ui(size: 44))
            .foregroundStyle(theme.accent)
            .symbolEffect(.bounce, value: stepKey)
        ImportHeader(
            title: String(localized: "\(report.converted) notes imported"),
            subtitle: String(localized: "They are in \(ImportModel.destination(of: vault)). The report lists what to check.")
        )
        Button("Open the Report") { model.openReport() }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
    }

    @ViewBuilder
    private func failed(_ message: String) -> some View {
        ImportHeader(title: "The import stopped", subtitle: message)
        Button("Back") { model.back() }
    }
}

// MARK: Pieces

private struct ImportHeader: View {
    let title: String
    let subtitle: String
    @Environment(\.themeTokens) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            PageHeader(title)
            Text(subtitle.uiLocalized)
                .font(.ui(.emphasis, weight: .regular))
                .foregroundStyle(theme.secondaryText)
        }
    }
}

/// One numbered line of the three it takes.
private struct ImportStep: View {
    let number: Int
    let text: String
    @Environment(\.themeTokens) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            Text(number, format: .number)
                .font(.ui(.body, weight: .semibold))
                .foregroundStyle(theme.secondaryText)
                .frame(width: 22, height: 22)
                .background(Circle().fill(theme.secondaryText.opacity(0.12)))
            Text(text.uiLocalized)
                .font(.ui(.emphasis, weight: .regular))
                .foregroundStyle(theme.text)
        }
    }
}

/// The prompt as it will be pasted, and the button that copies it.
private struct PromptCard: View {
    let prompt: String
    @State private var copied = false
    @Environment(\.themeTokens) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            Text(prompt)
                .font(.system(size: UIType.body.size, design: .monospaced))
                .foregroundStyle(theme.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(prompt, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy Prompt", symbol: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.l)
        .noteCard()
    }
}
