import AppKit
import PluginKitUI

/// A diagram shown over the page, large, to read and zoom: a click on a diagram opens it, as Craft opens one,
/// instead of showing its code. Pinch, Cmd-+ and Cmd-- zoom, Cmd-0 fits it, dragging or scrolling pans; Escape or a
/// click beside the picture closes it. "Edit Code" shows Craft's code page: the diagram on top, drawn again as the
/// code below it changes, and the code, written back to the note as it is typed (`CodeEditing`). Without a
/// `CodeEditing`, "Edit Code" closes it with the caret in the code.
///
/// It covers the editor's pane only (the view the editor's scroll view sits in), fades in while the picture grows
/// from a little smaller (`Motion.Metrics.overlayScale`), and fades out (`Motion.exit`).
@MainActor
final class PictureViewer: NSView, NSTextViewDelegate {
    /// What the code page edits: the block's code, how to draw it, and how to write it back to the note.
    struct CodeEditing {
        let code: String
        /// The picture of some code; nil when it does not draw (a syntax error).
        let render: @MainActor (String) async -> NSImage?
        /// Writes the code back into the block.
        let commit: @MainActor (String) -> Void
    }

    /// What "Edit Code" edits; nil to fall back on `onEditCode`.
    var codeEditing: CodeEditing?
    /// What "Edit Code" does without a `codeEditing`: puts the caret in the block.
    var onEditCode: (() -> Void)?
    /// What closing does once the viewer is gone: gives the keys back to the editor.
    var onClose: (() -> Void)?

    private let scrollView = ZoomScrollView()
    private let imageView = NSImageView()
    private let bar = NSVisualEffectView()
    private let zoomLabel = NSTextField(labelWithString: "100%")
    private var imageSize: NSSize
    /// The code page's parts, built when it first shows.
    private let header = NSStackView()
    private let codeScroll = NSScrollView()
    private let codeView = NSTextView()
    private let errorLabel = NSTextField(labelWithString: "This code does not draw yet.")
    private var viewing: [NSLayoutConstraint] = []
    private var editing: [NSLayoutConstraint] = []
    private(set) var isEditingCode = false
    private var renderTask: Task<Void, Never>?
    private var commitTask: Task<Void, Never>?

    static let minMagnification: CGFloat = 0.25
    static let maxMagnification: CGFloat = 6
    /// How much a Cmd-+ or Cmd-- multiplies the zoom by.
    static let step: CGFloat = 1.25
    /// The room left around the picture when it is fitted.
    static let margin: CGFloat = 40
    /// The height of the page's toolbar floating over the editor's top, which the code page's header goes under.
    static let toolbarRoom: CGFloat = 64

