import Foundation
import PluginKit

/// A smaller version of a file, written in a work folder, under the name it should have.
struct OptimizedFile: Equatable {
    let url: URL
    /// The file name with its new extension (`photo.png` -> `photo.webp`).
    let name: String
    let before: Int
    let after: Int
}

/// Why a file was left alone, in words for a command's answer.
enum Skip: Error, Equatable {
    case off
    case tooSmall
    case alreadyCompact
    case notWorthIt
    case unsupported
    case alreadyOptimized

    var reason: String {
        switch self {
        case .off: "this kind of file is switched off"
        case .tooSmall: "smaller than the minimum size"
        case .alreadyCompact: "already compact"
        case .notWorthIt: "the smaller version saves too little"
        case .unsupported: "nothing safe to convert it to"
        case .alreadyOptimized: "already optimized by Loam"
        }
    }
}

/// Turns one media file into a smaller one with `cwebp`, `ffmpeg` or the PDF rasterizer: images to WebP, sounds to mono
/// 64 kbps, videos to H.264 at 1080p at most, PDFs to JPEG pages. It never touches the vault: it reads `input` and
/// writes into `workFolder`, and the caller decides whether the result replaces anything.
struct MediaOptimizer: Sendable {
    let settings: SqueezeSettings
    let tools: MediaTools
    let rasterizer: PDFRasterizing?

