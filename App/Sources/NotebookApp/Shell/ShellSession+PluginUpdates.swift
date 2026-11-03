import Foundation
import PluginKitUI
import LoamCore

/// One row of `plugins.outdated`: a vault plugin, the version it runs and the newest one its source has.
public struct PluginUpdateInfo: Decodable, Equatable, Sendable {
    public let id: String
    public let installed: String
    public let latest: String?
    public let kind: String
    public let source: String
    public let updateAvailable: Bool
    public let needsApp: String?
    public let autoUpdate: Bool
    public let error: String?
}

/// The daily check of the vault's plugins (docs/UPDATES.md): a minute after the vault opens, then every day, the app
/// asks each plugin's source for a newer version. Plugins set to update automatically are updated when they ask for no
/// new permission; for the others a toast says updates wait in Settings > Plugins. Nothing runs in safe mode.
extension ShellSession {
    static let pluginUpdateInterval: Duration = .seconds(24 * 60 * 60)
    static let firstPluginUpdateDelay: Duration = .seconds(60)

    public func startPluginUpdateChecks() {
        guard pluginUpdateTask == nil, !isSafeMode,
              runtime.kernel.commands.command(id: "plugins.outdated") != nil else { return }
        pluginUpdateTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.firstPluginUpdateDelay)
            while !Task.isCancelled {
                await self?.checkPluginUpdates(announce: true)
                try? await Task.sleep(for: Self.pluginUpdateInterval)
            }
        }
    }

    /// Runs `plugins.outdated`, applies the automatic updates, and keeps the rows for Settings. Returns them.
    @discardableResult
    public func checkPluginUpdates(announce: Bool) async -> [PluginUpdateInfo] {
        guard let json = try? await run("plugins.outdated"),
              let rows = try? JSONDecoder().decode([PluginUpdateInfo].self, from: Data(json.utf8)) else { return pluginUpdates }
        var updated: [String] = []
        for row in rows where row.autoUpdate && row.updateAvailable && row.needsApp == nil {
            guard let json = try? await run("plugins.update", ["id": row.id, "same-permissions": "true"]),
                  let result = try? JSONDecoder().decode(UpdateOutcome.self, from: Data(json.utf8)),
                  result.updated else { continue }
            updated.append(row.id)
        }
        let waiting = rows.filter { $0.updateAvailable && $0.needsApp == nil && !updated.contains($0.id) }
        pluginUpdates = rows.map { row in
            guard updated.contains(row.id) else { return row }
            return PluginUpdateInfo(id: row.id, installed: row.latest ?? row.installed, latest: row.latest, kind: row.kind,
                                    source: row.source, updateAvailable: false, needsApp: nil, autoUpdate: true, error: nil)
        }
        guard announce, let toasts = runtime.kernel.services.service(.toasts) else { return pluginUpdates }
        if !updated.isEmpty {
            toasts.show(String(localized: "Updated \(updated.joined(separator: ", ")). Relaunch to use the new version."),
                        kind: .success)
        } else if !waiting.isEmpty {
            toasts.show(waiting.count == 1
                ? String(localized: "An update for \(waiting[0].id) is ready in Settings > Plugins.")
                : String(localized: "\(waiting.count) plugin updates are ready in Settings > Plugins."), kind: .info)
        }
        return pluginUpdates
    }

    private struct UpdateOutcome: Decodable {
        let updated: Bool
    }
}
