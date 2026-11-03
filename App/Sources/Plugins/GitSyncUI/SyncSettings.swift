import AppKit
import GitSyncPlugin
import Observation
import PluginKitUI
import SwiftUI

/// What Settings > Git sync shows and does. Not set up: a wizard, one screen at a time (Connect GitHub, sign in,
/// encrypt or not, done), the vault's private repository made on its own; or a code from another Mac. Set up: its
/// state, Sync Now, the automatic switch, and the agents with access, with the one line that connects a new one.
@MainActor
@Observable
final class SyncSettingsModel {
    enum Step: Equatable {
        /// The wizard's first screen, or the synced rows once set up.
        case idle
        /// GitHub shows `code` to type on its page, opened in the browser.
        case signingIn(GitHubDeviceCode)
        /// Signed in: encrypt the new repository or not.
        case protect
        case settingUp
        /// Set up: what was made, until Done.
        case done
        /// A code from another Mac: the vault's repository is encrypted (`message` says so), or the user has one.
        case needsCode(String?)
        /// Another git server: the address typed by hand.
        case manual
    }

    private(set) var status: SyncStatus
    private(set) var step = Step.idle
    private(set) var account: String?
    private(set) var agents: [String] = []
    /// The agent whose prompt (`AgentBrief`) was just copied; and for another Mac, its code.
    private(set) var copiedAgent: String?
    private(set) var deviceCode: String?
    var pastedCode = ""
    /// The manual form (Advanced): another repository's address.
    var url = ""
    /// Encrypt the new repository: GitHub then reads nothing, and agents need Loam to read the notes.
    var encrypt = true
    private(set) var isWorking = false
    /// Why the last action failed, in one sentence.
    private(set) var error: String?
    let inICloud: Bool
    @ObservationIgnored private let service: GitSyncService
    @ObservationIgnored private var signIn: Task<Void, Never>?
    /// Agents added or removed here: GitHub lists a new deploy key a few seconds late.
    @ObservationIgnored private var added: Set<String> = []
    @ObservationIgnored private var removed: Set<String> = []

    init(service: GitSyncService, root: URL) {
        self.service = service
        status = service.status
        inICloud = root.path.contains("/Library/Mobile Documents/")
        let folder = root.lastPathComponent.map { $0.isLetter || $0.isNumber || "-_.".contains($0) ? $0 : "-" }
        suggestedName = "loam-" + String(folder)
    }

    /// The first sync could not push or fetch for want of credentials, or a sign-in made before Loam asked GitHub
    /// for the `workflow` permission (the encrypted vault's check).
    static func refusedAccess(_ status: SyncStatus) -> Bool {
        guard status.state == .attention, let message = status.message?.lowercased() else { return false }
        return ["refused", "credentials", "authentication", "could not read username", "permission denied",
                "`workflow` scope"]
            .contains { message.contains($0) }
    }

    /// The vault is a git repository with a remote.
    var isSetUp: Bool { status.remoteURL != nil }
    var isOnGitHub: Bool { status.remoteURL?.contains("github.com") == true }
    var canSetUp: Bool { !isWorking && Self.looksLikeAddress(url) }
    /// The vault is encrypted and this Mac lacks the key: a code from another Mac brings it.
    var needsKey: Bool { status.message?.contains("does not have the vault's key") == true }

    func refresh() {
        Task {
            status = await service.report()
            account = await service.gitHubAccount()
            if isSetUp, isOnGitHub, account != nil {
                let listed = Set((try? await service.connectedAgents()) ?? [])
                agents = listed.union(added).subtracting(removed).sorted()
            }
        }
    }

    func update(_ status: SyncStatus) {
        // The live status lacks what only `report` reads (the remote's address): keep it.
        var status = status
        if status.remoteURL == nil { status.remoteURL = self.status.remoteURL }
        self.status = status
    }

    // MARK: - Connect GitHub

    /// git could not reach the repository with this Mac's credentials: signing in to GitHub gives it some.
    private(set) var needsSignIn = false
    /// The repository name GitHub's page is filled with: `loam-` and the vault's folder.
    let suggestedName: String

    /// The wizard's first button: signs in to GitHub unless signed in already, then asks about encryption.
    func connectGitHub() {
        guard account == nil else {
            go(.protect)
            return
        }
        signInThen { self.go(.protect) }
    }

    /// The wizard's last button: the vault syncs with its private repository on GitHub, made if new.
    func startSyncing() {
        error = nil
        go(.settingUp)
        Task {
            do {
                finish(try await service.setUpWithGitHub(encrypt: encrypt))
            } catch let needed as ConnectError where needed.message.contains("paste the code") {
                go(.needsCode(needed.message))
            } catch {
                self.error = error.localizedDescription
                go(.protect)
            }
            refresh()
        }
    }

