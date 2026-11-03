import AppKit
import ExcalidrawPlugin
import os
import PluginKitUI
import WebKit

/// The Excalidraw editor, vendored in `Resources/excalidraw` (scripts/vendor-excalidraw.sh), served to its web views
/// from this module's resources through `loam-excalidraw://`, so it loads nothing from the network.
enum ExcalidrawBundle {
    static let scheme = "loam-excalidraw"
    static let page = URL(string: "\(scheme)://app/index.html")!

    /// The editor's folder; nil when the app was built without it, and drawings cannot open. Looked up where
    /// SwiftPM's `Bundle.module` looks, without its `fatalError` (as `MermaidRenderer` does).
    @MainActor static let root: URL? = {
        let name = "LoamApp_ExcalidrawUI.bundle"
        let library = Bundle(for: DrawingEditor.self)
        let places = [Bundle.main.resourceURL, library.resourceURL, Bundle.main.bundleURL, library.bundleURL.deletingLastPathComponent()]
        for case let place? in places {
            if let bundle = Bundle(url: place.appendingPathComponent(name)),
               let url = bundle.url(forResource: "excalidraw", withExtension: nil) {
                return url
            }
        }
        return nil
    }()

    /// A configuration that serves the editor.
    @MainActor static func configuration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        if let root { configuration.setURLSchemeHandler(SchemeHandler(root: root), forURLScheme: scheme) }
        return configuration
    }

    /// Serves the files of the editor's folder, and nothing outside it.
    final class SchemeHandler: NSObject, WKURLSchemeHandler {
        let root: URL

        init(root: URL) {
            self.root = root.standardizedFileURL
        }

        static let types = [
            "html": "text/html", "js": "text/javascript", "css": "text/css", "json": "application/json",
            "woff2": "font/woff2", "woff": "font/woff", "ttf": "font/ttf", "png": "image/png", "svg": "image/svg+xml",
        ]

        func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
            guard let url = task.request.url else { return }
            let relative = url.path.isEmpty || url.path == "/" ? "index.html" : String(url.path.dropFirst())
            let file = root.appendingPathComponent(relative).standardizedFileURL
            guard file.path.hasPrefix(root.path + "/"), let data = try? Data(contentsOf: file) else {
                task.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            let type = Self.types[file.pathExtension.lowercased()] ?? "application/octet-stream"
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Type": type, "Content-Length": "\(data.count)", "Access-Control-Allow-Origin": "*",
            ])!
            task.didReceive(response)
            task.didReceive(data)
            task.didFinish()
        }

        func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
    }
}

/// Passes the page's messages on without the content controller keeping the receiver alive.
final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?

    init(_ target: any WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// One open drawing: its web view running Excalidraw, loaded from the file and saved to it as it changes.
///
/// Saves go one at a time, in order; a change on disk that is not this editor's own write reloads the drawing.
@MainActor
final class DrawingEditor: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    /// The drawing's file; it follows a rename, so the save of a tab closing after it never writes the old name back.
    var path: String
    let webView: DrawingWebView
    private let store: ExcalidrawStore
    private var isReady = false
    private var isDark = false
    /// The file's text after the last load or save: a change on disk with other text came from elsewhere.
    private var knownText: String?
    private var saving: Task<Void, Never>?
    private static let log = Logger(subsystem: "app.loam", category: "excalidraw")

    init(path: String, store: ExcalidrawStore) {
        self.path = path
        self.store = store
        // A real size from the start: the page lays out for it until the tab gives its own.
        webView = DrawingWebView(frame: CGRect(x: 0, y: 0, width: 1000, height: 700),
                                 configuration: ExcalidrawBundle.configuration())
        super.init()
        webView.configuration.userContentController.add(WeakMessageHandler(self), name: "loam")
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        #if DEBUG
        webView.isInspectable = true
        #endif
        if ExcalidrawBundle.root != nil { webView.load(URLRequest(url: ExcalidrawBundle.page)) }
        store.register(self)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            isReady = true
            send("loam.setTheme(theme)", ["theme": isDark ? "dark" : "light"])
            load()
        case "change":
            if let scene = body["scene"] as? String { save(scene) }
        case "openLink":
            if let url = body["url"] as? String { store.openLink(url, from: path) }
        case "library":
            if let library = body["library"] as? String { store.libraryChanged(library, by: self) }
        default:
            break
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        // The editor's own page only: Excalidraw's library catalogue opens in Loam, so what is added from it comes
        // back here; another link clicked in Excalidraw (its help) opens in the browser.
        guard let url = action.request.url, url.scheme != ExcalidrawBundle.scheme else { return .allow }
        if LibraryBrowser.isCatalogue(url) {
            store.browseLibraries(url, for: self)
        } else if action.navigationType == .linkActivated {
            NSWorkspace.shared.open(url)
        }
        return .cancel
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isReady = false
        webView.load(URLRequest(url: ExcalidrawBundle.page))
    }

    func setDark(_ dark: Bool) {
        guard dark != isDark else { return }
        isDark = dark
        if isReady { send("loam.setTheme(theme)", ["theme": dark ? "dark" : "light"]) }
    }

    /// Shows the drawing as the file holds it now.
    private func load() {
        guard isReady else { return }
        do {
            let scene = try store.service.scene(path)
            knownText = try? store.vault.read(path)
            send("loam.load(json, library)", ["json": scene, "library": store.libraryText ?? ""])
        } catch {
            Self.log.error("Cannot open \(self.path, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    private func save(_ scene: String) {
        let previous = saving
        let service = store.service, vault = store.vault, path = path
        saving = Task { [weak self] in
            await previous?.value
            do {
                try await service.save(path, scene: scene)
            } catch {
                Self.log.error("Cannot save \(path, privacy: .public): \(String(describing: error), privacy: .public)")
            }
            self?.knownText = try? vault.read(path)
        }
    }

    /// Shows the library another drawing changed.
    func setLibrary(_ library: String) {
        if isReady { send("loam.setLibrary(json)", ["json": library]) }
    }

    /// Merges a library downloaded from the catalogue into the shared one, and opens the library panel.
    func addLibrary(_ library: String) {
        if isReady { send("loam.addLibrary(json)", ["json": library]) }
    }

    /// Saves what the editor shows now, without waiting for its pause: before the tab closes or the app leaves.
    func flush() async {
        if isReady, let scene = try? await webView.callAsyncJavaScript("return loam.flush()", contentWorld: .page) as? String {
            save(scene)
        }
        await saving?.value
    }

    /// The file changed on disk: reloads it unless the change is this editor's own save.
    func fileChanged() {
        guard isReady else { return }
        Task { [weak self] in
            await self?.saving?.value
            guard let self, let text = try? self.store.vault.read(self.path), text != self.knownText else { return }
            self.load()
        }
    }

    private func send(_ script: String, _ arguments: [String: Any]) {
        webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { result in
            if case .failure(let error) = result {
                Self.log.error("Excalidraw bridge: \(String(describing: error), privacy: .public)")
            }
        }
    }
}

/// The web view of a drawing.
final class DrawingWebView: WKWebView {}
