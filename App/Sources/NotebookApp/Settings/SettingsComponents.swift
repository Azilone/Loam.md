import AppKit
import PluginKitUI
import SwiftUI

/// The measurements of Craft's settings, shared by every pane: a centred column of titled groups, each a light grey
/// rounded card of rows separated by hairlines.
enum SettingsStyle {
    /// The widest the column of groups gets; the page centres it.
    static let columnWidth: CGFloat = PageWidth.reading.maxWidth
    static let groupRadius: CGFloat = 14
    static let rowPadding: CGFloat = 14
    static let rowHeight: CGFloat = 40
    static let titleSize: CGFloat = UIType.body.size
    static let detailSize: CGFloat = UIType.label.size
    /// The room between two sections.
    static let sectionSpacing: CGFloat = Space.xl
}

/// A pane of the settings window: its toolbar (Back on a sub-page, the title, the parent's name under it) over a
/// scrolling column of sections.
struct SettingsPage<Content: View>: View {
    let title: String
    /// The page this one was opened from, shown under the title ("Plugins"); nil on a top page.
    var parent: String?
    var back: (() -> Void)?
    @ViewBuilder let content: () -> Content
    @Environment(\.themeTokens) private var theme
    @Environment(\.settingsNavigation) private var navigation
    @State private var position = ScrollPosition(edge: .top)
    /// False until the kept offset is back: a page rebuilt at the top must not overwrite it first.
    @State private var restored = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsStyle.sectionSpacing) {
                content()
            }
            .frame(maxWidth: SettingsStyle.columnWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, PageMetrics.edge)
            .padding(.top, Space.m)
            .padding(.bottom, Space.xxl)
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y + $0.contentInsets.top }) { _, offset in
            if restored { navigation?.scrollOffsets[title] = offset }
        }
        .task {
            // After the first layout, when the content is tall enough to scroll there.
            if let offset = navigation?.scrollOffsets[title], offset > 0 {
                await Task.yield()
                position.scrollTo(y: offset)
            }
            restored = true
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .safeAreaBar(edge: .top, spacing: 0) {
            HStack(spacing: 12) {
                if let back {
                    PageToolbarButton(title: String(localized: "Back"), symbol: "chevron.left", size: 15, weight: .regular) {
                        back()
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title.uiLocalized)
                        .font(.ui(.emphasis))
                        .foregroundStyle(theme.text)
                    if let parent {
                        Text(parent)
                            .font(.ui(.caption))
                            .foregroundStyle(theme.secondaryText)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: PageToolbar.height)
        }
    }
}

/// A titled group of rows: a semibold title with an optional grey line under it, then the rows on a light grey
/// rounded card, a hairline between two rows. A section whose rows are all empty draws nothing.
struct SettingsSection<Content: View>: View {
    var title: String?
    var subtitle: String?
    @ViewBuilder let content: () -> Content
    @Environment(\.themeTokens) private var theme

    var body: some View {
        Group(subviews: content()) { rows in
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    if title != nil || subtitle != nil {
                        VStack(alignment: .leading, spacing: 3) {
                            if let title {
                                Text(title.uiLocalized)
                                    .font(.ui(size: SettingsStyle.titleSize, weight: .semibold))
                                    .foregroundStyle(theme.text)
                            }
                            if let subtitle {
                                Text(subtitle.uiLocalized)
                                    .font(.ui(size: SettingsStyle.detailSize))
                                    .foregroundStyle(theme.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.horizontal, 6)
                    }
                    VStack(spacing: 0) {
                        ForEach(rows) { row in
                            row
                            if row.id != rows.last?.id {
                                SettingsDivider()
                            }
                        }
                    }
                    .settingsGroup()
                }
            }
        }
    }
}

extension View {
    /// The light grey rounded card of a settings group.
    func settingsGroup() -> some View {
        modifier(SettingsGroupModifier())
    }
}

private struct SettingsGroupModifier: ViewModifier {
    @Environment(\.themeTokens) private var theme
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                theme.text.opacity(colorScheme == .dark ? 0.07 : 0.045),
                in: .rect(cornerRadius: Corners.r(SettingsStyle.groupRadius), style: .continuous)
            )
    }
}

