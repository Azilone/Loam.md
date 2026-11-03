import Foundation
import PluginKit

/// Media compression: every image, sound, video and PDF that arrives in the vault is made smaller by default, as
/// the author's former Obsidian plugin did. Images and sounds are converted before they are written (WebP, mono 64 kbps), so the
/// note's link has the final name; videos (H.264, 1080p at most) and PDFs (JPEG pages, only for a big gain) take
/// longer and are replaced right after, their links rewritten. Provides `media-compression` and the `squeeze.*`
/// commands; the PDF drawing and the messages are `SqueezeUI`.
public final class SqueezePlugin: Plugin {
    public static var manifest: PluginManifest {
        PluginManifest(
            id: "squeeze",
            name: "Media compression",
            version: "0.1.0",
            description: "Makes the pictures, sounds, videos and PDFs you add to notes smaller, with ffmpeg and cwebp.",
            icon: "arrow.down.right.and.arrow.up.left",
            provides: ["media-compression"],
            requires: ["attachments", "note-graph"],
            permissions: ["vault.read", "vault.write", "shell"],
            settings: settingDescriptions
        )
    }

    /// Titles and help for Settings, in the order they are shown.
    static var settingDescriptions: [SettingDescription] {
        let d = SqueezeSettings()
        return [
            SettingDescription("optimizeNewFiles", title: "Optimize new files", help: "Each file dropped or pasted into a note is made smaller as it arrives.", default: .bool(d.optimizeNewFiles)),
            SettingDescription("images", title: "Pictures", help: "PNG, JPEG, TIFF and HEIC become WebP. Animated GIFs are left alone.", default: .bool(d.images)),
            SettingDescription("audio", title: "Sounds", help: "Mono, at a low bit rate.", default: .bool(d.audio)),
            SettingDescription("video", title: "Videos", help: "H.264 MP4, in the background after the drop.", default: .bool(d.video)),
            SettingDescription("pdfs", title: "PDFs as pictures", help: "Pages become JPEG pictures, only when it saves more than 30%. Loses selectable text, links and search.", default: .bool(d.pdfs)),
            SettingDescription("imageQuality", title: "WebP quality", help: "1 to 100; lower is smaller.", default: .number(d.imageQuality)),
            SettingDescription("audioBitrate", title: "Sound bit rate", help: "In kbps.", default: .number(d.audioBitrate)),
            SettingDescription("audioMono", title: "Sounds in mono", help: "", default: .bool(d.audioMono)),
            SettingDescription("videoCRF", title: "Video quality", help: "CRF, 18 to 35; higher is smaller.", default: .number(d.videoCRF)),
            SettingDescription("videoMaxHeight", title: "Video maximum height", help: "In pixels; taller videos are scaled down.", default: .number(d.videoMaxHeight)),
            SettingDescription("pdfDPI", title: "PDF page resolution", help: "In DPI.", default: .number(d.pdfDPI)),
            SettingDescription("pdfQuality", title: "PDF page quality", help: "JPEG quality, 1 to 100.", default: .number(d.pdfQuality)),
            SettingDescription("minimumSizeKB", title: "Minimum size", help: "In KB; smaller files are left alone.", default: .number(d.minimumSizeKB)),
            SettingDescription("keepOriginals", title: "Keep originals", help: "The original goes to the vault's .trash folder when a file is replaced.", default: .bool(d.keepOriginals)),
            SettingDescription("excludedFolders", title: "Excluded folders", help: "Separated by commas, such as Archive, Private/Scans.", default: .string(d.excludedFolders)),
            SettingDescription("ffmpegPath", title: "Path to ffmpeg", help: "Found in ~/.homebrew/bin, /opt/homebrew/bin or /usr/local/bin when empty."),
            SettingDescription("cwebpPath", title: "Path to cwebp", help: "Found like ffmpeg when empty."),
        ]
    }

