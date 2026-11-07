import AppKit
import PluginKitUI
import SwiftUI

/// How high a card stands off the board: resting, under the pointer, or in the hand.
enum BoardElevation {
    case rest, hover, held

    var shadowOpacity: Float {
        switch self {
        case .rest: 0.02
        case .hover: 0.08
        case .held: 0.22
        }
    }

    var shadowRadius: CGFloat {
        switch self {
        case .rest: 3
        case .hover: 6
        case .held: 18
        }
    }

    var shadowY: CGFloat {
        switch self {
        case .rest: 1
        case .hover: 3
        case .held: 10
        }
    }
}

/// One line under a card's title: a shown field that has a value, as `PropertyValueView` draws it.
@MainActor
enum BoardLine: Equatable {
    case text(String)
    case link(String)
    case pills([String], options: [String])
    case date(String)
    case checkbox(Bool)

    /// The line for `value` of a field of `kind`; nil when it shows nothing.
    static func make(_ value: PropertyValue?, kind: PropertyKind, options: [String]) -> BoardLine? {
        guard let value else { return nil }
        let text = CollectionViewModel.text(value)
        switch kind {
        case .checkbox: return .checkbox(value == .bool(true))
        case .select, .multiselect:
            let items = PropertyValueView.items(value)
            return items.isEmpty ? nil : .pills(items, options: options)
        case .url: return .link(text)
        case .date where DateValuePill.label(text) != nil: return .date(text)
        default: return .text(text)
        }
    }

    var height: CGFloat {
        switch self {
        case .text, .link, .checkbox: BoardCardDetails.lineHeight(NSFont.ui(size: 13))
        case .pills: BoardCardDetails.pillHeight
        case .date: BoardCardDetails.lineHeight(NSFont.ui(size: 13)) + 4
        }
    }
}

/// What a card shows: the title, the shown fields with a value, the note's checklist.
@MainActor
struct BoardCardContent: Equatable {
    var title: String
    var lines: [BoardLine]
    var checklist: BoardChecklist?

    static let inset: CGFloat = 12
    static let spacing: CGFloat = 8
    static let titleLines = 3

    func titleText(_ theme: ThemeTokens) -> NSAttributedString {
        NSAttributedString(string: title, attributes: [.font: NSFont.ui(size: 15, weight: .semibold), .foregroundColor: NSColor(theme.text)])
    }

    /// The fields and the checklist, under the title.
    var detailsHeight: CGFloat {
        var height: CGFloat = 0
        for line in lines { height += Self.spacing + line.height }
        if checklist != nil { height += Self.spacing + BoardCardDetails.checklistHeight }
        return height
    }

    /// The card's height at `width`.
    func height(width: CGFloat) -> CGFloat {
        let title = CardTextView.height(of: titleText(.standard), maxLines: Self.titleLines, width: width - 2 * Self.inset)
        return ceil(Self.inset + title + detailsHeight + Self.inset)
    }
}

/// A card of the board, as Craft draws it: a white card with a hairline, the title, then the shown fields that have
/// a value and the note's checklist. Under the pointer it rises a little and dips toward the pointer
/// (`Motion.HoverPose.compact`); in the hand (the copy that follows the pointer) it is bigger, with a deeper shadow,
/// and leans into the hand's movement. While its copy is in the hand the card is its own ghost: faded, with a
/// dashed outline in its column's colour.
///
/// Clicks, drags and the menu are the board's (`BoardDocumentView`): the card only draws and follows the pointer.
final class BoardCardView: NSView {
    /// What the card draws: faded as a ghost, posed as a whole by its layer's `sublayerTransform`.
    let body = NativeCardView.FlippedView()
    private let face = CALayer()
    let title = CardTextView()
    let details = BoardCardDetails()
    private let outline = CAShapeLayer()
    private var tracking: NSTrackingArea?

