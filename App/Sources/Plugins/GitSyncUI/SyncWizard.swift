import AppKit
import GitSyncPlugin
import PluginKitUI
import SwiftUI

/// Setting sync up, one screen at a time: Connect GitHub, authorize Loam there, encrypt or not, done. Each screen
/// says one thing and has one main button; the repository is made on its own, nothing to copy but GitHub's code.
struct SyncWizard: View {
    @Bindable var model: SyncSettingsModel
    @Environment(\.themeTokens) private var theme

    var body: some View {
        VStack(spacing: 0) {
            Dots(current: dot)
                .padding(.bottom, Space.l)
            ZStack {
                page
                    .id(pageID)
                    .transition(Motion.reduceMotion
                        ? .opacity
                        : .asymmetric(insertion: .opacity.combined(with: .offset(x: 24)),
                                      removal: .opacity.combined(with: .offset(x: -24))))
            }
            .frame(maxWidth: .infinity)
            .clipped()
        }
        .padding(.horizontal, Space.xxl)
        .padding(.top, Space.xl)
        .padding(.bottom, Space.xl)
        .frame(maxWidth: .infinity)
    }

    /// Which of the three dots is lit: connect, protect, done.
    private var dot: Int {
        switch model.step {
        case .idle, .signingIn, .needsCode, .manual: return 0
        case .protect: return 1
        case .settingUp, .done: return 2
        }
    }

    private var pageID: String {
        switch model.step {
        case .idle: return "idle"
        case .signingIn: return "signingIn"
        case .protect: return "protect"
        case .settingUp: return "settingUp"
        case .done: return "done"
        case .needsCode: return "needsCode"
        case .manual: return "manual"
        }
    }

    @ViewBuilder private var page: some View {
        switch model.step {
        case .idle: welcome
        case .signingIn(let code): signingIn(code)
        case .protect: protect
        case .settingUp: settingUp
        case .done: done
        case .needsCode(let message): needsCode(message)
        case .manual: manual
        }
    }

    // MARK: - Screens

    private var welcome: some View {
        Screen(symbol: LoamSymbol.github, title: "Sync your notes with GitHub",
               detail: "Loam keeps your notes in a private repository on your GitHub account, the same on every Mac. "
                   + "Free, and nothing to set up by hand.") {
            ErrorLine(error: model.error)
            PrimaryButton(title: "Connect GitHub", action: model.connectGitHub)
            HStack(spacing: Space.l) {
                LinkButton(title: "I have a code from another Mac") { model.go(.needsCode(nil)) }
                LinkButton(title: "Use another server") { model.go(.manual) }
            }
        }
    }

    private func signingIn(_ code: GitHubDeviceCode) -> some View {
        Screen(symbol: "person.badge.key", title: "Authorize Loam on GitHub",
               detail: "GitHub opened in your browser. Paste this code there (it is copied), then click Authorize.") {
            HStack(spacing: Space.m) {
                Text(code.userCode)
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .tracking(2)
                    .foregroundStyle(theme.text)
                    .textSelection(.enabled)
                CopyLink(text: code.userCode, model: model)
            }
            .padding(.horizontal, Space.l)
            .padding(.vertical, Space.s)
            .background(theme.fillSubtle, in: .rect(cornerRadius: Radius.m))
            HStack(spacing: Space.s) {
                ProgressView().controlSize(.small)
                Text("Waiting for GitHub…").font(.ui(.label)).foregroundStyle(theme.secondaryText)
            }
            HStack(spacing: Space.l) {
                LinkButton(title: "Open GitHub again") {
                    if let url = URL(string: code.verificationURL) { NSWorkspace.shared.open(url) }
                }
                LinkButton(title: "Cancel", action: model.cancelSignIn)
            }
        }
    }

    private var protect: some View {
        Screen(symbol: "lock.shield", title: "Encrypt your notes?",
               detail: model.account.map { "Signed in to GitHub as \($0). One last choice." } ?? "One last choice.") {
            HStack(spacing: Space.m) {
                Choice(symbol: "lock", title: "Encrypted", badge: "Recommended",
                       detail: "GitHub only sees scrambled files. Your Macs read them as usual.",
                       selected: model.encrypt) { model.encrypt = true }
                Choice(symbol: "doc.text", title: "Readable", badge: nil,
                       detail: "Readable on github.com, and by any AI agent with git alone.",
                       selected: !model.encrypt) { model.encrypt = false }
            }
            .frame(maxWidth: 440)
            ErrorLine(error: model.error)
            PrimaryButton(title: "Start Syncing", action: model.startSyncing)
        }
    }

    private var settingUp: some View {
        Screen(symbol: "arrow.triangle.2.circlepath", title: "Setting up sync…",
               detail: "Making your private repository and sending your notes. A large vault takes a minute.") {
            ProgressView().controlSize(.regular)
        }
    }

    private var done: some View {
        let repository = model.status.remoteURL.flatMap(ConnectCode.repositoryName) ?? model.suggestedName
        let encrypted = model.status.encryptionKey != nil
        return Screen(symbol: "checkmark.circle.fill", success: true, title: "Your notes are synced",
                      detail: "On GitHub in \(repository), private\(encrypted ? " and encrypted" : ""). Loam syncs on "
                          + "its own, a few seconds after you stop typing.") {
            PrimaryButton(title: "Done") { model.go(.idle) }
        }
    }

