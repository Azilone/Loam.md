import Foundation
import PluginKit

/// The Media compression plugin's settings, in `.loam/config.json` under `plugins.squeeze.settings`; their titles and
/// help in Settings come from the manifest (`SqueezePlugin.settingDescriptions`).
public struct SqueezeSettings: Codable, Equatable, Sendable {
    /// Optimizes every file as it is dropped or pasted into a note.
    public var optimizeNewFiles = true
    public var images = true
    public var audio = true
    public var video = true
    public var pdfs = true

    /// WebP quality, 1 to 100.
    public var imageQuality = 80.0
    /// Audio bit rate in kbps, mono.
    public var audioBitrate = 64.0
    public var audioMono = true
    /// Video quality: x264 CRF, higher is smaller.
    public var videoCRF = 28.0
    /// Taller videos are scaled down to this height; shorter ones are left alone.
    public var videoMaxHeight = 1080.0
    public var pdfDPI = 130.0
    public var pdfQuality = 70.0

    /// Files smaller than this are left alone (when optimizing on arrival and "all media"; not when asked for one).
    public var minimumSizeKB = 100.0
    /// Moves the original to the vault's `.trash/` when a file is replaced.
    public var keepOriginals = true
    /// Folders left alone, vault-relative, separated by commas.
    public var excludedFolders = ""

    /// Empty: found in `~/.homebrew/bin`, `/opt/homebrew/bin` and `/usr/local/bin`.
    public var ffmpegPath = ""
    public var cwebpPath = ""

    public init() {}

    public var excluded: [String] {
        excludedFolders.split(whereSeparator: { $0 == "," || $0 == "\n" }).compactMap {
            let folder = $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return folder.isEmpty ? nil : try? VaultPath.normalize(folder)
        }.filter { !$0.isEmpty }
    }

    /// Whether `path` is in an excluded folder (or is one).
    public func isExcluded(_ path: String) -> Bool {
        excluded.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    func clamped(_ value: Double, _ range: ClosedRange<Double>) -> Int {
        Int(min(max(value, range.lowerBound), range.upperBound).rounded())
    }

    var webpQuality: Int { clamped(imageQuality, 1...100) }
    var bitrateKbps: Int { clamped(audioBitrate, 8...320) }
    var crf: Int { clamped(videoCRF, 0...51) }
    var maxHeight: Int { clamped(videoMaxHeight, 144...4320) }
    var dpi: Int { clamped(pdfDPI, 36...300) }
    var jpegQuality: Int { clamped(pdfQuality, 1...100) }
    var minimumBytes: Int { Int(max(minimumSizeKB, 0) * 1024) }
}
