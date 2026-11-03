import AppKit
import PluginKitUI
import Quartz
import QuickLookThumbnailing
import SwiftUI

/// Any file the system can preview (Office documents, spreadsheets, code, 3D models…) with Quick Look, in a rounded
/// frame with Open and Reveal over its bottom edge. A file with nothing to preview (an archive) gets a clean card:
/// its icon, name, size, dates and the same two buttons.
struct QuickLookViewer: View {
    let view: ViewContext
    let file: FileLocation?
    @State private var previewable: Bool?

    var body: some View {
        Group {
            if previewable == false {
                ViewerFrame(view: view, file: file, showsMenu: false) { file in FileCard(file: file) }
            } else {
                ViewerFrame(view: view, file: file, barVisible: previewable == true, showsMenu: false) { file in
                    QuickLookPreview(url: file.url)
                        .clipShape(RoundedRectangle(cornerRadius: Corners.r(12), style: .continuous))
                        .shadow(color: .black.opacity(0.12), radius: 16, y: 5)
                        .padding(.horizontal, 28)
                        .padding(.top, 8)
                        .padding(.bottom, 76)
                } bar: {
                    if let file { OpenButtons(file: file) }
                }
            }
        }
        .task(id: file?.url) {
            guard let url = file?.url else { return }
            previewable = await Self.canPreview(url)
        }
    }

    /// Whether Quick Look draws something of the file, not only its icon.
    private static func canPreview(_ url: URL) async -> Bool {
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 256, height: 256), scale: 2, representationTypes: [.thumbnail, .lowQualityThumbnail]
        )
        return (try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)) != nil
    }
}

/// "Open" in the file's own app and "Reveal in Finder".
private struct OpenButtons: View {
    let file: FileLocation

    var body: some View {
        Button { NSWorkspace.shared.open(file.url) } label: {
            Label("Open", symbol: "arrow.up.forward.app").font(.ui(size: 12, weight: .medium))
        }
        Button { NSWorkspace.shared.activateFileViewerSelecting([file.url]) } label: {
            Label("Reveal in Finder", symbol: "folder").font(.ui(size: 12, weight: .medium))
        }
        .padding(.trailing, 4)
        .buttonStyle(.plain)
    }
}

/// The page of a file that has nothing to preview.
private struct FileCard: View {
    let file: FileLocation
    @Environment(\.themeTokens) private var theme

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                .resizable()
                .frame(width: 112, height: 112)
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
            VStack(spacing: 4) {
                Text(file.name).font(.ui(.section)).foregroundStyle(theme.text).lineLimit(2).multilineTextAlignment(.center)
                Text([file.kindText, file.sizeText].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.ui(.body)).foregroundStyle(theme.secondaryText)
            }
            VStack(alignment: .leading, spacing: 6) {
                if let created = file.created { dateRow("Created", created) }
                if let modified = file.modified { dateRow("Modified", modified) }
            }
            .themeLabel(size: 12)
            .foregroundStyle(theme.text)
            HStack(spacing: 10) {
                Button { NSWorkspace.shared.open(file.url) } label: {
                    Label("Open", symbol: "arrow.up.forward.app").frame(minWidth: 70)
                }
                .buttonStyle(.borderedProminent)
                Button { NSWorkspace.shared.activateFileViewerSelecting([file.url]) } label: {
                    Label("Reveal in Finder", symbol: "folder")
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
        .padding(36)
        .frame(maxWidth: 380)
        .background(theme.background, in: .rect(cornerRadius: Radius.l, style: .continuous))
        .shadow(color: .black.opacity(0.1), radius: 18, y: 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func dateRow(_ title: String, _ date: Date) -> some View {
        HStack(spacing: 12) {
            Text(title.uiLocalized).foregroundStyle(theme.secondaryText).frame(width: 60, alignment: .trailing)
            Text(date.formatted(date: .abbreviated, time: .shortened))
        }
    }
}

struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url { view.previewItem = url as NSURL }
    }

    /// Quick Look asks to be closed once its window is gone, and asserts when it is closed with no window (the tests'
    /// hosting windows go first): then dropping the item is all there is to do.
    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        if view.window != nil { view.close() } else { view.previewItem = nil }
    }
}
