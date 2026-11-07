import SwiftUI

/// The measurements of the left sidebar, shared by the shell's rows and the panels' so they line up. One place sets how
/// airy and how large the sidebar is: rows of 14 points on 34 high, icons of 20, medium titles (bold when selected),
/// section titles dimmer than the rows and set apart by a wide gap, every gap on a grid of 8. Every colour comes from
/// the theme's tokens, every corner from its `shape.corners` (a capsule in a round theme), every family from its
/// interface font, so a theme restyles it all.
public enum SidebarStyle {
    public static let rowHeight: CGFloat = 34
    public static let fontSize: CGFloat = 14
    /// Half the row's height: a capsule, unless the theme holds its corners to a smaller radius (`Corners.r`).
    public static let cornerRadius: CGFloat = 17
    /// A row's corner radius under the theme's corners: a capsule with `pill` ones.
    public static var radius: CGFloat { Corners.pill ? 999 : Corners.r(cornerRadius) }
    /// Inside a row, before its icon.
    public static let rowPadding: CGFloat = 12
    /// The column's own margin, left and right of the rows.
    public static let columnPadding: CGFloat = 12
    /// The side of a row's icon, drawn icons, folders and emoji alike: raise it and every icon grows with it.
    public static let iconSize: CGFloat = 20
    /// How much larger than the first, 17 point icons the sidebar's are, for pieces drawn at a fixed size (the folder).
    public static var iconScale: CGFloat { iconSize / 17 }
    /// Between a row's icon and its title.
    public static let iconGap: CGFloat = 10
    public static let titleWeight: Font.Weight = .medium
    public static let selectedWeight: Font.Weight = .bold
    /// The room above a section's title: the groups of the sidebar read as groups.
    public static let sectionGap: CGFloat = 24
    public static let sectionFontSize: CGFloat = 12.5
    /// Section titles are the dimmest text of the column, so the rows under them stand out.
    public static let sectionTitleOpacity: Double = 0.7
    /// The opacity of the theme's text colour for the rows' titles.
    public static let titleOpacity: Double = 0.82
    public static let selectedOpacity: Double = 0.07
    public static let hoveredOpacity: Double = 0.04
}

public extension ThemeTokens {
    /// Text and icons drawn on an accent fill (the selected row, "New"): white, unless the accent is so light that white
    /// would not read on it (a pale accent in a dark theme, Dither Green's mint), then a near black tinted with the accent.
    var onAccent: Color {
        guard let c = NSColor(accent).usingColorSpace(.sRGB) else { return .white }
        let fill = ThemeColor(red: Double(c.redComponent), green: Double(c.greenComponent), blue: Double(c.blueComponent))
        return fill.contrast(with: ThemeColor(red: 1, green: 1, blue: 1)) >= 3 ? .white : accent.mix(with: .black, by: 0.85)
    }

    /// The colour of a sidebar row's icon and count: the secondary text, `onAccent` on the selected row's accent pill.
    func sidebarAccessory(selected: Bool) -> Color {
        selected ? onAccent.opacity(0.9) : secondaryText
    }

    /// A sidebar row's symbol: its filled form on the selected row, when SF Symbols has one.
    func sidebarSymbol(_ name: String, selected: Bool) -> String {
        guard selected, !name.hasSuffix(".fill"), LoamSymbol.exists(name + ".fill") else { return name }
        return name + ".fill"
    }
}

public extension View {
    /// A sidebar row as Craft draws it: rounded, a light grey when selected or hovered. While a drop hovers it, it is
    /// tinted with the accent inside a dashed outline, with a "+" at its end: what is dropped goes in there. The row's text takes the soft row colour unless it sets its own.
    func sidebarRow(isSelected: Bool, isTargeted: Bool = false) -> some View {
        modifier(SidebarRowModifier(isSelected: isSelected, isTargeted: isTargeted))
    }

    /// A section title of the sidebar ("Folders", "Recent"): small, semibold, dimmer than the rows.
    func sidebarSectionTitle() -> some View {
        modifier(SidebarSectionTitleModifier())
    }
}

/// The thin line between the sidebar's groups (Craft's, under "New Document" and the navigation).
public struct SidebarSeparator: View {
    @Environment(\.themeTokens) private var theme

    public init() {}

    public var body: some View {
        Rectangle()
            .fill(theme.text.opacity(0.07))
            .frame(height: 1)
            .padding(.horizontal, SidebarStyle.rowPadding)
            .padding(.vertical, 5)
    }
}

