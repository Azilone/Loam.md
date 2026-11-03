// Renders an HTML or SVG file to a PNG with WebKit: render.swift in.html out.png width [scale] [transparent]
import AppKit
import WebKit

let a = CommandLine.arguments
let input = URL(fileURLWithPath: a[1]), output = URL(fileURLWithPath: a[2])
let width = CGFloat(Double(a[3]) ?? 1400), scale = a.count > 4 ? CGFloat(Double(a[4]) ?? 2) : 2
let transparent = a.count > 5 && a[5] == "transparent"

final class Loader: NSObject, WKNavigationDelegate {
    let web: WKWebView
    init(_ web: WKWebView) { self.web = web }
    func webView(_ w: WKWebView, didFinish _: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            w.evaluateJavaScript("Math.ceil(document.documentElement.scrollHeight)") { h, _ in
                let height = CGFloat((h as? Double) ?? 800)
                w.frame = NSRect(x: 0, y: 0, width: width, height: height)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    let config = WKSnapshotConfiguration()
                    config.rect = NSRect(x: 0, y: 0, width: width, height: height)
                    config.snapshotWidth = NSNumber(value: Double(width * scale))
                    w.takeSnapshot(with: config) { image, _ in
                        if let tiff = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                           let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: output) }
                        exit(0)
                    }
                }
            }
        }
    }
}
let app = NSApplication.shared
let web = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 800))
if transparent { web.setValue(false, forKey: "drawsBackground") }
let loader = Loader(web)
web.navigationDelegate = loader
let window = NSWindow(contentRect: web.frame, styleMask: [.borderless], backing: .buffered, defer: false)
window.contentView = web
window.orderBack(nil)
web.loadFileURL(input, allowingReadAccessTo: URL(fileURLWithPath: "/"))
app.run()
