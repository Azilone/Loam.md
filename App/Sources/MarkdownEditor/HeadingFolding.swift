import AppKit
import PluginKitUI

/// The chevron left of a heading, as in Bear and Obsidian: it points down while the heading is open and turns to
/// point right when it folds. Shown on hover; a folded heading's chevron the page draws all the time.
final class FoldChevronView: NSView {
    static let size = NSSize(width: 18, height: 24)
    /// How far left of the heading's text it stands: left of the block handle.
    static let offset: CGFloat = BlockHandleView.offset + 20

    var onClick: (() -> Void)?
    /// The heading it stands for.
    var section: HeadingFolds.Section?
    var color: NSColor = .secondaryLabelColor { didSet { updateColors() } }
    var hoverColor: NSColor = .quaternaryLabelColor

    private let chevron = CAShapeLayer()
    private var isHovered = false {
        didSet { if isHovered != oldValue { updateColors() } }
    }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Corners.r(4)
        layer?.cornerCurve = .continuous
        chevron.fillColor = nil
        chevron.lineWidth = 1.6
        chevron.lineCap = .round
        chevron.lineJoin = .round
        layer?.addSublayer(chevron)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        // A chevron pointing down, drawn round its centre so it turns in place.
        let path = CGMutablePath()
        path.move(to: CGPoint(x: -4, y: -2))
        path.addLine(to: CGPoint(x: 0, y: 2))
        path.addLine(to: CGPoint(x: 4, y: -2))
        chevron.path = path
        chevron.bounds = CGRect(x: -5, y: -5, width: 10, height: 10)
        chevron.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chevron.transform = transform(folded: isFolded)
        CATransaction.commit()
    }

    private(set) var isFolded = false

    /// Points it down (open) or right (folded), turning with a short spring when `animated`.
    func setFolded(_ folded: Bool, animated: Bool) {
        let from = chevron.presentation()?.transform ?? chevron.transform
        isFolded = folded
        setAccessibilityLabel(folded ? "Unfold heading" : "Fold heading")
        let to = transform(folded: folded)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chevron.transform = to
        CATransaction.commit()
        guard animated, !Motion.reduceMotion else { return }
        let turn = CASpringAnimation(perceptualDuration: Motion.Spring.tap.duration, bounce: Motion.Spring.tap.bounce)
        turn.keyPath = "transform"
        turn.fromValue = from
        turn.toValue = to
        chevron.add(turn, forKey: "turn")
    }

    private func transform(folded: Bool) -> CATransform3D {
        // The layer is flipped like the view: a quarter turn the other way points the chevron right.
        folded ? CATransform3DMakeRotation(-.pi / 2, 0, 0, 1) : CATransform3DIdentity
    }

    private func updateColors() {
        chevron.strokeColor = color.cgColor
        layer?.backgroundColor = isHovered ? hoverColor.cgColor : nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { updateColors() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    func show() {
        guard isHidden || alphaValue < 1 else { return }
        isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.appKitDuration(0.12)
            animator().alphaValue = 1
        }
    }

    func hide() {
        guard !isHidden else { return }
        isHovered = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.appKitDuration(0.12)
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            if self?.alphaValue == 0 { self?.isHidden = true }
        }
    }
}

/// Leaves the paragraphs of folded headings out of the layout: TextKit 2 lays out only what the content storage
/// enumerates, so a folded body takes no room at all (no line, no spacing) and the caret steps over it.
final class FoldingContentDelegate: NSObject, NSTextContentStorageDelegate {
    weak var textView: EditorTextView?

    func textContentManager(
        _ textContentManager: NSTextContentManager, shouldEnumerate textElement: NSTextElement,
        options: NSTextContentManager.EnumerationOptions
    ) -> Bool {
        guard let textView, !textView.foldedBodies.isEmpty, let range = textElement.elementRange else { return true }
        let offset = textContentManager.offset(from: textContentManager.documentRange.location, to: range.location)
        return !textView.isFolded(offset)
    }
}

