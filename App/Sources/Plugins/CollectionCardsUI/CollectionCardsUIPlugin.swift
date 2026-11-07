import AppKit
import PluginKitUI
import SwiftUI

/// The gallery view of collections (`type: cards`, Obsidian's name), as Craft draws it: a grid of cards, each a
/// cover (the image the view's `image` field names, else the note drawn small) over the title and the shown fields.
public final class CollectionCardsUIPlugin: UIPlugin {
    public static let manifest = PluginManifest(
        id: "collection-cards",
        name: "Collection gallery",
        version: "0.1.0",
        description: "The Gallery view of a collection: a card per note, with a cover.",
        icon: "square.grid.2x2",
        optionalRequires: ["collections.views"],
        permissions: ["ui", "vault.read"]
    )

    public init() {}

    @MainActor public func activateUI(context: PluginContext) throws {
        let covers = CardCovers(vault: context.vault)
        // The gallery is AppKit (`GalleryScrollView`), in a page and in a note alike.
        var type = CollectionViewType(
            id: "cards",
            title: "Gallery",
            symbol: "square.grid.2x2",
            order: 2,
            defaults: { definition, view in
                [.setOrder(view: view, order: [.title] + definition.properties.map(\.ref).filter { $0.namespace == .note })]
            }
        ) { model in
            AnyView(NativeView { GalleryScrollView(model: model, covers: covers) })
        }
        type.makeNSView = { model in GalleryScrollView(model: model, covers: covers) }
        context.addCollectionView(type)
    }
}

/// What a card's cover shows, read once per change of the note. A picture is only found here: it is decoded off the
/// main thread by the card (`DitheredThumbnail`).
@MainActor
final class CardCovers {
    enum Cover {
        case image(URL)
        case preview(NotePreview)
    }

    private let vault: VaultAccess
    private var cache: [String: (modified: Double, field: String?, cover: Cover)] = [:]

    init(vault: VaultAccess) {
        self.vault = vault
    }

    func cover(of entry: NoteRecord, imageField: String?) -> Cover {
        if let cached = cache[entry.path], cached.modified == entry.modified, cached.field == imageField { return cached.cover }
        let text = (try? vault.read(entry.path)) ?? ""
        let cover = (image(of: entry, field: imageField) ?? firstImage(in: text, of: entry)).map(Cover.image)
            ?? .preview(NotePreview.parse(text, title: entry.title, limit: 12))
        cache[entry.path] = (entry.modified, imageField, cover)
        return cover
    }

    /// The image a field names: a vault path (relative to the note, or a `[label](path)` / `![[path]]` link).
    private func image(of entry: NoteRecord, field: String?) -> URL? {
        guard let field, case .string(var text)? = PropertyComparison.property(field, of: entry.properties) else { return nil }
        if let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")"), open < close {
            text = String(text[text.index(after: open)..<close])
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "![] "))
        return load(text, from: entry)
    }

    /// The body's first embedded image, `![alt](path)` or `![[path|size]]`, when no field names one.
    private func firstImage(in text: String, of entry: NoteRecord) -> URL? {
        guard let regex = Self.embed else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            for group in 1...2 {
                guard let r = Range(match.range(at: group), in: text) else { continue }
                let path = String(text[r]).removingPercentEncoding ?? String(text[r])
                if let image = load(path.trimmingCharacters(in: .whitespaces), from: entry) { return image }
            }
        }
        return nil
    }

    private static let embed = try? NSRegularExpression(pattern: #"!\[\[([^\]|#]+)[^\]]*\]\]|!\[[^\]]*\]\(<?([^)>\s]+)>?(?:\s+"[^"]*")?\)"#)

    /// The picture file a path names, relative to the note or to the vault; nil when none is there.
    private func load(_ text: String, from entry: NoteRecord) -> URL? {
        for candidate in [(try? VaultPath.resolve(text, from: entry.path)), (try? VaultPath.normalize(text))].compactMap({ $0 }) {
            let url = vault.rootURL.appendingPathComponent(candidate)
            if DitheredThumbnails.isPicture(url), FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }
}
