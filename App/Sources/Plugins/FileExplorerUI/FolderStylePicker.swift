import AppKit
import PluginKitUI
import SwiftUI

/// A folder's "Icon & Color" popover, Craft's two pickers in one: the colours on top, then a search field over SF
/// Symbols and, under them, the emoji. A pick applies at once; "Reset" gives the folder its default look back.
struct FolderStylePicker: View {
    let model: ExplorerModel
    let path: String
    @State private var query = ""
    @Environment(\.themeTokens) private var theme

    private var style: FolderStyle { model.folderStyle(path) }
    private var color: Color { FolderTint.color(for: path) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            colors
            Divider()
            TextField("Search Icons", text: $query)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    let symbols = FolderIconCatalog.symbols(matching: query)
                    if !symbols.isEmpty {
                        grid(symbols) { name in
                            Image(symbol: name).font(.ui(size: 15)).foregroundStyle(color)
                        }
                    }
                    let emoji = FolderIconCatalog.emoji(matching: query)
                    if !emoji.isEmpty {
                        Text("EMOJI")
                            .font(.ui(size: 11, weight: .semibold))
                            .foregroundStyle(theme.secondaryText)
                            .padding(.top, 4)
                        grid(emoji) { ThemedEmoji(emoji: $0, size: 18) }
                    }
                }
            }
            .frame(height: 300)
            HStack {
                Spacer()
                Button("Reset") { model.setFolderStyle(path, FolderStyle()) }
                    .disabled(style.isEmpty)
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private var colors: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 10), count: 6), spacing: 10) {
            ForEach(FolderTint.palette, id: \.self) { hex in
                let selected = style.color == hex
                Button {
                    model.setFolderStyle(path, FolderStyle(icon: style.icon, color: selected ? nil : hex))
                } label: {
                    Circle()
                        .fill(FolderTint.color(hex: hex) ?? .gray)
                        .frame(width: 24, height: 24)
                        .padding(2)
                        .overlay(Circle().strokeBorder(selected ? theme.text.opacity(0.5) : .clear, lineWidth: 2))
                }
                .buttonStyle(.plain)
                .help(hex)
            }
        }
    }

    private func grid<Cell: View>(_ icons: [String], @ViewBuilder cell: @escaping (String) -> Cell) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 6), count: 8), spacing: 6) {
            ForEach(icons, id: \.self) { icon in
                let selected = style.icon == icon
                Button {
                    model.setFolderStyle(path, FolderStyle(icon: icon, color: style.color))
                } label: {
                    cell(icon)
                        .frame(width: 30, height: 30)
                        .background(RoundedRectangle(cornerRadius: Corners.r(6)).fill(selected ? theme.text.opacity(0.12) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// The icons a folder can take: a set of SF Symbols (the library Craft's picker uses) and every emoji, searched by
/// name.
enum FolderIconCatalog {
    static let allSymbols: [String] = [
        "folder", "folder.fill", "tray", "tray.full", "tray.2", "archivebox", "shippingbox", "cube", "square.stack.3d.up",
        "doc.text", "doc.on.doc", "note.text", "book", "book.closed", "books.vertical", "text.book.closed", "bookmark",
        "magazine", "newspaper", "graduationcap", "studentdesk", "pencil", "highlighter", "paintbrush", "paintpalette",
        "scribble", "lightbulb", "brain", "brain.head.profile", "sparkles", "wand.and.stars", "star", "heart",
        "flame", "bolt", "leaf", "tree", "globe", "globe.europe.africa", "map", "mappin", "location", "airplane",
        "car", "tram", "bicycle", "figure.walk", "figure.run", "dumbbell", "sportscourt", "soccerball", "tennisball",
        "trophy", "medal", "flag", "flag.checkered", "target", "scope", "chart.bar", "chart.pie", "chart.line.uptrend.xyaxis",
        "list.bullet", "checklist", "checkmark.circle", "calendar", "clock", "alarm", "hourglass", "timer",
        "waveform", "mic", "headphones", "music.note", "music.mic", "guitars", "pianokeys", "film", "tv", "camera",
        "photo", "video", "play.rectangle", "gamecontroller", "puzzlepiece", "theatermasks", "paintbrush.pointed",
        "person", "person.2", "person.3", "figure.2.and.child.holdinghands", "house", "building.2", "building.columns",
        "briefcase", "case", "bag", "cart", "creditcard", "banknote", "dollarsign.circle", "eurosign.circle",
        "chart.bar.doc.horizontal", "doc.richtext", "envelope", "paperplane", "bubble.left", "bubble.left.and.bubble.right",
        "phone", "megaphone", "bell", "link", "paperclip", "pin", "tag", "key", "lock", "shield", "hammer",
        "wrench.and.screwdriver", "gearshape", "cpu", "desktopcomputer", "laptopcomputer", "iphone", "keyboard",
        "terminal", "chevron.left.forwardslash.chevron.right", "curlybraces", "server.rack", "externaldrive", "icloud",
        "network", "antenna.radiowaves.left.and.right", "atom", "flask", "testtube.2", "stethoscope", "cross.case",
        "pills", "heart.text.square", "bed.double", "fork.knife", "cup.and.saucer", "carrot", "birthday.cake",
        "gift", "balloon", "party.popper", "pawprint", "hare", "tortoise", "bird", "fish", "ant", "ladybug",
        "sun.max", "moon", "cloud", "cloud.rain", "snowflake", "drop", "mountain.2", "beach.umbrella", "tent",
        "sailboat", "crown", "diamond", "seal", "rosette", "infinity", "questionmark.circle", "exclamationmark.triangle",
        "eye", "hand.raised", "hand.thumbsup", "face.smiling", "lasso", "square.grid.2x2", "rectangle.3.group",
        "circle.grid.3x3", "point.3.connected.trianglepath.dotted", "map.fill", "signpost.right", "lifepreserver",
    ]

    /// The symbols this Mac draws, so an older macOS shows no empty cells.
    static let symbols: [String] = allSymbols.filter { NSImage.symbol($0, accessibilityDescription: nil) != nil }

    /// Every emoji that stands on its own (one code point drawn as an emoji), in Unicode's order.
    static let emoji: [(text: String, name: String)] = {
        let ranges: [ClosedRange<UInt32>] = [0x1F300...0x1F5FF, 0x1F600...0x1F64F, 0x1F680...0x1F6FF, 0x1F900...0x1F9FF, 0x1FA70...0x1FAFF, 0x2600...0x27BF]
        return ranges.flatMap { $0 }.compactMap { value in
            guard let scalar = Unicode.Scalar(value), scalar.properties.isEmojiPresentation,
                  !scalar.properties.isEmojiModifier else { return nil }
            return (String(Character(scalar)), (scalar.properties.name ?? "").lowercased())
        }
    }()

    /// The symbols whose name holds every word of `query` ("cal" finds the calendar).
    static func symbols(matching query: String) -> [String] {
        let words = words(query)
        guard !words.isEmpty else { return symbols }
        return symbols.filter { name in words.allSatisfy { name.contains($0) } }
    }

    /// The emoji whose Unicode name holds every word of `query`; an emoji typed in the field is offered itself.
    static func emoji(matching query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if FolderIcon.isEmoji(trimmed) { return [trimmed] }
        let words = words(query)
        guard !words.isEmpty else { return emoji.map(\.text) }
        return emoji.filter { item in words.allSatisfy { item.name.contains($0) } }.map(\.text)
    }

    private static func words(_ query: String) -> [String] {
        query.lowercased().split(whereSeparator: { $0 == " " || $0 == "." }).map(String.init)
    }
}
