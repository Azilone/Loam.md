import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import MarkdownEditor

/// Fenced code blocks of a language the host has a live view for: a SwiftUI view in the text, in a real window, with
/// a sample view standing in for a plugin's.
@MainActor
final class LiveBlockTests: XCTestCase {
    private var window: NSWindow!
    private var textView: EditorTextView!
    private var controller: EditorController!
    /// The handles the provider was asked to build a view for.
    private var built: [LiveBlockHandle] = []
    /// The sample view's height.
    private var viewHeight: CGFloat = 200

    private let text = "Intro\n\n```demo\nhello\n```\n\nAfter"

    override func setUp() async throws {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scrollView = NSScrollView(frame: window.contentView!.bounds)
        textView = EditorTextView(usingTextLayoutManager: true)
        textView.frame = scrollView.bounds
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
        window.contentView!.addSubview(scrollView)
        controller = EditorController()
        controller.attach(textView)
        controller.liveBlockProviders = ["demo": { [weak self] handle in
            self?.built.append(handle)
            return AnyView(SampleBlock(handle: handle, height: self?.viewHeight ?? 0))
        }]
    }

    override func tearDown() async throws {
        window.close()
    }

    /// Lets the views be built, measured and placed: layout, then the main queue, a few times.
    private func settle() {
        for _ in 0..<8 {
            window.layoutIfNeeded()
            window.displayIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func load(caret: Int = 0, _ text: String? = nil) {
        controller.show(EditorContent(id: 1, text: text ?? self.text, initialState: EditorViewState(caret: caret, scrollY: 0)))
        settle()
    }

    private var storage: NSTextStorage { textView.textStorage! }
    private var block: NSRange { (textView.string as NSString).range(of: "```demo\nhello\n```") }
    private var hosts: [LiveBlockHostingView] { Self.views(LiveBlockHostingView.self, in: textView) }

    func testTheViewTakesThePlaceOfTheCodeInTheRoomMadeForIt() throws {
        load()
        XCTAssertEqual(built.map(\.code), ["hello"])
        XCTAssertEqual(built.first?.isEditingCode, false)
        let font = try XCTUnwrap(storage.attribute(.font, at: block.location + 9, effectiveRange: nil) as? NSFont)
        XCTAssertLessThan(font.pointSize, 1, "the code is hidden")
        let style = try XCTUnwrap(storage.attribute(.paragraphStyle, at: NSMaxRange(block) - 1, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(style.paragraphSpacing, 200 + 2 * PictureMark.margin, "room for the view, at its measured height")
        let host = try XCTUnwrap(hosts.first)
        XCTAssertEqual(hosts.count, 1)
        let (mark, frame) = try XCTUnwrap((textView.blockFrames(.markdownLiveBlock) as [(LiveBlockMark, NSRect)]).first)
        XCTAssertEqual(host.frame.height, 200)
        XCTAssertEqual(host.frame.width, textView.columnWidth, accuracy: 1)
        XCTAssertEqual(host.frame.minY, frame.minY, accuracy: 1)
        XCTAssertEqual(host.frame.minX, frame.minX, accuracy: 1)
        XCTAssertEqual(mark.caret, block.location + 8)
        // Between the intro and the text after the block.
        func box(_ word: String) -> NSRect {
            let screen = textView.firstRect(forCharacterRange: (textView.string as NSString).range(of: word), actualRange: nil)
            return textView.convert(window.convertFromScreen(screen), from: nil)
        }
        XCTAssertGreaterThanOrEqual(host.frame.minY, box("Intro").maxY)
        XCTAssertLessThanOrEqual(host.frame.maxY, box("After").minY)
    }

    func testATallerViewMakesMoreRoomWithoutALayoutLoop() throws {
        load()
        let handle = try XCTUnwrap(built.first)
        let host = try XCTUnwrap(hosts.first)
        let frame = host.frame
        settle()
        XCTAssertEqual(host.frame, frame, "the frame is stable: measuring it does not grow it")
        XCTAssertEqual(built.count, 1, "the view is built once")

        // The view grows past the cap: it scrolls inside, at the cap.
        handle.replaceCode("tall")
        settle()
        let scroller = try XCTUnwrap(host.enclosingScrollView)
        XCTAssertTrue(scroller.superview === textView, "the view scrolls inside its own scroll view")
        XCTAssertEqual(scroller.frame.height, LiveBlock.maximumHeight)
        XCTAssertEqual(host.frame.height, 900, "at its whole height inside")
        XCTAssertTrue(hosts.first === host, "the same view, so its state stays")
        let tall = (textView.string as NSString).range(of: "```demo\ntall\n```")
        let style = try XCTUnwrap(storage.attribute(.paragraphStyle, at: NSMaxRange(tall) - 1, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(style.paragraphSpacing, LiveBlock.maximumHeight + 2 * PictureMark.margin)
        XCTAssertEqual(built.count, 1, "the same view follows the code")

        // Back under the cap: out of the scroll view.
        handle.replaceCode("short")
        settle()
        XCTAssertTrue(host.superview === textView)
        XCTAssertEqual(host.frame.height, 200)
    }

    func testTheWheelScrollsTheNoteOverTheViewAndTheViewSidewaysInside() throws {
        load(text + String(repeating: "\n\nMore text", count: 80))
        let host = try XCTUnwrap(hosts.first)
        let clip = try XCTUnwrap(textView.enclosingScrollView?.contentView)
        XCTAssertEqual(clip.bounds.minY, 0)
        wheel(at: NSPoint(x: host.frame.midX, y: host.frame.maxY - 20), dx: 0, dy: -60)
        XCTAssertGreaterThan(clip.bounds.minY, 0, "the note scrolls with the pointer over the view")

        let row = try XCTUnwrap(Self.views(NSScrollView.self, in: host).first, "the sample's sideways scroll view")
        let before = clip.bounds.minY
        let point = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: textView)
        wheel(at: point, dx: -80, dy: 0)
        // The sideways view moves on a later pass of the run loop, which takes longer when the whole suite is busy.
        let deadline = Date().addingTimeInterval(2)
        while row.contentView.bounds.minX == 0, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertGreaterThan(row.contentView.bounds.minX, 0, "the view scrolls sideways inside")
        XCTAssertEqual(clip.bounds.minY, before, accuracy: 1)
    }

    func testReplaceCodeIsOneUndoStep() throws {
        load()
        let handle = try XCTUnwrap(built.first)
        handle.replaceCode("one\ntwo")
        settle()
        XCTAssertEqual(textView.string, "Intro\n\n```demo\none\ntwo\n```\n\nAfter")
        XCTAssertEqual(handle.code, "one\ntwo")
        let undo = try XCTUnwrap(textView.undoManager)
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        settle()
        XCTAssertEqual(textView.string, text)
        XCTAssertEqual(handle.code, "hello", "the view follows undo")
        XCTAssertFalse(undo.canUndo, "a single step")
    }

    func testAnEmptyBlockGetsItsCodeOnItsOwnLine() throws {
        load("Intro\n\n```demo\n```\n")
        let handle = try XCTUnwrap(built.first)
        XCTAssertEqual(handle.code, "")
        handle.replaceCode("x")
        XCTAssertEqual(textView.string, "Intro\n\n```demo\nx\n```\n")
    }

    func testEditCodeShowsTheCode() throws {
        load()
        let handle = try XCTUnwrap(built.first)
        handle.editCode()
        XCTAssertEqual(textView.selectedRange(), NSRange(location: block.location + 8, length: 0))
        XCTAssertTrue(handle.isEditingCode)
        let font = try XCTUnwrap(storage.attribute(.font, at: block.location + 9, effectiveRange: nil) as? NSFont)
        XCTAssertGreaterThan(font.pointSize, 5, "the code shows")
        XCTAssertEqual(hosts.count, 1, "the view stays under it")
    }

    func testSelectingAllNeverShowsTheCodeOfTheBlock() throws {
        load()
        let handle = try XCTUnwrap(built.first)
        textView.setSelectedRange(NSRange(location: 0, length: (text as NSString).length))
        XCTAssertFalse(handle.isEditingCode, "a selection that merely reaches into the block does not open its code")
        let font = try XCTUnwrap(storage.attribute(.font, at: block.location + 9, effectiveRange: nil) as? NSFont)
        XCTAssertLessThan(font.pointSize, 1, "the code stays hidden")
        // A selection inside the block does.
        textView.setSelectedRange(NSRange(location: block.location + 8, length: 3))
        XCTAssertTrue(handle.isEditingCode)
    }

    func testTheViewGoesAwayWithItsBlock() throws {
        load()
        XCTAssertEqual(hosts.count, 1)
        let range = block
        XCTAssertTrue(textView.shouldChangeText(in: range, replacementString: "gone"))
        storage.replaceCharacters(in: range, with: "gone")
        textView.didChangeText()
        settle()
        XCTAssertTrue(hosts.isEmpty)
        XCTAssertTrue(controller.liveBlocks.isEmpty)

        // Another note drops the views of the last one.
        controller.show(EditorContent(id: 2, text: text))
        settle()
        XCTAssertEqual(hosts.count, 1)
        controller.show(EditorContent(id: 3, text: "Other"))
        settle()
        XCTAssertTrue(hosts.isEmpty)
    }

    func testEditingTheCodeKeepsTheView() throws {
        load(caret: (text as NSString).range(of: "hello").location + 2)
        let handle = try XCTUnwrap(built.first)
        XCTAssertTrue(handle.isEditingCode)
        textView.insertText("X", replacementRange: textView.selectedRange())
        settle()
        XCTAssertEqual(handle.code, "heXllo")
        XCTAssertEqual(built.count, 1)
        XCTAssertEqual(hosts.count, 1)
    }

    func testCopyingAcrossTheBlockCopiesTheMarkdown() throws {
        load()
        textView.setSelectedRange(NSRange(location: 0, length: (text as NSString).length))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("loam.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(textView.writeSelection(to: pasteboard, types: textView.writablePasteboardTypes))
        XCTAssertEqual(pasteboard.string(forType: .string), text)
    }

    func testFocusGoesIntoTheViewAndEscapeGivesItBack() throws {
        load()
        let host = try XCTUnwrap(hosts.first)
        let field = try XCTUnwrap(Self.textField(in: host))
        XCTAssertTrue(window.makeFirstResponder(field))
        let responder = try XCTUnwrap(window.firstResponder as? NSView)
        XCTAssertTrue(responder.isDescendant(of: host), "a text field in the view takes the keyboard")

        let escape = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
        ))
        NSApp.postEvent(escape, atStart: true)
        // Local monitors see an event as the application takes it from the queue.
        if let event = NSApp.nextEvent(matching: .keyDown, until: Date().addingTimeInterval(0.5), inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
        XCTAssertTrue(window.firstResponder === textView, "Escape gives the keyboard back to the text")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: NSMaxRange(block), length: 0), "after the block, its code hidden")
    }

    func testADropTargetInTheViewTakesDropsBeforeThePane() throws {
        load()
        let host = try XCTUnwrap(hosts.first)
        settle()
        // AppKit gives a drag to the deepest view registered for its type: the view's (SwiftUI registers any data and
        // sorts it out by the view's `onDrop` types), not the pane's around the editor.
        let registered = ([host] + Self.views(NSView.self, in: host)).filter { !$0.registeredDraggedTypes.isEmpty }
        XCTAssertFalse(registered.isEmpty)
        XCTAssertTrue(registered.allSatisfy { $0.isDescendant(of: host) })
        XCTAssertTrue(registered.contains { $0.registeredDraggedTypes.contains(NSPasteboard.PasteboardType(UTType.data.identifier)) })
        XCTAssertTrue(SampleBlock.dropType.conforms(to: .data))
    }

    func testTheViewIsInTheAccessibilityTree() throws {
        load()
        let host = try XCTUnwrap(hosts.first)
        XCTAssertTrue(textView.accessibilityChildren()?.contains { ($0 as AnyObject) === host } == true)
    }

    /// A wheel event at `point` in the text view, as a trackpad sends it (pixels; negative `dy` scrolls down).
    private func wheel(at point: NSPoint, dx: Int32, dy: Int32) {
        let screen = window.convertPoint(toScreen: textView.convert(point, to: nil))
        let height = NSScreen.screens.first?.frame.height ?? 0
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { return }
        cg.location = CGPoint(x: screen.x, y: height - screen.y)
        guard let event = NSEvent(cgEvent: cg) else { return }
        // As the window sends it: to the view under the pointer, which passes on what it does not use.
        let target = window.contentView?.hitTest(textView.convert(point, to: nil))
        target?.scrollWheel(with: event)
        settle()
    }

    private static func views<View: NSView>(_ type: View.Type, in view: NSView) -> [View] {
        view.subviews.flatMap { subview in [subview as? View].compactMap { $0 } + views(type, in: subview) }
    }

    private static func textField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        for subview in view.subviews {
            if let field = textField(in: subview) { return field }
        }
        return nil
    }
}

/// A plugin's view, as small as a test needs: its code, a text field, and a height (`tall` code goes past the cap).
private struct SampleBlock: View {
    /// As `DragPayload.type`: a private type of data.
    static let dropType = UTType(tag: "application/x-loam-tests", tagClass: .mimeType, conformingTo: .data)!
    let handle: LiveBlockHandle
    let height: CGFloat
    @State private var code: String
    @State private var draft = ""

    init(handle: LiveBlockHandle, height: CGFloat) {
        self.handle = handle
        self.height = height
        _code = State(initialValue: handle.code)
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Draft", text: $draft)
            Text(code)
            ScrollView(.horizontal) {
                Text(String(repeating: "wide ", count: 400)).fixedSize()
            }
            Spacer(minLength: 0)
        }
        .onDrop(of: [Self.dropType], isTargeted: nil) { _ in true }
        .frame(height: code == "tall" ? 900 : height)
        .onAppear {
            handle.onChange = { [handle] in code = handle.code }
        }
    }
}