    private(set) var path = ""
    private(set) var content: BoardCardContent?
    var theme = ThemeTokens.standard
    /// The theme the title and the details were last made with.
    private var drawnTheme: ThemeTokens?
    /// Whether the board lets the card take its hover pose (not while a card is in the hand).
    var canHover: () -> Bool = { true }
    private(set) var isHovered = false
    private var pointerX: CGFloat = 0
    private(set) var elevation = BoardElevation.rest
    /// The held copy's pose: bigger, leaning `tilt` degrees.
    private var heldScale: CGFloat = 1
    private var tilt: Double = 0

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    /// The board takes the clicks: it picks a card up, opens it or shows its menu.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        body.wantsLayer = true
        body.layer?.masksToBounds = false
        addSubview(body)
        face.cornerCurve = .continuous
        face.borderWidth = 1
        face.shadowColor = NSColor.black.cgColor
        body.layer?.addSublayer(face)
        title.maxLines = BoardCardContent.titleLines
        body.addSubview(title)
        body.addSubview(details)
        outline.fillColor = nil
        outline.lineWidth = 1.5
        outline.lineDashPattern = [5, 4]
        outline.zPosition = 10
        outline.isHidden = true
        layer?.addSublayer(outline)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(path: String, content: BoardCardContent, theme: ThemeTokens) {
        // The theme the text was made with, not `self.theme`: the board sets that one ahead of `show`, and a title
        // drawn in the old theme's colour would stay.
        let themeChanged = theme != drawnTheme
        self.path = path
        self.theme = theme
        if content != self.content || themeChanged {
            drawnTheme = theme
            self.content = content
            title.attributed = content.titleText(theme)
            details.show(BoardCardDetails.Content(lines: content.lines, checklist: content.checklist, theme: theme))
        }
        setAccessibilityLabel(content.title)
        toolTip = String(localized: "Open \(content.title)")
        applyLook()
        needsLayout = true
    }

