import SwiftUI

/// The bricks of the right sidebar, shared by every plugin so that a note's, a mindmap's and a board's sidebars read
/// as one design: titled groups over white cards of rows, tiles that show an option rather than name it, segmented
/// pickers, colour dots and switches. An option shows itself (a tile, a colour) rather than explains itself.
public enum InspectorStyle {
    /// The column's margin, left and right.
    public static let padding: CGFloat = 16
    /// Between two groups.
    public static let groupSpacing: CGFloat = 20
    public static let cardRadius: CGFloat = 12
    public static let rowHeight: CGFloat = 36
    public static let tileHeight: CGFloat = 64
    public static let tileSpacing: CGFloat = 8
    public static let fontSize: CGFloat = 13
}

// MARK: Group

/// A titled group: a 13 point title, an optional grey note at its right ("3 headings", "click to hide"), then its
/// content.
public struct InspectorGroup<Content: View>: View {
    let title: String?
    let accessory: String?
    let content: Content
    @Environment(\.themeTokens) private var theme

    public init(_ title: String? = nil, accessory: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = accessory
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if title != nil || accessory != nil {
                HStack(alignment: .firstTextBaseline) {
                    if let title {
                        Text(title.uiLocalized)
                            .font(.ui(size: 13, weight: .semibold))
                            .foregroundStyle(theme.text.opacity(0.9))
                            .accessibilityAddTraits(.isHeader)
                    }
                    Spacer(minLength: 8)
                    if let accessory {
                        Text(accessory)
                            .font(.ui(size: 11))
                            .foregroundStyle(theme.secondaryText.opacity(0.8))
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 2)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Card and rows

/// The white rounded surface the rows and swatches sit on, raised a little from the sidebar's grey.
public struct InspectorCard<Content: View>: View {
    let padding: CGFloat
    let content: Content

    public init(padding: CGFloat = 4, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .inspectorSurface()
    }
}

public extension View {
    /// The look of a card or a tile: white (a light tint in dark mode), rounded, a hairline ring and a soft shadow;
    /// with `isSelected`, an accent ring.
    func inspectorSurface(isSelected: Bool = false, radius: CGFloat = InspectorStyle.cardRadius) -> some View {
        modifier(InspectorSurface(isSelected: isSelected, radius: radius))
    }
}

private struct InspectorSurface: ViewModifier {
    let isSelected: Bool
    let radius: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.themeTokens) private var theme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Corners.r(radius), style: .continuous)
        content
            .background {
                shape
                    .fill(colorScheme == .dark ? Color.white.opacity(0.07) : .white)
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.05), radius: 2, y: 1)
            }
            .overlay {
                shape.strokeBorder(
                    isSelected ? theme.accent : theme.text.opacity(colorScheme == .dark ? 0.08 : 0.05),
                    lineWidth: isSelected ? 2 : 1
                )
            }
    }
}

/// One line of a card: an optional coloured dot or symbol, a title, an optional grey number or trailing view.
/// With an action it highlights under the pointer; `isSelected` tints it with the accent.
public struct InspectorRow<Trailing: View>: View {
    let title: String
    let dot: Color?
    let symbol: String?
    let isSelected: Bool
    let isDimmed: Bool
    let action: (() -> Void)?
    let trailing: Trailing
    @State private var isHovered = false
    @Environment(\.themeTokens) private var theme

    public init(
        _ title: String, dot: Color? = nil, symbol: String? = nil, isSelected: Bool = false, isDimmed: Bool = false,
        action: (() -> Void)? = nil, @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.dot = dot
        self.symbol = symbol
        self.isSelected = isSelected
        self.isDimmed = isDimmed
        self.action = action
        self.trailing = trailing()
    }

