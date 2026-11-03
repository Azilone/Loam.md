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
        context.addCollectionView(CollectionViewType(
            id: "cards",
            title: "Gallery",
            symbol: "square.grid.2x2",
            order: 2,
            defaults: { definition, view in
                [.setOrder(view: view, order: [.title] + definition.properties.map(\.ref).filter { $0.namespace == .note })]
            }
        ) { model in
            AnyView(CollectionCardsView(model: model, covers: covers))
        })
    }
}

/// What a card's cover shows, read once per change of the note.
@MainActor
final class CardCovers {
    enum Cover {
        case image(NSImage)
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
    private func image(of entry: NoteRecord, field: String?) -> NSImage? {
        guard let field, case .string(var text)? = PropertyComparison.property(field, of: entry.properties) else { return nil }
        if let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")"), open < close {
            text = String(text[text.index(after: open)..<close])
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "![] "))
        return load(text, from: entry)
    }

    /// The body's first embedded image, `![alt](path)` or `![[path|size]]`, when no field names one.
    private func firstImage(in text: String, of entry: NoteRecord) -> NSImage? {
        let pattern = #"!\[\[([^\]|#]+)[^\]]*\]\]|!\[[^\]]*\]\(<?([^)>\s]+)>?(?:\s+"[^"]*")?\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
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

    private func load(_ text: String, from entry: NoteRecord) -> NSImage? {
        for candidate in [(try? VaultPath.resolve(text, from: entry.path)), (try? VaultPath.normalize(text))].compactMap({ $0 }) {
            let url = vault.rootURL.appendingPathComponent(candidate)
            if let image = NSImage(contentsOf: url) { return image }
        }
        return nil
    }
}

struct CollectionCardsView: View {
    let model: CollectionViewModel
    let covers: CardCovers
    @Environment(\.themeTokens) private var theme
    /// True once the first cards have cascaded in; later ones (added, re-sorted) do not wait their turn.
    @State private var settled = false

    private var imageField: String? {
        if case .string(let field)? = model.view?.options["image"] { return PropertyRef(field).name }
        return nil
    }

    var body: some View {
        let entries = model.entries
        ScrollView {
            if entries.isEmpty {
                CollectionEmptyState(model: model, symbol: "square.grid.2x2")
                    .collectionTransition(.opacity)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: 260), spacing: 14, alignment: .top)],
                      alignment: .leading, spacing: 14) {
                ForEach(Array(entries.enumerated()), id: \.element.path) { index, entry in
                    GalleryCard(model: model, entry: entry, cover: covers.cover(of: entry, imageField: imageField))
                        .cascadeIn(index: settled ? nil : index)
                        .collectionTransition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.94)), removal: CollectionMotion.leave))
                }
            }
            // Room for the cards' shadow and lift, which the scroll view would otherwise cut.
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 24)
            // Sorting, filtering, adding and removing slide the cards into place.
            .collectionAnimation(value: entries.map(\.path))
        }
        .softScrollEdges()
        .task {
            try? await Task.sleep(for: .milliseconds(600))
            settled = true
        }
    }
}

/// A card: the cover on a light grey band, a hairline, then the title and the fields as pills.
struct GalleryCard: View {
    let model: CollectionViewModel
    let entry: NoteRecord
    let cover: CardCovers.Cover
    @State private var probe = OpenOriginProbe()
    @Environment(\.themeTokens) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            coverView
                .frame(height: 124)
                .frame(maxWidth: .infinity)
                .clipped()
                .background(theme.text.opacity(0.03))
            Rectangle().fill(theme.separator.opacity(0.5)).frame(height: 1)
            VStack(alignment: .leading, spacing: 8) {
                Text(entry.title)
                    .font(.ui(size: 15, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .lineLimit(2)
                ForEach(model.fields, id: \.self) { ref in
                    if let value = model.value(ref, of: entry) {
                        PropertyValueView(value, kind: model.kind(ref), options: model.property(ref).options)
                            .font(.ui(size: 13))
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .clipShape(RoundedRectangle(cornerRadius: Corners.r(12), style: .continuous))
        // The same card as the folder pages': rises, turns toward the pointer, ring in the accent, deeper shadow.
        .interactiveNoteCard(cornerRadius: Corners.r(12))
        .opensFrom(probe)
        .tappableRow { model.open(entry.path, placement: NSEvent.modifierFlags.contains(.command) ? .newTab : .replace, from: probe.origin) }
        .draggableResource(.file(entry.path))
        .help("Open \(entry.title)")
    }

    @ViewBuilder private var coverView: some View {
        switch cover {
        case .image(let image):
            Image(nsImage: ImageDither.dithered(image, style: theme.dither)).resizable().scaledToFill()
        case .preview(let preview):
            if preview.blocks.isEmpty {
                Color.clear
            } else {
                NotePreviewView(preview)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .mask(LinearGradient(colors: [.black, .black, .clear], startPoint: .top, endPoint: .bottom))
            }
        }
    }
}
