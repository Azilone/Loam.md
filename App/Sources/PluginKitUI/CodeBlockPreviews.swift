import AppKit
import SwiftUI

/// What cards show for a fenced block with a language: the picture a plugin draws for it (a Mermaid diagram), or a
/// small labelled tile for a block a plugin shows as a live view (a ` ```base ` collection). `PluginContext` fills it
/// as plugins add their renderers and views, so a card matches the note without running the editor.
///
/// Pictures are drawn once per code and look, shrunk to a card's size and kept: a scroll only lays images out. A
/// card asks for its picture only after staying on screen a moment, so a fast scroll draws nothing.
@MainActor
public final class CodeBlockPreviews {
    public static let shared = CodeBlockPreviews()

    private var renderers: [(token: Int, renderer: CodeBlockRenderer)] = []
    private var viewLanguages: [(token: Int, languages: [String])] = []
    private var nextToken = 0
    private var pictures: [CodeBlockRequest: CGImage] = [:]
    /// The order pictures were kept in, the oldest first, to let the oldest go past `capacity`.
    private var order: [CodeBlockRequest] = []
    /// The requests being drawn, so two cards of one diagram draw it once.
    private var drawing: [CodeBlockRequest: Task<CGImage?, Never>] = [:]
    /// The codes with no picture (a syntax error), which stay code.
    private var failed: Set<CodeBlockRequest> = []

    nonisolated static let capacity = 120
    /// The widest a kept picture is, in pixels: a card column is at most about 260 points at 2x.
    nonisolated static let thumbnailWidth: CGFloat = 640

    public init() {}

    /// Adds `renderer`; the returned function removes it.
    public func add(_ renderer: CodeBlockRenderer) -> @MainActor () -> Void {
        let token = nextToken
        nextToken += 1
        renderers.append((token, renderer))
        return { [weak self] in self?.renderers.removeAll { $0.token == token } }
    }

    /// Adds the languages of a live view; the returned function removes them.
    public func addView(languages: [String]) -> @MainActor () -> Void {
        let token = nextToken
        nextToken += 1
        viewLanguages.append((token, languages.map { $0.lowercased() }))
        return { [weak self] in self?.viewLanguages.removeAll { $0.token == token } }
    }

    /// Whether a plugin draws `language` as a picture.
    public func drawsPicture(_ language: String) -> Bool {
        renderers.contains { $0.renderer.languages.contains(language) }
    }

    /// Whether a plugin shows `language` as a live view.
    public func showsView(_ language: String) -> Bool {
        viewLanguages.contains { $0.languages.contains(language) }
    }

    /// The kept picture of `request`, if it was drawn.
    public func picture(for request: CodeBlockRequest) -> CGImage? { pictures[request] }

    /// Whether `request` was drawn and could not be.
    public func hasFailed(_ request: CodeBlockRequest) -> Bool { failed.contains(request) }

    /// Draws `request` with the last renderer added for its language, shrunk to a card's size, and keeps it.
    public func draw(_ request: CodeBlockRequest) async -> CGImage? {
        if let kept = pictures[request] { return kept }
        if failed.contains(request) { return nil }
        if let running = drawing[request] { return await running.value }
        guard let renderer = renderers.last(where: { $0.renderer.languages.contains(request.language) })?.renderer
        else { return nil }
        let task = Task { @MainActor () -> CGImage? in
            guard let rendered = await renderer.render(request) else { return nil }
            return Self.thumbnail(rendered.image)
        }
        drawing[request] = task
        let image = await task.value
        drawing[request] = nil
        if let image {
            pictures[request] = image
            order.append(request)
            if order.count > Self.capacity { pictures[order.removeFirst()] = nil }
        } else {
            failed.insert(request)
        }
        return image
    }

