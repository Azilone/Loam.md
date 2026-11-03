import AppKit
import CanvasPlugin
import ImageIO
import PluginKitUI
import SwiftUI

/// The cards of a board zoomed far out, all drawn in one pass: a tinted paper with the card's title, or a small
/// picture for a picture. No view per card: a thousand cards cost one drawing, and panning or zooming only redraws
/// it. It fades out as the real cards (views, with their full content) fade in (`BoardModel.detailAlpha`).
struct BoardFarCards: View {
    let model: BoardModel
    /// The cards that are views just now: they are drawn here only while they fade in.
    let views: Set<String>
    @Environment(\.themeTokens) private var theme

    private struct Item {
        let rect: CGRect
        let tint: Color?
        let title: String
        let selected: Bool
        let picture: NSImage?
        let shape: CanvasNodeShape?
        let invisible: Bool
        /// Free text is drawn at its own size, scaled, rather than as a title.
        let textSize: CGFloat?
        let textBold: Bool
        /// A shape's title sits in its middle.
        let centred: Bool
        /// A table: a sheet with its header band, no title.
        let table: Bool
        let sticky: Bool
        /// A drawing, relative to the card, and the card's size as written.
        let ink: CanvasInk?
        let natural: CGSize
        /// 1 for a card that is only drawn; fading out for one whose view is taking over.
        let opacity: Double
    }

    var body: some View {
        let camera = model.camera
        let scale = camera.scale
        let alpha = BoardModel.detailAlpha(scale)
        let nodes = model.visibleNodes().filter { $0.kind != .group }
        if alpha < 1 || nodes.contains(where: { !views.contains($0.id) }) {
            let offset = camera.offset
            let selection = model.selection
            let navigating = model.isNavigating
            let items: [Item] = BoardProfile.measure("farItems") { nodes.compactMap { node in
                let opacity = views.contains(node.id) ? 1 - alpha : 1
                guard opacity > 0.001 else { return nil }
                let frame = model.frame(of: node)
                let rect = CGRect(x: frame.x * scale + offset.width, y: frame.y * scale + offset.height,
                                  width: frame.width * scale, height: frame.height * scale)
                // Moving fast over many cards, titles wait: they are most of what is drawn.
                let wide = rect.width >= 36 && rect.height >= 18 && !(navigating && nodes.count > 80) && opacity == 1
                var picture: NSImage?
                if node.kind == .file, let file = node.file, CardFile.kind(of: file) == .image, rect.width >= 8 {
                    picture = model.store.smallImage(file)
                }
                return Item(rect: rect, tint: BoardStyle.color(node.color),
                            title: (wide || node.isFreeText) && picture == nil && !node.isTable && !node.isDrawing
                                ? model.store.title(of: node) : "",
                            selected: selection.contains(node.id), picture: picture,
                            shape: node.kind == .text ? node.shape : nil, invisible: node.border == .invisible || model.isBare(node),
                            textSize: node.isFreeText ? CGFloat(node.effectiveFontSize) * scale * Self.headingScale(node.text) : nil,
                            textBold: Self.headingScale(node.text) > 1,
                            centred: node.kind == .text && node.centresText,
                            table: node.isTable, sticky: node.isSticky,
                            ink: model.store.ink(node), natural: CGSize(width: node.width, height: node.height),
                            opacity: opacity)
            } }
            let paper = theme.background, edge = theme.text.opacity(0.22), text = theme.text, accent = theme.accent
            let fontSize = min(14, 9 + scale * 20).rounded()
            Canvas { context, _ in BoardProfile.measure("farDraw") {
                for item in items {
                    context.opacity = item.opacity
                    let corner = min(8, max(1.5, item.rect.width * 0.08))
                    let shape = item.shape == nil ? Path(roundedRect: item.rect, cornerRadius: Corners.r(corner))
                        : BoardShape(item.shape, radius: corner).path(in: item.rect)
                    if let picture = item.picture {
                        context.draw(context.resolve(Image(nsImage: picture)), in: item.rect)
                        context.stroke(shape, with: .color(item.selected ? accent : edge), lineWidth: item.selected ? 2 : 0.5)
                        continue
                    }
                    if let ink = item.ink {
                        var drawn = context
                        drawn.translateBy(x: item.rect.minX, y: item.rect.minY)
                        BoardInkPath.draw(ink, natural: item.natural, in: item.rect.size, context: drawn, text: text,
                                          lineScale: 1)
                        if item.selected {
                            context.stroke(Path(item.rect.insetBy(dx: -2, dy: -2)), with: .color(accent), lineWidth: 1)
                        }
                        continue
                    }
                    if item.table {
                        let header = CGRect(x: item.rect.minX, y: item.rect.minY, width: item.rect.width,
                                            height: min(item.rect.height, max(1, item.rect.height / 5)))
                        context.fill(shape, with: .color(paper))
                        context.fill(Path(header), with: .color(item.tint ?? accent))
                        context.stroke(shape, with: .color(item.selected ? accent : edge), lineWidth: item.selected ? 2 : 0.75)
                        continue
                    }
                    if item.invisible {
                        if item.selected { context.stroke(shape, with: .color(accent), lineWidth: 2) }
                    } else {
                        context.fill(shape, with: .color(paper))
                        if let tint = item.tint { context.fill(shape, with: .color(tint.opacity(item.sticky ? 0.78 : 0.28))) }
                        if item.rect.width >= 3 {
                            context.stroke(shape, with: .color(item.selected ? accent : item.tint?.opacity(0.8) ?? edge),
                                           lineWidth: item.selected ? 2 : 0.75)
                        } else if item.selected {
                            context.fill(shape, with: .color(accent))
                        }
                    }
                    guard !item.title.isEmpty else { continue }
                    if let size = item.textSize {
                        guard size >= 3 else { continue }
                        let resolved = context.resolve(Text(item.title)
                            .font(.ui(size: size, weight: item.textBold ? .bold : .regular)).foregroundStyle(text))
                        context.draw(resolved, in: item.rect.insetBy(dx: BoardStyle.freeTextPadding * scale, dy: 0))
                        continue
                    }
                    let resolved = context.resolve(Text(item.title).font(.ui(size: fontSize, weight: .semibold))
                        .foregroundStyle(text))
                    if item.centred {
                        let room = item.rect.insetBy(dx: 6, dy: 5)
                        let size = resolved.measure(in: room.size)
                        context.draw(resolved, in: CGRect(x: room.midX - size.width / 2, y: room.midY - size.height / 2,
                                                          width: size.width, height: size.height))
                        continue
                    }
                    context.draw(resolved, in: item.rect.insetBy(dx: 6, dy: 5))
                }
            } }
            .allowsHitTesting(false)
        }
    }
}

