import AppKit
import PluginKit
import PluginKitUI
import SwiftUI
import WorkspaceModel

/// What the page toolbars can do beyond the pane itself, given by the window.
struct PageActions {
    /// Creates a note and opens it; nil when no plugin offers it.
    var newNote: (@MainActor () -> Void)?
    /// What plugins can create besides a note: the "+" of a page of one kind (the drawings) creates that kind.
    var newItems: [NewItem] = []
    /// What Home opens: the first navigation link ("All Notes"); nil hides it.
    var home: Resource?
    /// What plugins add to the menu of a file or folder ("Rename…"), for the tab's and the page's right-click menus.
    var resourceActions: @MainActor (Resource) -> [ResourceAction] = { _ in [] }
}

extension PageActions {
    /// The plugins' items for `resource` in a right-click menu: none for a page that is no file or folder.
    @MainActor func menuItems(for resource: Resource?) -> [RightClickItem] {
        guard let resource, resource.kind != .virtual else { return [] }
        return resourceActions(resource).map { action in
            RightClickItem(title: action.title, symbol: action.symbol) { action.perform(resource) }
        }
    }
}

extension EnvironmentValues {
    @Entry var pageActions = PageActions()
}

/// The toolbar at the top of a page, as in Craft: Back (and Forward after a Back) on the left, the folders the page
/// lives in and, once it scrolled under the toolbar, the page's title, and the view switch on the right, as light grey
/// rounded squares (40 by 36, radius 12) with a hairline edge.
///
/// In AppKit, over the pages (`PageStackView`): it follows the pane's selected tab itself (`Follow`), so a note switch
/// or a scroll that brings the title in sets a few frames and texts, and never evaluates a SwiftUI body. Only the
/// glass behind it is SwiftUI (`EdgeGlassBand`, the plugins' own scroll edges), redrawn when the page scrolls under it.
final class PageToolbar: ShellView {
    static let height: CGFloat = 56

    /// What the toolbar shows, read from the workspace.
    struct State: Equatable {
        var tab: TabID?
        /// What the tab shows, for the trail of folders it lives in.
        var resource: Resource?
        var canGoBack = false
        var canGoForward = false
        /// The page's title once its own has scrolled under the toolbar (`ViewContext.toolbarTitle`).
        var title: ToolbarTitle?
        /// The views the tab's resource can be shown with, when there are several (a mindmap and its Markdown).
        var viewSwitch: ViewSwitch?
        /// False for the first pane, whose Back and Forward are in the title bar row (`ShellRootView`).
        var showsNavigation = true
    }

    private let pane: PaneID
    private weak var workspace: WorkspaceController?
    private let views: ViewRegistryStore
    var environment: PaneEnvironment { didSet { if environment.themeTokens != oldValue.themeTokens { themeChanged() } } }
    private(set) var state = State()
    private var follow: Follow<State>?

    private let glass: GlassHostingView
    private let back = ChromeButton(look: .toolbar, title: "Back", symbol: "chevron.left")
    private let forward = ChromeButton(look: .toolbar, title: "Forward", symbol: "chevron.right")
    /// The title and the folders, which a right-click on opens the page's menu ("Rename…").
    private let titleBlock = FlippedShellView()
    private let titleText = ChromeText()
    private let trail = BreadcrumbTrail()
    private let subtitle = ToolbarSubtitle()
    private let pageMenu = RightClickMenu.MenuView()
    private let switcher = ViewSwitcher()