    /// Put back in the pool: no hover, no ghost, no pose left from its last card.
    func recycle() {
        isHovered = false
        setGhost(false, tint: nil)
        heldScale = 1
        tilt = 0
        elevation = .rest
        layer?.removeAllAnimations()
        body.layer?.removeAllAnimations()
        face.removeAllAnimations()
        applyPose(animated: false)
        applyLook()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body.frame = bounds
        face.frame = bounds
        let radius = Corners.r(8)
        face.cornerRadius = radius
        face.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let inner = max(0, bounds.width - 2 * BoardCardContent.inset)
        let titleHeight = title.height(for: inner)
        title.frame = CGRect(x: BoardCardContent.inset, y: BoardCardContent.inset, width: inner, height: titleHeight)
        details.frame = CGRect(x: BoardCardContent.inset, y: title.frame.maxY, width: inner,
                               height: max(0, bounds.height - title.frame.maxY - BoardCardContent.inset))
        outline.frame = bounds
        outline.path = CGPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), cornerWidth: max(0, radius - 0.75),
                              cornerHeight: max(0, radius - 0.75), transform: nil)
        CATransaction.commit()
        applyPose(animated: false)
    }

    private func applyLook() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            face.backgroundColor = NSColor(theme.background).cgColor
            face.borderColor = NSColor(theme.separator.opacity(elevation == .rest ? 0.5 : 0.9)).cgColor
        }
        face.shadowOpacity = elevation.shadowOpacity
        face.shadowRadius = elevation.shadowRadius
        face.shadowOffset = CGSize(width: 0, height: elevation.shadowY)
        CATransaction.commit()
    }

    // MARK: Ghost

    /// The card whose copy is in the hand: faded, with a dashed outline in `tint`.
    func setGhost(_ ghost: Bool, tint: NSColor?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body.layer?.opacity = ghost ? 0.35 : 1
        outline.isHidden = !ghost
        if let tint { outline.strokeColor = tint.withAlphaComponent(0.6).cgColor }
        CATransaction.commit()
        if ghost { setHovered(false, animated: false) }
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        // Its own bounds: `.inVisibleRect` reaches past a view that does not clip (see `NativeCardView`).
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hover(event) }
    override func mouseMoved(with event: NSEvent) { hover(event) }
    override func mouseExited(with event: NSEvent) { setHovered(false, animated: true) }

    private func hover(_ event: NSEvent) {
        guard canHover(), body.layer?.opacity == 1 else { return setHovered(false, animated: true) }
        let point = convert(event.locationInWindow, from: nil)
        let x = bounds.width > 0 ? point.x / bounds.width * 2 - 1 : 0
        if isHovered {
            guard abs(x - pointerX) > 0.02 else { return }
            pointerX = x
            applyPose(animated: true, follow: true)
        } else {
            pointerX = x
            setHovered(true, animated: true)
        }
    }

    func setHovered(_ hovered: Bool, animated: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        if !hovered { pointerX = 0 }
        // Above its neighbours while it rises, as SwiftUI's `zIndex` did.
        layer?.zPosition = hovered ? 1 : 0
        setElevation(hovered ? .hover : .rest, animated: animated)
        applyPose(animated: animated)
    }

    /// The held copy: lifted (bigger, deeper shadow) or set down on its slot.
    func setHeld(_ held: Bool, animated: Bool) {
        heldScale = held && !Motion.reduceMotion ? 1.03 : 1
        if !held { tilt = 0 }
        setElevation(held ? .held : .rest, animated: animated)
        applyPose(animated: animated)
    }

    /// The held copy's lean, in degrees, as it follows the hand (no animation: it is set at each frame).
    func setTilt(_ degrees: Double) {
        guard degrees != tilt else { return }
        tilt = degrees
        applyPose(animated: false)
    }

    private func setElevation(_ elevation: BoardElevation, animated: Bool) {
        guard elevation != self.elevation else { return }
        let old = self.elevation
        self.elevation = elevation
        applyLook()
        guard animated, !Motion.reduceMotion else { return }
        let duration = Motion.Spring.lift.duration
        for (key, from, to) in [
            ("shadowOpacity", old.shadowOpacity as Any, elevation.shadowOpacity as Any),
            ("shadowRadius", old.shadowRadius as Any, elevation.shadowRadius as Any),
            ("shadowOffset", NSValue(size: CGSize(width: 0, height: old.shadowY)), NSValue(size: CGSize(width: 0, height: elevation.shadowY))),
        ] {
            let animation = CABasicAnimation(keyPath: key)
            animation.fromValue = face.presentation()?.value(forKeyPath: key) ?? from
            animation.toValue = to
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            face.add(animation, forKey: key)
        }
    }

    /// The pose as a transform of what the card draws: risen, bigger, dipping toward the pointer, leaning.
    private var pose: CATransform3D {
        let hover = Motion.HoverPose.compact.resolved(hovered: isHovered)
        let scale = heldScale * hover.scale
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        var transform = CATransform3DMakeTranslation(-center.x, -center.y, 0)
        transform = CATransform3DConcat(transform, CATransform3DMakeScale(scale, scale, 1))
        if tilt != 0 { transform = CATransform3DConcat(transform, CATransform3DMakeRotation(tilt * .pi / 180, 0, 0, 1)) }
        let dip = hover.tilt(pointerX: Double(pointerX))
        if dip != 0 {
            transform = CATransform3DConcat(transform, CATransform3DMakeRotation(dip * .pi / 180, 0, 1, 0))
            var perspective = CATransform3DIdentity
            perspective.m34 = -1 / 600
            transform = CATransform3DConcat(transform, perspective)
        }
        // Up is a smaller y: the card's layer is flipped.
        return CATransform3DConcat(transform, CATransform3DMakeTranslation(center.x, center.y - hover.lift, 0))
    }

    private func applyPose(animated: Bool, follow: Bool = false) {
        guard let layer = body.layer else { return }
        let target = pose
        let from = layer.presentation()?.sublayerTransform ?? layer.sublayerTransform
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.sublayerTransform = target
        CATransaction.commit()
        guard animated, !Motion.reduceMotion, !CATransform3DEqualToTransform(from, target) else { return }
        let spring = follow
            ? CASpringAnimation(perceptualDuration: 0.16, bounce: 0)
            : CASpringAnimation(perceptualDuration: Motion.Spring.lift.duration, bounce: Motion.Spring.lift.bounce)
        spring.keyPath = "sublayerTransform"
        spring.fromValue = NSValue(caTransform3D: from)
        spring.toValue = NSValue(caTransform3D: target)
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: "pose")
    }
}

/// A card's fields and checklist, drawn once into its layer.
final class BoardCardDetails: CachedDrawingView {
    struct Content: Equatable {
        var lines: [BoardLine]
        var checklist: BoardChecklist?
        var theme: ThemeTokens
    }

    private var content: Content?

    static func lineHeight(_ font: NSFont) -> CGFloat { ceil(font.ascender - font.descender + font.leading) }
    /// An option's pill at 12 points (`OptionPill`).
    static var pillHeight: CGFloat { ceil(lineHeight(NSFont.ui(size: 12, weight: .medium)) + 12 * 0.4) }
    static let checklistHeight: CGFloat = 15

    func show(_ content: Content) {
        guard content != self.content else { return }
        self.content = content
        invalidate()
    }

