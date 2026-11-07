import AppKit
import SwiftUI

/// Where an open came from, so the page can grow out of it (`docs/design/MOTION.md`, "Pages, tabs and panes"): the
/// card or row that was clicked, a sidebar, or the palette. A plugin that opens a note from something the user
/// clicked passes it to `Workspace.open(_:placement:from:)`; the shell decides what to do with it.
public struct OpenOrigin: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// A card or a row, as its frame in the window (SwiftUI's global space: top left origin).
        case frame(CGRect)
        /// A row, link or backlink of the sidebar on this side: the page arrives from that edge.
        case sidebar(HorizontalEdge)
        /// Quick Open or the command palette: the page rises where the palette was, top centre.
        case palette
    }

    public let source: Source

    public init(_ source: Source) {
        self.source = source
    }

    public static func frame(_ rect: CGRect) -> OpenOrigin { OpenOrigin(.frame(rect)) }
    public static func sidebar(_ edge: HorizontalEdge) -> OpenOrigin { OpenOrigin(.sidebar(edge)) }
    public static let palette = OpenOrigin(.palette)

    /// The point of a pane at `paneFrame` (same space as the frame) that a page opened from here grows out of, as a
    /// unit point of the pane: the clicked frame's centre, clamped to the pane; the top centre for the palette; the
    /// edge for a sidebar.
    public func anchor(in paneFrame: CGRect) -> UnitPoint {
        switch source {
        case .frame(let rect):
            guard paneFrame.width > 0, paneFrame.height > 0 else { return .center }
            let x = (rect.midX - paneFrame.minX) / paneFrame.width
            let y = (rect.midY - paneFrame.minY) / paneFrame.height
            return UnitPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
        case .sidebar(let edge):
            return edge == .leading ? .leading : .trailing
        case .palette:
            return .top
        }
    }
}

/// Reads, when a click comes, the frame of the view it is attached to (`View.opensFrom(_:)`). The frame is measured
/// on demand from the live view, not tracked, so a card in a scrolling grid costs nothing while it scrolls.
@MainActor
public final class OpenOriginProbe {
    fileprivate weak var view: NSView?

    public init() {}

    /// The origin to give `Workspace.open(_:placement:from:)`; nil when the view is not on screen.
    public var origin: OpenOrigin? {
        guard let view, let window = view.window, let content = window.contentView else { return nil }
        let rect = view.convert(view.bounds, to: content)
        guard rect.width > 0, rect.height > 0 else { return nil }
        // SwiftUI measures from the top left; AppKit from the bottom left unless the view is flipped.
        let top = content.isFlipped ? rect.minY : content.bounds.height - rect.maxY
        return .frame(CGRect(x: rect.minX, y: top, width: rect.width, height: rect.height))
    }
}

extension View {
    /// Marks this view as where an open starts: a card or a row. Pass the same probe to `Workspace.open`'s `from:`
    /// through `probe.origin` in the click handler, and the page grows out of this view.
    public func opensFrom(_ probe: OpenOriginProbe) -> some View {
        background(OpenOriginMarker(probe: probe))
    }
}

private struct OpenOriginMarker: NSViewRepresentable {
    let probe: OpenOriginProbe

    func makeNSView(context: Context) -> MarkerView {
        let view = MarkerView()
        probe.view = view
        return view
    }

    func updateNSView(_ view: MarkerView, context: Context) {
        probe.view = view
    }

    /// Invisible and out of the way of clicks.
    final class MarkerView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