    init(pane: PaneID, workspace: WorkspaceController, views: ViewRegistryStore, environment: PaneEnvironment) {
        self.pane = pane
        self.workspace = workspace
        self.views = views
        self.environment = environment
        glass = GlassHostingView(rootView: ToolbarGlass(isScrolled: false, theme: environment.themeTokens))
        super.init(frame: .zero)
        glass.safeAreaRegions = []
        glass.sizingOptions = []
        addSubview(glass)
        for button in [back, forward] { addSubview(button) }
        back.onPress = { [weak self] in
            guard let self, let tab = self.state.tab else { return }
            self.workspace?.goBack(in: tab)
        }
        forward.onPress = { [weak self] in
            guard let self, let tab = self.state.tab else { return }
            self.workspace?.goForward(in: tab)
        }
        titleBlock.wantsLayer = true
        titleText.isHidden = true
        titleBlock.addSubview(titleText)
        titleBlock.addSubview(trail)
        titleBlock.addSubview(subtitle)
        pageMenu.items = { [weak self] in
            guard let self else { return [] }
            return self.environment.pageActions.menuItems(for: self.state.resource)
        }
        titleBlock.addSubview(pageMenu)
        addSubview(titleBlock)
        trail.open = { [weak self] folder in
            // A folder of the trail opens in this tab; Back returns to the page.
            self?.workspace?.open(.folder(folder), placement: .replace)
        }
        switcher.choose = { [weak self] id in
            guard let self, let tab = self.state.tab, let viewSwitch = self.state.viewSwitch else { return }
            self.workspace?.setViewType(id == viewSwitch.choices.first?.id ? nil : id, for: tab)
        }
        addSubview(switcher)
        themeChanged()
        follow = Follow { [weak self] in self?.read() ?? State() } apply: { [weak self] state in
            self?.show(state)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    private func read() -> State {
        guard let workspace, let pane = workspace.layout.panes.first(where: { $0.id == self.pane }) else { return State() }
        let selected = pane.tabs.first { $0.id == pane.selected }
        var state = State()
        state.tab = selected?.id
        state.resource = selected?.resource
        if let tab = selected?.id {
            state.canGoBack = workspace.canGoBack(in: tab)
            state.canGoForward = workspace.canGoForward(in: tab)
        }
        state.title = selected.flatMap { workspace.context(for: $0).toolbarTitle }
        state.viewSwitch = selected.flatMap { ViewSwitch(tab: $0, views: views) }
        state.showsNavigation = workspace.layout.panes.first?.id != self.pane
        return state
    }

    private func themeChanged() {
        let theme = environment.themeTokens
        for button in [back, forward] { button.theme = theme }
        titleText.theme = theme
        trail.theme = theme
        subtitle.theme = theme
        switcher.theme = theme
        glass.rootView = ToolbarGlass(isScrolled: state.title != nil, theme: theme)
        showTexts()
        needsLayout = true
    }

    // MARK: State

    private func show(_ new: State) {
        let old = state
        state = new
        back.isEnabled = new.tab != nil && new.canGoBack
        if new.title != old.title || (new.title == nil) != (old.title == nil) {
            glass.rootView = ToolbarGlass(isScrolled: new.title != nil, theme: environment.themeTokens)
        }
        switcher.show(new.viewSwitch)
        showTexts()
        let reduceMotion = Motion.reduceMotion
        // The page changed: its title and folders cross-fade (`Motion.crossfade`).
        if old.resource != nil, new.resource != old.resource, window != nil {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = Motion.appKitDuration(0.16, reduceMotion: false)
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            titleBlock.layer?.add(fade, forKey: "crossfade")
        }
        // The title comes in from a little lower, or goes, and the folders make room for it (`Motion.Spring.smooth`).
        let titleChanged = (new.title == nil) != (old.title == nil)
        let before = titleChanged && old.resource == new.resource ? (trail.frame.origin.y, subtitle.frame.origin.y) : nil
        needsLayout = true
        layoutSubtreeIfNeeded()
        if let before, window != nil {
            animateTitle(shown: new.title != nil, trailFrom: before.0, subtitleFrom: before.1, reduceMotion: reduceMotion)
        }
    }

    private func showTexts() {
        titleText.isHidden = state.title == nil
        if let title = state.title {
            titleText.set(title.title.uiLocalized, font: .ui(size: 13, weight: .semibold), color: environment.themeTokens.text)
        }
        trail.trail = state.resource.map(Breadcrumb.init(resource:)) ?? Breadcrumb(folderNames: [])
        subtitle.show(state.title?.subtitle.map { ($0, state.title?.symbol ?? "doc") })
    }

    private func animateTitle(shown: Bool, trailFrom: CGFloat, subtitleFrom: CGFloat, reduceMotion: Bool) {
        CATransaction.begin()
        if shown {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = Motion.appKitDuration(0.2, reduceMotion: false)
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            titleText.layer?.add(fade, forKey: "in")
            if !reduceMotion { titleText.layer?.add(Self.rise(from: 6), forKey: "rise") }
        }
        if !reduceMotion {
            for (view, from) in [(trail as NSView, trailFrom), (subtitle as NSView, subtitleFrom)] {
                let delta = from - view.frame.origin.y
                if delta != 0 { view.layer?.add(Self.rise(from: delta), forKey: "rise") }
            }
        }
        CATransaction.commit()
    }

    /// A move of `delta` points down to its place with `Motion.Spring.smooth`, on the render server.
    private static func rise(from delta: CGFloat) -> CASpringAnimation {
        let rise = SplitTreeView.spring(.smooth, keyPath: "position.y")
        rise.isAdditive = true
        rise.fromValue = delta
        rise.toValue = 0
        return rise
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let height = bounds.height
        if glass.frame != bounds { glass.frame = bounds }
        let edge = PageMetrics.edge
        let controlY = ((height - PageToolbarStyle.height) / 2).rounded()
        var x = edge
        back.isHidden = !state.showsNavigation
        forward.isHidden = !(state.showsNavigation && state.tab != nil && state.canGoForward)
        if !back.isHidden {
            back.frame = NSRect(x: x, y: controlY, width: ChromeButton.toolbarSize.width, height: PageToolbarStyle.height)
            x += ChromeButton.toolbarSize.width + 10
            // Forward only once Back has been used, so the toolbar stays Craft's until there is somewhere to go.
            if !forward.isHidden {
                forward.frame = back.frame.offsetBy(dx: ChromeButton.toolbarSize.width + 10, dy: 0)
                x += ChromeButton.toolbarSize.width + 10
            }
        }
        x += 4
        // Back keeps its place; the trail gives way to the view switch when the pane is narrow, and in a pane too
        // narrow for all of it the right end is cut.
        var right = bounds.width - edge
        if !switcher.isHidden {
            let width = switcher.width
            let switchX = max(right - width, x + 10)
            switcher.frame = NSRect(x: switchX, y: controlY, width: width, height: PageToolbarStyle.height)
            right = switchX - 10
        }
        titleBlock.frame = NSRect(x: x, y: 0, width: max(0, right - x), height: height)
        pageMenu.frame = titleBlock.bounds
        layoutTitleBlock()
    }

    /// The title over the folders and the subtitle, centred as a whole.
    private func layoutTitleBlock() {
        let width = titleBlock.bounds.width
        let titleHeight = state.title == nil ? 0 : ChromeText.lineHeight(of: .ui(size: 13, weight: .semibold))
        let rowHeight = trail.trail.isEmpty && state.title?.subtitle == nil ? 0 : ChromeText.lineHeight(of: .ui(size: 11))
        var y = ((titleBlock.bounds.height - titleHeight - rowHeight) / 2).rounded()
        titleText.frame = NSRect(x: 0, y: y, width: width, height: titleHeight)
        y += titleHeight
        let subtitleWidth = subtitle.isHidden ? 0 : subtitle.width
        let trailWidth = trail.trail.isEmpty ? 0 : trail.width(within: max(0, width - (subtitleWidth > 0 ? subtitleWidth + 6 : 0)))
        trail.frame = NSRect(x: 0, y: y, width: trailWidth, height: rowHeight)
        subtitle.frame = NSRect(x: trailWidth > 0 ? trailWidth + 6 : 0, y: y, width: subtitleWidth, height: rowHeight)
    }
}

/// Behind the page's toolbar: the same glass as the other scroll edges (`EdgeGlassBand`), a progressive blur of what
/// scrolls under it, strongest at the top and gone by its bottom edge, so text passing under the buttons softens
/// instead of colliding with them (Craft's glassy top). Over the bare page it is invisible: its wash is the page's own
/// colour and the blur stays out. A page whose text has gone under the toolbar (its title shows there) brings the
/// blur in; a page that does not say keeps the wash, since what scrolls under it cannot be known from here.
struct ToolbarGlass: View {
    /// The page's title has gone under the toolbar.
    let isScrolled: Bool
    let theme: ThemeTokens

    var body: some View {
        ZStack {
            EdgeGlassBand(edge: .top, progress: 1, blur: isScrolled ? 1 : 0, length: PageToolbar.height, tint: theme.background)
            // With the title in it, the toolbar is the page's own colour down to under the title, as Craft's: the
            // title and its folders never sit over the text or a block scrolling under them.
            LinearGradient(
                stops: [.init(color: theme.background, location: 0), .init(color: theme.background, location: 0.82),
                        .init(color: theme.background.opacity(0), location: 1)],
                startPoint: .top, endPoint: .bottom
            )
            .opacity(isScrolled ? 1 : 0)
        }
        .frame(height: PageToolbar.height)
        .frame(maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
        .animation(Motion.ambient, value: isScrolled)
        .environment(\.themeTokens, theme)
    }
}

/// The glass's hosting view: drawn, never clicked.
final class GlassHostingView: NSHostingView<ToolbarGlass> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
}

/// One line of text in the chrome, drawn in its bounds and cut at its end; it can open something when clicked (a
/// folder of the trail) and darken under the pointer.
final class ChromeText: NSView {
    var theme: ThemeTokens = .standard
    /// Set for a text that opens something: it darkens under the pointer and is a button for VoiceOver.
    var onClick: (@MainActor () -> Void)? {
        didSet {
            if onClick != nil, pointer == nil { pointer = addPointerCursor(.pointingHand) }
        }
    }
    private var pointer: PointerCursorView?
    private var text = ""
    private var font = NSFont.ui(size: 11)
    private var color: Color = .secondary
    private var hoverColor: Color?
    private var isHovered = false
    private var tracking: NSTrackingArea?

    static func lineHeight(of font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    func set(_ text: String, font: NSFont, color: Color, hoverColor: Color? = nil) {
        guard text != self.text || font != self.font || color != self.color || hoverColor != self.hoverColor else { return }
        self.text = text
        self.font = font
        self.color = color
        self.hoverColor = hoverColor
        setAccessibilityLabel(text)
        needsDisplay = true
    }

    var textWidth: CGFloat { ceil(attributed.size().width) }

    private var attributed: NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        var shown = NSColor(isHovered ? hoverColor ?? color : color)
        effectiveAppearance.performAsCurrentDrawingAppearance { shown = shown.usingColorSpace(.sRGB) ?? shown }
        return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: shown, .paragraphStyle: paragraph])
    }

