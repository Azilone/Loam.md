import SwiftUI

// The rules every page follows, whatever the theme. A theme chooses colours, families, corners and card styles; the
// layout below is the app's: where a page's title sits and how big it is, how wide its content runs, the type,
// spacing and radius scales, the empty state. Built-in pages and third-party plugins use the same pieces, so a
// plugin looks like the app without measuring anything. Details: docs/UI-RULES.md.

// MARK: Scales

/// The type scale of the app's own text. Use `.font(.ui(.body))` rather than a size: these seven steps are the only
/// sizes a page needs.
public enum UIType: CaseIterable, Sendable {
    /// 11: a small label, a count, a date.
    case caption
    /// 12: secondary lines, hints, buttons in a dense bar.
    case label
    /// 13: the interface's body: rows, fields, buttons, descriptions.
    case body
    /// 15: a row's emphasised name, an empty state's message title.
    case emphasis
    /// 17: a section's title inside a page, an empty state's title.
    case section
    /// 28: a page's title (`PageHeader`).
    case title
    /// 40: an editorial hero (Home's greeting, Onboarding).
    case display

    public var size: CGFloat {
        switch self {
        case .caption: 11
        case .label: 12
        case .body: 13
        case .emphasis: 15
        case .section: 17
        case .title: 28
        case .display: 40
        }
    }

    public var defaultWeight: Font.Weight {
        switch self {
        case .caption, .label, .body: .regular
        case .emphasis, .section: .semibold
        case .title, .display: .bold
        }
    }
}

public extension Font {
    /// The app's own text at a step of the type scale, in the theme's interface family.
    static func ui(_ style: UIType, weight: Font.Weight? = nil) -> Font {
        .ui(size: style.size, weight: weight ?? style.defaultWeight)
    }
}

/// The spacing scale, in points. Paddings and stack spacings take one of these.
public enum Space {
    public static let xxs: CGFloat = 2
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 12
    public static let l: CGFloat = 16
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32
    public static let xxxl: CGFloat = 48
}

/// The radius scale, already held to the theme's cap (`Corners.r`). Pills are `ThemeCapsule`.
public enum Radius {
    /// 4: a tag, a check box, a small chip.
    public static var xs: CGFloat { Corners.r(4) }
    /// 6: a button, a field, a row.
    public static var s: CGFloat { Corners.r(6) }
    /// 10: a menu, a popover, a tile.
    public static var m: CGFloat { Corners.r(10) }
    /// 14: a card.
    public static var l: CGFloat { Corners.r(14) }
}

/// How wide a page's content runs. Always centred in the pane.
public enum PageWidth: Sendable {
    /// 760: lists, forms, settings, a day, a timeline.
    case reading
    /// 1320: grids, boards, galleries.
    case wide
    /// The whole pane: canvases, graphs, maps.
    case full

    public var maxWidth: CGFloat {
        switch self {
        case .reading: 760
        case .wide: 1320
        case .full: .infinity
        }
    }
}

public extension PageMetrics {
    /// Room between the page's toolbar and its title.
    static let top: CGFloat = 16
    /// Room between the page's header and its content.
    static let headerGap: CGFloat = 20
}

// MARK: Semantic colours

public extension ThemeTokens {
    /// A quiet fill behind a field, a chip, an idle button.
    var fillSubtle: Color { text.opacity(0.05) }
    /// Under the pointer.
    var fillHover: Color { text.opacity(0.08) }
    /// Pressed or selected.
    var fillStrong: Color { text.opacity(0.12) }
    /// Destructive actions and errors.
    var danger: Color { Color(red: 0.86, green: 0.21, blue: 0.20) }
    /// Warnings.
    var warning: Color { Color(red: 0.90, green: 0.55, blue: 0.10) }
    /// Success.
    var success: Color { Color(red: 0.20, green: 0.62, blue: 0.33) }
}

// MARK: Page

public extension View {
    /// Lays a page's content in the app's column: centred, at most `width` wide, with the page's side margin and
    /// room under the toolbar. Use on the content of a `ScrollView` (or the page itself when it does not scroll).
    func pageColumn(_ width: PageWidth = .reading, top: CGFloat = PageMetrics.top) -> some View {
        modifier(PageColumnModifier(width: width, top: top))
    }
}

private struct PageColumnModifier: ViewModifier {
    let width: PageWidth
    let top: CGFloat

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: width.maxWidth, alignment: .topLeading)
            .padding(.horizontal, width == .full ? 0 : PageMetrics.edge)
            .padding(.top, top)
            .frame(maxWidth: .infinity, alignment: .top)
    }
}

/// A page's title: the name in `UIType.title`, an optional meta line under it (a count, a date) as a theme label,
/// and the page's actions on the right, on the title's line. Every page starts with one.
public struct PageHeader<Actions: View>: View {
    let title: String
    let subtitle: String?
    let actions: Actions
    @Environment(\.themeTokens) private var theme

    public init(_ title: String, subtitle: String? = nil, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.subtitle = subtitle
        self.actions = actions()
    }