/// The page's fold and unfold: what follows the heading slides up over the body as it fades (folding), or slides
/// down to uncover it (unfolding). Drawn from two pictures of the page, before and after, so the text itself is laid
/// out once, not on each frame (MOTION.md, "off the main thread when it is big").
private final class FoldTransitionView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension EditorTextView {
    /// Whether `location` is in the body of a folded heading.
    func isFolded(_ location: Int) -> Bool {
        foldedBodies.contains { NSLocationInRange(location, $0) }
    }

    /// The headings that can fold and what the page hides, from the controller's last restyle. `animating` is the
    /// heading whose fold changed: the page shows the change moving.
    func setFolds(sections: [HeadingFolds.Section], bodies: [NSRange], animating section: HeadingFolds.Section? = nil) {
        foldSections = sections
        if let shown = foldChevron.section, !sections.contains(shown) { foldChevron.section = nil; foldChevron.hide() }
        guard bodies != foldedBodies else {
            needsDisplay = true
            return
        }
        let changed = (bodies + foldedBodies).reduce(nil as NSRange?) { union, range in union.map { NSUnionRange($0, range) } ?? range }
        let canAnimate = section.map { lineBox(for: $0.heading).map { visibleRect.intersects($0) } ?? false } ?? false
        let before = canAnimate ? snapshot() : nil
        let followerBefore = section.flatMap { followerTop(of: $0) }
        foldedBodies = bodies
        relayout(changed)
        needsDisplay = true
        if let section, let before, let followerBefore, let followerAfter = followerTop(of: section) {
            animateFold(from: before, followerBefore: followerBefore, followerAfter: followerAfter)
        }
    }

    /// Lays the paragraphs of `range` out again, which asks the delegate again which of them to show.
    private func relayout(_ range: NSRange?) {
        guard let range, let storage = textStorage, let layout = textLayoutManager,
              let content = layout.textContentManager as? NSTextContentStorage else { return }
        let whole = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
        content.performEditingTransaction {
            storage.edited(.editedAttributes, range: whole, changeInLength: 0)
        }
        layout.textViewportLayoutController.layoutViewport()
        layoutSubtreeIfNeeded()
    }

    /// Where what follows the heading's body starts, in view coordinates: the next line shown, or the end of the text.
    private func followerTop(of section: HeadingFolds.Section) -> CGFloat? {
        guard let storage = textStorage, let layout = textLayoutManager, let content = layout.textContentManager else { return nil }
        let end = NSMaxRange(section.body)
        if end < storage.length, let location = content.location(content.documentRange.location, offsetBy: end) {
            layout.ensureLayout(for: NSTextRange(location: location))
            if let fragment = layout.textLayoutFragment(for: location) { return fragment.layoutFragmentFrame.minY + textContainerOrigin.y }
        }
        layout.ensureLayout(for: layout.documentRange)
        return layout.usageBoundsForTextContainer.maxY + textContainerOrigin.y
    }

    /// A picture of the visible part of the page, as drawn now.
    private func snapshot() -> (image: CGImage, rect: NSRect)? {
        let rect = visibleRect
        guard rect.width > 0, rect.height > 0, let rep = bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        cacheDisplay(in: rect, to: rep)
        return rep.cgImage.map { ($0, rect) }
    }