    override func draw(_ dirtyRect: NSRect) {
        attributed.draw(with: bounds, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        onClick == nil ? nil : super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = nil
        guard hoverColor != nil else { return }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    private func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        // `Motion.hover`.
        if let layer {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = Motion.appKitDuration(0.12)
            layer.add(fade, forKey: "hover")
        }
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func accessibilityRole() -> NSAccessibility.Role? { onClick == nil ? .staticText : .button }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return onClick != nil
    }
}

/// The folders a page lives in as one line of small secondary text, "Areas › nested folder": each folder opens when
/// clicked. When the pane is too narrow for all of them the middle goes first ("Areas › … › nested folder"), then
/// the start, and at last only the folder the page is in, cut at its end if it must (`Breadcrumb.candidates`).
final class BreadcrumbTrail: ShellView {
    var trail = Breadcrumb(folderNames: []) { didSet { if trail.folders.map(\.title) != oldValue.folders.map(\.title) || trail.folders.map(\.folder) != oldValue.folders.map(\.folder) { shown = nil; needsLayout = true } } }
    var theme: ThemeTokens = .standard { didSet { if theme != oldValue { shown = nil; needsLayout = true } } }
    var open: (@MainActor (String) -> Void)?
    /// The candidate laid out now, by index.
    private var shown: Int?
    private var chevrons: [CALayer] = []
    private var texts: [ChromeText] = []

