import AppKit
import CanvasPlugin
import Foundation
import Observation
import PDFKit
import PluginKitUI
import SwiftUI

/// The previews of the links on boards, and their pictures: fetched once when a card first shows, kept in memory and in
/// the user's caches folder (never in the vault), so a board opens with its previews at once the next time. A link that
/// cannot be read keeps the plain card.
@MainActor
@Observable
final class BoardLinkPreviews {
    /// Changes when a preview or a picture arrives: the cards showing it are drawn again.
    private(set) var version = 0
    @ObservationIgnored private var previews: [String: CanvasLinkPreview] = [:]
    @ObservationIgnored private var images: [URL: NSImage] = [:]
    @ObservationIgnored private var pdfs: [URL: PDFDocument] = [:]
    @ObservationIgnored private var asked: Set<String> = []
    private let cache: URL?
    private let session: URLSession

    init(cache: URL? = BoardLinkPreviews.defaultCache, session: URLSession = .shared) {
        self.cache = cache
        self.session = session
    }

    static var defaultCache: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Loam").appendingPathComponent("link-previews")
    }

    /// A browser's name: some sites only give their preview to browsers.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) "
        + "Version/18.0 Safari/605.1.15"

    /// The preview of `url` if known; asks for it otherwise.
    func preview(for url: URL) -> CanvasLinkPreview? {
        let key = url.absoluteString
        if let known = previews[key] { return known }
        if !asked.contains(key) {
            asked.insert(key)
            if let stored = read(key) {
                previews[key] = stored
                return stored
            }
            if let offline = CanvasLinkPreview.offline(url) { previews[key] = offline }
            Task { await fetch(url) }
        }
        return previews[key]
    }

    /// A picture of a preview if loaded; loads it otherwise.
    func image(_ url: URL) -> NSImage? {
        if let known = images[url] { return known }
        let key = "image:" + url.absoluteString
        guard !asked.contains(key) else { return nil }
        asked.insert(key)
        if let file = file(key), let image = NSImage(contentsOf: file) {
            images[url] = image
            return image
        }
        Task {
            guard let data = await get(url), let image = NSImage(data: data) else { return }
            images[url] = image
            if let file = file(key) { try? data.write(to: file) }
            version += 1
        }
        return nil
    }

    /// A PDF behind a link, downloaded once into the caches folder; nil until it is there.
    func pdf(_ url: URL) -> PDFDocument? {
        if let known = pdfs[url] { return known }
        let key = "pdf:" + url.absoluteString
        guard !asked.contains(key) else { return nil }
        asked.insert(key)
        if let file = file(key), let document = PDFDocument(url: file) {
            pdfs[url] = document
            return document
        }
        Task {
            guard let data = await get(url, limit: 200_000_000), let document = PDFDocument(data: data) else { return }
            pdfs[url] = document
            if let file = file(key) { try? data.write(to: file) }
            version += 1
        }
        return nil
    }

    private func fetch(_ url: URL) async {
        var preview: CanvasLinkPreview?
        switch CanvasLinkKind(url) {
        case .tweet:
            if let oembed = CanvasLinkPreview.tweetOEmbed(for: url), let data = await get(oembed) {
                preview = CanvasLinkPreview(tweetOEmbed: data)
            }
        case .youtube:
            // YouTube's page is a consent page for many; its oEmbed has the title and channel.
            var components = URLComponents(string: "https://www.youtube.com/oembed")
            components?.queryItems = [URLQueryItem(name: "url", value: url.absoluteString), URLQueryItem(name: "format", value: "json")]
            var read = CanvasLinkPreview.offline(url) ?? CanvasLinkPreview()
            if let oembed = components?.url, let data = await get(oembed),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                read.title = object["title"] as? String
                read.author = object["author_name"] as? String
                read.site = (object["author_name"] as? String).map { "YouTube · " + $0 } ?? "YouTube"
            }
            preview = read
        case .pdf:
            preview = CanvasLinkPreview(title: url.deletingPathExtension().lastPathComponent.removingPercentEncoding,
                                        site: url.host())
        default:
            if let data = await get(url, limit: 1_500_000, anyStatus: true) {
                let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
                var read = CanvasLinkPreview(html: html, url: url)
                // A YouTube page's picture is known better offline (its og:image is the same, but may be missing).
                if let offline = CanvasLinkPreview.offline(url) { read.image = read.image ?? offline.image }
                preview = read
            }
        }
        guard let preview else { return }
        previews[url.absoluteString] = preview
        write(preview, url.absoluteString)
        version += 1
    }

    /// `anyStatus`: a page's body is read whatever its status (Notion answers its own blog with a 404 holding the
    /// whole page and its preview).
    private func get(_ url: URL, limit: Int = 8_000_000, anyStatus: Bool = false) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/json,image/*;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              anyStatus || (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true
        else { return nil }
        return data.count > limit ? data.prefix(limit) : data
    }

    // MARK: Disk cache

    private func file(_ key: String) -> URL? {
        guard let cache else { return nil }
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        return cache.appendingPathComponent(Self.hash(key))
    }

    private func read(_ key: String) -> CanvasLinkPreview? {
        guard let file = file(key), let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(CanvasLinkPreview.self, from: data)
    }

    private func write(_ preview: CanvasLinkPreview, _ key: String) {
        guard let file = file(key), let data = try? JSONEncoder().encode(preview) else { return }
        try? data.write(to: file)
    }

    /// A file name for a key (FNV-1a, 64 bits): stable across launches, unlike `hashValue`.
    static func hash(_ key: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}

/// How tall a link card is for its preview at `width`: the picture, then the lines under it; nothing empty.
enum BoardLinkLayout {
    static func height(_ kind: CanvasLinkKind, _ preview: CanvasLinkPreview?, hasImage: Bool, width: Double) -> Double {
        func lines(_ text: String?, size: Double, max: Int) -> Double {
            guard let text, !text.isEmpty else { return 0 }
            let perLine = Swift.max(10, (width - 28) / (size * 0.52))
            let count = text.split(separator: "\n").map { ceil(Double($0.count) / perLine) }.reduce(0, +)
            return min(Double(max), Swift.max(1, count)) * size * 1.3
        }
        switch kind {
        case .youtube, .vimeo:
            return (width * 9 / 16).rounded()
        case .tweet:
            return (16 + 40 + 10 + lines(preview?.summary, size: 16, max: 14) + 18).rounded()
        case .pdf:
            return (width * 1.294).rounded()
        case .page:
            let picture = hasImage ? width / 1.91 : 0
            let text = 14 + 18 + 6 + lines(preview?.title, size: hasImage ? 17 : 20, max: hasImage ? 2 : 3)
                + (preview?.summary == nil ? 0 : 6 + lines(preview?.summary, size: 13, max: hasImage ? 2 : 4))
                + (hasImage ? 0 : 6 + 17) + 14
            return (picture + text).rounded()
        }
    }
}