    public var body: some View {
        let row = HStack(spacing: 10) {
            if let dot {
                Circle()
                    .fill(isDimmed ? Color.clear : dot)
                    .overlay { if isDimmed { Circle().strokeBorder(dot, lineWidth: 1.5) } }
                    .frame(width: 8, height: 8)
            }
            if let symbol {
                Image(symbol: symbol)
                    .font(.ui(size: 12))
                    .foregroundStyle(isSelected ? theme.accent : theme.secondaryText)
                    .frame(width: 16)
            }
            Text(title.uiLocalized)
                .font(.ui(size: InspectorStyle.fontSize, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? theme.accent : theme.text.opacity(isDimmed ? 0.4 : 0.85))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            trailing
                .font(.ui(size: 12))
                .foregroundStyle(theme.secondaryText.opacity(0.8))
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .frame(minHeight: InspectorStyle.rowHeight)
        .background {
            RoundedRectangle(cornerRadius: Corners.r(8), style: .continuous)
                .fill(isSelected ? theme.accent.opacity(0.1) : theme.text.opacity(isHovered && action != nil ? 0.04 : 0))
        }
        .animation(Motion.hover, value: isHovered)
        .animation(Motion.hover, value: isSelected)

        if let action {
            row
                .onHover { isHovered = $0 }
                .tappableRow(action)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else {
            row.accessibilityElement(children: .combine)
        }
    }
}

public extension InspectorRow where Trailing == InspectorCount {
    /// A row with a grey number at its end (nil for none).
    init(
        _ title: String, dot: Color? = nil, symbol: String? = nil, count: Int? = nil, isSelected: Bool = false,
        isDimmed: Bool = false, action: (() -> Void)? = nil
    ) {
        self.init(
            title, dot: dot, symbol: symbol, isSelected: isSelected, isDimmed: isDimmed, action: action,
            trailing: { InspectorCount(value: count) }
        )
    }
}

/// The grey number at the end of a row.
public struct InspectorCount: View {
    let value: Int?
    public init(value: Int?) { self.value = value }
    public var body: some View {
        if let value { Text("\(value)") }
    }
}

/// A row whose end is a short bar, its length the value's share of the largest (Craft's "most linked").
public struct InspectorBarRow: View {
    let title: String
    let value: Int
    let maximum: Int
    let color: Color
    let action: (() -> Void)?

    public init(_ title: String, value: Int, maximum: Int, color: Color, action: (() -> Void)? = nil) {
        self.title = title
        self.value = value
        self.maximum = maximum
        self.color = color
        self.action = action
    }

    public var body: some View {
        InspectorRow(title, action: action) {
            HStack(spacing: 10) {
                ThemeCapsule()
                    .fill(color)
                    .frame(width: 64 * CGFloat(value) / CGFloat(max(maximum, 1)), height: 3)
                    .frame(width: 64, alignment: .trailing)
                Text("\(value)").frame(minWidth: 14, alignment: .trailing)
            }
        }
    }
}

/// A row with a switch at its end.
public struct InspectorToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    public init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        _isOn = isOn
    }

    public var body: some View {
        InspectorRow(title) {
            // The loam style draws its label beside the switch, so it gets none: the row already shows the title.
            Toggle(isOn: $isOn.animation(Motion.Spring.tap.animation)) { EmptyView() }
                .accessibilityLabel(title)
                .toggleStyle(.loam)
        }
    }
}

// MARK: Tiles

/// A grid of tiles, three to a row (two for wide pictures).
public struct InspectorTileGrid<Content: View>: View {
    let columns: Int
    let content: Content

    public init(columns: Int = 3, @ViewBuilder content: () -> Content) {
        self.columns = columns
        self.content = content()
    }

    public var body: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: InspectorStyle.tileSpacing), count: columns
            ),
            spacing: InspectorStyle.tileSpacing
        ) { content }
    }
}

/// A tile: a picture of the option over its name. Selected, it takes an accent ring and an accent name.
public struct InspectorTile<Picture: View>: View {
    let title: String
    let isSelected: Bool
    let height: CGFloat
    let action: () -> Void
    let picture: Picture
    @State private var isHovered = false
    @State private var isPressed = false
    @Environment(\.themeTokens) private var theme

    public init(
        _ title: String, isSelected: Bool = false, height: CGFloat = InspectorStyle.tileHeight,
        action: @escaping () -> Void, @ViewBuilder picture: () -> Picture
    ) {
        self.title = title
        self.isSelected = isSelected
        self.height = height
        self.action = action
        self.picture = picture()
    }

    public var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                picture
                    .foregroundStyle(isSelected ? theme.accent : theme.text.opacity(0.8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text(title.uiLocalized)
                    .font(.ui(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? theme.accent : theme.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .padding(.top, 10)
            .padding(.bottom, 8)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .inspectorSurface(isSelected: isSelected)
            .overlay {
                RoundedRectangle(cornerRadius: Corners.r(InspectorStyle.cardRadius), style: .continuous)
                    .fill(theme.text.opacity(isHovered && !isSelected ? 0.025 : 0))
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: Corners.r(InspectorStyle.cardRadius), style: .continuous))
        }
        .buttonStyle(.press)
        .onHover { isHovered = $0 }
        .animation(Motion.hover, value: isHovered)
        .animation(Motion.Spring.tap.animation, value: isSelected)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

public extension InspectorTile where Picture == InspectorSymbol {
    /// A tile drawn with an SF Symbol.
    init(
        _ title: String, symbol: String, isSelected: Bool = false, height: CGFloat = InspectorStyle.tileHeight,
        action: @escaping () -> Void
    ) {
        self.init(title, isSelected: isSelected, height: height, action: action) { InspectorSymbol(name: symbol) }
    }
}

/// The symbol of a tile, at the tiles' size.
public struct InspectorSymbol: View {
    let name: String
    public init(name: String) { self.name = name }
    public var body: some View {
        Image(symbol: name).font(.ui(size: 17, weight: .regular))
    }
}


// MARK: Figures

/// A count as a large figure, as Bear's statistics: the value, its symbol at the top right, its name under it.
public struct InspectorFigure: View {
    let value: String
    let label: String
    let symbol: String
    @Environment(\.themeTokens) private var theme

    public init(_ value: String, _ label: String, symbol: String) {
        self.value = value
        self.label = label
        self.symbol = symbol
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(value)
                    .font(.ui(size: 22, weight: .bold))
                    .foregroundStyle(theme.text)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer(minLength: 4)
                Image(symbol: symbol)
                    .font(.ui(size: 13))
                    .foregroundStyle(theme.secondaryText.opacity(0.7))
            }
            Text(label.uiLocalized)
                .font(.ui(size: 12))
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .inspectorSurface()
        .accessibilityElement(children: .combine)
    }
}

// MARK: Segmented

/// A segmented picker as Craft draws it: a grey track, the chosen segment a white raised plate that slides.
public struct InspectorSegmented<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    let isProminent: Bool
    @Namespace private var namespace
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.themeTokens) private var theme