    private static let font = NSFont.ui(size: 11)
    private static let spacing: CGFloat = 4

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Folder path".uiLocalized)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var chevronImage: NSImage? {
        var color = NSColor(theme.secondaryText)
        effectiveAppearance.performAsCurrentDrawingAppearance { color = color.usingColorSpace(.sRGB) ?? color }
        return tintedSymbol("chevron.right", size: 8, weight: .semibold, color: color.withAlphaComponent(color.alphaComponent * 0.6))
    }

    private func width(of segments: [Breadcrumb.Segment]) -> CGFloat {
        let texts = segments.reduce(0) { $0 + ceil(NSAttributedString(string: $1.title.uiLocalized, attributes: [.font: Self.font]).size().width) }
        let chevron = (chevronImage?.size.width ?? 5) * CGFloat(max(0, segments.count - 1))
        return texts + chevron + Self.spacing * CGFloat(max(0, 2 * segments.count - 2))
    }

    /// The first candidate that fits in `available`; the last one, cut, when none does.
    private func candidate(within available: CGFloat) -> (index: Int, width: CGFloat) {
        let candidates = trail.candidates
        for (index, segments) in candidates.enumerated() {
            let width = width(of: segments)
            if width <= available || index == candidates.count - 1 { return (index, min(width, available)) }
        }
        return (0, 0)
    }