    init(image: NSImage) {
        imageSize = image.size
        super.init(frame: .zero)
        wantsLayer = true

        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.frame = NSRect(origin: .zero, size: image.size)
        let document = CenteringClipView()
        scrollView.contentView = document
        scrollView.documentView = imageView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = Self.minMagnification
        scrollView.maxMagnification = Self.maxMagnification
        scrollView.onClickOutside = { [weak self] in self?.close() }
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        bar.material = .popover
        bar.blendingMode = .withinWindow
        bar.state = .active
        bar.wantsLayer = true
        bar.layer?.cornerRadius = Corners.r(10)
        bar.layer?.cornerCurve = .continuous
        bar.layer?.masksToBounds = true
        bar.translatesAutoresizingMaskIntoConstraints = false
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        zoomLabel.textColor = .secondaryLabelColor
        zoomLabel.alignment = .center
        zoomLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true
        let stack = NSStackView(views: [
            Self.button("minus.magnifyingglass", "Zoom Out", self, #selector(zoomOut)),
            zoomLabel,
            Self.button("plus.magnifyingglass", "Zoom In", self, #selector(zoomIn)),
            Self.button("arrow.up.left.and.down.right.magnifyingglass", "Fit", self, #selector(fit)),
            Self.textButton("Edit Code", self, #selector(editCode)),
            Self.button("xmark", "Close", self, #selector(closeViewer)),
        ])
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        addSubview(bar)

        buildCodePage()
        viewing = [
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]
        editing = [
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: codeScroll.topAnchor),
            codeScroll.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.45),
        ]
        NSLayoutConstraint.activate(viewing)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            bar.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
        NotificationCenter.default.addObserver(
            self, selector: #selector(magnificationChanged), name: NSScrollView.didEndLiveMagnifyNotification, object: scrollView
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The page's own background, so the diagram reads as it does in the note.
    var background: NSColor = .textBackgroundColor
    /// The background of the code, as a code block has it in the note.
    var codeBackground: NSColor = .textBackgroundColor {
        didSet { codeScroll.backgroundColor = codeBackground }
    }
    /// Whether the zoom was chosen (a key, a button, a pinch): until then a new picture of the code is fitted again.
    private var zoomChosen = false

    override func draw(_ dirtyRect: NSRect) {
        background.setFill()
        dirtyRect.fill()
    }

    // MARK: Showing

    /// Puts the viewer over `host`, the picture fitted, and takes the keys.
    func show(over host: NSView) {
        frame = host.bounds
        autoresizingMask = [.width, .height]
        host.addSubview(self)
        layoutSubtreeIfNeeded()
        scrollView.magnification = fittedMagnification
        updateZoomLabel()
        window?.makeFirstResponder(self)

        alphaValue = 0
        let duration = Motion.appKitDuration(0.18)
        if duration > 0, let layer = scrollView.layer {
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = Motion.Metrics.overlayScale
            grow.toValue = 1
            grow.duration = duration
            grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(grow, forKey: "grow")
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }

    func close() {
        guard superview != nil else { return }
        commitNow()
        let onClose = onClose
        self.onClose = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.appKitDuration(0.12)
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.removeFromSuperview() }
        }
        onClose?()
    }

    // MARK: Zoom

    /// The zoom that shows the whole picture in the viewer: a small diagram grows, up to `maxFit` times its size.
    var fittedMagnification: CGFloat {
        let area = scrollView.frame.size == .zero ? bounds.size : scrollView.frame.size
        let room = NSSize(width: max(area.width - 2 * Self.margin, 1), height: max(area.height - 2 * Self.margin - (isEditingCode ? 0 : 50), 1))
        let fit = min(room.width / max(imageSize.width, 1), room.height / max(imageSize.height, 1))
        return min(max(min(fit, Self.maxFit), Self.minMagnification), Self.maxMagnification)
    }

    /// The most a fitted diagram grows: past that a small diagram looks blown up.
    static let maxFit: CGFloat = 2

    var magnification: CGFloat { scrollView.magnification }

    private func zoom(to value: CGFloat) {
        let target = min(max(value, Self.minMagnification), Self.maxMagnification)
        let center = NSPoint(x: scrollView.contentView.bounds.midX, y: scrollView.contentView.bounds.midY)
        if Motion.reduceMotion {
            scrollView.setMagnification(target, centeredAt: center)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                scrollView.animator().setMagnification(target, centeredAt: center)
            }
        }
        zoomLabel.stringValue = "\(Int((target * 100).rounded()))%"
    }

    @objc func zoomIn() { zoomChosen = true; zoom(to: scrollView.magnification * Self.step) }
    @objc func zoomOut() { zoomChosen = true; zoom(to: scrollView.magnification / Self.step) }
    @objc func fit() { zoomChosen = false; zoom(to: fittedMagnification) }
    @objc func editCode() {
        guard let codeEditing else {
            let edit = onEditCode
            close()
            edit?()
            return
        }
        guard !isEditingCode else { return }
        isEditingCode = true
        codeView.string = codeEditing.code
        bar.isHidden = true
        header.isHidden = false
        codeScroll.isHidden = false
        NSLayoutConstraint.deactivate(viewing)
        NSLayoutConstraint.activate(editing)
        layoutSubtreeIfNeeded()
        scrollView.magnification = fittedMagnification
        window?.makeFirstResponder(codeView)
        codeView.setSelectedRange(NSRange(location: 0, length: 0))
    }

    // MARK: The code page

    private func buildCodePage() {
        let back = Self.button("chevron.left", "Back to the Note", self, #selector(closeViewer))
        back.isBordered = true
        back.bezelStyle = .rounded
        let title = NSTextField(labelWithString: "Code")
        title.font = .systemFont(ofSize: 20, weight: .bold)
        header.orientation = .horizontal
        header.spacing = 12
        // Below the page's own toolbar, which floats over the top of the editor.
        header.edgeInsets = NSEdgeInsets(top: Self.toolbarRoom, left: 16, bottom: 10, right: 16)
        header.setViews([back, title], in: .leading)
        header.translatesAutoresizingMaskIntoConstraints = false
        header.isHidden = true
        addSubview(header)

        codeView.isRichText = false
        codeView.allowsUndo = true
        codeView.isAutomaticQuoteSubstitutionEnabled = false
        codeView.isAutomaticDashSubstitutionEnabled = false
        codeView.isAutomaticTextReplacementEnabled = false
        codeView.isContinuousSpellCheckingEnabled = false
        codeView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        codeView.textContainerInset = NSSize(width: 16, height: 14)
        codeView.drawsBackground = false
        codeView.delegate = self
        codeView.isVerticallyResizable = true
        codeView.autoresizingMask = [.width]
        codeView.textContainer?.widthTracksTextView = true
        codeScroll.documentView = codeView
        codeScroll.hasVerticalScroller = true
        codeScroll.autohidesScrollers = true
        codeScroll.drawsBackground = true
        codeScroll.translatesAutoresizingMaskIntoConstraints = false
        codeScroll.isHidden = true
        addSubview(codeScroll)
        let rule = NSBox()
        rule.boxType = .separator
        rule.translatesAutoresizingMaskIntoConstraints = false
        codeScroll.addSubview(rule)

        errorLabel.font = .systemFont(ofSize: 11, weight: .medium)
        errorLabel.textColor = .secondaryLabelColor
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.isHidden = true
        addSubview(errorLabel)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            codeScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            codeScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            codeScroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            rule.topAnchor.constraint(equalTo: codeScroll.topAnchor),
            rule.leadingAnchor.constraint(equalTo: codeScroll.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: codeScroll.trailingAnchor),
            errorLabel.bottomAnchor.constraint(equalTo: codeScroll.topAnchor, constant: -8),
            errorLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])
    }

    func textDidChange(_ notification: Notification) {
        guard let codeEditing else { return }
        let code = codeView.string
        renderTask?.cancel()
        renderTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let image = await codeEditing.render(code)
            guard let self, !Task.isCancelled else { return }
            self.errorLabel.isHidden = image != nil
            if let image { self.showPicture(image) }
        }
        commitTask?.cancel()
        commitTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.commitNow()
        }
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        close()
        return true
    }