    private func animateFold(from before: (image: CGImage, rect: NSRect), followerBefore: CGFloat, followerAfter: CGFloat) {
        foldTransition?.removeFromSuperview()
        foldTransition = nil
        let visible = visibleRect
        let folding = followerAfter < followerBefore
        // The body's room: between where what follows starts when folded and when unfolded.
        let top = min(followerBefore, followerAfter)
        let distance = abs(followerBefore - followerAfter)
        guard distance > 0.5, top < visible.maxY, let after = snapshot() else { return }
        let overlay = FoldTransitionView(frame: NSRect(x: visible.minX, y: max(top, visible.minY), width: visible.width, height: visible.maxY - max(top, visible.minY)))
        overlay.wantsLayer = true
        guard let root = overlay.layer else { return }
        root.masksToBounds = true
        root.backgroundColor = theme.backgroundColor.cgColor
        addSubview(overlay, positioned: .above, relativeTo: nil)
        foldTransition = overlay

        /// A layer showing `rect` (view coordinates) of a picture of the visible page, placed in the overlay.
        func slice(of picture: (image: CGImage, rect: NSRect), _ rect: NSRect, opaque: Bool) -> CALayer {
            let layer = CALayer()
            let clipped = rect.intersection(picture.rect)
            let scale = CGFloat(picture.image.height) / picture.rect.height
            let pixels = CGRect(x: (clipped.minX - picture.rect.minX) * scale, y: (clipped.minY - picture.rect.minY) * scale,
                                width: clipped.width * scale, height: clipped.height * scale).integral
            layer.contents = picture.image.cropping(to: pixels)
            layer.contentsGravity = .resize
            if opaque { layer.backgroundColor = theme.backgroundColor.cgColor }
            layer.frame = CGRect(x: clipped.minX - overlay.frame.minX, y: clipped.minY - overlay.frame.minY,
                                 width: clipped.width, height: clipped.height)
            return layer
        }

        let duration = Motion.Spring.smooth.duration
        if Motion.reduceMotion {
            // A fade from the page before to the page after, nothing moving.
            let old = slice(of: before, overlay.frame, opaque: true)
            root.backgroundColor = nil
            root.addSublayer(old)
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self, weak overlay] in self?.endFoldTransition(overlay) }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = Motion.appKitDuration(0.12)
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            old.opacity = 0
            old.add(fade, forKey: "fade")
            CATransaction.commit()
            return
        }
        // The body: from the picture where it shows (before folding, after unfolding).
        let body = slice(of: folding ? before : after, NSRect(x: visible.minX, y: top, width: visible.width, height: distance), opaque: false)
        // What follows the body, as one sheet over it: from the picture where it sits higher up, so the sheet covers
        // the page to its bottom all the way.
        let sheet = slice(of: folding ? after : before, NSRect(x: visible.minX, y: top, width: visible.width, height: visible.maxY - top), opaque: true)
        root.addSublayer(body)
        root.addSublayer(sheet)
        // The body shrinks a little towards its heading as it goes, and grows from there as it comes.
        let bodyFrame = body.frame
        body.anchorPoint = CGPoint(x: 0.5, y: 0)
        body.frame = bodyFrame

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak overlay] in self?.endFoldTransition(overlay) }
        let slide = CASpringAnimation(perceptualDuration: duration, bounce: Motion.Spring.smooth.bounce)
        slide.keyPath = "position.y"
        let low = sheet.position.y + distance
        let high = sheet.position.y
        slide.fromValue = folding ? low : high
        slide.toValue = folding ? high : low
        slide.duration = slide.settlingDuration
        sheet.position.y = folding ? high : low
        sheet.add(slide, forKey: "slide")

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = folding ? 1 : 0
        fade.toValue = folding ? 0 : 1
        fade.duration = folding ? duration * 0.6 : duration
        fade.timingFunction = CAMediaTimingFunction(name: folding ? .easeIn : .easeOut)
        body.opacity = folding ? 0 : 1
        body.add(fade, forKey: "fade")

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = folding ? 1 : 0.98
        scale.toValue = folding ? 0.98 : 1
        scale.duration = duration
        scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
        body.add(scale, forKey: "scale")
        CATransaction.commit()
    }

    private func endFoldTransition(_ overlay: NSView?) {
        guard let overlay, overlay === foldTransition else { return }
        overlay.removeFromSuperview()
        foldTransition = nil
    }

    // MARK: Chevron and pill

    /// The section whose heading line is at `point`'s height, among those on screen.
    private func foldSection(at point: NSPoint) -> (HeadingFolds.Section, NSRect)? {
        guard let container = textContainer, isEditable || !foldedBodies.isEmpty else { return nil }
        let left = textContainerOrigin.x + container.lineFragmentPadding
        guard point.x >= left - (chevronFitsBesideHandle ? FoldChevronView.offset : BlockHandleView.offset) - 4, point.x <= left + container.size.width else { return nil }
        let drawn = drawnRange()
        for section in foldSections where NSLocationInRange(section.heading.location, drawn) || section.heading.location == NSMaxRange(drawn) {
            guard !isFolded(section.heading.location), let box = lineBox(for: section.heading) else { continue }
            if point.y >= box.minY, point.y <= box.maxY { return (section, box) }
        }
        return nil
    }

    /// Whether the margin has room for the chevron left of the block handle. A narrow page (sidebars open) has room
    /// for one of them: the chevron takes the handle's place on a heading.
    var chevronFitsBesideHandle: Bool {
        let left = textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0)
        return left - FoldChevronView.offset >= bounds.minX + 2
    }

    private func chevronFrame(for box: NSRect) -> NSRect {
        let left = textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0)
        let size = FoldChevronView.size
        let offset = chevronFitsBesideHandle ? FoldChevronView.offset : BlockHandleView.offset
        return NSRect(x: left - offset, y: (textMidY(box) - size.height / 2).rounded(), width: size.width, height: size.height)
    }

    /// Whether `block` starts on a heading that folds, where a narrow page shows the chevron instead of the handle.
    func chevronReplacesHandle(on block: MarkdownBlock) -> Bool {
        !chevronFitsBesideHandle && foldSections.contains { $0.heading.location == block.firstLine.location }
    }

    /// Shows the chevron by the heading under `point`, and hides it elsewhere.
    func updateFoldChevron(at point: NSPoint?) {
        if let point, !foldChevron.isHidden, foldChevron.alphaValue > 0, foldChevron.frame.contains(point) {
            return foldChevron.show()
        }
        guard let point, let (section, box) = foldSection(at: point) else {
            foldChevron.section = nil
            foldChevron.hide()
            return
        }
        if foldChevron.superview !== self {
            foldChevron.alphaValue = 0
            foldChevron.isHidden = true
            foldChevron.onClick = { [weak self] in
                guard let self, let section = self.foldChevron.section else { return }
                self.onToggleFold?(section)
            }
            addSubview(foldChevron, positioned: .above, relativeTo: nil)
        }
        foldChevron.color = theme.secondaryTextColor.withAlphaComponent(0.8)
        foldChevron.hoverColor = theme.textColor.withAlphaComponent(0.08)
        let frame = chevronFrame(for: box)
        if foldChevron.section != section {
            foldChevron.section = section
            foldChevron.setFolded(foldedBodies.contains { NSLocationInRange(section.body.location, $0) }, animated: false)
        }
        if foldChevron.frame != frame {
            foldChevron.frame = frame
            window?.invalidateCursorRects(for: foldChevron)
        }
        foldChevron.show()
    }

    /// The folded headings on screen: their heading line and where their pill is.
    private func foldedHeadings(in drawn: NSRange) -> [(section: HeadingFolds.Section, box: NSRect, pill: NSRect)] {
        foldSections.compactMap { section in
            guard foldedBodies.contains(where: { $0.location == section.body.location || NSLocationInRange(section.body.location, $0) }),
                  !isFolded(section.heading.location),
                  NSLocationInRange(section.heading.location, drawn) || section.heading.location == NSMaxRange(drawn),
                  let box = lineBox(for: section.heading) else { return nil }
            let textEnd = segments(for: section.heading).last?.maxX ?? box.minX
            let height = (theme.fontSize * 0.95).rounded()
            let pill = NSRect(x: (textEnd + 10).rounded(), y: (textMidY(box) - height / 2).rounded(), width: (height * 1.75).rounded(), height: height)
            return (section, box, pill)
        }
    }

    /// Each folded heading's chevron, pointing right, and its pill of three dots after the text (Bear's): the pill
    /// unfolds it too.
    func drawFolds(in drawn: NSRange) {
        guard !foldedBodies.isEmpty else { return }
        for (section, box, pill) in foldedHeadings(in: drawn) {
            if foldChevron.section != section || foldChevron.isHidden {
                let frame = chevronFrame(for: box)
                let path = NSBezierPath()
                path.move(to: NSPoint(x: frame.midX - 2, y: frame.midY - 4))
                path.line(to: NSPoint(x: frame.midX + 2, y: frame.midY))
                path.line(to: NSPoint(x: frame.midX - 2, y: frame.midY + 4))
                path.lineWidth = 1.6
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                theme.accentColor.setStroke()
                path.stroke()
            }
            theme.textColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(continuousRoundedRect: pill, radius: Corners.r(pill.height / 2.6)).fill()
            theme.secondaryTextColor.setFill()
            let dot: CGFloat = 3
            for index in -1...1 {
                let x = pill.midX + CGFloat(index) * (dot + 2.5) - dot / 2
                NSBezierPath(ovalIn: NSRect(x: x, y: pill.midY - dot / 2, width: dot, height: dot)).fill()
            }
        }
    }

    /// The folded heading whose pill or chevron is at `point`, for a click to unfold it.
    func foldedHeading(at point: NSPoint) -> HeadingFolds.Section? {
        guard !foldedBodies.isEmpty else { return nil }
        return foldedHeadings(in: drawnRange()).first { item in
            item.pill.insetBy(dx: -3, dy: -3).contains(point) || chevronFrame(for: item.box).contains(point)
        }?.section
    }
}

