import AppKit
import ObsidianImportPlugin
import PluginKitUI
import SwiftUI

/// What the window shows with no vault open: where the notes come from, in one choice. Bringing Obsidian's notes
/// comes first when Obsidian has vaults on this Mac.
struct OnboardingView: View {
    let model: AppModel
    @State private var vaults: [ObsidianVault]?
    @State private var folder = AppModel.defaultVaultFolder
    @Environment(\.themeTokens) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Welcome to Loam")
                    .font(.ui(size: 38, weight: .bold))
                    .kerning(-0.8)
                    .foregroundStyle(theme.text)
                Text("Your notes stay plain Markdown files, in a folder on your Mac.")
                    .font(.ui(size: 15))
                    .foregroundStyle(theme.secondaryText)
            }
            .cascadeIn(index: 0)

            // Drawn once the vaults are known, so the cards cascade in once, in their final places.
            if let vaults {
            VStack(spacing: 10) {
                if let vault = vaults.first {
                    StartCard(
                        symbol: "square.and.arrow.down",
                        title: String(localized: "Bring your Obsidian notes"),
                        detail: vaults.count == 1
                            ? String(localized: "\(vault.name) · \(vault.notes) notes")
                            : String(localized: "\(vault.name) and \(vaults.count - 1) more"),
                        prominent: true
                    ) { model.begin(.importNotes, in: folder) }
                    .cascadeIn(index: 1)
                }
                StartCard(
                    symbol: "square.and.pencil",
                    title: String(localized: "Start fresh"),
                    detail: String(localized: "An empty vault, ready for your first note."),
                    prominent: vaults.isEmpty
                ) { model.begin(.fresh, in: folder) }
                .cascadeIn(index: 2)
            }
            }

            HStack(spacing: 6) {
                Image(symbol: "folder")
                Text(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Change…") { if let url = model.chooseNewVaultFolder() { folder = url } }
                    .buttonStyle(.link)
                Spacer(minLength: 16)
                Button("Open an Existing Vault…") { model.chooseVault() }
                    .buttonStyle(.link)
            }
            .font(.ui(size: 13))
            .foregroundStyle(theme.secondaryText)
            .cascadeIn(index: 3)
        }
        .frame(maxWidth: 560)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
        // Obsidian's list is a small file, but counting the notes reads every folder: off the main thread.
        .task { vaults = await Task.detached { ObsidianVaults.find() }.value }
    }
}

/// One way to start: a large card with an icon, a title and a line.
private struct StartCard: View {
    let symbol: String
    let title: String
    let detail: String
    let prominent: Bool
    let action: () -> Void
    @Environment(\.themeTokens) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(symbol: symbol)
                    .font(.ui(size: 20, weight: .medium))
                    .foregroundStyle(prominent ? theme.accent : theme.secondaryText)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.ui(size: 17, weight: .semibold)).foregroundStyle(theme.text)
                    Text(detail).font(.ui(size: 13)).foregroundStyle(theme.secondaryText)
                }
                Spacer(minLength: 0)
                Image(symbol: "arrow.right").foregroundStyle(theme.secondaryText)
            }
            .padding(20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .interactiveNoteCard()
    }
}
