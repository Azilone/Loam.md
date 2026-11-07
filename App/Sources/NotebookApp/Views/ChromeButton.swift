import AppKit
import PluginKitUI
import SwiftUI

/// A button of the window's chrome in AppKit: a symbol on a shape that darkens under the pointer, drawn with layers
/// so a state change or a resize never evaluates a SwiftUI body. Two looks:
///
/// - `.window`: the title bar row's (the sidebar buttons, Back, Forward, Home), a symbol on a faint disc, round as
///   the tabs beside it are under the theme's corners, its symbol greyed while there is nothing to do.
/// - `.toolbar`: the page toolbar's, Craft's light grey rounded square (40 by 36, radius 12) with a hairline edge and
///   a faint shadow under it.
class ChromeButton: NSButton {
    enum Look {
        case window
        case toolbar
    }

    let look: Look
    var theme: ThemeTokens = .standard { didSet { if theme != oldValue { updateColors() } } }
    var symbolName: String { didSet { if symbolName != oldValue { updateColors() } } }
    var onPress: (@MainActor () -> Void)?

    private let shape = CALayer()
    private let glyph = CALayer()
    private var isHovered = false
    private var tracking: NSTrackingArea?

    static let windowSide = TitleBar.buttonSide
    static let toolbarSize = NSSize(width: 40, height: PageToolbarStyle.height)

    init(look: Look, title: String, symbol: String) {
        self.look = look
        symbolName = symbol
        super.init(frame: NSRect(origin: .zero, size: look == .window
            ? NSSize(width: Self.windowSide, height: Self.windowSide) : Self.toolbarSize))
        self.title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        imagePosition = .noImage
        wantsLayer = true
        layer?.masksToBounds = false
        shape.cornerCurve = .continuous
        layer?.addSublayer(shape)
        glyph.contentsGravity = .center
        layer?.addSublayer(glyph)
        if look == .toolbar {
            shape.borderWidth = 1
            shape.shadowColor = NSColor.black.cgColor
            shape.shadowOpacity = 1
            shape.shadowRadius = 1
            // Down: the view's layers are flipped.
            shape.shadowOffset = CGSize(width: 0, height: 1)
        }
        target = self
        action = #selector(pressed)
        // `.pointerStyle(.link)` on the page's controls.
        if look == .toolbar { addPointerCursor(.pointingHand) }
        setTitle(title)
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The tooltip and VoiceOver's label.
    func setTitle(_ title: String) {
        let localized = title.uiLocalized
        toolTip = localized
        setAccessibilityLabel(localized)
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override var isFlipped: Bool { true }
    override var isEnabled: Bool { didSet { if isEnabled != oldValue { updateColors() } } }

    @objc private func pressed() {
        onPress?()
    }

    override func draw(_ dirtyRect: NSRect) {}

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = bounds
        switch look {
        case .window: shape.cornerRadius = min(Corners.cap ?? bounds.height / 2, bounds.height / 2)
        case .toolbar: shape.cornerRadius = Corners.r(PageToolbarStyle.cornerRadius)
        }
        shape.shadowPath = look == .toolbar
            ? CGPath(roundedRect: bounds, cornerWidth: shape.cornerRadius, cornerHeight: shape.cornerRadius, transform: nil) : nil
        glyph.frame = bounds
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { setHovered(false) }
    }


    private func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        // `Motion.hover`: a short ease-out.
        CATransaction.begin()
        CATransaction.setAnimationDuration(Motion.appKitDuration(0.12))
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        applyFill()
        CATransaction.commit()
    }

    // MARK: Colours

    private func resolved(_ color: Color) -> NSColor {
        var result = NSColor(color)
        effectiveAppearance.performAsCurrentDrawingAppearance { result = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color) }
        return result
    }

    private func applyFill() {
        let active = isHovered && isEnabled
        let alpha: CGFloat = switch look {
        case .window: active ? 0.1 : 0.05
        case .toolbar: active ? 0.08 : 0.045
        }
        shape.backgroundColor = resolved(theme.text).withAlphaComponent(alpha).cgColor
    }

    func updateColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyFill()
        let tint: NSColor
        let size: CGFloat, weight: NSFont.Weight
        switch look {
        case .window:
            tint = resolved(theme.secondaryText).withAlphaComponent(isEnabled ? 1 : 0.55)
            (size, weight) = (14, .medium)
        case .toolbar:
            tint = isEnabled ? resolved(theme.text).withAlphaComponent(0.8) : resolved(theme.secondaryText).withAlphaComponent(0.5)
            (size, weight) = (15, .regular)
            shape.borderColor = resolved(theme.text).withAlphaComponent(0.05).cgColor
            shape.shadowColor = NSColor.black.withAlphaComponent(0.04).cgColor
        }
        let scale = window?.backingScaleFactor ?? 2
        glyph.contentsScale = scale
        glyph.contents = tintedSymbol(symbolName, size: size, weight: weight, color: tint)?.layerContents(forContentsScale: scale)
        CATransaction.commit()
    }
}

/// The page toolbar's controls: Craft's light grey rounded square.
enum PageToolbarStyle {
    static let height: CGFloat = 36
    static let cornerRadius: CGFloat = 12
}