    override func drawContent(in bounds: CGRect) {
        guard let content else { return }
        let theme = content.theme
        var y: CGFloat = 0
        for line in content.lines {
            y += BoardCardContent.spacing
            let rect = CGRect(x: 0, y: y, width: bounds.width, height: line.height)
            NSGraphicsContext.saveGraphicsState()
            rect.clip()
            draw(line, in: rect, theme: theme)
            NSGraphicsContext.restoreGraphicsState()
            y += line.height
        }
        if let list = content.checklist {
            y += BoardCardContent.spacing
            drawChecklist(list, in: CGRect(x: 0, y: y, width: bounds.width, height: Self.checklistHeight), theme: theme)
        }
    }

    private func draw(_ line: BoardLine, in rect: CGRect, theme: ThemeTokens) {
        let font = NSFont.ui(size: 13)
        switch line {
        case .text(let text): Self.text(text, font: font, color: NSColor(theme.text), in: rect)
        case .link(let text): Self.text(text, font: font, color: NSColor(theme.link), in: rect)
        case .checkbox(let on):
            guard let image = tintedSymbol(on ? "checkmark.square.fill" : "square", size: 13,
                                           color: on ? NSColor(theme.accent) : NSColor(theme.secondaryText)) else { return }
            image.draw(in: CGRect(x: rect.minX, y: rect.midY - image.size.height / 2, width: image.size.width, height: image.size.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        case .pills(let items, let options):
            // Whole pills at their own width, cut by the card rather than squeezed to "…".
            var x = rect.minX
            for item in items {
                guard x < rect.maxX else { break }
                x += Self.pill(item, options: options, at: x, midY: rect.midY) + 4
            }
        case .date(let day): Self.datePill(day, font: font, theme: theme, at: rect.minX, midY: rect.midY)
        }
    }

    /// One line of text in `rect`, cut with "…".
    private static func text(_ text: String, font: NSFont, color: NSColor, in rect: CGRect) {
        guard !text.isEmpty, rect.width > 0 else { return }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        NSAttributedString(string: text.replacingOccurrences(of: "\n", with: " "),
                           attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
            .draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// An option's pill (`OptionPill`, 12 points) at `x`; its width.
    private static func pill(_ text: String, options: [String], at x: CGFloat, midY: CGFloat) -> CGFloat {
        let swatch = OptionPalette.swatch(for: text, in: options)
        let size: CGFloat = 12
        let font = NSFont.ui(size: size, weight: .medium)
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor(swatch.text)])
        let measured = string.size()
        let rect = CGRect(x: x, y: midY - pillHeight / 2, width: ceil(measured.width + size * 1.1), height: pillHeight)
        let radius = Corners.r(6)
        NSColor(swatch.fill).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        NSColor(swatch.text.opacity(0.12)).setStroke()
        let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: max(0, radius - 0.5), yRadius: max(0, radius - 0.5))
        border.lineWidth = 1
        border.stroke()
        string.draw(at: CGPoint(x: x + size * 0.55, y: rect.midY - measured.height / 2))
        return rect.width
    }

    /// A date's pill (`DateValuePill`): a calendar and the day, blue, grey once past.
    private static func datePill(_ day: String, font: NSFont, theme: ThemeTokens, at x: CGFloat, midY: CGFloat) {
        let past = String(day.prefix(10)) < DateValuePill.today()
        let colour = NSColor(past ? theme.secondaryText : theme.link)
        let string = NSAttributedString(string: DateValuePill.label(day) ?? day, attributes: [.font: font, .foregroundColor: colour])
        let measured = string.size()
        let icon = tintedSymbol("calendar", size: 11, color: colour)
        let iconWidth = icon.map { $0.size.width + 4 } ?? 0
        let rect = CGRect(x: x, y: midY - (measured.height + 4) / 2, width: ceil(6 + iconWidth + measured.width + 6), height: ceil(measured.height + 4))
        colour.withAlphaComponent(past ? 0.1 : 0.12).setFill()
        let radius = Corners.r(6)
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        if let icon {
            icon.draw(in: CGRect(x: x + 6, y: rect.midY - icon.size.height / 2, width: icon.size.width, height: icon.size.height),
                      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        string.draw(at: CGPoint(x: x + 6 + iconWidth, y: rect.midY - measured.height / 2))
    }

    /// "☰ 1/3" and a bar: green when every item is done.
    private func drawChecklist(_ list: BoardChecklist, in rect: CGRect, theme: ThemeTokens) {
        let colour = NSColor(theme.secondaryText)
        var x = rect.minX
        if let icon = tintedSymbol("checklist", size: 11, color: colour) {
            icon.draw(in: CGRect(x: x, y: rect.midY - icon.size.height / 2, width: icon.size.width, height: icon.size.height),
                      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += icon.size.width + 6
        }
        let base = NSFont.ui(size: 12)
        let digits = NSFont(descriptor: base.fontDescriptor.addingAttributes([.featureSettings: [[
            NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
            NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
        ]]]), size: 12) ?? base
        let count = NSAttributedString(string: "\(list.done)/\(list.total)", attributes: [.font: digits, .foregroundColor: colour])
        let size = count.size()
        count.draw(at: CGPoint(x: x, y: rect.midY - size.height / 2))
        x += ceil(size.width) + 6
        let track = CGRect(x: x, y: rect.midY - 2, width: 64, height: 4)
        let radius = Corners.r(2)
        NSColor(theme.fillHover).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
        (list.done == list.total ? NSColor.systemGreen.withAlphaComponent(0.85) : NSColor(theme.accent)).setFill()
        let filled = CGRect(x: track.minX, y: track.minY, width: max(4, 64 * CGFloat(list.done) / CGFloat(list.total)), height: 4)
        NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
    }
}

/// A column's header: its value as a pill and how many cards.
final class BoardHeaderView: CachedDrawingView {
    struct Content: Equatable {
        var name: String
        var options: [String]
        var count: Int
        var theme: ThemeTokens
    }

    private var content: Content?

    func show(_ content: Content) {
        guard content != self.content else { return }
        // The count changing (a card came or left) cross-fades, as SwiftUI's `numericText` did.
        if let old = self.content, old.count != content.count, old.name == content.name, !Motion.reduceMotion {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.2
            layer?.add(fade, forKey: "count")
        }
        self.content = content
        invalidate()
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("\(content.name), \(content.count)")
    }

    override func drawContent(in bounds: CGRect) {
        guard let content else { return }
        let size: CGFloat = 14
        let swatch = OptionPalette.swatch(for: content.name, in: content.options)
        let font = NSFont.ui(size: size, weight: .medium)
        let name = NSAttributedString(string: content.name, attributes: [.font: font, .foregroundColor: NSColor(swatch.text)])
        let measured = name.size()
        let height = ceil(BoardCardDetails.lineHeight(font) + size * 0.4)
        let midY = (bounds.height - 2) / 2
        let pill = CGRect(x: 0, y: midY - height / 2, width: min(bounds.width - 30, ceil(measured.width + size * 1.1)), height: height)
        let radius = Corners.r(6)
        NSColor(swatch.fill).setFill()
        NSBezierPath(roundedRect: pill, xRadius: radius, yRadius: radius).fill()
        NSColor(swatch.text.opacity(0.12)).setStroke()
        let border = NSBezierPath(roundedRect: pill.insetBy(dx: 0.5, dy: 0.5), xRadius: max(0, radius - 0.5), yRadius: max(0, radius - 0.5))
        border.lineWidth = 1
        border.stroke()
        name.draw(with: CGRect(x: pill.minX + size * 0.55, y: midY - measured.height / 2, width: pill.width - size * 1.1, height: measured.height),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        // The count as `themeLabel`: the theme's mono face, a little smaller, spaced.
        let mono = (UIType.label.size * 0.78).rounded()
        let count = NSAttributedString(string: "\(content.count)", attributes: [
            .font: NSFont.theme(content.theme.monoFamily, size: mono), .foregroundColor: NSColor(content.theme.secondaryText),
            .kern: mono * 0.09,
        ])
        let countSize = count.size()
        count.draw(at: CGPoint(x: pill.maxX + 8, y: midY - countSize.height / 2))
    }
}

/// "+" under a column's cards, and "+" after the columns: a symbol on a soft card that takes the accent under the
/// pointer (`collectionHover`).
final class BoardPlusButton: NSView {
    private let symbol = CALayer()
    private let hover = CALayer()
    private var tracking: NSTrackingArea?
    var action: () -> Void = {}
    /// Whether it is the column's "+", with its soft card behind; else the round "+" of a new column.
    var isColumn = true { didSet { needsLayout = true } }
    private var theme = ThemeTokens.standard
    private var swatch = OptionPalette.grey

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        hover.cornerCurve = .continuous
        hover.opacity = 0
        layer?.addSublayer(hover)
        symbol.contentsGravity = .center
        layer?.addSublayer(symbol)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(theme: ThemeTokens, swatch: OptionPalette.Swatch, help: String) {
        self.theme = theme
        self.swatch = swatch
        toolTip = help
        setAccessibilityLabel(help)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = isColumn ? NSColor(theme.background.opacity(0.55)).cgColor : nil
            layer?.borderColor = NSColor(swatch.text.opacity(0.08)).cgColor
            hover.backgroundColor = NSColor(theme.accent.opacity(0.07 * 1.3)).cgColor
        }
        layer?.borderWidth = isColumn ? 1 : 0
        let image = tintedSymbol("plus", size: 15, color: NSColor(theme.secondaryText))
        symbol.contents = image
        symbol.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let radius = Corners.r(isColumn ? 8 : 16)
        layer?.cornerRadius = radius
        hover.frame = bounds
        hover.cornerRadius = radius
        symbol.frame = bounds
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false) }

    private func setHover(_ on: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        hover.opacity = on ? 1 : 0
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        action()
    }

    override func accessibilityPerformPress() -> Bool {
        action()
        return true
    }
}

/// A column's tinted background; it takes the stronger tint and a dashed outline while a card is held over it.
final class BoardColumnLayer: CALayer {
    private let outline = CAShapeLayer()
    private var swatch = OptionPalette.grey
    private(set) var isTargeted = false

    override init() {
        super.init()
        cornerCurve = .continuous
        outline.fillColor = nil
        outline.lineWidth = 1.5
        outline.lineDashPattern = [5, 4]
        outline.opacity = 0
        addSublayer(outline)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ swatch: OptionPalette.Swatch, frame: CGRect, appearance: NSAppearance) {
        self.swatch = swatch
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.frame = frame
        cornerRadius = Corners.r(10)
        outline.frame = bounds
        outline.path = CGPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), cornerWidth: max(0, cornerRadius - 0.75),
                              cornerHeight: max(0, cornerRadius - 0.75), transform: nil)
        appearance.performAsCurrentDrawingAppearance {
            backgroundColor = NSColor(isTargeted ? swatch.fill : swatch.tint).cgColor
            outline.strokeColor = NSColor(swatch.text.opacity(0.25)).cgColor
        }
        CATransaction.commit()
    }

    func setTargeted(_ targeted: Bool, appearance: NSAppearance) {
        guard targeted != isTargeted else { return }
        isTargeted = targeted
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        appearance.performAsCurrentDrawingAppearance {
            backgroundColor = NSColor(targeted ? swatch.fill : swatch.tint).cgColor
        }
        outline.opacity = targeted ? 1 : 0
        CATransaction.commit()
    }
}

/// The inline field that turns into a card on Return; Escape, or leaving it empty, takes it away.
final class BoardAddField: NSView, NSTextFieldDelegate {
    let field = NSTextField()
    var commit: (String) -> Void = { _ in }
    var cancel: () -> Void = {}
    private var finished = false