    /// `image` at most `thumbnailWidth` pixels wide: a smaller texture for the cards to draw while scrolling.
    nonisolated static func thumbnail(_ image: CGImage) -> CGImage {
        let width = CGFloat(image.width)
        guard width > thumbnailWidth else { return image }
        let scale = thumbnailWidth / width
        let size = CGSize(width: thumbnailWidth, height: max(1, (CGFloat(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
        return context.makeImage() ?? image
    }

    /// The name a live view's block gives itself (a base's first view's `name:`), for its tile; nil when it has none.
    public nonisolated static func viewTitle(of code: String) -> (name: String?, kind: String?) {
        var name: String?
        var kind: String?
        var inViews = false
        for line in code.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !line.hasPrefix(" "), !line.hasPrefix("-") { inViews = trimmed.hasPrefix("views:") }
            guard inViews else { continue }
            let entry = trimmed.hasPrefix("- ") ? String(trimmed.dropFirst(2)) : trimmed
            if kind == nil, entry.hasPrefix("type:") { kind = value(entry.dropFirst(5)) }
            if name == nil, entry.hasPrefix("name:") { name = value(entry.dropFirst(5)) }
            if name != nil, kind != nil { break }
        }
        return (name, kind)
    }

    private nonisolated static func value(_ text: Substring) -> String? {
        let value = text.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return value.isEmpty ? nil : value
    }
}

/// A fenced block on a card: its picture when a plugin draws it (held in a fixed height, so the card never jumps when
/// it arrives), a tile when a plugin shows it as a live view, else its first lines of code.
struct CardCodeBlock: View {
    let language: String
    let code: String
    let size: CGFloat
    @Environment(\.themeTokens) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isScrollingCards) private var isScrolling
    @State private var drawn: CGImage?

    private var k: CGFloat { size / 10 }
    /// The most a diagram takes on a card.
    private var pictureHeight: CGFloat { 140 * k }
    /// The room a diagram holds while it is drawn, the first time only: then it is kept.
    private var placeholderHeight: CGFloat { 70 * k }

    var body: some View {
        let previews = CodeBlockPreviews.shared
        if previews.drawsPicture(language) {
            let request = self.request
            if !previews.hasFailed(request) {
                picture(request: request, kept: previews.picture(for: request))
            } else {
                CardCodeLines(code: code, size: size)
            }
        } else if previews.showsView(language) {
            tile
        } else {
            CardCodeLines(code: code, size: size)
        }
    }

    private func picture(request: CodeBlockRequest, kept: CGImage?) -> some View {
        let image = kept ?? drawn
        return Group {
            if let image {
                // As tall as the diagram at the card's width, at most `pictureHeight`.
                Image(decorative: image, scale: 2)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: pictureHeight, alignment: .topLeading)
                    .transition(.opacity)
            } else {
                RoundedRectangle(cornerRadius: Corners.r(6 * k), style: .continuous)
                    .fill(theme.codeBackground.opacity(0.6))
                    .frame(maxWidth: .infinity)
                    .frame(height: placeholderHeight)
            }
        }
        .task(id: DrawKey(request: request, waits: isScrolling)) {
            // Drawn once the scroll stops, and only for a card that stays: a frame of a scroll only lays out images
            // (the first diagram also starts the renderer's web view, a long frame).
            guard kept == nil, !isScrolling else { return }
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let image = await CodeBlockPreviews.shared.draw(request)
            guard !Task.isCancelled else { return }
            withAnimation(Motion.resolved(Motion.fade)) { drawn = image }
        }
    }

    private var tile: some View {
        let title = CodeBlockPreviews.viewTitle(of: code)
        return HStack(spacing: 7 * k) {
            Image(symbol: symbol(for: title.kind))
                .font(.ui(size: 11 * k, weight: .medium))
                .foregroundStyle(theme.accent)
                .frame(width: 22 * k, height: 22 * k)
                .background(RoundedRectangle(cornerRadius: Corners.r(6 * k), style: .continuous).fill(theme.accent.opacity(0.12)))
            VStack(alignment: .leading, spacing: 1 * k) {
                Text(title.name ?? language.capitalized)
                    .font(.ui(size: 10 * k, weight: .semibold))
                    .foregroundStyle(theme.text)
                Text(title.kind.map { $0.caseInsensitiveCompare(title.name ?? "") == .orderedSame ? "Collection" : $0.capitalized }
                     ?? "Collection")
                    .font(.ui(size: 9 * k))
                    .foregroundStyle(theme.secondaryText)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(6 * k)
        .background(RoundedRectangle(cornerRadius: Corners.r(8 * k), style: .continuous).fill(theme.codeBackground.opacity(0.7)))
    }

    private func symbol(for kind: String?) -> String {
        switch kind?.lowercased() {
        case "kanban", "board": return "rectangle.split.3x1"
        case "cards", "gallery": return "square.grid.2x2"
        case "list": return "list.bullet"
        case "calendar": return "calendar"
        default: return "tablecells"
        }
    }

    private var request: CodeBlockRequest {
        let dark = colorScheme == .dark
        return CodeBlockRequest(
            language: language, code: code, isDark: dark,
            text: Self.css(theme.text, dark: dark), secondaryText: Self.css(theme.secondaryText, dark: dark),
            accent: Self.css(theme.accent, dark: dark), background: Self.css(theme.background, dark: dark),
            codeBackground: Self.css(theme.codeBackground, dark: dark), separator: Self.css(theme.separator, dark: dark),
            fontSize: 13
        )
    }

    /// `color` as CSS in the light or dark appearance.
    static func css(_ color: Color, dark: Bool) -> String {
        var resolved = NSColor(color)
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        }
        let c = resolved.usingColorSpace(.sRGB) ?? resolved
        return String(format: "rgba(%d,%d,%d,%.3f)", Int(c.redComponent * 255), Int(c.greenComponent * 255),
                      Int(c.blueComponent * 255), c.alphaComponent)
    }
}

private struct DrawKey: Equatable {
    let request: CodeBlockRequest
    let waits: Bool
}

public extension EnvironmentValues {
    /// Whether the cards' page is scrolling: cards draw their diagrams only when it stops (`CardCodeBlock`).
    @Entry var isScrollingCards = false
}

/// A code block's first lines on a card, as before a plugin draws it.
struct CardCodeLines: View {
    let code: String
    let size: CGFloat
    @Environment(\.themeTokens) private var theme

    private var k: CGFloat { size / 10 }

    var body: some View {
        VStack(alignment: .leading, spacing: 3 * k) {
            ForEach(Array(code.split(separator: "\n", omittingEmptySubsequences: false).prefix(16).enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : String(line))
                    .font(.system(size: 9 * k, design: .monospaced))
                    .foregroundStyle(theme.accent.opacity(0.85))
                    .lineLimit(1)
                    .padding(.horizontal, 6 * k)
                    .padding(.vertical, 1 * k)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.codeBackground)
            }
        }
    }
}
