import AppKit
import PluginKitUI
import WebKit

/// Draws Mermaid code as a picture with Pele (github.com/obsidianmd/pele, MIT, vendored as
/// `Resources/pele.global.js`, version 1.6.0), which turns every Mermaid diagram type into SVG in a few milliseconds.
/// Pele runs in one offscreen web view, created at the first diagram: WebKit measures the text with the page's font
/// and draws the SVG, then a snapshot gives the picture. One diagram at a time, in the order they were asked.
///
/// The page has no network access to give: Pele makes no requests, and links and images in diagrams are off.
@MainActor
final class MermaidRenderer: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var window: NSWindow?
    private var isLoaded = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    /// The diagram being drawn, which the next one waits for.
    private var tail: Task<Void, Never>?

    /// The largest picture, in points: past it a diagram is cut, which only a diagram nobody could read reaches.
    static let maximumSize: CGFloat = 4000
    /// The largest diagram, in square points, drawn at twice the page's sharpness.
    static let sharpArea: CGFloat = 1600 * 1200

    /// Pele's bundle, from this module's resources; nil when the app was built without them, and diagrams stay
    /// code. Looked up where SwiftPM's `Bundle.module` looks (the app's resources, next to the library, the build
    /// folder) but without its `fatalError` when it is missing.
    static let script: String? = {
        let name = "LoamApp_DiagramsUI.bundle"
        let library = Bundle(for: MermaidRenderer.self)
        let places = [Bundle.main.resourceURL, library.resourceURL, Bundle.main.bundleURL, library.bundleURL.deletingLastPathComponent()]
        for case let place? in places {
            if let bundle = Bundle(url: place.appendingPathComponent(name)),
               let url = bundle.url(forResource: "pele.global", withExtension: "js") {
                return try? String(contentsOf: url, encoding: .utf8)
            }
        }
        return nil
    }()

    /// The picture of `request.code`; nil when it is not valid Mermaid.
    func render(_ request: CodeBlockRequest) async -> RenderedCodeBlock? {
        let previous = tail
        let task = Task { @MainActor [weak self] () -> RenderedCodeBlock? in
            await previous?.value
            return await self?.draw(request)
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    /// Loads the web view and Pele ahead of the first diagram, a few seconds after launch while nothing else happens:
    /// making it took about 100 ms of the main thread, and the first card or note with a diagram hitched on it.
    func warm(after delay: Duration = .seconds(3)) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, self.webView == nil, !self.isClosed else { return }
            _ = await self.loadedWebView()
        }
    }

    /// Set once the plugin has stopped: a warm-up still waiting makes no web view.
    private var isClosed = false

    /// Lets the web view go.
    func close() {
        isClosed = true
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        window?.close()
        webView = nil
        window = nil
        isLoaded = false
        for continuation in waiting { continuation.resume() }
        waiting = []
    }

    private func draw(_ request: CodeBlockRequest) async -> RenderedCodeBlock? {
        guard let webView = await loadedWebView() else { return nil }
        let size: CGSize
        do {
            let result = try await webView.callAsyncJavaScript(
                Self.renderScript,
                arguments: [
                    "code": request.code,
                    "style": Self.style(for: request),
                    "font": request.fontFamily,
                    "size": max(10, request.fontSize - 1),
                ],
                contentWorld: .page
            )
            let numbers = (result as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
            guard numbers.count == 2, numbers[0] >= 1, numbers[1] >= 1 else { return nil }
            size = CGSize(width: min(ceil(numbers[0]), Self.maximumSize), height: min(ceil(numbers[1]), Self.maximumSize))
        } catch {
            // Pele throws on invalid code: the block stays code.
            return nil
        }
        // The page is as big as the picture: its backing store is all the memory it takes.
        window?.setContentSize(size)
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(origin: .zero, size: size)
        configuration.afterScreenUpdates = true
        // Twice as sharp as the page needs, so the picture still reads zoomed in its viewer; a huge diagram once.
        if size.width * size.height <= Self.sharpArea { configuration.snapshotWidth = NSNumber(value: Double(size.width * 2)) }
        guard let image = try? await webView.takeSnapshot(configuration: configuration),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return RenderedCodeBlock(image: cgImage, size: size)
    }

    /// The web view with Pele loaded, created on first use; nil without Pele's bundle or if the page failed.
    private func loadedWebView() async -> WKWebView? {
        if let webView, isLoaded { return webView }
        if webView == nil {
            guard let script = Self.script else { return nil }
            let frame = NSRect(x: 0, y: 0, width: 400, height: 300)
            let webView = WKWebView(frame: frame, configuration: WKWebViewConfiguration())
            webView.setValue(false, forKey: "drawsBackground")
            webView.navigationDelegate = self
            // Never shown: a window only gives WebKit somewhere to draw for the snapshots.
            let window = NSWindow(
                contentRect: NSRect(x: -20_000, y: -20_000, width: frame.width, height: frame.height),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = webView
            self.webView = webView
            self.window = window
            webView.loadHTMLString(Self.page(script: script), baseURL: nil)
        }
        await withCheckedContinuation { waiting.append($0) }
        return isLoaded ? webView : nil
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { finishLoading(loaded: true) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finishLoading(loaded: false) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finishLoading(loaded: false) }
    }

    private func finishLoading(loaded: Bool) {
        isLoaded = loaded
        if !loaded {
            webView = nil
            window?.close()
            window = nil
        }
        for continuation in waiting { continuation.resume() }
        waiting = []
    }

    /// Pele's CSS variables from the page's look, so a diagram reads like the note around it.
    static func style(for request: CodeBlockRequest) -> String {
        [
            "--pele-bg: \(request.background)",
            "--pele-fg: \(request.text)",
            "--pele-muted: \(request.secondaryText)",
            "--pele-line: \(request.secondaryText)",
            "--pele-surface: \(request.codeBackground)",
            "--pele-surface-alt: \(request.separator)",
            "--pele-border: \(request.separator)",
            "--pele-accent: \(request.accent)",
            "--pele-font: \(request.fontFamily)",
            "--pele-radius: 8px",
            "color-scheme: \(request.isDark ? "dark" : "light")",
        ].joined(separator: "; ")
    }

    private static func page(script: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <style>html, body { margin: 0; background: transparent; } #diagram { display: inline-block; }
        #diagram > svg { display: block; max-width: none !important; }</style>
        <script>\(script)</script></head><body><div id="diagram"></div></body></html>
        """
    }

    /// Renders `code` into the page and returns the picture's size. Runs as an async function body: the arguments
    /// are its variables, never pasted into the code.
    private static let renderScript = """
        const root = document.getElementById('diagram');
        root.innerHTML = '';
        root.style.cssText = style;
        const result = pele.render(code, { fontFamily: font, fontSize: size, links: false, images: false });
        root.innerHTML = result.svg;
        const box = root.firstElementChild.getBoundingClientRect();
        return [box.width, box.height];
        """
}