    private func needsCode(_ message: String?) -> some View {
        Screen(symbol: "laptopcomputer.and.arrow.down",
               title: message == nil ? "Join from another Mac" : "This vault is encrypted on GitHub",
               detail: "On the Mac that already syncs: Settings > Sync > Another Mac. "
                   + "Paste the code here.") {
            TextField("loam-connect:…", text: $model.pastedCode)
                .textFieldStyle(.roundedBorder)
                .font(.ui(.label))
                .frame(maxWidth: 320)
                .onSubmit(model.joinWithCode)
            ErrorLine(error: model.error)
            PrimaryButton(title: "Join", action: model.joinWithCode)
                .disabled(!model.pastedCode.trimmingCharacters(in: .whitespaces).hasPrefix(ConnectCode.prefix))
            LinkButton(title: "Back") { model.go(.idle) }
        }
    }

    private var manual: some View {
        Screen(symbol: "server.rack", title: "Use another server",
               detail: "Make an empty private repository there, then paste its address.") {
            TextField("https://… or git@…", text: $model.url)
                .textFieldStyle(.roundedBorder)
                .font(.ui(.label))
                .frame(maxWidth: 320)
                .onSubmit(model.setUp)
            Toggle("Encrypt", isOn: $model.encrypt)
                .toggleStyle(.loam)
                .font(.ui(.label))
            ErrorLine(error: model.error)
            if model.isWorking {
                ProgressView().controlSize(.small)
            } else {
                PrimaryButton(title: "Set Up Sync", action: model.setUp).disabled(!model.canSetUp)
            }
            LinkButton(title: "Back") { model.go(.idle) }
        }
    }
}

// MARK: - Parts

/// A screen: its picture, title and one sentence, then what it asks for.
private struct Screen<Content: View>: View {
    let symbol: String
    var success = false
    let title: String
    let detail: String
    @ViewBuilder let content: () -> Content
    @Environment(\.themeTokens) private var theme

    var body: some View {
        let tint = success ? theme.success : theme.accent
        VStack(spacing: Space.m) {
            Image(symbol: symbol)
                .font(.ui(size: 24))
                .foregroundStyle(tint)
                .frame(width: 48, height: 48)
                .background(tint.opacity(0.12), in: Circle())
            VStack(spacing: Space.xs) {
                Text(title).font(.ui(.section)).foregroundStyle(theme.text)
                Text(detail)
                    .font(.ui(.body))
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 380)
            }
            .padding(.bottom, Space.xs)
            content()
        }
        .frame(maxWidth: .infinity)
    }
}

/// The screen's one main button: filled with the accent.
private struct PrimaryButton: View {
    let title: String
    let action: () -> Void
    @Environment(\.themeTokens) private var theme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.ui(.body, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, Space.xl)
                .frame(minWidth: 180, minHeight: 34)
                .background(theme.accent.opacity(isEnabled ? 1 : 0.4), in: .rect(cornerRadius: Radius.s))
                .contentShape(Rectangle())
        }
        .buttonStyle(.press)
        .keyboardShortcut(.defaultAction)
    }
}

private struct LinkButton: View {
    let title: String
    let action: () -> Void
    @Environment(\.themeTokens) private var theme

    var body: some View {
        Button(action: action) {
            Text(title).font(.ui(.label)).foregroundStyle(theme.secondaryText).underline()
        }
        .buttonStyle(.plain)
    }
}

/// One of two options, side by side; the selected one outlined with the accent.
private struct Choice: View {
    let symbol: String
    let title: String
    let badge: String?
    let detail: String
    let selected: Bool
    let action: () -> Void
    @Environment(\.themeTokens) private var theme

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(spacing: Space.s) {
                    Image(symbol: symbol).foregroundStyle(selected ? theme.accent : theme.secondaryText)
                    Text(title).font(.ui(.body, weight: .semibold)).foregroundStyle(theme.text)
                    Spacer(minLength: Space.xs)
                    Image(symbol: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? theme.accent : theme.secondaryText.opacity(0.5))
                }
                if let badge {
                    Text(badge)
                        .font(.ui(.caption, weight: .medium))
                        .foregroundStyle(theme.accent)
                        .padding(.horizontal, Space.s)
                        .padding(.vertical, Space.xxs)
                        .background(theme.accent.opacity(0.12), in: ThemeCapsule())
                }
                Text(detail)
                    .font(.ui(.label))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(Space.m)
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .background(selected ? theme.fillSubtle : .clear, in: .rect(cornerRadius: Radius.m))
            .overlay(RoundedRectangle(cornerRadius: Radius.m)
                .strokeBorder(selected ? theme.accent : theme.text.opacity(0.1), lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.press)
        .animation(Motion.resolved(Motion.Spring.tap.animation), value: selected)
    }
}

/// Where the wizard is: one dot per screen of the main path.
private struct Dots: View {
    let current: Int
    @Environment(\.themeTokens) private var theme

    var body: some View {
        HStack(spacing: Space.xs) {
            ForEach(0..<3) { index in
                ThemeCapsule()
                    .fill(index <= current ? theme.accent : theme.fillStrong)
                    .frame(width: index == current ? 18 : 6, height: 6)
            }
        }
        .animation(Motion.resolved(Motion.Spring.standard.animation), value: current)
        .accessibilityElement()
        .accessibilityLabel("Step \(current + 1) of 3")
    }
}

private struct ErrorLine: View {
    let error: String?
    @Environment(\.themeTokens) private var theme

    var body: some View {
        if let error {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.ui(.label))
                .foregroundStyle(theme.warning)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
    }
}

/// "Copy", then "Copied" for a moment.
private struct CopyLink: View {
    let text: String
    let model: SyncSettingsModel
    @State private var copied = false
    @Environment(\.themeTokens) private var theme

    var body: some View {
        Button {
            model.copyToPasteboard(text)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Image(symbol: copied ? "checkmark" : "doc.on.doc").foregroundStyle(theme.secondaryText)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copied ? "Copied" : "Copy")
    }
}