/// The hairline between two rows of a group, inset from the left as Craft's.
struct SettingsDivider: View {
    @Environment(\.themeTokens) private var theme
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle()
            .fill(theme.text.opacity(0.08))
            .frame(height: 1 / max(displayScale, 1))
            .padding(.leading, SettingsStyle.rowPadding)
    }
}

/// A row of a settings group: an optional icon, a title with an optional line of detail under it, and a control on
/// the right (a switch, a picker, a blue action, a chevron).
struct SettingsRow<Icon: View, Trailing: View>: View {
    let title: String
    var detail: String?
    var detailColor: Color?
    @ViewBuilder let icon: () -> Icon
    @ViewBuilder let trailing: () -> Trailing
    @Environment(\.themeTokens) private var theme

    var body: some View {
        HStack(spacing: 12) {
            icon()
            VStack(alignment: .leading, spacing: 2) {
                Text(title.uiLocalized)
                    .font(.ui(size: SettingsStyle.titleSize))
                    .foregroundStyle(theme.text.opacity(0.88))
                if let detail, !detail.isEmpty {
                    Text(detail.uiLocalized)
                        .font(.ui(size: SettingsStyle.detailSize))
                        .foregroundStyle(detailColor ?? theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .padding(.horizontal, SettingsStyle.rowPadding)
        .padding(.vertical, 9)
        .frame(minHeight: SettingsStyle.rowHeight)
    }
}

extension SettingsRow where Icon == EmptyView {
    init(title: String, detail: String? = nil, detailColor: Color? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.init(title: title, detail: detail, detailColor: detailColor, icon: { EmptyView() }, trailing: trailing)
    }
}

extension SettingsRow where Icon == EmptyView, Trailing == EmptyView {
    init(title: String, detail: String? = nil, detailColor: Color? = nil) {
        self.init(title: title, detail: detail, detailColor: detailColor, icon: { EmptyView() }, trailing: { EmptyView() })
    }
}

/// A row's switch: Craft's blue capsule, at the size of its rows.
struct SettingsSwitch: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        // The loam style draws its label beside the switch, so it gets none: the row already shows the title.
        Toggle(isOn: $isOn) { EmptyView() }
            .accessibilityLabel(title)
            .toggleStyle(.loam)
    }
}

/// A blue text action at the right of a row ("Reveal in Finder", "Restore"), or a row of its own.
struct SettingsAction: View {
    let title: String
    var symbol: String?
    var role: ButtonRole?
    let action: () -> Void
    @Environment(\.themeTokens) private var theme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(role: role) { action() } label: {
            HStack(spacing: 8) {
                if let symbol { Image(symbol: symbol) }
                Text(title.uiLocalized)
            }
            .font(.ui(size: SettingsStyle.titleSize, weight: .medium))
            .foregroundStyle(isEnabled ? (role == .destructive ? theme.danger : theme.accent) : theme.secondaryText.opacity(0.6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A notice at the top of a pane (safe mode, a plugin that did not start): an icon and a line, in a tinted card.
struct SettingsNotice<Trailing: View>: View {
    let text: String
    let symbol: String
    var color: Color = .orange
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.themeTokens) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Image(symbol: symbol)
                .font(.ui(size: 14))
                .foregroundStyle(color)
            Text(text)
                .font(.ui(size: SettingsStyle.titleSize))
                .foregroundStyle(theme.text.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .padding(.horizontal, SettingsStyle.rowPadding)
        .padding(.vertical, 11)
        .background(color.opacity(0.1), in: .rect(cornerRadius: Corners.r(SettingsStyle.groupRadius), style: .continuous))
    }
}

extension SettingsNotice where Trailing == EmptyView {
    init(text: String, symbol: String, color: Color = .orange) {
        self.init(text: text, symbol: symbol, color: color, trailing: { EmptyView() })
    }
}

/// The chevron of a row that opens a page.
struct SettingsChevron: View {
    @Environment(\.themeTokens) private var theme

    var body: some View {
        Image(symbol: "chevron.right")
            .font(.ui(size: 11, weight: .semibold))
            .foregroundStyle(theme.secondaryText.opacity(0.7))
    }
}

/// A plugin's icon: the image its plugin.json names (`iconFile`), else its SF Symbol, else the default, on a white
/// rounded tile as Craft draws its integrations and empty states.
struct PluginIconView: View {
    let symbol: String?
    var imageURL: URL?
    var size: CGFloat = 28
    @State private var image: NSImage?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.themeTokens) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Corners.r(size * 0.27), style: .continuous)
        let dark = colorScheme == .dark
        ZStack {
            shape.fill(dark ? Color(hex: 0x3A3A3D) : .white)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(shape)
            } else {
                Image(symbol: PluginIcon.symbol(symbol))
                    .font(.ui(size: size * 0.5, weight: .regular))
                    .foregroundStyle(theme.text.opacity(0.78))
            }
        }
        .frame(width: size, height: size)
        .overlay { shape.strokeBorder(Color.primary.opacity(dark ? 0.12 : 0.07), lineWidth: 1) }
        .shadow(color: .black.opacity(dark ? 0.25 : 0.06), radius: size > 40 ? 6 : 1.5, y: size > 40 ? 3 : 1)
        .task(id: imageURL) { image = imageURL.flatMap(PluginIcon.image(at:)) }
        .accessibilityHidden(true)
    }
}

enum PluginIcon {
    /// The icon of a plugin that declares none, or one the system does not know.
    static let defaultSymbol = "puzzlepiece.extension"

