import AppKit
import PluginKitUI
import SwiftUI

/// What every viewer shares, so a file feels like a page of Loam and not a window dropped into it: the file's name
/// and details in the page's toolbar (as a note's title goes there once scrolled), a quiet stage behind the content, a
/// soft opening, and floating glass controls over the bottom edge.
struct ViewerFrame<Content: View, Bar: View>: View {
    let view: ViewContext
    let file: FileLocation?
    /// What the toolbar says after the kind and size: "1600 × 900", "12 pages".
    var detail: String?
    /// False for a bar that hides itself (a player's controls while it plays).
    var barVisible = true
    /// Whether the bar ends with the "…" menu (reveal, open); a viewer with its own buttons says no.
    var showsMenu = true
    private let hasBar: Bool
    @ViewBuilder let content: (FileLocation) -> Content
    @ViewBuilder let bar: () -> Bar
    @Environment(\.pageChromeInset) private var chromeInset
    @Environment(\.viewerIsEmbedded) private var embedded
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    init(
        view: ViewContext, file: FileLocation?, detail: String? = nil, barVisible: Bool = true, showsMenu: Bool = true,
        @ViewBuilder content: @escaping (FileLocation) -> Content, @ViewBuilder bar: @escaping () -> Bar
    ) {
        self.view = view
        self.file = file
        self.detail = detail
        self.barVisible = barVisible
        self.showsMenu = showsMenu
        self.hasBar = true
        self.content = content
        self.bar = bar
    }

    var body: some View {
        if let file, file.exists {
            ZStack {
                Color.primary.opacity(0.045)
                content(file).padding(.top, embedded ? 0 : chromeInset)
            }
            .overlay(alignment: hasBar ? .bottom : .bottomTrailing) { controls(for: file) }
            .opacity(appeared ? 1 : 0)
            .scaleEffect(appeared || reduceMotion ? 1 : 0.985)
            .onAppear {
                if !embedded { publish(file) }
                withAnimation(reduceMotion ? CollectionMotion.fade : CollectionMotion.reveal) { appeared = true }
            }
            .onChange(of: detail) { if !embedded { publish(file) } }
            .onDisappear { if !embedded { view.toolbarTitle = nil } }
        } else {
            ContentUnavailableView("File not found", symbol: "questionmark.folder")
        }
    }

    @ViewBuilder
    private func controls(for file: FileLocation) -> some View {
        if hasBar {
            FloatingBar {
                bar()
                if showsMenu { FileMenu(file: file) }
            }
            .padding(.bottom, 18)
            .opacity(barVisible ? 1 : 0)
            .allowsHitTesting(barVisible)
            .animation(CollectionMotion.reveal, value: barVisible)
        } else if showsMenu {
            FloatingBar { FileMenu(file: file) }.padding(18)
        }
    }

    private func publish(_ file: FileLocation) {
        view.toolbarTitle = ToolbarTitle(title: file.name, subtitle: file.summary(detail), symbol: file.symbol)
    }
}

extension ViewerFrame where Bar == EmptyView {
    /// A viewer with no controls of its own: only the "…" menu floats over its corner.
    init(
        view: ViewContext, file: FileLocation?, detail: String? = nil, showsMenu: Bool = true,
        @ViewBuilder content: @escaping (FileLocation) -> Content
    ) {
        self.view = view
        self.file = file
        self.detail = detail
        self.showsMenu = showsMenu
        self.hasBar = false
        self.content = content
        self.bar = { EmptyView() }
    }
}

/// A capsule of Liquid Glass that floats over a page's content, as Craft's and the canvas's controls do.
struct FloatingBar<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 6) { content() }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .glassEffect(.regular, in: .capsule)
            .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
    }
}

/// A round icon button for a floating bar.
struct BarButton: View {
    let symbol: String
    let help: String
    var size: CGFloat = 13
    var isOn = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(symbol: symbol)
                .font(.ui(size: size, weight: .medium))
                .frame(width: 30, height: 30)
                .background(isOn ? Color.primary.opacity(0.1) : .clear, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .collectionHover(cornerRadius: Corners.r(16))
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A thin vertical rule between groups of a floating bar.
struct BarDivider: View {
    var body: some View {
        Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 18).padding(.horizontal, 2)
    }
}

/// "…": reveal the file in Finder, open it with its default app, copy its path.
struct FileMenu: View {
    let file: FileLocation

    var body: some View {
        Menu {
            Button("Open with Default App", symbol: "arrow.up.forward.app") { NSWorkspace.shared.open(file.url) }
            Button("Reveal in Finder", symbol: "folder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
            Divider()
            Button("Copy Path", symbol: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.url.path, forType: .string)
                Sounds.play(.copied)
            }
        } label: {
            Image(symbol: "ellipsis")
                .font(.ui(size: 13, weight: .medium))
                .frame(width: 30, height: 30)
                .contentShape(.circle)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
        .accessibilityLabel("More")
    }
}

private struct ViewerIsEmbeddedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True when the viewer sits in a card of another view (a board): no room for the page's toolbar, which it must not
    /// write its title into.
    var viewerIsEmbedded: Bool {
        get { self[ViewerIsEmbeddedKey.self] }
        set { self[ViewerIsEmbeddedKey.self] = newValue }
    }
}
