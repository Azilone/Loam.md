import AppKit
import SwiftUI

/// One fenced code block shown as a live view (` ```base `), as the host's view sees it: its code, whether the caret
/// is in it, and the two edits it may make. The editor keeps the same handle for as long as the block stays in the
/// text, so a view built for it keeps its state while the code changes.
@MainActor
public final class LiveBlockHandle {
    /// Lowercased, as written after the opening fence.
    public let language: String
    /// The text between the fences.
    public private(set) var code: String
    /// Whether the caret is in the block, which then shows its code above the view.
    public private(set) var isEditingCode: Bool
    /// Called after `code` or `isEditingCode` changed.
    public var onChange: (() -> Void)?

    weak var controller: EditorController?
    /// The block, fence to fence, and its code, at the last restyle.
    var blockRange: NSRange
    var codeRange: NSRange

    init(language: String, code: String, isEditingCode: Bool, blockRange: NSRange, codeRange: NSRange) {
        self.language = language
        self.code = code
        self.isEditingCode = isEditingCode
        self.blockRange = blockRange
        self.codeRange = codeRange
    }

    /// Replaces the code between the fences, as one edit the user can undo.
    public func replaceCode(_ code: String) {
        controller?.replaceCode(of: self, with: code)
    }

    /// Puts the caret at the start of the code, which shows it.
    public func editCode() {
        controller?.editCode(of: self)
    }

    func update(code: String, isEditingCode: Bool) {
        guard code != self.code || isEditingCode != self.isEditingCode else { return }
        self.code = code
        self.isEditingCode = isEditingCode
        onChange?()
    }
}

/// Builds the live view of a fenced code block, once per block. The view follows the handle (`onChange`) as its code
/// changes.
public typealias LiveBlockProvider = @MainActor (LiveBlockHandle) -> AnyView

extension NSAttributedString.Key {
    /// On the last character of a fenced code block shown as a live view; the value is a `LiveBlockMark`.
    static let markdownLiveBlock = NSAttributedString.Key("Loam.markdownLiveBlock")
}

/// The room a live view takes below a block, in the paragraph spacing of its closing fence, as a picture's.
final class LiveBlockMark: NSObject, BlockMark {
    let block: LiveBlock
    let size: NSSize
    /// Where the caret goes to show the code; nil while the code shows already.
    let caret: Int?

    init(block: LiveBlock, size: NSSize, caret: Int?) {
        self.block = block
        self.size = size
        self.caret = caret
    }

    // Equal when it stands for the same block in the same room, so marking it again leaves the text as it was.
    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? LiveBlockMark else { return false }
        return other.block === block && other.size == size && other.caret == caret
    }

    override var hash: Int { ObjectIdentifier(block).hashValue }
}

/// What the editor keeps for one live block: the handle, the view once it is near the visible area, its height.
@MainActor
final class LiveBlock {
    let handle: LiveBlockHandle
    let provider: LiveBlockProvider
    var host: LiveBlockHostingView?
    /// The scroll view the host goes into while its content is taller than the cap; the host stays the same view, so
    /// the view keeps its state.
    var scroller: NSScrollView?
    /// What sits in the text view: the scroll view, or the host itself.
    var outer: NSView? { scroller ?? host }
    /// The height of the view's content at the column width; an estimate until the view has measured it.
    var contentHeight: CGFloat = LiveBlock.estimatedHeight

    init(handle: LiveBlockHandle, provider: @escaping LiveBlockProvider) {
        self.handle = handle
        self.provider = provider
    }

    /// The height shown: taller content scrolls inside.
    var height: CGFloat { min(contentHeight, Self.maximumHeight) }
    var scrolls: Bool { contentHeight > Self.maximumHeight + 0.5 }

    static let estimatedHeight: CGFloat = 120
    static let maximumHeight: CGFloat = 560
}

/// The hosting view of a live block, a subview of the text view: it reports its content's height, and Escape in it
/// gives the keyboard back to the text.
final class LiveBlockHostingView: NSHostingView<LiveBlockRoot> {
    var onEscape: (() -> Void)?
    private var monitor: Any?

    /// A click on a block's control acts at once, as on the text around it, even while the window is not the key one.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard window != nil else { return }
        // A text field's field editor takes Escape for itself (completion), so it never comes up the responder chain.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            let window = event.window
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, window === self.window,
                      let responder = self.window?.firstResponder as? NSView, responder.isDescendant(of: self)
                else { return false }
                self.onEscape?()
                return true
            }
            return handled ? nil : event
        }
    }
}

/// The root of a live block's hosting view: the host's view at the column's width and at its own height, which it
/// reports. The host's frame is that height; past `LiveBlock.maximumHeight`, a scroll view around the host shows part
/// of it.
struct LiveBlockRoot: View {
    let content: AnyView
    let onHeight: (CGFloat) -> Void