    /// Done only once the notes reached GitHub. Refused (no access, or a sign-in older than the `workflow`
    /// permission): signs in again, then syncs once more. Another problem: said on the encryption screen.
    private func finish(_ status: SyncStatus, signedInAgain: Bool = false) {
        guard status.state == .attention else {
            go(.done)
            return
        }
        if Self.refusedAccess(status), !signedInAgain {
            signInThen {
                self.go(.settingUp)
                Task { self.finish(await self.service.syncNow(), signedInAgain: true) }
            }
            return
        }
        error = status.message
        go(.protect)
    }

    /// Signs in to GitHub (only when git has no credentials for it), then syncs again.
    func signInAndRetry() {
        signInThen {
            self.go(.idle)
            if self.isSetUp {
                self.service.requestSync()
            } else if Self.looksLikeAddress(self.url) {
                self.setUp()
            }
        }
    }

    /// GitHub's device flow: its code copied and its page opened; `then` once the user authorized Loam there.
    private func signInThen(_ then: @escaping @MainActor () -> Void) {
        error = nil
        signIn?.cancel()
        signIn = Task {
            do {
                let code = try await service.startGitHubSignIn()
                go(.signingIn(code))
                copyToPasteboard(code.userCode)
                if let url = URL(string: code.verificationURL) { NSWorkspace.shared.open(url) }
                try await service.finishGitHubSignIn(code)
                account = await service.gitHubAccount()
                needsSignIn = false
                then()
            } catch is CancellationError {
                go(.idle)
            } catch {
                self.error = error.localizedDescription
                go(.idle)
            }
        }
    }

    func cancelSignIn() {
        signIn?.cancel()
        go(.idle)
    }

    /// Moves the wizard to `step`, with its slide (a fade under Reduce Motion).
    func go(_ step: Step) {
        withAnimation(Motion.resolved(Motion.Spring.standard.animation)) { self.step = step }
    }

    func joinWithCode() {
        let code = pastedCode
        let asked = step
        error = nil
        go(.settingUp)
        Task {
            do {
                _ = try await service.join(code, maxChanges: nil)
                pastedCode = ""
                go(.done)
            } catch {
                self.error = error.localizedDescription
                go(asked)
            }
            refresh()
        }
    }

    // MARK: - Agents and devices

    /// Makes an agent's access and copies the one prompt that tells it everything: how to connect, sync and work.
    /// Named `agent`, `agent-2`…: the user never has to pick a name.
    func copyAgentPrompt() {
        guard account != nil else {
            signInThen {
                self.go(.idle)
                self.copyAgentPrompt()
            }
            return
        }
        let taken = Set(agents)
        let name = (["agent"] + (2...99).map { "agent-\($0)" }).first { !taken.contains($0) } ?? "agent-\(UUID().uuidString.prefix(4))"
        run {
            let access = try await self.service.agentAccess(for: name)
            self.copyToPasteboard(access.brief)
            self.deviceCode = nil
            self.copiedAgent = ConnectCode.deviceName(name)
            self.added.insert(ConnectCode.deviceName(name))
            self.removed.remove(ConnectCode.deviceName(name))
        }
    }

    /// The code another Mac pastes, shown and copied.
    func showMacCode() {
        run {
            let code = try await self.service.connectCode(for: "Mac", agent: false)
            self.copyToPasteboard(code)
            self.copiedAgent = nil
            self.deviceCode = code
        }
    }

    func removeAgent(_ name: String) {
        run {
            _ = try await self.service.removeAgent(name)
            self.removed.insert(name)
            self.added.remove(name)
            if self.copiedAgent == name { self.copiedAgent = nil }
        }
    }

    // MARK: - Setting up

    func setUp() {
        guard canSetUp else { return }
        run {
            let status = try await self.service.setUp(url: self.url, device: nil, encrypt: self.encrypt)
            self.needsSignIn = Self.refusedAccess(status)
            if !self.needsSignIn { self.go(.done) }
        }
    }

    func syncNow() {
        service.requestSync()
    }

    func setAutomatic(_ on: Bool) {
        run { try await self.service.setAutomatic(on) }
    }

