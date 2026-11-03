import AppKit
import ExcalidrawPlugin
import PluginKitUI
import SwiftUI
import WebKit

/// Pictures of drawings, for a drawing shown as a card on a board or embedded in a note: drawn by Excalidraw's own
/// export in one offscreen web view (one drawing at a time), kept until the file changes.
@MainActor
final class DrawingPreviews: NSObject, WKScriptMessageHandler {
    struct Picture {
        let image: CGImage
        /// In points.
        let size: CGSize
    }

    /// The longest side of a picture, in pixels.
    static let maximumPixels = 2400

    private let service: ExcalidrawService
    private let vault: VaultAccess
    private var webView: WKWebView?
    private var window: NSWindow?
    private var isReady = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var tail: Task<Void, Never>?
    private var cache: [String: (stamp: String, picture: Picture?)] = [:]

    init(service: ExcalidrawService, vault: VaultAccess) {
        self.service = service
        self.vault = vault
    }

    func forget(_ path: String) {
        cache[path + "|light"] = nil
        cache[path + "|dark"] = nil
    }

    /// The picture of the drawing at `path`; nil for an empty drawing or one that cannot be read.
    func picture(of path: String, dark: Bool) async -> Picture? {
        let key = path + (dark ? "|dark" : "|light")
        let stamp = Self.stamp(of: vault.rootURL.appendingPathComponent(path))
        if let known = cache[key], known.stamp == stamp { return known.picture }
        let previous = tail
        let task = Task { @MainActor [weak self] () -> Picture? in
            await previous?.value
            return await self?.draw(path, dark: dark)
        }
        tail = Task { _ = await task.value }
        let picture = await task.value
        cache[key] = (stamp, picture)
        return picture
    }

    private static func stamp(of url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return "\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values?.fileSize ?? 0)"
    }

    private func draw(_ path: String, dark: Bool) async -> Picture? {
        guard let scene = try? service.scene(path), let webView = await loadedWebView() else { return nil }
        guard let result = try? await webView.callAsyncJavaScript(
            "return await loam.renderPNG(json, dark, maxSize)",
            arguments: ["json": scene, "dark": dark, "maxSize": Self.maximumPixels],
            contentWorld: .page
        ), let base64 = result as? String, let data = Data(base64Encoded: base64),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        // Excalidraw exports at twice the scene's size when it can: points are half the pixels.
        let scale: CGFloat = 2
        return Picture(image: image, size: CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
    }

    private func loadedWebView() async -> WKWebView? {
        guard ExcalidrawBundle.root != nil else { return nil }
        if webView == nil {
            let configuration = ExcalidrawBundle.configuration()
            configuration.userContentController.add(WeakMessageHandler(self), name: "loam")
            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
            // Never shown: a window only gives WebKit somewhere to lay out and draw the page.
            let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 800, height: 600),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            self.window = window
            webView = view
            view.load(URLRequest(url: ExcalidrawBundle.page))
        }
        if !isReady { await withCheckedContinuation { waiting.append($0) } }
        return isReady ? webView : nil
    }

    func close() {
        webView?.stopLoading()
        window?.close()
        webView = nil
        window = nil
        isReady = false
        for continuation in waiting { continuation.resume() }
        waiting = []
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard (message.body as? [String: Any])?["type"] as? String == "ready" else { return }
        isReady = true
        for continuation in waiting { continuation.resume() }
        waiting = []
    }
}

/// A drawing's picture, light or dark with the view it is in, redrawn when the file changes.
struct DrawingPreview: View {
    let store: ExcalidrawStore
    let path: String
    @Environment(\.themeTokens) private var theme
    /// Read from AppKit: a view the editor hosts in a note does not get SwiftUI's colour scheme.
    @State private var dark: Bool?
    @State private var picture: DrawingPreviews.Picture?
    @State private var loaded = false

    var body: some View {
        ZStack {
            Color.clear
            if let picture {
                Image(decorative: picture.image, scale: 2)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(8)
            } else if loaded {
                Image(symbol: ExcalidrawUIPlugin.symbol)
                    .font(.ui(size: 28, weight: .light))
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { AppearanceReader { dark = $0 } }
        .task(id: "\(path)|\(String(describing: dark))|\(store.version(of: path))") {
            guard let dark else { return }
            picture = await store.previews.picture(of: path, dark: dark)
            loaded = true
        }
    }
}

/// Tells whether the view it is in shows dark, and again when that changes.
private struct AppearanceReader: NSViewRepresentable {
    let changed: (Bool) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.changed = changed
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.changed = changed
    }

    final class ReaderView: NSView {
        var changed: ((Bool) -> Void)?
        private var reported: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            report()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            report()
        }

        private func report() {
            guard window != nil else { return }
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            guard dark != reported else { return }
            reported = dark
            DispatchQueue.main.async { [changed] in changed?(dark) }
        }
    }
}
