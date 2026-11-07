import AppKit
import Observation
import PDFKit
import PluginKitUI
import SwiftUI

/// A PDF with PDFKit: continuous scrolling with a shadow under each page, a thumbnail column, zoom, and a search that
/// highlights every match and steps through them. Its controls float over the bottom edge.
struct PDFViewer: View {
    let view: ViewContext
    let file: FileLocation?
    @State private var model = PDFModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ViewerFrame(
            view: view, file: file,
            detail: model.pageCount > 0 ? "\(model.pageCount) \(model.pageCount == 1 ? "page" : "pages")" : nil
        ) { file in
            HStack(spacing: 0) {
                if model.showsThumbnails {
                    PDFThumbnails(model: model)
                        .frame(width: 128)
                        .background(Color.primary.opacity(0.03))
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                PDFSurface(url: file.url, model: model)
            }
            .animation(reduceMotion ? CollectionMotion.fade : CollectionMotion.reveal, value: model.showsThumbnails)
        } bar: {
            PDFControls(model: model)
        }
    }
}

/// What the PDF view shows and searches.
@MainActor
@Observable
final class PDFModel {
    private(set) var pageCount = 0
    private(set) var pageNumber = 1
    var showsThumbnails = false
    var isSearching = false
    var query = ""
    private(set) var matches: [PDFSelection] = []
    private(set) var current = 0
    @ObservationIgnored fileprivate weak var view: PDFView?

    fileprivate func attach(_ view: PDFView) {
        self.view = view
        pageCount = view.document?.pageCount ?? 0
        pageChanged()
    }

    fileprivate func pageChanged() {
        guard let view, let page = view.currentPage, let document = view.document else { return }
        pageNumber = document.index(for: page) + 1
    }

    func nextPage() { view?.goToNextPage(nil) }
    func previousPage() { view?.goToPreviousPage(nil) }
    func zoomIn() { view?.autoScales = false; view?.zoomIn(nil) }
    func zoomOut() { view?.autoScales = false; view?.zoomOut(nil) }
    func fitWidth() { view?.autoScales = true }

    /// Finds every occurrence of `query`, highlights them and goes to the first.
    func search() {
        guard let view, let document = view.document else { return }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return clear() }
        matches = document.findString(text, withOptions: [.caseInsensitive, .diacriticInsensitive])
        for match in matches { match.color = NSColor.systemYellow.withAlphaComponent(0.5) }
        view.highlightedSelections = matches
        current = 0
        show()
    }

    func next() { step(1) }
    func previous() { step(-1) }

    func clear() {
        matches = []
        current = 0
        view?.highlightedSelections = nil
        view?.clearSelection()
    }

    func closeSearch() {
        query = ""
        clear()
        isSearching = false
    }

    private func step(_ delta: Int) {
        guard !matches.isEmpty else { return search() }
        current = (current + delta + matches.count) % matches.count
        show()
    }

    private func show() {
        guard let view, matches.indices.contains(current) else { return }
        let match = matches[current]
        view.setCurrentSelection(match, animate: true)
        view.go(to: match)
    }
}

private struct PDFControls: View {
    @Bindable var model: PDFModel
    @FocusState private var focused: Bool

    var body: some View {
        BarButton(symbol: "sidebar.left", help: "Thumbnails", isOn: model.showsThumbnails) { model.showsThumbnails.toggle() }
        BarDivider()
        BarButton(symbol: "chevron.up", help: "Previous Page") { model.previousPage() }
        Text("\(model.pageNumber) / \(model.pageCount)")
            .font(.ui(size: 12, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
            .fixedSize()
            .help("Page \(model.pageNumber) of \(model.pageCount)")
        BarButton(symbol: "chevron.down", help: "Next Page") { model.nextPage() }
        BarDivider()
        BarButton(symbol: "minus", help: "Zoom Out") { model.zoomOut() }
        BarButton(symbol: "plus", help: "Zoom In") { model.zoomIn() }
        BarButton(symbol: "arrow.left.and.right", help: "Fit Width") { model.fitWidth() }
        BarDivider()
        if model.isSearching {
            HStack(spacing: 4) {
                TextField("Search", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.ui(size: 12))
                    .frame(width: 130)
                    .focused($focused)
                    .onSubmit { model.matches.isEmpty ? model.search() : model.next() }
                    .onChange(of: model.query) { model.query.isEmpty ? model.clear() : model.search() }
                    .onExitCommand { model.closeSearch() }
                if !model.query.isEmpty {
                    Text(model.matches.isEmpty ? "0" : "\(model.current + 1)/\(model.matches.count)")
                        .font(.ui(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    BarButton(symbol: "chevron.up", help: "Previous Match", size: 11) { model.previous() }
                        .disabled(model.matches.isEmpty)
                    BarButton(symbol: "chevron.down", help: "Next Match", size: 11) { model.next() }
                        .disabled(model.matches.isEmpty)
                }
                BarButton(symbol: "xmark.circle.fill", help: "Close Search", size: 12) { model.closeSearch() }
            }
            .onAppear { focused = true }
        } else {
            BarButton(symbol: "magnifyingglass", help: "Search") { model.isSearching = true }
        }
        BarDivider()
    }
}

private struct PDFSurface: NSViewRepresentable {
    let url: URL
    let model: PDFModel

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = PDFDocument(url: url)
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.pageBreakMargins = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        view.backgroundColor = .clear
        model.attach(view)
        context.coordinator.token = NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged, object: view, queue: .main
        ) { [model] _ in MainActor.assumeIsolated { model.pageChanged() } }
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var token: (any NSObjectProtocol)?
        deinit { token.map(NotificationCenter.default.removeObserver) }
    }
}

/// The pages as small pictures down the left, click to go there.
private struct PDFThumbnails: NSViewRepresentable {
    let model: PDFModel

    func makeNSView(context: Context) -> PDFThumbnailView {
        let thumbnails = PDFThumbnailView()
        thumbnails.pdfView = model.view
        thumbnails.thumbnailSize = CGSize(width: 90, height: 120)
        thumbnails.backgroundColor = .clear
        return thumbnails
    }

    func updateNSView(_ view: PDFThumbnailView, context: Context) {}
}