    var body: some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: onHeight)
            .frame(maxHeight: .infinity, alignment: .topLeading)
    }
}

extension EditorController {
    /// Shows the fenced code blocks of the languages a host has live views for: outside the block the view takes the
    /// place of the code (hidden, as a picture's); with the caret inside, the code shows and the view stays under it.
    /// Blocks keep their view from one restyle to the next: matched by their code, else by their rank.
    func applyLiveBlocks(_ spans: [StyleSpan], to storage: NSTextStorage, revealing selection: NSRange) {
        guard textView != nil else { return }
        let ns = storage.string as NSString
        var old = liveBlocks
        var found: [(span: StyleSpan, language: String, code: NSRange, text: String)] = []
        for span in spans {
            guard case .fencedCode(let language, let code) = span.style, liveBlockProviders[language] != nil else { continue }
            found.append((span, language, code, ns.substring(with: code)))
        }
        // Same code first (a block moved or another was added above it), then same rank (its code was edited).
        var kept: [LiveBlock?] = found.map { entry in
            guard let index = old.firstIndex(where: { $0.handle.language == entry.language && $0.handle.code == entry.text }) else { return nil }
            return old.remove(at: index)
        }
        for index in kept.indices where kept[index] == nil {
            if let reuse = old.firstIndex(where: { $0.handle.language == found[index].language }) {
                kept[index] = old.remove(at: reuse)
            }
        }
        for gone in old { gone.outer?.removeFromSuperview() }

        var blocks: [LiveBlock] = []
        for (index, entry) in found.enumerated() {
            let editing = syntaxMode == .source || MarkdownTheme.enters(selection, entry.span.range)
            let block = kept[index] ?? {
                let handle = LiveBlockHandle(
                    language: entry.language, code: entry.text, isEditingCode: editing,
                    blockRange: entry.span.range, codeRange: entry.code
                )
                handle.controller = self
                return LiveBlock(handle: handle, provider: liveBlockProviders[entry.language]!)
            }()
            block.handle.blockRange = entry.span.range
            block.handle.codeRange = entry.code
            block.handle.update(code: entry.text, isEditingCode: editing)
            blocks.append(block)
            if !editing { storage.setIfChanged(MarkdownTheme.concealed, range: entry.span.range) }
            mark(block, in: storage)
        }
        liveBlocks = blocks
    }

    /// Reserves the room of a block's view under its closing fence and marks where it goes.
    func mark(_ block: LiveBlock, in storage: NSTextStorage) {
        guard let textView else { return }
        let ns = storage.string as NSString
        let range = block.handle.blockRange
        guard NSMaxRange(range) <= ns.length, range.length > 0 else { return }
        let last = NSMaxRange(range) - 1
        let paragraph = ns.paragraphRange(for: NSRange(location: last, length: 0))
        let style = (storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle)?
            .mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        style.paragraphSpacing = block.height + 2 * PictureMark.margin
        storage.setIfChanged([.paragraphStyle: style], range: paragraph)
        let caret = block.handle.isEditingCode ? nil : block.handle.codeRange.location
        storage.setIfChanged(
            [.markdownLiveBlock: LiveBlockMark(block: block, size: NSSize(width: textView.columnWidth, height: block.height), caret: caret)],
            range: NSRange(location: last, length: 1)
        )
    }

    /// Places each block's view in its room, creating the views of the blocks near the visible part of the page.
    func positionLiveViews() {
        positionTableViews()
        guard let textView, !liveBlocks.isEmpty else { return }
        let visible = textView.visibleRect
        let near = visible.insetBy(dx: 0, dy: -max(visible.height, 400))
        // A block under a folded heading has no room: hidden until it unfolds.
        for block in liveBlocks { block.outer?.isHidden = textView.isFolded(block.handle.blockRange.location) }
        for (mark, frame) in textView.blockFrames(.markdownLiveBlock, near: textView.placedRange) as [(LiveBlockMark, NSRect)] {
            let block = mark.block
            guard liveBlocks.contains(where: { $0 === block }) else { continue }
            if block.host == nil {
                guard frame.intersects(near) else { continue }
                makeHost(for: block, in: textView)
            }
            guard let host = block.host, let outer = block.outer else { continue }
            if outer.superview !== textView { textView.addSubview(outer) }
            // On whole points, at the height the room was made for: rounding outwards would grow it each pass.
            let rounded = NSRect(x: frame.minX.rounded(), y: frame.minY.rounded(), width: frame.width.rounded(), height: frame.height)
            if outer.frame != rounded { outer.frame = rounded }
            if let scroller = block.scroller {
                let inner = NSRect(x: 0, y: 0, width: scroller.contentSize.width, height: block.contentHeight)
                if host.frame != inner { host.frame = inner }
            }
        }
    }