    /// How wide the trail is when given `available` points.
    func width(within available: CGFloat) -> CGFloat { candidate(within: available).width }

    override func layout() {
        super.layout()
        let candidates = trail.candidates
        guard !candidates.isEmpty else {
            clear()
            return
        }
        let (index, _) = candidate(within: bounds.width)
        if shown != index { build(candidates[index]); shown = index }
        var x: CGFloat = 0
        let height = bounds.height
        for (position, text) in texts.enumerated() {
            if position > 0 {
                let chevron = chevrons[position - 1]
                let size = (chevron.contents as? NSImage)?.size ?? CGSize(width: 5, height: 8)
                x += Self.spacing
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                chevron.frame = CGRect(x: x, y: ((height - size.height) / 2).rounded(), width: size.width, height: size.height)
                CATransaction.commit()
                x += size.width + Self.spacing
            }
            // The last segment takes what is left, and is cut at its end.
            let width = position == texts.count - 1 ? max(0, bounds.width - x) : text.textWidth
            text.frame = NSRect(x: x, y: 0, width: width, height: height)
            x += width
        }
    }

    private func clear() {
        texts.forEach { $0.removeFromSuperview() }
        chevrons.forEach { $0.removeFromSuperlayer() }
        texts = []
        chevrons = []
        shown = nil
    }

    private func build(_ segments: [Breadcrumb.Segment]) {
        clear()
        let image = chevronImage
        for (index, segment) in segments.enumerated() {
            if index > 0 {
                let chevron = CALayer()
                chevron.contents = image
                chevron.contentsGravity = .center
                chevron.contentsScale = window?.backingScaleFactor ?? 2
                layer?.addSublayer(chevron)
                chevrons.append(chevron)
            }
            let text = ChromeText()
            text.wantsLayer = true
            if let folder = segment.folder {
                text.set(segment.title.uiLocalized, font: Self.font, color: theme.secondaryText, hoverColor: theme.text)
                text.toolTip = String(localized: "Open \(segment.title)")
                text.onClick = { [weak self] in self?.open?(folder) }
            } else {
                text.set(segment.title.uiLocalized, font: Self.font, color: theme.secondaryText)
            }
            addSubview(text)
            texts.append(text)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        shown = nil
        needsLayout = true
    }
}

/// The page's subtitle beside its folders: a small symbol and a line of secondary text ("12 words").
final class ToolbarSubtitle: ShellView {
    var theme: ThemeTokens = .standard
    private let icon = CALayer()
    private let text = ChromeText()
    private var content: (text: String, symbol: String)?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        icon.contentsGravity = .center
        layer?.addSublayer(icon)
        addSubview(text)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static let font = NSFont.ui(size: 11)

