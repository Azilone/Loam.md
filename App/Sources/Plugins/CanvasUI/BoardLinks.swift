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

/// A PDF's pages, one under the other: still while the card is not selected, scrolling and zooming once it is.
struct BoardPDFPages: NSViewRepresentable {
    let document: PDFDocument
    let interactive: Bool

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = document
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = .clear
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
        view.autoScales = true
    }
}

/// YouTube's play button: the red rounded rectangle with its white triangle (Vimeo's is blue).
struct BoardPlayButton: View {
    let youtube: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Corners.r(14), style: .continuous)
                .fill(youtube ? Color(red: 1, green: 0, blue: 0) : Color(red: 0.1, green: 0.72, blue: 0.92))
                .frame(width: 68, height: 48)
            Path { path in
                path.move(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: 19, y: 11))
                path.addLine(to: CGPoint(x: 0, y: 22))
                path.closeSubpath()
            }
            .fill(.white)
            .frame(width: 19, height: 22)
            .offset(x: 2)
        }
        .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
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

/// A link card, as Notion and Whimsical show one: a video with its picture and a play button, a post with its text and
/// author, a PDF with its name, a page with its picture, site, title and summary. Double-click plays the video or
/// opens the page in the card.
struct BoardRichLink: View {
    let links: BoardLinkPreviews
    let url: URL
    let tint: Color?
    /// The card is the one selected: a PDF scrolls and zooms in place.
    var interactive = false
    @Environment(\.themeTokens) private var theme

    var body: some View {
        let _ = links.version
        let preview = links.preview(for: url)
        let kind = CanvasLinkKind(url)
        switch kind {
        case .youtube, .vimeo:
            video(preview)
        case .tweet:
            post(preview)
        case .pdf:
            if let pdf = links.pdf(url) {
                if interactive {
                    BoardPDFPages(document: pdf, interactive: true)
                } else if let page = pdf.page(at: 0) {
                    // Still, the first page as a picture: cheap, and drawn wherever the card is.
                    Image(nsImage: page.thumbnail(of: CGSize(width: 900, height: 1200), for: .mediaBox))
                        .resizable().scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .background(Color.white)
                        .overlay(alignment: .bottomLeading) { pdfLabel(preview) }
                }
            } else {
                document(preview)
            }
        case .page:
            page(preview)
        }
    }

    private func picture(_ address: URL?) -> NSImage? { address.flatMap { links.image($0) } }

    private func video(_ preview: CanvasLinkPreview?) -> some View {
        ZStack(alignment: .topLeading) {
            // The picture fills the card without making it larger, so the title stays inside.
            Color.black.overlay {
                if let image = picture(preview?.image) { Image(nsImage: image).resizable().scaledToFill() }
            }
            .clipped()
            LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .center)
            BoardPlayButton(youtube: CanvasLinkKind(url) != .vimeo)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 3) {
                Text(preview?.site ?? "Video").font(.ui(size: 12, weight: .semibold)).opacity(0.8)
                Text(preview?.title ?? url.absoluteString).font(.ui(size: 16, weight: .bold)).lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(14)
        }
    }

    private func post(_ preview: CanvasLinkPreview?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("𝕏").font(.ui(size: 20, weight: .black)).foregroundStyle(theme.text)
                VStack(alignment: .leading, spacing: 0) {
                    Text(preview?.title ?? "Post").font(.ui(size: 15, weight: .bold)).foregroundStyle(theme.text)
                    if let author = preview?.author {
                        Text(author).font(.ui(size: 13)).foregroundStyle(theme.secondaryText)
                    }
                }
            }
            Text(preview?.summary ?? url.absoluteString)
                .font(.ui(size: 16))
                .foregroundStyle(theme.text)
                .lineSpacing(2)
        }
        .padding(BoardStyle.textPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func pdfLabel(_ preview: CanvasLinkPreview?) -> some View {
        Label(preview?.title ?? url.lastPathComponent, symbol: "doc.richtext.fill")
            .font(.ui(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(ThemeCapsule().fill(.black.opacity(0.6)))
            .padding(10)
    }

    private func document(_ preview: CanvasLinkPreview?) -> some View {
        HStack(spacing: 14) {
            Image(symbol: "doc.richtext.fill")
                .font(.ui(size: 40))
                .foregroundStyle(tint ?? Color.red.opacity(0.85)) // ui-rules: illustration
            VStack(alignment: .leading, spacing: 4) {
                Text(preview?.title ?? url.lastPathComponent)
                    .font(.ui(size: 17, weight: .bold))
                    .foregroundStyle(theme.text)
                    .lineLimit(3)
                Text("PDF · " + (url.host() ?? "")).font(.ui(size: 13)).foregroundStyle(theme.secondaryText)
            }
        }
        .padding(BoardStyle.textPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    @ViewBuilder private func page(_ preview: CanvasLinkPreview?) -> some View {
        let image = picture(preview?.image)
        VStack(alignment: .leading, spacing: 0) {
            if let image {
                // Social pictures are 1.91:1.
                Color.clear.aspectRatio(1.91, contentMode: .fit)
                    .overlay { Image(nsImage: image).resizable().scaledToFill() }
                    .clipped()
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if let icon = picture(preview?.icon) {
                        Image(nsImage: icon).resizable().scaledToFit().frame(width: 16, height: 16)
                            .clipShape(RoundedRectangle(cornerRadius: Corners.r(4)))
                    } else {
                        Image(symbol: "globe").font(.ui(size: 13)).foregroundStyle(tint ?? theme.accent)
                    }
                    Text(preview?.site ?? url.host() ?? "").font(.ui(size: 12, weight: .semibold))
                        .foregroundStyle(theme.secondaryText).lineLimit(1)
                }
                Text(preview?.title ?? url.host() ?? url.absoluteString)
                    .font(.ui(size: image == nil ? BoardStyle.titleSize : 17, weight: .bold))
                    .foregroundStyle(theme.text)
                    .lineLimit(image == nil ? 3 : 2)
                if let summary = preview?.summary {
                    Text(summary).font(.ui(size: 13)).foregroundStyle(theme.secondaryText).lineLimit(image == nil ? 5 : 2)
                }
                if image == nil {
                    Text(url.absoluteString).font(.ui(size: 12)).foregroundStyle(theme.link).lineLimit(1)
                }
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
