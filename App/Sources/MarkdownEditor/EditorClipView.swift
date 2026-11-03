import AppKit
import PluginKitUI

/// How much text is beyond the top and bottom edge of the editor's scroll view, in points; negative while pulled
/// past an end. The host turns it into the glass at the edges (`EdgeGlassBand`).
public struct EditorScrollEdges: Equatable, Sendable {
    public var top: CGFloat
    public var bottom: CGFloat

    public init(top: CGFloat, bottom: CGFloat) {
        self.top = top
        self.bottom = bottom
    }
}

/// The editor's clip view. It keeps the text view only as wide as the column and the room beside it
/// (`EditorTextView.fittingWidth(in:)`) and centres it, so a page that widens or narrows around the column, as it
/// does while a sidebar slides, only moves the text: nothing is laid out or drawn again. Resizing the text view with
/// the page re-laid out and redrew the visible text on every frame. A click in the margins goes to the text view,
/// as it did when the text view spanned the page.
final class EditorClipView: NSClipView {
    /// How far the text reaches past the visible part, in points, top and bottom (the editor's scroll edges).
    var edges: EditorScrollEdges {
        guard let documentView else { return EditorScrollEdges(top: 0, bottom: 0) }
        return EditorScrollEdges(top: bounds.minY, bottom: documentView.frame.height - bounds.maxY)
    }

    /// The width change, in points, that is a pixel's noise rather than a resize.
    static let jitter: CGFloat = 1.5

    override init(frame: NSRect) {
        super.init(frame: frame)
        documentCursor = .iBeam
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        documentCursor = .iBeam
    }

    override func setFrameSize(_ newSize: NSSize) {
        // AppKit may centre the text view again itself as the frame changes, before `fitDocument` does.
        let before = columnX
        super.setFrameSize(newSize)
        fitDocument()
        if Motion.isSidebarSliding, let before, let after = columnX { slideColumn(from: before - after) }
    }

    /// Where the column starts in the clip view: the text view centred in it, or the column centred in a text view
    /// as wide as it (`EditorTextView.centreColumn`).
    private var columnX: CGFloat? {
        guard let textView = documentView as? EditorTextView else { return nil }
        return textView.frame.minX - bounds.minX + textView.textContainerOrigin.x
    }

    /// The clip width the text view was last fitted to.
    private var fittedClipWidth: CGFloat?

    /// Gives the text view its width for this clip view and centres it again. A clip view that moves by fractions of
    /// a point, as a page does while a sidebar slides under it, changes width by a pixel or so from one frame to the
    /// next; following that laid the whole column out again each time, so a change under `jitter` keeps the width
    /// fitted before. `force` refits whatever the width (a new theme).
    func fitDocument(force: Bool = false) {
        guard let textView = documentView as? EditorTextView else { return }
        var clipWidth = bounds.width
        if !force, let fitted = fittedClipWidth, abs(clipWidth - fitted) < Self.jitter { clipWidth = fitted }
        fittedClipWidth = clipWidth
        let width = textView.fittingWidth(in: clipWidth)
        if textView.frame.width != width { textView.setFrameSize(NSSize(width: width, height: textView.frame.height)) }
        let centred = constrainBoundsRect(bounds)
        if centred.origin != bounds.origin {
            setBoundsOrigin(centred.origin)
            (superview as? NSScrollView)?.reflectScrolledClipView(self)
            // The margins moved.
            window?.invalidateCursorRects(for: self)
        }
    }

    /// Plays a sidebar's slide on the column centred again at the page's new width: drawn `shift` points from its
    /// new place (where it was), it comes back to it with the slide's spring, on the render server, as the page's edge does.
    private func slideColumn(from shift: CGFloat) {
        guard abs(shift) >= Self.jitter, let layer = documentView?.layer else { return }
        let spring = Motion.Spring.slide
        let slide = CASpringAnimation(perceptualDuration: spring.duration, bounce: spring.bounce)
        slide.keyPath = "position.x"
        slide.duration = slide.settlingDuration
        slide.isAdditive = true
        slide.fromValue = shift
        slide.toValue = 0
        layer.add(slide, forKey: "sidebarSlide")
    }

    /// A text view narrower than the clip view sits in its middle, on whole pixels.
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        let width = fittedClipWidth ?? rect.width
        guard let documentView, documentView.frame.width < width else { return rect }
        let scale = window?.backingScaleFactor ?? 2
        rect.origin.x = -(((width - documentView.frame.width) / 2) * scale).rounded() / scale
        return rect
    }

    /// The I-beam over the margins beside and under the text view only. Over the text view its own pointer rules (the
    /// I-beam, an arrow over a picture, the resize pointer on a picture's handles): a clip view's document cursor
    /// covers all of it, and where it overlapped a handle's resize rectangle, each rebuild of the window's cursor
    /// rectangles picked either one, so the pointer flickered between the two.
    override func resetCursorRects() {
        guard let documentView, let cursor = documentCursor else { return super.resetCursorRects() }
        let visible = visibleRect
        let page = documentView.frame
        let margins = [
            NSRect(x: visible.minX, y: visible.minY, width: page.minX - visible.minX, height: visible.height),
            NSRect(x: page.maxX, y: visible.minY, width: visible.maxX - page.maxX, height: visible.height),
            NSRect(x: page.minX, y: page.maxY, width: page.width, height: visible.maxY - page.maxY),
        ]
        for margin in margins where margin.width > 0 && margin.height > 0 { addCursorRect(margin, cursor: cursor) }
    }

    override func mouseDown(with event: NSEvent) {
        guard let documentView else { return super.mouseDown(with: event) }
        if window?.firstResponder !== documentView { window?.makeFirstResponder(documentView) }
        documentView.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let documentView else { return super.rightMouseDown(with: event) }
        documentView.rightMouseDown(with: event)
    }

    // MARK: Drops in the margins

    /// The margins beside a narrowed text view are this clip view's: it takes the drops the text view takes and hands
    /// them over, so dropping on the far side of a wide page still reaches the editor.
    private var dropTarget: NSDraggingDestination? { documentView as? NSDraggingDestination }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let types = documentView?.registeredDraggedTypes, !types.isEmpty { registerForDraggedTypes(types) }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dropTarget?.draggingEntered?(sender) ?? []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dropTarget?.draggingUpdated?(sender) ?? []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        dropTarget?.draggingExited?(sender)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        dropTarget?.prepareForDragOperation?(sender) ?? false
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        dropTarget?.performDragOperation?(sender) ?? false
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        dropTarget?.concludeDragOperation?(sender)
    }
}
