import AppKit
import AttachmentsPlugin
import PluginKitUI
import SwiftUI

/// Files in the editor: a file dropped on a note or pasted into it (a screenshot from the clipboard) goes into the
/// attachments folder through the `attachments` service, and its link goes where it was dropped. Image links alone on
/// their line show what they point to: pictures (animated GIFs play), videos and sounds in the system's player, PDFs
/// as Craft's card with the first page. Without an editor the plugin does nothing; without the service, notes still
/// show their media but take no files.
public final class AttachmentsUIPlugin: UIPlugin {
    public static let manifest = PluginManifest(
        id: "attachments-ui",
        name: "Attachments in notes",
        version: "0.1.0",
        description: "Drop or paste files into a note, and see pictures, videos, sounds and PDFs in place.",
        icon: "photo.on.rectangle",
        optionalRequires: ["editor", "attachments"],
        permissions: ["ui", "vault.read", "vault.write", "clipboard"]
    )

    static let images = ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp"]
    static let videos = ["mp4", "mov", "m4v"]
    static let sounds = ["mp3", "m4a", "wav", "aac", "flac", "aif", "aiff", "caf"]

    public init() {}

    @MainActor public func activateUI(context: PluginContext) throws {
        guard context.editor != nil else { return }
        if context.service(.attachments) != nil {
            let vault = context.vault.rootURL
            context.addFileDropHandler(FileDropHandler(id: "attachments.import") { [weak context] drop in
                guard let attachments = context?.service(.attachments) else { return nil }
                return await Self.importDropped(drop, into: attachments, vault: vault)
            })
        }
        context.addEmbedRenderer(EmbedRenderer(id: "attachments.image", extensions: Self.images) { request in
            await Self.picture(request)
        })
        context.addEmbedRenderer(EmbedRenderer(id: "attachments.video", extensions: Self.videos) { request in
            await Self.video(request)
        })
        context.addEmbedRenderer(EmbedRenderer(id: "attachments.audio", extensions: Self.sounds) { request in
            await Self.sound(request)
        })
        context.addEmbedRenderer(EmbedRenderer(id: "attachments.pdf", extensions: ["pdf"]) { request in
            await Self.pdf(request)
        })
    }

    // MARK: Drops and pastes

    /// Imports each dropped file (a pasted picture gets a name from the moment) and returns their links, one per line;
    /// nil when none could be imported. A file already in the vault is linked where it is, not copied again. Folders
    /// are left out.
    @MainActor
    static func importDropped(_ drop: DroppedFiles, into attachments: AttachmentsService, vault: URL, now: Date = Date()) async -> String? {
        let root = vault.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        var links: [String] = []
        for item in drop.items {
            let file: AttachmentImport
            switch item {
            case .file(let url):
                var isFolder: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue else { continue }
                let path = url.resolvingSymlinksInPath().standardizedFileURL.path
                if path.hasPrefix(root) {
                    links.append(attachments.markdownLink(to: String(path.dropFirst(root.count)), from: drop.notePath))
                    continue
                }
                file = AttachmentImport(name: url.lastPathComponent, contents: .file(url), notePath: drop.notePath)
            case .data(let data, let ext):
                file = AttachmentImport(name: AttachmentNames.pasted(extension: ext, at: now), contents: .data(data), notePath: drop.notePath)
            }
            if let imported = try? await attachments.importFile(file) { links.append(imported.markdown) }
        }
        if links.isEmpty, !drop.items.isEmpty { NSSound.beep() } else if !links.isEmpty { Sounds.play(.attached) }
        return links.isEmpty ? nil : links.joined(separator: "\n")
    }

    // MARK: Embeds

    /// A still picture, drawn by the editor; an animated one plays in an image view.
    @MainActor
    static func picture(_ request: EmbedRequest) async -> RenderedEmbed? {
        let url = request.file
        guard let picture = await Task.detached(operation: { MediaLoader.picture(at: url) }).value else { return nil }
        if picture.frames > 1 {
            return RenderedEmbed(size: picture.size, isInteractive: false) { AnyView(AnimatedPicture(url: url)) }
        }
        return RenderedEmbed(image: picture.image, size: picture.size)
    }

    @MainActor
    static func video(_ request: EmbedRequest) async -> RenderedEmbed? {
        guard let size = await MediaLoader.videoSize(at: request.file) else { return nil }
        let url = request.file
        return RenderedEmbed(size: size) { AnyView(PlayerView(url: url)) }
    }

    @MainActor
    static func sound(_ request: EmbedRequest) async -> RenderedEmbed? {
        guard await MediaLoader.hasAudio(at: request.file) else { return nil }
        let url = request.file
        let name = url.lastPathComponent
        let size = MediaLoader.formattedSize(of: url)
        return RenderedEmbed(size: CGSize(width: 10_000, height: AudioCard.height), keepsHeight: true) {
            AnyView(AudioCard(url: url, name: name, size: size))
        }
    }

    @MainActor
    static func pdf(_ request: EmbedRequest) async -> RenderedEmbed? {
        let url = request.file
        guard let thumbnail = await Task.detached(operation: {
            MediaLoader.pdfThumbnail(at: url, maxSize: CGSize(width: 128, height: 108)).map(SendableImage.init)
        }).value else { return nil }
        let name = url.lastPathComponent
        let size = MediaLoader.formattedSize(of: url)
        return RenderedEmbed(size: PDFCard.size, keepsHeight: true, isInteractive: false) {
            AnyView(PDFCard(thumbnail: thumbnail.image, name: name, size: size))
        }
    }
}

/// A picture handed from a background task.
private struct SendableImage: @unchecked Sendable {
    let image: CGImage
}