    public var body: some View {
        HStack(alignment: .center, spacing: Space.m) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(title.uiLocalized)
                    .font(.ui(.title))
                    .tracking(-0.4)
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let subtitle {
                    Text(subtitle.uiLocalized)
                        .themeLabel(size: UIType.body.size, weight: .medium)
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Space.m)
            actions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

public extension PageHeader where Actions == EmptyView {
    init(_ title: String, subtitle: String? = nil) {
        self.init(title, subtitle: subtitle) { EmptyView() }
    }
}

/// A whole page: header, content, in the app's column, scrolling. The simplest way for a plugin to make a page that
/// looks like the others.
public struct PageScaffold<Actions: View, Content: View>: View {
    let title: String
    let subtitle: String?
    let width: PageWidth
    let actions: Actions
    let content: Content
    @Environment(\.themeTokens) private var theme

    public init(
        _ title: String,
        subtitle: String? = nil,
        width: PageWidth = .reading,
        @ViewBuilder actions: () -> Actions,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.width = width
        self.actions = actions()
        self.content = content()
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PageMetrics.headerGap) {
                PageHeader(title, subtitle: subtitle) { actions }
                content
            }
            .pageColumn(width)
            .padding(.bottom, Space.xxxl)
        }
        .background(theme.background)
    }
}

public extension PageScaffold where Actions == EmptyView {
    init(_ title: String, subtitle: String? = nil, width: PageWidth = .reading, @ViewBuilder content: () -> Content) {
        self.init(title, subtitle: subtitle, width: width, actions: { EmptyView() }, content: content)
    }
}

// MARK: Empty state

/// What a page or a list shows with nothing in it: a symbol (or a drawing), a title, one line, and at most one
/// action. The one empty state of the app.
public struct EmptyState<Art: View>: View {
    let title: String
    let message: String?
    let actionTitle: String?
    let actionSymbol: String
    let action: (() -> Void)?
    let art: Art
    @Environment(\.themeTokens) private var theme

    public init(
        _ title: String,
        message: String? = nil,
        actionTitle: String? = nil,
        actionSymbol: String = "plus",
        action: (() -> Void)? = nil,
        @ViewBuilder art: () -> Art
    ) {
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.actionSymbol = actionSymbol
        self.action = action
        self.art = art()
    }

    public var body: some View {
        VStack(spacing: Space.s) {
            art.padding(.bottom, Space.xs)
            Text(title.uiLocalized)
                .font(.ui(.section))
                .foregroundStyle(theme.text)
            if let message {
                Text(message.uiLocalized)
                    .font(.ui(.body))
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            if let actionTitle, let action {
                Button(action: action) {
                    Label(actionTitle.uiLocalized, symbol: actionSymbol)
                        .font(.ui(.body, weight: .medium))
                        .foregroundStyle(theme.text.opacity(0.85))
                        .padding(.horizontal, Space.m)
                        .frame(height: 28)
                        .hoverFill(in: ThemeCapsule())
                        .background(ThemeCapsule().fill(theme.fillSubtle))
                        .contentShape(ThemeCapsule())
                }
                .buttonStyle(.press)
                .padding(.top, Space.s)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.xxxl)
        .accessibilityElement(children: .contain)
    }
}

public extension EmptyState where Art == EmptyStateSymbol {
    init(
        _ title: String,
        symbol: String,
        message: String? = nil,
        actionTitle: String? = nil,
        actionSymbol: String = "plus",
        action: (() -> Void)? = nil
    ) {
        self.init(title, message: message, actionTitle: actionTitle, actionSymbol: actionSymbol, action: action) {
            EmptyStateSymbol(name: symbol)
        }
    }
}

/// The symbol of an empty state.
public struct EmptyStateSymbol: View {
    let name: String
    @Environment(\.themeTokens) private var theme

    public init(name: String) { self.name = name }

    public var body: some View {
        Image(symbol: name)
            .font(.ui(size: 28, weight: .light))
            .foregroundStyle(theme.secondaryText.opacity(0.7))
    }
}

// MARK: Interaction

/// Shrinks a little while pressed (`Motion.Metrics.pressScale`), unless Reduce Motion is on. The app's one
/// press feedback: `.buttonStyle(.press)`.
public struct PressStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !Motion.reduceMotion ? Motion.Metrics.pressScale : 1)
            .animation(Motion.Spring.tap.animation, value: configuration.isPressed)
    }
}

public extension ButtonStyle where Self == PressStyle {
    static var press: PressStyle { PressStyle() }
}

public extension View {
    /// The app's hover: `fillHover` in `shape` under the pointer.
    func hoverFill<S: Shape>(in shape: S, enabled: Bool = true) -> some View {
        modifier(HoverFillModifier(shape: shape, enabled: enabled))
    }

    /// The app's hover in a rounded rectangle of `radius`.
    func hoverFill(radius: CGFloat = Radius.s, enabled: Bool = true) -> some View {
        hoverFill(in: RoundedRectangle(cornerRadius: radius, style: .continuous), enabled: enabled)
    }
}

private struct HoverFillModifier<S: Shape>: ViewModifier {
    let shape: S
    let enabled: Bool
    @State private var hovered = false
    @Environment(\.themeTokens) private var theme

    func body(content: Content) -> some View {
        content
            .background(shape.fill(hovered && enabled ? theme.fillHover : .clear))
            .onHover { hovered = $0 }
            .animation(Motion.hover, value: hovered)
    }
}