    public static var requiresTools: [String] { ["ffmpeg"] }
    public static var optionalTools: [String] { ["cwebp"] }

    public required init() {}

    public func activate(context: PluginContext) throws {
        let settings = context.settings
        let locate: (String) -> String? = { [weak context] name in
            context?.service(ServiceKey<ToolLocating>.tools)?.locate(name)?.path
        }
        Self.storeDefaults(settings, locate: locate)
        let compressor = MediaCompressor(
            vault: context.vault,
            settings: { settings.value(default: SqueezeSettings()) },
            attachments: { [weak context] in context?.service(.attachments) },
            rasterizer: { [weak context] in context?.service(.pdfRasterizer) },
            locate: locate,
            announce: { [weak context] event in context?.emit(event) }
        )
        try context.provide(.mediaCompression, compressor as MediaCompressionService)

        context.addAttachmentProcessor(AttachmentProcessor(id: "squeeze.media", kinds: [.image, .audio]) { file in
            await compressor.process(file)
        })
        context.on(AttachmentImported.self) { event in
            guard event.kind == .video || event.kind == .pdf else { return }
            let path = event.path
            Task.detached { await compressor.processImported(path) }
        }

        try context.registerCommand(Command(
            id: "squeeze.optimize",
            title: "Optimize a media file by path",
            summary: "Makes one image, sound, video or PDF of the vault smaller, whatever its size: images to WebP, "
                + "sounds to mono 64 kbps, videos to H.264 at 1080p at most, PDFs to JPEG pages (the text is lost; "
                + "only for a gain over 30%). Replaces the file only when that saves more than 10% (the duration of "
                + "a sound or video must stay the same); the original goes to .trash/ unless the setting says "
                + "otherwise, and the links follow a new extension. Writes to the vault. Argument: path (vault path). "
                + "Returns the outcome, the path, and the sizes before and after.",
            isInPalette: false
        ) { arguments in
            try JSON.string(try await compressor.optimize(try arguments.require("path")))
        })

        try context.registerCommand(Command(
            id: "squeeze.optimize-vault",
            title: "Optimize all media in the vault without asking",
            summary: "Looks at every image, sound, video and PDF of the vault (outside .trash/ and the excluded "
                + "folders, skipping files under the minimum size) and optimizes them one after the other, as "
                + "squeeze.optimize does. It can take a long time. Writes to the vault. Argument: confirm (\"true\" to "
                + "run; without it only the number of files and their size are returned). Returns what it saved.",
            isInPalette: false
        ) { arguments in
            let candidates = try compressor.candidates()
            guard arguments["confirm"] == "true" else {
                return try JSON.string(Preview(files: candidates.count, bytes: candidates.reduce(0) { $0 + $1.size }))
            }
            return try JSON.string(await compressor.optimizeVault())
        })
    }

    private struct Preview: Encodable {
        let files: Int
        let bytes: Int
    }

    /// The form lists what is stored, so the defaults go in once, with the tools found on this Mac. Later runs only
    /// refresh a path that stopped being valid.
    static func storeDefaults(_ settings: PluginSettingsAccess, locate: (String) -> String?) {
        // A sentinel no stored value can equal: a missing key decodes to it.
        var probe = SqueezeSettings()
        probe.ffmpegPath = "\u{0}"
        let stored = settings.value(default: probe)
        var current = stored
        let first = stored.ffmpegPath == "\u{0}"
        if first { current = SqueezeSettings() }
        if first || current.ffmpegPath.isEmpty || !FileManager.default.isExecutableFile(atPath: current.ffmpegPath) {
            current.ffmpegPath = locate("ffmpeg") ?? ""
        }
        if first || current.cwebpPath.isEmpty || !FileManager.default.isExecutableFile(atPath: current.cwebpPath) {
            current.cwebpPath = locate("cwebp") ?? ""
        }
        if first || current != stored { try? settings.update(current) }
    }
}
