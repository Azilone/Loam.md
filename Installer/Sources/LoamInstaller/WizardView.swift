import SwiftUI

/// The wizard's window: the steps, one after the other.
struct WizardView: View {
    @Environment(WizardModel.self) private var wizard

    var body: some View {
        @Bindable var wizard = wizard
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 18) {
                switch wizard.step {
                case .welcome: welcome
                case .destination: destination
                case .vault: vault
                case .installing: installing
                case .done: done
                }
                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer
        }
        .frame(width: 580, height: 470)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Install Loam").font(.title2.weight(.semibold))
                Text("A local-first Markdown notebook, where everything beyond writing is a plugin.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What you get").font(.headline)
            bullet("The app, in /Applications or ~/Applications.")
            bullet("The `loam` command line in ~/.local/bin, for your agents.")
            bullet("A vault folder: plain Markdown files, yours forever.")
            if let problem = wizard.requirementProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var destination: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Where should Loam go?").font(.headline)
            Picker("Destination", selection: $wizard.destination) {
                ForEach(InstallDestination.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.radioGroup)
            Text(wizard.destination.detail).font(.callout).foregroundStyle(.secondary)
            Toggle("Link the `loam` command line into ~/.local/bin", isOn: $wizard.linkCommandLine)
        }
    }

    private var vault: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your vault").font(.headline)
            Text("A vault is a folder of Markdown files. Loam opens it, and your agent can work in it too.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Create a vault folder", isOn: $wizard.createVault)
            if wizard.createVault {
                TextField("Folder", text: $wizard.vaultPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
            }
        }
    }

    private var installing: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let problem = wizard.problem {
                Label(problem, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again") { Task { await wizard.install() } }
            } else {
                ProgressView().controlSize(.small)
                Text("Installing Loam…").font(.headline)
                Text("Loam is quitting if it runs, and the app is copied to \(wizard.destination.title).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Loam is installed", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)
            Text(wizard.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Loam") { wizard.launch() }
                .buttonStyle(.borderedProminent)
        }
    }

    private var footer: some View {
        HStack {
            if wizard.step == .destination || wizard.step == .vault {
                Button("Back") { wizard.goBack() }
            }
            Spacer()
            switch wizard.step {
            case .welcome:
                Button("Continue") { wizard.step = .destination }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(wizard.requirementProblem != nil)
            case .destination:
                Button("Continue") { wizard.step = .vault }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            case .vault:
                Button("Install") { Task { await wizard.install() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            case .installing, .done:
                EmptyView()
            }
        }
        .padding(16)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "checkmark")
                .font(.caption)
                .foregroundStyle(.tint)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
