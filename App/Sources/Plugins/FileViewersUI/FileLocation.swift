import Foundation
import PluginKitUI
import UniformTypeIdentifiers

/// The file a viewer shows: its place on disk and what to say about it.
struct FileLocation: Equatable {
    let url: URL

    /// The file of a resource in the vault; nil when its path leaves the vault.
    init?(resource: Resource, root: URL) {
        guard resource.kind == .file else { return nil }
        let base = root.standardizedFileURL
        let file = base.appendingPathComponent(resource.path).standardizedFileURL
        guard file.path.hasPrefix(base.path + "/") else { return nil }
        url = file
    }

    var name: String { url.lastPathComponent }
    var ext: String { url.pathExtension.lowercased() }

    /// The SF Symbol shown before the file's details in the page's toolbar.
    var symbol: String {
        if FileKinds.images.contains(ext) { return "photo" }
        if FileKinds.pdf.contains(ext) { return "doc.richtext" }
        if FileKinds.audio.contains(ext) { return "waveform" }
        if FileKinds.video.contains(ext) { return "play.rectangle" }
        return "doc"
    }

    var created: Date? { (try? FileManager.default.attributesOfItem(atPath: url.path))?[.creationDate] as? Date }
    var modified: Date? { (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date }

    /// "PNG image · 58 KB · 1600 × 900": what the page's toolbar says under the name.
    func summary(_ detail: String? = nil) -> String {
        [kindText, sizeText, detail ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }
    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Finder's size, "2 MB"; empty when the file cannot be read.
    var sizeText: String {
        guard let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// "PNG image", "MP3 audio": the system's description of the type, else the extension in capitals.
    var kindText: String {
        if let description = UTType(filenameExtension: url.pathExtension)?.localizedDescription { return description }
        return url.pathExtension.isEmpty ? "Document" : url.pathExtension.uppercased() + " file"
    }
}