    /// `declared` when it names an SF Symbol of this system or one of Loam's, else the default.
    static func symbol(_ declared: String?) -> String {
        guard let declared, !declared.isEmpty,
              LoamSymbol.exists(declared) else { return defaultSymbol }
        return declared
    }

    /// The image file of a plugin from the vault, nil when it is missing or not an image.
    static func image(at url: URL) -> NSImage? {
        guard let image = NSImage(contentsOf: url), image.isValid, image.size.width > 0 else { return nil }
        return image
    }
}

extension EnvironmentValues {
    /// The settings window's navigation, which outlives its views: `SettingsPage` keeps its scroll there.
    @Entry var settingsNavigation: SettingsNavigation?
}

/// Craft's toolbar control: a #F7F7F7 rounded square on the white page, a hairline edge and a faint shadow under it.
struct PageToolbarBackground: ViewModifier {
    var isHovered = false
    @Environment(\.themeTokens) private var theme

    static let height: CGFloat = 36
    static let cornerRadius: CGFloat = 12

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Corners.r(Self.cornerRadius), style: .continuous)
        content
            .frame(height: Self.height)
            .background(shape.fill(theme.text.opacity(isHovered ? 0.08 : 0.045)))
            .overlay(shape.strokeBorder(theme.text.opacity(0.05)))
            .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
            .contentShape(shape)
            .animation(Motion.hover, value: isHovered)
    }
}

/// The settings page's Back: an icon on Craft's light grey rounded square, as the page toolbar's (`ChromeButton`).
struct PageToolbarButton: View {
    let title: String
    let symbol: String
    var size: CGFloat = 14
    var weight: Font.Weight = .medium
    /// The symbol's colour; the text's when nil.
    var tint: Color?
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.themeTokens) private var theme

    var body: some View {
        Button { action() } label: {
            Image(symbol: symbol)
                .font(.ui(size: size, weight: weight))
                .foregroundStyle(isEnabled ? tint ?? theme.text.opacity(0.8) : theme.secondaryText.opacity(0.5))
                .frame(width: 40)
                .modifier(PageToolbarBackground(isHovered: isHovered && isEnabled))
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help(title)
        .accessibilityLabel(title)
        .onHover { isHovered = $0 }
    }
}
