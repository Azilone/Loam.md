import AppKit
import PluginKit
import PluginKitUI

/// The app side of Media compression: draws PDFs (the `pdf-rasterizer` service, PDFKit), says what happened in toasts
/// (an image optimized as it arrived, a video shrinking in the background, a failure or a missing tool), and adds the
/// two palette commands: pick a media file to optimize, and optimize every media file of the vault after asking.
public final class SqueezeUIPlugin: UIPlugin {
    public static let manifest = PluginManifest(
        id: "squeeze-ui",
        name: "Media compression in the app",
        version: "0.1.0",
        description: "Optimizes media from the command palette and reads PDFs to shrink them.",
        icon: "rectangle.compress.vertical",
        provides: ["pdf-rasterizer"],
        permissions: ["ui", "vault.read", "vault.write"]
    )

    /// How the vault-wide command asks; tests replace it.
    @MainActor static var confirm: (_ message: String) -> Bool = { message in
        let alert = NSAlert()
        alert.messageText = "Optimize all media in the vault?"
        alert.informativeText = message
        alert.addButton(withTitle: "Optimize")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    public init() {}

    @MainActor public func activateUI(context: PluginContext) throws {
        try context.provide(.pdfRasterizer, PDFKitRasterizer() as PDFRasterizing)

        context.on(MediaOptimized.self) { [weak context] event in
            context?.toasts?.show(SqueezeMessages.optimized(event.path, before: event.before, after: event.after), kind: .success)
        }
        context.on(MediaOptimizationStarted.self) { [weak context] event in
            context?.toasts?.show(SqueezeMessages.started(event.path), isError: false)
        }
        context.on(MediaBatchProgress.self) { [weak context] event in
            if let text = SqueezeMessages.progress(event) { context?.toasts?.show(text, isError: false) }
        }
        context.on(MediaOptimizationFailed.self) { [weak context] event in
            context?.toasts?.show(SqueezeMessages.failed(event), isError: true)
        }

        let actions = Actions(context: context)
        try context.registerCommand(Command(
            id: "squeeze.pick",
            title: "Optimize a media file…",
            summary: "Lists the images, sounds, videos and PDFs of the vault, biggest first, and optimizes the one "
                + "picked: smaller, with its links kept right and the original in .trash/. Opens a popup, so it is "
                + "for the palette; from the command line or an agent use squeeze.optimize with a path."
        ) { _ in
            await actions.pick()
            return ""
        })

        try context.registerCommand(Command(
            id: "squeeze.optimize-all",
            title: "Optimize all media in the vault…",
            summary: "Asks first, then optimizes every image, sound, video and PDF of the vault (outside the excluded "
                + "folders and under the minimum size), one after the other, with a message for each. Opens a "
                + "dialog, so it is for the palette; from the command line or an agent use squeeze.optimize-vault "
                + "with confirm=true."
        ) { _ in
            try await actions.optimizeAll()
        })
    }

    static func symbol(_ kind: AttachmentKind) -> String {
        switch kind {
        case .image: "photo"
        case .audio: "waveform"
        case .video: "film"
        case .pdf, .file: "doc"
        @unknown default: "doc"
        }
    }
}

/// What the two palette commands do. Main-actor, so the commands (which must be `Sendable`) can hold it while the
/// plugin context, which is not, stays on the main actor.
@MainActor
private final class Actions {
    private weak var context: PluginContext?

    init(context: PluginContext) {
        self.context = context
    }

    /// The quick pick of media files, biggest first; picking one optimizes it and says how it went.
    func pick() {
        guard let context, let quickPick = context.quickPick else { return }
        guard let service = context.service(.mediaCompression) else {
            context.toasts?.show("Media compression is not available.", isError: true)
            return
        }
        let files = ((try? service.candidates()) ?? []).sorted { $0.size > $1.size }
        let items = files.map { file in
            QuickPickItem(
                id: file.path, title: SqueezeMessages.name(file.path),
                subtitle: (file.path as NSString).deletingLastPathComponent.isEmpty ? nil : (file.path as NSString).deletingLastPathComponent,
                symbol: SqueezeUIPlugin.symbol(file.kind), detail: SqueezeMessages.bytes(file.size)
            )
        }
        quickPick.show(
            placeholder: files.isEmpty ? "No media files in the vault" : "Optimize a media file",
            items: { query in
                Fuzzy.rank(items, query: query) { $0.title + " " + ($0.subtitle ?? "") }
            },
            choose: { [weak context] item in
                guard let toasts = context?.toasts else { return }
                toasts.show("Optimizing \(item.title)…", isError: false)
                let path = item.id
                Task { @MainActor in
                    do {
                        let result = try await service.optimize(path)
                        toasts.show(SqueezeMessages.single(result), kind: result.outcome == .optimized ? .success : .info)
                    } catch {
                        let text = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                        toasts.show("Could not optimize \(item.title): \(text)", isError: true)
                    }
                }
            }
        )
    }

    /// Asks, then optimizes the whole vault; the answer is the sentence the palette shows.
    func optimizeAll() async throws -> String {
        guard let context, let service = context.service(.mediaCompression) else { throw ServiceOff(service: "Media compression") }
        let files = try service.candidates()
        guard !files.isEmpty else { return SqueezeMessages.batch(MediaBatchReport()) }
        let message = SqueezeMessages.confirmation(
            files: files.count, bytes: files.reduce(0) { $0 + $1.size }, keepsOriginals: service.keepsOriginals
        )
        guard SqueezeUIPlugin.confirm(message) else { return "Cancelled." }
        return SqueezeMessages.batch(await service.optimizeVault())
    }
}

/// The command line and agents get this error when the logic plugin is off.
struct ServiceOff: Error, LocalizedError {
    let service: String
    var errorDescription: String? { "\(service) is turned off." }
}
