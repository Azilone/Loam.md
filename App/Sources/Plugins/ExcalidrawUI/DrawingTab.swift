import AppKit
import ExcalidrawPlugin
import PluginKitUI
import SwiftUI

/// A drawing in a tab: Excalidraw, under the page's toolbar. Embedded in another view (a card on a board), the
/// drawing's picture instead, which a double-click on the card opens.
struct DrawingTab: View {
    let store: ExcalidrawStore
    let view: ViewContext

    var body: some View {
        if view.presentation == .embedded {
            DrawingPreview(store: store, path: view.resource.path)
        } else {
            DrawingPage(store: store, view: view)
        }
    }
}

private struct DrawingPage: View {
    let view: ViewContext
    @State private var editor: DrawingEditor
    @Environment(\.colorScheme) private var colorScheme

    init(store: ExcalidrawStore, view: ViewContext) {
        self.view = view
        _editor = State(wrappedValue: DrawingEditor(path: view.resource.path, store: store))
    }

    var body: some View {
        Group {
            if ExcalidrawBundle.root == nil {
                ContentUnavailableView("This build has no Excalidraw editor", symbol: ExcalidrawUIPlugin.symbol)
            } else {
                DrawingWebViewHost(webView: editor.webView)
            }
        }
        .onAppear {
            view.toolbarTitle = ToolbarTitle(title: ExcalidrawFile.title(of: view.resource.path),
                                             symbol: ExcalidrawUIPlugin.symbol)
            editor.setDark(colorScheme == .dark)
        }
        .onChange(of: colorScheme) { _, scheme in editor.setDark(scheme == .dark) }
        .onDisappear { [editor] in Task { await editor.flush() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { [editor] _ in
            Task { await editor.flush() }
        }
    }
}

private struct DrawingWebViewHost: NSViewRepresentable {
    let webView: DrawingWebView

    func makeNSView(context: Context) -> DrawingWebView { webView }
    func updateNSView(_ nsView: DrawingWebView, context: Context) {}
}