extension EditorController {
    /// The headings that can fold in the restyled text, and what the page hides of them. A fold whose body holds the
    /// caret opens: Return at the end of a folded heading, or a search landing inside, shows the lines.
    func updateFolds(spans: [StyleSpan], text: NSString, animating section: HeadingFolds.Section? = nil) {
        guard textView != nil else { return }
        setFoldSections(syntaxMode == .rendered ? HeadingFolds.sections(in: spans, text: text) : [], animating: section)
    }

    /// The block editor's folds: its heading blocks fold what follows them.
    func updateBlockFolds(_ scan: PageScan) {
        guard let storage = textView?.textStorage else { return }
        setFoldSections(PageBlocks.sections(of: scan.headings, in: storage), animating: nil)
    }

    private func setFoldSections(_ sections: [HeadingFolds.Section], animating section: HeadingFolds.Section?) {
        guard let textView else { return }
        foldSections = sections
        folds.keep(sections)
        let caret = textView.selectedRange()
        for section in sections where folds.isFolded(section) && Self.hides(section.body, caret) { folds.unfold(section) }
        textView.setFolds(sections: sections, bodies: folds.bodies(of: sections), animating: section)
    }

    /// Folds or unfolds a heading, the page showing it move. A caret in the lines folding away goes to the end of
    /// the heading.
    func toggleFold(_ section: HeadingFolds.Section) {
        guard let textView, let current = foldSections.first(where: { $0.heading.location == section.heading.location }) else { return }
        folds.toggle(current)
        let folding = folds.isFolded(current)
        if folding, Self.hides(current.body, textView.selectedRange()) {
            textView.setSelectedRange(NSRange(location: NSMaxRange(current.heading), length: 0))
        }
        textView.setFolds(sections: foldSections, bodies: folds.bodies(of: foldSections), animating: current)
        if textView.foldChevron.section == current { textView.foldChevron.setFolded(folding, animated: true) }
        onViewStateChange(viewState)
    }

    /// Opens the folds the selection went into (a search, Select All, the caret moved by code).
    func unfoldAroundSelection() {
        guard let textView, !folds.isEmpty else { return }
        let selection = textView.selectedRange()
        let opened = foldSections.filter { folds.isFolded($0) && Self.hides($0.body, selection) }
        guard !opened.isEmpty else { return }
        for section in opened { folds.unfold(section) }
        textView.setFolds(sections: foldSections, bodies: folds.bodies(of: foldSections))
    }

    /// Whether a fold of `body` would hide an end of `selection`. A selection over the whole fold (Select All)
    /// leaves it folded.
    private static func hides(_ body: NSRange, _ selection: NSRange) -> Bool {
        NSLocationInRange(selection.location, body)
            || (selection.length > 0 && NSMaxRange(selection) < NSMaxRange(body) && NSLocationInRange(NSMaxRange(selection), body))
    }
}