private struct SidebarRowModifier: ViewModifier {
    let isSelected: Bool
    let isTargeted: Bool
    @State private var isHovered = false
    @Environment(\.themeTokens) private var theme

    func body(content: Content) -> some View {
        content
            .environment(\.sidebarRowHovered, isHovered)
            .environment(\.sidebarRowSelected, isSelected)
            .font(.ui(size: SidebarStyle.fontSize, weight: isSelected ? SidebarStyle.selectedWeight : SidebarStyle.titleWeight))
            .foregroundStyle(onAccent ? theme.onAccent : theme.text.opacity(SidebarStyle.titleOpacity))
            .padding(.horizontal, SidebarStyle.rowPadding)
            .frame(minHeight: SidebarStyle.rowHeight)
            .background {
                if onAccent {
                    SelectedRowPill()
                } else {
                    RoundedRectangle(cornerRadius: SidebarStyle.radius, style: .continuous).fill(fill)
                }
            }
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: SidebarStyle.radius, style: .continuous)
                        .strokeBorder(theme.accent.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .motionTransition(.opacity.combined(with: .scale(scale: 1.03)))
                }
            }
            .overlay(alignment: .trailing) {
                if isTargeted {
                    Image(symbol: "plus")
                        .font(.ui(size: 11, weight: .semibold))
                        .foregroundStyle(theme.accent)
                        .padding(.trailing, SidebarStyle.rowPadding)
                        .motionTransition(.opacity.combined(with: .scale(scale: 0.5)))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: SidebarStyle.radius, style: .continuous))
            .onHover { isHovered = $0 }
            .animation(Motion.hover, value: isHovered)
            .animation(Motion.hover, value: isSelected)
            .motion(.pop, value: isTargeted)
    }

    private var onAccent: Bool { isSelected && !isTargeted }

    private var fill: Color {
        if isTargeted { return theme.accent.opacity(0.14) }
        if isSelected { return theme.text.opacity(SidebarStyle.selectedOpacity) }
        // Cards answer the pointer in the accent: the sidebar's rows do too, so the app has one hover colour.
        if isHovered { return theme.accent.opacity(0.08) }
        return .clear
    }
}

private struct SidebarSectionTitleModifier: ViewModifier {
    @Environment(\.themeTokens) private var theme

    func body(content: Content) -> some View {
        content
            .themeLabel(size: SidebarStyle.sectionFontSize, weight: .semibold)
            .foregroundStyle(theme.secondaryText.opacity(SidebarStyle.sectionTitleOpacity))
            .padding(.horizontal, SidebarStyle.rowPadding)
            .padding(.top, SidebarStyle.sectionGap)
            .padding(.bottom, 8)
    }
}

/// The selected row: the accent fading lighter toward the right,
/// a fine grain of light dots gathering at its right end, a lit top edge and a soft glow of the accent under it, so
/// the selection reads as printed rather than as a flat block of colour.
private struct SelectedRowPill: View {
    @Environment(\.themeTokens) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SidebarStyle.radius, style: .continuous)
        ZStack {
            shape.fill(LinearGradient(
                colors: [theme.accent.opacity(0.94), theme.accent.mix(with: .white, by: 0.3).opacity(0.9)],
                startPoint: .leading, endPoint: .trailing
            ))
            HalftoneCloud(corner: .bottomTrailing, step: 2, seed: 41, color: .white.opacity(0.3))
                .clipShape(shape)
            shape.strokeBorder(
                LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom),
                lineWidth: 1
            )
        }
        .shadow(color: theme.accent.opacity(0.3), radius: 6, y: 2)
    }
}

/// The selected row's pill as a picture, for rows drawn in AppKit (the folder tree): the same view as `sidebarRow`
/// draws, rendered once per size, theme and scale. The picture is `margin` larger on each side, for the glow under it.
@MainActor
package enum SidebarPillImage {
    package static let margin: CGFloat = 10
    private static var cache: [String: CGImage] = [:]

    package static func image(size: CGSize, theme: ThemeTokens, scale: CGFloat) -> CGImage? {
        guard size.width >= 1, size.height >= 1 else { return nil }
        let key = "\(Int(size.width))x\(Int(size.height))|\(scale)|\(Corners.pill)|\(theme.accent)"
        if let known = cache[key] { return known }
        let renderer = ImageRenderer(content: SelectedRowPill()
            .frame(width: size.width, height: size.height)
            .padding(margin)
            .environment(\.themeTokens, theme))
        renderer.scale = scale
        guard let image = renderer.cgImage else { return nil }
        if cache.count > 32 { cache.removeAll() }
        cache[key] = image
        return image
    }
}