    /// - Parameter isProminent: the larger form, for the sidebar's own tabs.
    public init(_ options: [(value: Value, title: String)], selection: Binding<Value>, isProminent: Bool = false) {
        self.options = options
        _selection = selection
        self.isProminent = isProminent
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { option in
                let isSelected = option.value == selection
                Button {
                    withAnimation(Motion.reduceMotion ? Motion.fade : Motion.Spring.tap.animation) {
                        selection = option.value
                    }
                } label: {
                    Text(option.title.uiLocalized)
                        .font(.ui(size: isProminent ? 13 : 12, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? theme.text : theme.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .frame(height: isProminent ? 28 : 26)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: Corners.r(8), style: .continuous)
                                    .fill(colorScheme == .dark ? Color.white.opacity(0.14) : .white)
                                    .shadow(color: .black.opacity(0.08), radius: 1.5, y: 1)
                                    .matchedGeometryEffect(id: "plate", in: namespace)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: Corners.r(10), style: .continuous).fill(theme.text.opacity(0.055)))
    }
}

// MARK: Colours

/// A card of colour dots, the chosen one ringed. `nil` is the "none" choice when `allowsNone`.
public struct InspectorSwatches<ID: Hashable>: View {
    let colors: [(id: ID, color: Color, name: String)]
    let selection: ID?
    let select: (ID) -> Void

    public init(_ colors: [(id: ID, color: Color, name: String)], selection: ID?, select: @escaping (ID) -> Void) {
        self.colors = colors
        self.selection = selection
        self.select = select
    }

    public var body: some View {
        InspectorCard(padding: 10) {
            HStack(spacing: 0) {
                ForEach(colors, id: \.id) { swatch in
                    let isSelected = swatch.id == selection
                    Button { select(swatch.id) } label: {
                        Circle()
                            .fill(swatch.color)
                            .frame(width: 22, height: 22)
                            .padding(3)
                            .overlay { Circle().strokeBorder(isSelected ? swatch.color : .clear, lineWidth: 2) }
                            .contentShape(Circle())
                    }
                    .buttonStyle(.press)
                    .frame(maxWidth: .infinity)
                    .help(swatch.name)
                    .accessibilityLabel(swatch.name)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .animation(Motion.Spring.tap.animation, value: selection)
        }
    }
}

/// The palette plugins share for their groups and branches, in the order they are handed out.
public enum InspectorPalette {
    public static let colors: [Color] = [
        Color(red: 0.20, green: 0.42, blue: 0.93),
        Color(red: 0.13, green: 0.62, blue: 0.47),
        Color(red: 0.55, green: 0.38, blue: 0.93),
        Color(red: 0.95, green: 0.55, blue: 0.13),
        Color(red: 0.90, green: 0.27, blue: 0.27),
        Color(red: 0.96, green: 0.80, blue: 0.25),
        Color(red: 0.55, green: 0.56, blue: 0.58),
    ]

    /// The colour of the `index`th group, cycling.
    public static func color(_ index: Int) -> Color { colors[((index % colors.count) + colors.count) % colors.count] }
}

// MARK: Empty state

/// What a group shows when it has nothing: a soft, quiet card with the group's symbol over a short line, so an empty
/// group still reads as a place things will land rather than a stray caption.
public struct InspectorEmpty: View {
    let text: String
    let systemImage: String?
    @Environment(\.themeTokens) private var theme
    @Environment(\.colorScheme) private var colorScheme
    public init(_ text: String, systemImage: String? = nil) {
        self.text = text
        self.systemImage = systemImage
    }
    public var body: some View {
        VStack(spacing: 8) {
            if let systemImage {
                Image(symbol: systemImage)
                    .font(.ui(size: 13, weight: .medium))
                    .foregroundStyle(theme.secondaryText.opacity(0.9))
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: Corners.r(10), style: .continuous).fill(theme.background))
                    .overlay(RoundedRectangle(cornerRadius: Corners.r(10), style: .continuous).strokeBorder(theme.text.opacity(0.08)))
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.04), radius: 3, y: 1)
                    .accessibilityHidden(true)
            }
            Text(text.uiLocalized)
                .font(.ui(size: 12))
                .foregroundStyle(theme.secondaryText.opacity(0.85))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, systemImage == nil ? 12 : 16)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: Corners.r(12), style: .continuous)
            .fill(theme.text.opacity(colorScheme == .dark ? 0.04 : 0.03)))
    }
}
