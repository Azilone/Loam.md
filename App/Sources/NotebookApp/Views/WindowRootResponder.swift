import AppKit
import ObjectiveC

/// The window's root hosting view (SwiftUI's, which the app does not subclass) answers at once that it does not take
/// the keyboard as a whole, as the side columns' hosting views do (`ColumnHostingView`).
///
/// Whenever a view moves under a movable window's title bar (a scroll, a page or a sidebar sliding), AppKit works out
/// again on the next frame which parts of the title bar drag the window, and asks the root view whether it accepts
/// first responder. SwiftUI answers by walking its whole focus tree, which grows with what the page shows: a third of
/// each frame while scrolling All Notes, and the frames got slower as more cards came in. The views that do take the
/// keyboard (text fields, the editor) are AppKit responders of their own and keep doing so; SwiftUI still gets the
/// keys they pass up the responder chain (`onExitCommand`, `onKeyPress`).
enum WindowRootResponder {
    @MainActor static func answerAtOnce(in window: NSWindow) {
        guard let root = window.contentView, root.className.contains("HostingView"),
              let rootClass = object_getClass(root) else { return }
        let selector = #selector(getter: NSResponder.acceptsFirstResponder)
        let refuse: @convention(block) (AnyObject) -> Bool = { _ in false }
        // On this class only: the main window's root view type, not the Settings window's.
        class_replaceMethod(rootClass, selector, imp_implementationWithBlock(refuse), "B@:")
    }
}
