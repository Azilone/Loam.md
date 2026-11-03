import AppKit
import os
import WebKit

/// Excalidraw's public library catalogue (libraries.excalidraw.com), in a window of Loam's own: "Add to Excalidraw"
/// there sends the browser back to the page that opened it with `#addLibrary=<url>`, which only this window can take,
/// since the editor's page is not an address the system knows. The library is downloaded from the catalogue and
/// handed to `added`, then the window closes.
@MainActor
final class LibraryBrowser: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    static let host = "libraries.excalidraw.com"

    /// Whether a link goes to the catalogue.
    static func isCatalogue(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == host
    }

    /// The library a return address asks to add (`…#addLibrary=<url>&token=…`), if it comes from the catalogue.
    static func libraryURL(in url: URL) -> URL? {
        guard let fragment = url.fragment, fragment.contains("addLibrary=") else { return nil }
        var parts = URLComponents()
        parts.percentEncodedQuery = fragment
        guard let value = parts.queryItems?.first(where: { $0.name == "addLibrary" })?.value,
              let library = URL(string: value), isCatalogue(library) else { return nil }
        return library
    }

    private let window: NSWindow
    private let webView: WKWebView
    private let added: @MainActor (String) -> Void
    private var adding = false
    private static let log = Logger(subsystem: "app.loam", category: "excalidraw")

    init(url: URL, added: @escaping @MainActor (String) -> Void) {
        self.added = added
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1100, height: 820))
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1100, height: 820),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Excalidraw Libraries"
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.delegate = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.load(URLRequest(url: url))
    }

    func show() {
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window.close()
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        if let library = Self.libraryURL(in: url) {
            add(library)
            return .cancel
        }
        if Self.isCatalogue(url) || url.scheme == "about" { return .allow }
        // Elsewhere (an author's page, GitHub): the browser.
        NSWorkspace.shared.open(url)
        return .cancel
    }

    /// "Add to Excalidraw" opens its return address in a new window: taken here instead.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url {
            if let library = Self.libraryURL(in: url) {
                add(library)
            } else if !Self.isCatalogue(url) {
                NSWorkspace.shared.open(url)
            } else {
                webView.load(action.request)
            }
        }
        return nil
    }

    private func add(_ library: URL) {
        guard !adding else { return }
        adding = true
        Task { @MainActor in
            defer { adding = false }
            do {
                let (data, response) = try await URLSession.shared.data(from: library)
                guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 20_000_000,
                      let text = String(data: data, encoding: .utf8),
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      json["libraryItems"] != nil || json["library"] != nil else {
                    throw URLError(.cannotParseResponse)
                }
                added(text)
                close()
            } catch {
                Self.log.error("Cannot add the library \(library, privacy: .public): \(String(describing: error), privacy: .public)")
                NSSound.beep()
            }
        }
    }
}