extension BoardFarCards {
    /// How much larger the first line of a text is drawn when it is a heading (as `NotePreviewView` draws them).
    static func headingScale(_ text: String?) -> CGFloat {
        let hashes = (text ?? "").prefix { $0 == "#" }.count
        guard (1...4).contains(hashes), (text ?? "").dropFirst(hashes).first == " " else { return 1 }
        return [1.75, 1.45, 1.25, 1.1][hashes - 1]
    }
}

extension BoardStore {
    /// A card's first line without its Markdown marks: what a far-away card says.
    func title(of node: CanvasNode) -> String {
        switch node.kind {
        case .file: return CardFile.title(of: node.file ?? "")
        case .link: return URL(string: node.url ?? "")?.host() ?? ""
        case .text:
            let text = node.text ?? ""
            if let known = titles[text] { return known }
            if titles.count > 4000 { titles.removeAll() }
            let first = text.split(separator: "\n", omittingEmptySubsequences: true).first.map {
                $0.trimmingCharacters(in: CharacterSet(charactersIn: "#*-> ").union(.whitespaces))
            } ?? ""
            titles[text] = first
            return first
        default: return ""
        }
    }

    /// A small copy of a picture (at most 192 points), cheap to draw by the hundred, read once.
    func smallImage(_ path: String) -> NSImage? {
        if let known = smalls[path] { return known.image }
        let url = vault.rootURL.appendingPathComponent(path)
        var image: NSImage?
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceCreateThumbnailWithTransform: true,
               kCGImageSourceThumbnailMaxPixelSize: 192,
           ] as CFDictionary) {
            image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
        smalls[path] = SmallImage(image: image)
        return image
    }
}