    /// Writes what the code page holds back to the note, if it changed.
    private var committed: String?
    private func commitNow() {
        commitTask?.cancel()
        guard isEditingCode, let codeEditing else { return }
        let code = codeView.string
        guard code != (committed ?? codeEditing.code) else { return }
        committed = code
        codeEditing.commit(code)
    }

    /// Puts a new picture of the code in place, keeping the zoom.
    private func showPicture(_ image: NSImage) {
        imageView.image = image
        imageSize = image.size
        imageView.frame = NSRect(origin: .zero, size: image.size)
        if !zoomChosen {
            scrollView.magnification = fittedMagnification
            updateZoomLabel()
        }
    }
    @objc private func closeViewer() { close() }

    @objc private func magnificationChanged() {
        zoomChosen = true
        updateZoomLabel()
    }

    private func updateZoomLabel() {
        zoomLabel.stringValue = "\(Int((scrollView.magnification * 100).rounded()))%"
    }

    // MARK: Keys

    override var acceptsFirstResponder: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self || window?.firstResponder === codeView else {
            return super.performKeyEquivalent(with: event)
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.shift, .numericPad, .function])
        guard modifiers == .command else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers {
        case "=", "+": zoomIn()
        case "-": zoomOut()
        case "0": fit()
        case "w": close()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case "+", "=": zoomIn()
        case "-": zoomOut()
        case "0": fit()
        case "\r": editCode()
        default: interpretKeyEvents([event])
        }
    }

    override func cancelOperation(_ sender: Any?) { close() }

    // MARK: Building

    private static func button(_ symbol: String, _ label: String, _ target: AnyObject, _ action: Selector) -> NSButton {
        let image = NSImage.symbol(symbol, accessibilityDescription: label) ?? NSImage()
        let button = NSButton(image: image, target: target, action: action)
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return button
    }

    private static func textButton(_ title: String, _ target: AnyObject, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .accessoryBarAction
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.setAccessibilityLabel(title)
        return button
    }
}

/// The viewer's scroll view: a click on the empty room around the picture closes the viewer.
private final class ZoomScrollView: NSScrollView {
    var onClickOutside: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        // A press on the picture pans it; a press beside it closes the viewer.
        guard let document = documentView, document.bounds.contains(document.convert(event.locationInWindow, from: nil)) else {
            onClickOutside?()
            return
        }
        var last = event.locationInWindow
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type == .leftMouseDragged {
            let delta = NSPoint(x: next.locationInWindow.x - last.x, y: next.locationInWindow.y - last.y)
            last = next.locationInWindow
            var origin = contentView.bounds.origin
            origin.x -= delta.x / magnification
            origin.y += delta.y / magnification * (contentView.isFlipped ? 1 : -1)
            contentView.scroll(to: contentView.constrainBoundsRect(NSRect(origin: origin, size: contentView.bounds.size)).origin)
            reflectScrolledClipView(contentView)
        }
    }
}

/// Keeps a picture smaller than the viewer in its middle rather than at its bottom-left corner.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
        if rect.height > document.frame.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
        return rect
    }
}