    func show(_ content: (text: String, symbol: String)?) {
        self.content = content
        isHidden = content == nil
        guard let content else { return }
        text.set(content.text.uiLocalized, font: Self.font, color: theme.secondaryText)
        var color = NSColor(theme.secondaryText)
        effectiveAppearance.performAsCurrentDrawingAppearance { color = color.usingColorSpace(.sRGB) ?? color }
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular, scale: .small)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        icon.contents = NSImage.symbol(content.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        icon.contentsScale = window?.backingScaleFactor ?? 2
        needsLayout = true
    }

    private var iconWidth: CGFloat { (icon.contents as? NSImage)?.size.width ?? 0 }

    var width: CGFloat { content == nil ? 0 : iconWidth + 3 + text.textWidth }

    override func layout() {
        super.layout()
        let size = (icon.contents as? NSImage)?.size ?? .zero
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        icon.frame = CGRect(x: 0, y: ((bounds.height - size.height) / 2).rounded(), width: size.width, height: size.height)
        CATransaction.commit()
        text.frame = NSRect(x: size.width + 3, y: 0, width: max(0, bounds.width - size.width - 3), height: bounds.height)
    }
}

/// The view types a tab can switch between: each one that can open its resource and has an icon, the default
/// first. Nil when there is only one.
struct ViewSwitch: Equatable {
    struct Choice: Identifiable, Equatable {
        let id: String
        let title: String
        let symbol: String
    }

    let choices: [Choice]
    let current: String

    @MainActor
    init?(tab: WorkspaceModel.Tab, views: ViewRegistryStore) {
        // A collection (a folder, a `.base`) switches between its own views in its tabs (Kanban, Table, Gallery), not
        // between the collection and the plain folder grid.
        guard tab.resource.kind != .folder, !tab.resource.path.hasSuffix(".base") else { return nil }
        // A catch-all viewer (Quick Look, negative priority) stays in "Open with" but is no view of the page.
        let choices = views.viewTypes(for: tab.resource).filter { $0.priority >= 0 }.compactMap { type in
            type.symbol.map { Choice(id: type.id, title: type.title, symbol: $0) }
        }
        guard choices.count > 1, let current = WorkspaceController.viewType(for: tab, in: views)?.id else { return nil }
        self.choices = choices
        self.current = current
    }
}

/// Icons grouped on one toolbar square, as Craft groups its page controls, one per view of the page, the current one
/// shaded: Mindmap and Markdown for a mindmap note.
final class ViewSwitcher: ShellView {
    var theme: ThemeTokens = .standard { didSet { if theme != oldValue { updateColors() } } }
    var choose: (@MainActor (String) -> Void)?
    private let shape = CALayer()
    private var segments: [Segment] = []
    private var shown: ViewSwitch?

    private static let segmentSize = NSSize(width: 32, height: 28)

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        shape.cornerCurve = .continuous
        shape.borderWidth = 1
        shape.shadowOpacity = 1
        shape.shadowRadius = 1
        shape.shadowOffset = CGSize(width: 0, height: 1)
        layer?.addSublayer(shape)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var width: CGFloat {
        let count = CGFloat(segments.count)
        return 8 + count * Self.segmentSize.width + max(0, count - 1) * 2
    }