    /// Stops syncing with this repository, to set up another one; the vault keeps its files and history.
    func disconnect() {
        run {
            _ = try await self.service.disconnect()
            self.copiedAgent = nil
            self.deviceCode = nil
            self.agents = []
        }
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func run(_ body: @escaping @MainActor () async throws -> Void) {
        isWorking = true
        error = nil
        Task {
            do { try await body() } catch { self.error = error.localizedDescription }
            isWorking = false
            refresh()
        }
    }

    /// `https://…`, `git@host:…`, `ssh://…` or `file://…`: enough to try.
    static func looksLikeAddress(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["https://", "http://", "ssh://", "git@", "file://"].contains { text.hasPrefix($0) } && text.count > 10
    }
}

/// The section on the Git sync page in Settings: the wizard until the vault syncs, then where it stands and the two
/// ways to connect something else (another Mac, an AI agent), each one click.
struct SyncSettingsView: View {
    @Bindable var model: SyncSettingsModel
    @Environment(\.themeTokens) private var theme

    var body: some View {
        VStack(spacing: 0) {
            if !model.isSetUp || model.step != .idle {
                SyncWizard(model: model)
            } else {
                synced
            }
        }
        .onAppear { model.refresh() }
    }

    // MARK: - Synced

    private var synced: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            statusCard
            VStack(alignment: .leading, spacing: Space.s) {
                Text("Connect").themeLabel(size: 11)
                HStack(spacing: Space.m) {
                    Tile(symbol: "laptopcomputer", title: "Another Mac", detail: "Show a code to paste on it",
                         selected: model.deviceCode != nil, action: model.showMacCode)
                    Tile(symbol: "sparkles", title: "An AI agent", detail: "Copy a prompt that sets it up",
                         selected: model.copiedAgent != nil, action: model.copyAgentPrompt)
                }
                if let code = model.deviceCode {
                    Note(symbol: "doc.on.clipboard",
                         text: "Code copied. On the other Mac: Settings > Sync > I have a code from another Mac.") {
                        Text(code.prefix(28) + "…")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(theme.secondaryText)
                    }
                } else if let agent = model.copiedAgent {
                    Note(symbol: "checkmark.circle.fill",
                         text: "Prompt copied for \(agent). Paste it into your agent: it connects, syncs and knows "
                            + "how to work in your notes.") { EmptyView() }
                }
            }
            if !model.agents.isEmpty {
                VStack(alignment: .leading, spacing: Space.s) {
                    Text("Agents").themeLabel(size: 11)
                    VStack(spacing: 0) {
                        ForEach(Array(model.agents.enumerated()), id: \.element) { index, agent in
                            if index > 0 { Hairline() }
                            Row(symbol: "sparkles", title: agent, detail: nil, detailColor: nil) {
                                Action(title: "Remove") { model.removeAgent(agent) }
                            }
                        }
                    }
                    .background(theme.fillSubtle, in: .rect(cornerRadius: Radius.m))
                }
            }
            HStack(spacing: Space.l) {
                let on = model.status.state != .off
                FooterLink(title: on ? "Pause sync" : "Resume sync") { model.setAutomatic(!on) }
                FooterLink(title: "Disconnect", action: model.disconnect)
                Spacer()
            }
        }
        .padding(Space.l)
    }

    private var statusCard: some View {
        let status = model.status
        let problem = status.state == .attention
        return VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.m) {
                Image(symbol: symbol(status))
                    .font(.ui(size: 20))
                    .foregroundStyle(problem ? theme.warning : theme.success)
                    .frame(width: 40, height: 40)
                    .background((problem ? theme.warning : theme.success).opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(status.label).font(.ui(.emphasis)).foregroundStyle(theme.text)
                    Text(subtitle(status)).font(.ui(.label)).foregroundStyle(theme.secondaryText)
                }
                Spacer(minLength: Space.s)
                if model.isWorking || status.state == .syncing {
                    ProgressView().controlSize(.small)
                } else {
                    Action(title: "Sync Now", action: model.syncNow)
                }
            }
            if model.needsSignIn || SyncSettingsModel.refusedAccess(status) {
                Fix(text: "GitHub needs you to sign in again.", button: "Sign In", action: model.signInAndRetry)
            } else if model.needsKey {
                Fix(text: "This Mac needs the vault's key: paste a code from a Mac that syncs it.", button: nil) {}
                codeField
            } else if problem, let message = status.message {
                Text(message)
                    .font(.ui(.label))
                    .foregroundStyle(theme.warning)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .help(message)
            } else if !status.conflicts.isEmpty {
                Text("A note changed on two devices: its other version is saved next to it. Keep what you want, delete the copy.")
                    .font(.ui(.label)).foregroundStyle(theme.secondaryText)
            }
            if let error = model.error {
                Text(error).font(.ui(.label)).foregroundStyle(theme.warning).textSelection(.enabled)
            }
        }
        .padding(Space.l)
        .background(theme.fillSubtle, in: .rect(cornerRadius: Radius.l))
    }

    private var codeField: some View {
        HStack(spacing: Space.s) {
            TextField("loam-connect:…", text: $model.pastedCode)
                .textFieldStyle(.roundedBorder)
                .font(.ui(.label))
                .onSubmit(model.joinWithCode)
            Action(title: "Join", action: model.joinWithCode)
                .disabled(!model.pastedCode.trimmingCharacters(in: .whitespaces).hasPrefix(ConnectCode.prefix))
        }
    }

    /// The repository, encrypted or not, and when it last synced: "Azilone/loam-vault · encrypted · 2 min ago".
    private func subtitle(_ status: SyncStatus) -> String {
        var parts = [status.remoteURL.flatMap(ConnectCode.repositoryName) ?? status.remoteURL ?? ""]
        if status.encryptionKey != nil { parts.append("encrypted") }
        if status.state == .off {
            parts.append("paused")
        } else if let last = status.lastSync {
            parts.append(last.formatted(.relative(presentation: .named)))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func symbol(_ status: SyncStatus) -> String {
        switch status.state {
        case .attention: return "exclamationmark.triangle"
        case .offline: return "wifi.slash"
        case .off: return "pause.circle"
        default: return status.conflicts.isEmpty ? "checkmark" : "doc.on.doc"
        }
    }
}

// MARK: - Parts

/// One way to connect something: a picture, a name, what a click does.
private struct Tile: View {
    let symbol: String
    let title: String
    let detail: String
    let selected: Bool
    let action: () -> Void
    @Environment(\.themeTokens) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.m) {
                Image(symbol: symbol)
                    .font(.ui(size: 16))
                    .foregroundStyle(theme.accent)
                    .frame(width: 32, height: 32)
                    .background(theme.accent.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(title).font(.ui(.body, weight: .semibold)).foregroundStyle(theme.text)
                    Text(detail).font(.ui(.label)).foregroundStyle(theme.secondaryText)
                }
                Spacer(minLength: 0)
            }
            .padding(Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? theme.fillStrong : theme.fillSubtle, in: .rect(cornerRadius: Radius.m))
            .contentShape(Rectangle())
            .hoverFill(in: RoundedRectangle(cornerRadius: Radius.m))
        }
        .buttonStyle(.press)
    }
}