    override var isFlipped: Bool { true }

    init(theme: ThemeTokens) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = Corners.r(8)
        layer?.borderWidth = 1.5
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor(theme.background).cgColor
            layer?.borderColor = NSColor(theme.accent.opacity(0.5)).cgColor
        }
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .ui(size: 15, weight: .semibold)
        field.textColor = NSColor(theme.text)
        field.placeholderString = String(localized: "Title")
        field.delegate = self
        field.cell?.isScrollable = true
        addSubview(field)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        let height = BoardCardDetails.lineHeight(field.font ?? .ui(size: 15)) + 2
        field.frame = CGRect(x: 12, y: (bounds.height - height) / 2, width: max(0, bounds.width - 24), height: height)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            finish(commit: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            finish(commit: false)
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        // Clicked away: a title typed is kept as a card, an empty field goes.
        finish(commit: !field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private func finish(commit: Bool) {
        guard !finished else { return }
        finished = true
        let title = field.stringValue.trimmingCharacters(in: .whitespaces)
        if commit, !title.isEmpty { self.commit(title) } else { cancel() }
    }
}

/// "“Title” deleted · Undo", at the bottom of the board for a few seconds after a card went to the trash.
struct BoardUndoBar: View {
    let title: String
    let undo: () -> Void
    @Environment(\.themeTokens) private var theme

    var body: some View {
        HStack(spacing: 12) {
            Text("“\(title)” deleted").lineLimit(1).foregroundStyle(theme.text)
            Button("Undo", action: undo)
                .buttonStyle(.plain)
                .foregroundStyle(theme.accent)
                .fontWeight(.semibold)
        }
        .font(.ui(size: 13))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(ThemeCapsule().fill(theme.background))
        .overlay(ThemeCapsule().strokeBorder(theme.separator.opacity(0.7)))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .padding(.bottom, 14)
    }
}