    private func makeHost(for block: LiveBlock, in textView: EditorTextView) {
        let content = block.provider(block.handle)
        let host = LiveBlockHostingView(rootView: LiveBlockRoot(content: content) { [weak self, weak block] height in
            guard let self, let block else { return }
            self.liveBlock(block, measured: height)
        })
        host.sizingOptions = []
        host.onEscape = { [weak self, weak block] in
            guard let self, let block else { return }
            self.leaveLiveBlock(block)
        }
        block.host = host
        textView.addSubview(host)
        if block.scrolls { wrap(block) }
    }

    /// Puts a block's host in a scroll view of its own, or takes it out, as its content passes the cap.
    private func wrap(_ block: LiveBlock) {
        guard let host = block.host, let parent = block.outer?.superview else { return }
        if block.scrolls, block.scroller == nil {
            let scroller = NSScrollView(frame: host.frame)
            scroller.hasVerticalScroller = true
            scroller.autohidesScrollers = true
            scroller.drawsBackground = false
            scroller.borderType = .noBorder
            host.removeFromSuperview()
            scroller.documentView = host
            parent.addSubview(scroller)
            block.scroller = scroller
        } else if !block.scrolls, let scroller = block.scroller {
            host.removeFromSuperview()
            scroller.removeFromSuperview()
            parent.addSubview(host)
            block.scroller = nil
        }
    }

    /// A view's content changed height: the room under its block follows, restyling that paragraph only.
    private func liveBlock(_ block: LiveBlock, measured height: CGFloat) {
        let height = height.rounded(.up)
        guard height > 0, height != block.contentHeight else { return }
        block.contentHeight = height
        wrap(block)
        // Not inside SwiftUI's or TextKit's layout pass, which reported it.
        DispatchQueue.main.async { [weak self, weak block] in
            MainActor.assumeIsolated {
                guard let self, let block, let storage = self.textView?.textStorage,
                      self.liveBlocks.contains(where: { $0 === block }) else { return }
                storage.beginEditing()
                self.mark(block, in: storage)
                storage.endEditing()
                self.positionLiveViews()
                self.textView?.needsDisplay = true
            }
        }
    }

    /// Removes every live block and its view (another note is shown).
    func removeLiveBlocks() {
        for block in liveBlocks { block.outer?.removeFromSuperview() }
        liveBlocks = []
    }

    // MARK: Edits from a view

    func replaceCode(of handle: LiveBlockHandle, with code: String) {
        if blockSession != nil {
            guard let storage = textView?.textStorage, handle.blockRange.location < storage.length,
                  let block = BlockStorage.block(in: storage, paragraph: (storage.string as NSString).paragraphRange(for: handle.blockRange))
            else { return }
            return setCode(code, ofBlock: block.id)
        }
        guard let textView, let storage = textView.textStorage, liveBlocks.contains(where: { $0.handle === handle }),
              NSMaxRange(handle.codeRange) <= storage.length else { return }
        let range = handle.codeRange
        // An empty block has no line for its code yet: the code goes on its own line before the closing fence.
        let replacement = range.length == 0 && !code.isEmpty ? code + "\n" : code
        guard (storage.string as NSString).substring(with: range) != replacement else { return }
        let selection = textView.selectedRange()
        guard textView.shouldChangeText(in: range, replacementString: replacement) else { return }
        storage.replaceCharacters(in: range, with: replacement)
        textView.didChangeText()
        let delta = (replacement as NSString).length - range.length
        let moved = selection.location >= NSMaxRange(range) ? selection.location + delta : min(selection.location, range.location)
        textView.setSelectedRange(NSRange(location: max(0, min(moved, storage.length)), length: 0))
    }

    func editCode(of handle: LiveBlockHandle) {
        if blockSession != nil { return openBlockCodePage(at: handle.blockRange.location) }
        guard let textView, liveBlocks.contains(where: { $0.handle === handle }) else { return }
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: handle.codeRange.location, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    /// Escape in a view: the caret goes after its block, where the code stays hidden.
    private func leaveLiveBlock(_ block: LiveBlock) {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: min(NSMaxRange(block.handle.blockRange), textView.string.utf16.count), length: 0))
    }
}

extension EditorController {
    /// Shows `view` under the title (`EditorTextView.titleAccessory`), keeping its hosting view, and so its state,
    /// from one update to the next; nil removes it.
    func setTitleAccessory(_ view: AnyView?) {
        guard let textView else { return }
        guard let view else {
            if textView.titleAccessory != nil {
                textView.titleAccessory = nil
                textView.titleAccessoryHeight = 0
            }
            return
        }
        let root = LiveBlockRoot(content: view) { [weak textView] height in
            textView?.titleAccessoryHeight = ceil(height)
        }
        if let host = textView.titleAccessory as? LiveBlockHostingView {
            host.rootView = root
        } else {
            let host = LiveBlockHostingView(rootView: root)
            host.sizingOptions = []
            host.onEscape = { [weak self] in self?.focusBody() }
            textView.titleAccessory = host
        }
    }
}