    func show(_ viewSwitch: ViewSwitch?) {
        guard viewSwitch != shown else { return }
        let sameChoices = viewSwitch?.choices == shown?.choices
        shown = viewSwitch
        isHidden = viewSwitch == nil
        guard let viewSwitch else { return }
        if !sameChoices {
            segments.forEach { $0.removeFromSuperview() }
            segments = viewSwitch.choices.map { choice in
                let segment = Segment(choice: choice)
                segment.onPress = { [weak self] in self?.choose?(choice.id) }
                addSubview(segment)
                return segment
            }
            needsLayout = true
        }
        // `.tap`: the shade moves to the chosen view quickly.
        CATransaction.begin()
        CATransaction.setAnimationDuration(sameChoices ? Motion.appKitDuration(Motion.Spring.tap.duration) : 0)
        for segment in segments { segment.isSelected = segment.choice.id == viewSwitch.current }
        updateColors()
        CATransaction.commit()
    }

    private func updateColors() {
        var text = NSColor(theme.text)
        effectiveAppearance.performAsCurrentDrawingAppearance { text = text.usingColorSpace(.sRGB) ?? text }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.backgroundColor = text.withAlphaComponent(0.045).cgColor
        shape.borderColor = text.withAlphaComponent(0.05).cgColor
        shape.shadowColor = NSColor.black.withAlphaComponent(0.04).cgColor
        CATransaction.commit()
        for segment in segments { segment.theme = theme }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = bounds
        shape.cornerRadius = Corners.r(PageToolbarStyle.cornerRadius)
        shape.shadowPath = CGPath(roundedRect: bounds, cornerWidth: shape.cornerRadius, cornerHeight: shape.cornerRadius, transform: nil)
        CATransaction.commit()
        var x: CGFloat = 4
        let y = ((bounds.height - Self.segmentSize.height) / 2).rounded()
        for segment in segments {
            segment.frame = NSRect(origin: NSPoint(x: x, y: y), size: Self.segmentSize)
            x += Self.segmentSize.width + 2
        }
    }

    /// One view of the page: its icon, shaded while it is the current one.
    final class Segment: NSButton {
        let choice: ViewSwitch.Choice
        var theme: ThemeTokens = .standard { didSet { updateColors() } }
        var onPress: (@MainActor () -> Void)?
        var isSelected = false { didSet { if isSelected != oldValue { updateColors() } } }
        private let fill = CALayer()
        private let icon = CALayer()

        init(choice: ViewSwitch.Choice) {
            self.choice = choice
            super.init(frame: .zero)
            title = ""
            isBordered = false
            imagePosition = .noImage
            wantsLayer = true
            fill.cornerCurve = .continuous
            layer?.addSublayer(fill)
            icon.contentsGravity = .center
            layer?.addSublayer(icon)
            target = self
            action = #selector(pressed)
            addPointerCursor(.pointingHand)
            let label = String(localized: "Show as \(choice.title)")
            toolTip = label
            setAccessibilityLabel(label)
            updateColors()
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func draw(_ dirtyRect: NSRect) {}
        override func isAccessibilitySelected() -> Bool { isSelected }

        @objc private func pressed() { onPress?() }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fill.frame = bounds
            fill.cornerRadius = Corners.r(8)
            icon.frame = bounds
            CATransaction.commit()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            updateColors()
        }

        private func updateColors() {
            var text = NSColor(theme.text), secondary = NSColor(theme.secondaryText)
            effectiveAppearance.performAsCurrentDrawingAppearance {
                text = text.usingColorSpace(.sRGB) ?? text
                secondary = secondary.usingColorSpace(.sRGB) ?? secondary
            }
            fill.backgroundColor = isSelected ? text.withAlphaComponent(0.07).cgColor : NSColor.clear.cgColor
            let scale = window?.backingScaleFactor ?? 2
            icon.contentsScale = scale
            icon.contents = tintedSymbol(choice.symbol, size: 14, weight: .medium,
                                         color: isSelected ? text.withAlphaComponent(0.8) : secondary)?
                .layerContents(forContentsScale: scale)
        }
    }
}

/// A shell view laid out from its top left corner.
final class FlippedShellView: ShellView {
    override var isFlipped: Bool { true }
}
