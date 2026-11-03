import AppKit
import Observation
import SwiftUI

/// The drag of a tab or a note that is under way inside the window.
///
/// SwiftUI tells a drop target when a drag comes over it, but not that a drag has started anywhere: the views that
/// start one (`draggableResource`, the tab bar) report it here, so the workspace can show its split zones as soon as
/// the drag begins rather than when it reaches a pane. SwiftUI does not say either when a drag ends without a drop,
/// so the session watches the mouse button.
@MainActor
@Observable
public final class DragSession {
    public static let shared = DragSession()

    /// What is dragged; nil when nothing is.
    public private(set) var payload: DragPayload?
    /// A picture of the page being dragged, when the drag started from a page's tab.
    @ObservationIgnored public private(set) var snapshot: NSImage?
    @ObservationIgnored private var watcher: Timer?

    public var isActive: Bool { payload != nil }

    /// A drag starts: `title` and `symbol` (the resource's name and icon by default) are what the picture under the
    /// pointer shows (`DragGhost`), with `snapshot` for a page's tab.
    public func begin(_ payload: DragPayload, snapshot: NSImage? = nil, title: String? = nil, symbol: String? = nil) {
        self.payload = payload
        self.snapshot = snapshot
        var name = title ?? ""
        if title == nil, case .resource(let resource) = payload { name = resource.name }
        DragGhost.shared.show(title: name, symbol: symbol ?? "doc.text", snapshot: snapshot)
        watcher?.invalidate()
        // The first check waits: the drag session only starts after the view's `onDrag` has returned.
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                if NSEvent.pressedMouseButtons & 1 == 0 { self?.end() }
            }
        }
        timer.fireDate = Date().addingTimeInterval(0.25)
        RunLoop.main.add(timer, forMode: .common)
        watcher = timer
    }

    public func end() {
        DragGhost.shared.hide()
        watcher?.invalidate()
        watcher = nil
        payload = nil
        snapshot = nil
    }
}

/// The small picture that follows the pointer during a drag: the page's own image when there is one, else a blank
/// page with the title, in a rounded frame.
public struct DragThumbnail: View {
    private let title: String
    private let image: NSImage?
    @Environment(\.colorScheme) private var colorScheme

    public static let width: CGFloat = 220

    public init(title: String, image: NSImage?) {
        self.title = title
        self.image = image
    }

    public var body: some View {
        let height = Self.height(for: image)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: Corners.r(10), style: .continuous)
                .fill(colorScheme == .dark ? Color(white: 0.14) : .white)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: Self.width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: Corners.r(10), style: .continuous))
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title.isEmpty ? "Untitled" : title)
                        .font(.ui(size: 13, weight: .semibold))
                        .lineLimit(1)
                    ForEach(0..<4, id: \.self) { line in
                        ThemeCapsule().fill(.secondary.opacity(0.25)).frame(width: line == 3 ? 90 : nil, height: 5)
                    }
                }
                .padding(14)
            }
        }
        .frame(width: Self.width, height: height)
        .overlay {
            RoundedRectangle(cornerRadius: Corners.r(10), style: .continuous).strokeBorder(.secondary.opacity(0.35), lineWidth: 1)
        }
        .padding(12)
    }

    private static func height(for image: NSImage?) -> CGFloat {
        guard let image, image.size.width > 0 else { return 130 }
        return min(max(width * image.size.height / image.size.width, 90), 160)
    }
}