    /// A file replaced only when it gains this much; PDFs, which lose their text, need much more.
    static let minimumGain = 0.10
    static let minimumPDFGain = 0.30

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "tif", "tiff", "heic", "heif"]
    static let audioExtensions: Set<String> = ["mp3", "m4a", "wav", "flac", "aac", "aif", "aiff", "caf"]
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    enum Family { case image, audio, video, pdf }

    /// What kind of media a file name is, whether or not its setting is on; nil for anything else (GIF, WebP, SVG...).
    static func family(ofExtension ext: String) -> Family? {
        let ext = ext.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if audioExtensions.contains(ext) { return .audio }
        if videoExtensions.contains(ext) { return .video }
        if ext == "pdf" { return .pdf }
        return nil
    }

    func isOn(_ family: Family) -> Bool {
        switch family {
        case .image: settings.images
        case .audio: settings.audio
        case .video: settings.video
        case .pdf: settings.pdfs
        }
    }

    /// The smaller version of `input`, or the reason it was left alone. Throws `ToolMissing` or `ToolFailed`.
    /// - Parameters:
    ///   - name: the name the file has (its extension decides the kind; `input` may be a temporary file).
    ///   - force: ignores the minimum size, for a file the user asked about.
    ///   - started: called once the file is known to be worth an encoder (after the size and bitrate checks), just
    ///     before the slow part, so a progress message is not shown for a file that is then skipped.
    func optimize(
        _ input: URL, name: String, force: Bool, workFolder: URL, started: (@Sendable () async -> Void)? = nil
    ) async throws -> OptimizedFile {
        guard let family = Self.family(ofExtension: (name as NSString).pathExtension) else { throw Skip.unsupported }
        guard isOn(family) || force else { throw Skip.off }
        let before = try Self.size(of: input)
        if !force, before < settings.minimumBytes { throw Skip.tooSmall }
        guard before > 0 else { throw Skip.tooSmall }

        let ext = (name as NSString).pathExtension.lowercased()
        let base = (name as NSString).deletingPathExtension
        try FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
        let id = UUID().uuidString
        var minimumGain = Self.minimumGain
        let outputExtension: String
        switch family {
        case .image:
            outputExtension = "webp"
            let output = workFolder.appendingPathComponent("\(id).webp")
            try await encodeImage(input, ext: ext, to: output, workFolder: workFolder)
            return try finish(output, name: base + ".webp", before: before, minimumGain: minimumGain)
        case .audio:
            // MP3 stays MP3; everything else becomes AAC in M4A, which Loam's player and Safari play.
            outputExtension = ext == "mp3" ? "mp3" : "m4a"
            let output = workFolder.appendingPathComponent("\(id).\(outputExtension)")
            try await encodeAudio(input, ext: ext, to: output, started: started)
            return try await finishTimed(input, output, name: base + "." + outputExtension, before: before, minimumGain: minimumGain)
        case .video:
            let output = workFolder.appendingPathComponent("\(id).mp4")
            try await encodeVideo(input, ext: ext, to: output, started: started)
            return try await finishTimed(input, output, name: base + ".mp4", before: before, minimumGain: minimumGain)
        case .pdf:
            guard let rasterizer else { throw Skip.unsupported }
            minimumGain = Self.minimumPDFGain
            await started?()
            let output = workFolder.appendingPathComponent("\(id).pdf")
            try await rasterizer.rasterize(input, to: output, dpi: settings.dpi, jpegQuality: settings.jpegQuality)
            return try finish(output, name: base + ".pdf", before: before, minimumGain: minimumGain)
        }
    }

    // MARK: Images

    private func encodeImage(_ input: URL, ext: String, to output: URL, workFolder: URL) async throws {
        let format = try Self.imageFormat(of: input, ext: ext)
        var source = input
        var viaFFmpeg = false
        switch format {
        case .heic:
            // cwebp reads neither HEIC nor HEIF: macOS' own converter makes a PNG first, ffmpeg is the fallback.
            let sips = "/usr/bin/sips"
            if FileManager.default.isExecutableFile(atPath: sips), tools.hasCwebp {
                let png = workFolder.appendingPathComponent("\(UUID().uuidString).png")
                _ = try await MediaTools.run(sips, ["-s", "format", "png", input.path, "--out", png.path])
                source = png
            } else {
                viaFFmpeg = true
            }
        case .jpeg(let orientation):
            // cwebp drops the EXIF orientation and would turn a portrait photo on its side; ffmpeg applies it.
            viaFFmpeg = orientation > 1
        case .png, .tiff:
            break
        }
        defer { if source != input { try? FileManager.default.removeItem(at: source) } }

        let quality = String(settings.webpQuality)
        if !viaFFmpeg, tools.hasCwebp {
            do {
                _ = try await MediaTools.run(tools.cwebp, ["-quiet", "-q", quality, "-m", "6", "-metadata", "icc", source.path, "-o", output.path])
                return
            } catch let error as ToolFailed {
                // A TIFF flavour cwebp cannot read: try ffmpeg before giving up.
                guard tools.hasFFmpeg else { throw error }
            }
        }
        guard tools.hasFFmpeg else { throw ToolMissing(tool: viaFFmpeg || tools.hasCwebp ? "ffmpeg" : "cwebp") }
        // ffmpeg's WebP encoder drops the colour profile (Display P3 screenshots and photos would look different):
        // a picture that has one, or may have one, is left as it is rather than converted with the wrong colours.
        if try Self.mayCarryColourProfile(source, format: format) { throw Skip.unsupported }
        _ = try await MediaTools.run(tools.ffmpeg, [
            "-nostdin", "-y", "-v", "error", "-i", source.path, "-frames:v", "1",
            "-c:v", "libwebp", "-quality", quality, "-compression_level", "6", output.path,
        ])
    }

    enum ImageFormat: Equatable {
        case png, tiff, heic
        /// The EXIF orientation, 1 when upright or absent.
        case jpeg(orientation: Int)
    }

    /// The format from the first bytes, since a name can lie: nil-equivalent (`Skip.unsupported`) for a GIF named `.png`.
    static func imageFormat(of url: URL, ext: String) throws -> ImageFormat {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw Skip.unsupported }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 256 * 1024)) ?? Data()
        let bytes = [UInt8](head)
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            // An animated PNG would be flattened to its first frame.
            if pngChunks(bytes).contains("acTL") { throw Skip.unsupported }
            return .png
        }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg(orientation: exifOrientation(bytes)) }
        if bytes.starts(with: [0x49, 0x49, 0x2A, 0x00]) || bytes.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) { return .tiff }
        if bytes.count > 12, Array(bytes[4..<8]) == Array("ftyp".utf8) { return .heic }
        throw Skip.unsupported
    }

    /// The names of the PNG chunks before the image data (`IHDR`, `iCCP`, `acTL`...).
    static func pngChunks(_ bytes: [UInt8]) -> [String] {
        var names: [String] = []
        var index = 8
        while index + 8 <= bytes.count {
            let length = Int(bytes[index]) << 24 | Int(bytes[index + 1]) << 16 | Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            let name = String(decoding: bytes[(index + 4)..<(index + 8)], as: UTF8.self)
            names.append(name)
            if name == "IDAT" { break }
            index += 12 + length
        }
        return names
    }

    /// Whether `url` has a colour profile, or might (a TIFF, a HEIC with a `prof` box), judged on its first bytes.
    static func mayCarryColourProfile(_ url: URL, format: ImageFormat) throws -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return true }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 256 * 1024)) ?? Data()
        let bytes = [UInt8](head)
        func contains(_ text: String) -> Bool {
            let needle = Array(text.utf8)
            guard bytes.count >= needle.count else { return false }
            return (0...(bytes.count - needle.count)).contains { Array(bytes[$0..<($0 + needle.count)]) == needle }
        }
        switch format {
        case .png: return pngChunks(bytes).contains("iCCP")
        case .jpeg: return contains("ICC_PROFILE")
        case .heic: return contains("prof")
        case .tiff: return true
        }
    }

    /// The EXIF orientation of a JPEG whose first bytes are `bytes`: 1 when it has none or cannot be read.
    static func exifOrientation(_ bytes: [UInt8]) -> Int {
        var index = 2
        while index + 4 < bytes.count, bytes[index] == 0xFF {
            let marker = bytes[index + 1]
            let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            if marker == 0xDA { break }
            if marker == 0xE1, index + 4 + 14 < bytes.count, Array(bytes[(index + 4)..<(index + 10)]) == Array("Exif\0\0".utf8) {
                let tiff = index + 10
                let little = bytes[tiff] == 0x49
                func u16(_ at: Int) -> Int {
                    guard at + 1 < bytes.count else { return 0 }
                    return little ? Int(bytes[at]) | Int(bytes[at + 1]) << 8 : Int(bytes[at]) << 8 | Int(bytes[at + 1])
                }
                func u32(_ at: Int) -> Int { little ? u16(at) | u16(at + 2) << 16 : u16(at) << 16 | u16(at + 2) }
                let directory = tiff + u32(tiff + 4)
                guard directory + 2 < bytes.count else { return 1 }
                for entry in 0..<u16(directory) {
                    let at = directory + 2 + entry * 12
                    if u16(at) == 0x0112 { return max(1, u16(at + 8)) }
                }
                return 1
            }
            index += 2 + length
        }
        return 1
    }

    // MARK: Audio and video

    private func encodeAudio(_ input: URL, ext: String, to output: URL, started: (@Sendable () async -> Void)?) async throws {
        guard tools.hasFFmpeg else { throw ToolMissing(tool: "ffmpeg") }
        let bitrate = settings.bitrateKbps
        // A compact MP3 or M4A is not encoded twice: that only costs quality.
        if ext == "mp3" || ext == "m4a" {
            let known = try await tools.probe(input).bitRate
            if known > 0, known <= Double(bitrate) * 1000 * 1.15 { throw Skip.alreadyCompact }
        }
        await started?()
        let codec = output.pathExtension == "mp3" ? ["-c:a", "libmp3lame"] : ["-c:a", "aac", "-movflags", "+faststart"]
        _ = try await MediaTools.run(tools.ffmpeg, [
            "-nostdin", "-y", "-v", "error", "-i", input.path, "-vn", "-map_metadata", "0",
        ] + (settings.audioMono ? ["-ac", "1"] : []) + codec + ["-b:a", "\(bitrate)k", output.path])
    }

    private func encodeVideo(_ input: URL, ext: String, to output: URL, started: (@Sendable () async -> Void)?) async throws {
        guard tools.hasFFmpeg else { throw ToolMissing(tool: "ffmpeg") }
        let known = try await tools.probe(input)
        if ext == "mp4", known.bitRate > 0, known.bitRate < 1_200_000, known.height <= settings.maxHeight {
            throw Skip.alreadyCompact
        }
        await started?()
        _ = try await MediaTools.run(tools.ffmpeg, [
            "-nostdin", "-y", "-v", "error", "-i", input.path, "-map_metadata", "0",
            "-c:v", "libx264", "-crf", String(settings.crf), "-preset", "medium", "-pix_fmt", "yuv420p",
            "-vf", "scale=-2:'min(\(settings.maxHeight),ih)'",
            "-c:a", "aac", "-b:a", "96k", "-movflags", "+faststart", output.path,
        ])
    }

    // MARK: Checks

    private func finish(_ output: URL, name: String, before: Int, minimumGain: Double) throws -> OptimizedFile {
        let after = try Self.size(of: output)
        guard after > 0, Double(after) <= Double(before) * (1 - minimumGain) else {
            try? FileManager.default.removeItem(at: output)
            throw Skip.notWorthIt
        }
        return OptimizedFile(url: output, name: name, before: before, after: after)
    }

    /// As `finish`, and the duration must stay within 2%: a conversion that cut a recording short is dropped.
    private func finishTimed(_ input: URL, _ output: URL, name: String, before: Int, minimumGain: Double) async throws -> OptimizedFile {
        let result = try finish(output, name: name, before: before, minimumGain: minimumGain)
        let original = try await tools.probe(input).duration
        let converted = try await tools.probe(output).duration
        guard original > 0, converted > 0, abs(original - converted) / original <= 0.02 else {
            try? FileManager.default.removeItem(at: output)
            throw ToolFailed(tool: "ffmpeg", message: "the duration changed after conversion, the original was kept")
        }
        return result
    }

    static func size(of url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }
}