/// What a tile did, under the tiles.
private struct Note<Trailing: View>: View {
    let symbol: String
    let text: String
    @ViewBuilder let trailing: () -> Trailing
    @Environment(\.themeTokens) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Image(symbol: symbol).foregroundStyle(theme.success)
            Text(text).font(.ui(.label)).foregroundStyle(theme.text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Space.s)
            trailing()
        }
        .padding(.horizontal, Space.xs)
        .transition(.opacity)
    }
}

/// A problem and the one button that fixes it.
private struct Fix: View {
    let text: String
    let button: String?
    let action: () -> Void
    @Environment(\.themeTokens) private var theme

    var body: some View {
        HStack(spacing: Space.s) {
            Text(text).font(.ui(.label)).foregroundStyle(theme.warning)
            Spacer(minLength: Space.s)
            if let button { Action(title: button, action: action) }
        }
    }
}

private struct FooterLink: View {
    let title: String
    let action: () -> Void
    @Environment(\.themeTokens) private var theme

    var body: some View {
        Button(action: action) {
            Text(title).font(.ui(.label)).foregroundStyle(theme.secondaryText)
        }
        .buttonStyle(.plain)
    }
}

private struct Row<Trailing: View>: View {
    let symbol: String
    let title: String
    let detail: String?
    let detailColor: Color?
    @ViewBuilder let trailing: () -> Trailing
    @Environment(\.themeTokens) private var theme

    var body: some View {
        HStack(spacing: Space.m) {
            Image(symbol: symbol).frame(width: 20).foregroundStyle(theme.secondaryText)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title).font(.ui(.body)).foregroundStyle(theme.text)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.ui(.label))
                        .foregroundStyle(detailColor ?? theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Space.s)
            trailing()
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .frame(minHeight: 40)
    }
}

private struct Action: View {
    let title: String
    let action: () -> Void
    @Environment(\.themeTokens) private var theme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.ui(.body, weight: .medium))
                .foregroundStyle(isEnabled ? theme.accent : theme.secondaryText.opacity(0.6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct Hairline: View {
    @Environment(\.themeTokens) private var theme
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle()
            .fill(theme.separator)
            .frame(height: 1 / max(displayScale, 1))
            .padding(.leading, Space.m)
    }
}
