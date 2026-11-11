import Observation
import PluginKitUI
import SwiftUI
import WorkspaceModel

/// The right sidebar: the inspector of the focused tab, as Craft's. Its tabs are the view's own (a note's "Insert",
/// a mindmap's "Style"), then "Info", made of the sections plugins add for the resource (and of the right column's
/// panels, if any plugin still registers one). The sections placed `.primary` go under the view's first tab.
///
/// The chosen tab is kept in the chrome (`trailingPanel`) by id: "Info" stays chosen from a note to a board, and a
/// tab the new view does not have falls back to its first.
struct InspectorColumn: View {
    let session: ShellSession
    let workspace: WorkspaceController
    /// The tab the column describes: the active one, a moment after it changes (`InspectorFollower`).
    let follower: InspectorFollower
    /// The right column's panels the user shows, drawn as groups of "Info".
    let panels: [Panel]

    @Environment(\.themeTokens) private var theme

    var body: some View {
        let tabs = self.tabs()
        let selected = tabs.first { $0.id == workspace.chrome.trailingPanel } ?? tabs.first
        VStack(spacing: 0) {
            // A lone tab is a title, as Bear's; several are a segmented control.
            if tabs.count == 1, let selected {
                Text(selected.title.uiLocalized)
                    .font(.ui(size: 15, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, InspectorStyle.padding + 2)
                    .frame(height: 32)
                    .padding(.bottom, 8)
                    .accessibilityAddTraits(.isHeader)
            } else if let selected {
                InspectorSegmented(
                    tabs.map { (value: $0.id, title: $0.title) },
                    selection: Binding(
                        get: { selected.id },
                        set: { workspace.selectPanel($0, in: .trailing) }
                    ),
                    isProminent: true
                )
                .padding(.horizontal, InspectorStyle.padding)
                .padding(.bottom, 12)
            }
            if let selected {
                ScrollView {
                    selected.makeView()
                        .padding(.horizontal, InspectorStyle.padding)
                        .padding(.top, 4)
                        .padding(.bottom, 28)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .scrollIndicators(.never)
                .softScrollEdges()
                .id(selected.id + "|" + (follower.tab?.resource.path ?? ""))
                .transition(.opacity.animation(Motion.crossfade))
            } else {
                InspectorColumnEmpty()
                    .padding(.horizontal, InspectorStyle.padding + 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(Motion.crossfade, value: selected?.id)
        .accessibilityIdentifier("inspector")
    }

    /// The tabs of the focused tab's resource: the view's and the sections' own, by order, then "Info". Empty without a focused tab.
    private func tabs() -> [InspectorTab] {
        guard let tab = follower.tab, let context = follower.context else { return [] }
        let resource = tab.resource
        let viewType = WorkspaceController.viewType(for: tab, in: session.views)
        var viewTabs: [InspectorTab] = []
        if let content = context.inspector, content.viewType == viewType?.id { viewTabs = content.tabs }

        let primary = session.inspector.sections(for: resource, viewType: viewType?.id, in: .primary)
        if !primary.isEmpty {
            if let first = viewTabs.first {
                viewTabs[0] = InspectorTab(id: first.id, title: first.title) {
                    AnyView(InspectorTabBody(lead: first.makeView, sections: primary, resource: resource))
                }
            } else {
                viewTabs = [InspectorTab(id: "inspector.page", title: String(localized: "Page")) {
                    AnyView(InspectorTabBody(lead: nil, sections: primary, resource: resource))
                }]
            }
        }

        // The sections' own tabs, among the view's (which count as order 0).
        var ordered = viewTabs.map { (order: 0, tab: $0) }
        for (page, sections) in session.inspector.pages(for: resource, viewType: viewType?.id) {
            ordered.append((page.order, InspectorTab(id: page.id, title: page.title) {
                AnyView(InspectorTabBody(lead: nil, sections: sections, resource: resource))
            }))
        }
        viewTabs = ordered.enumerated()
            .sorted { $0.element.order != $1.element.order ? $0.element.order < $1.element.order : $0.offset < $1.offset }
            .map(\.element.tab)

        let info = session.inspector.sections(for: resource, viewType: viewType?.id, in: .info)
        let panels = self.panels
        if !info.isEmpty || !panels.isEmpty {
            viewTabs.append(InspectorTab(id: InspectorTab.infoID, title: String(localized: "Info")) {
                AnyView(InspectorTabBody(lead: nil, sections: info, resource: resource, panels: panels))
            })
        }
        return viewTabs
    }
}

/// The tab the right column describes: the active tab, followed a moment after it changes rather than in the frame
/// the page changes in. The column's content is made again for each tab (a daily note's calendar, its tasks: ~45 ms
/// of SwiftUI), and that was the longest frame of ⌘W, ⌘T and each note switch, under the page's motion. Shown, the
/// column follows once the page's change is on screen (its motion plays on the render server meanwhile); hidden (it
/// is never removed, `SlidingColumnView`), only once the app has had no input for a second, so nothing is made
/// under a person's hands for a column they do not see.
@MainActor
@Observable
final class InspectorFollower {
    private(set) var tab: WorkspaceModel.Tab?
    /// The tab's context, taken while the tab was open: a tab closed meanwhile is never asked for a new one.
    private(set) var context: ViewContext?
    @ObservationIgnored private weak var workspace: WorkspaceController?
    @ObservationIgnored private var work: DispatchWorkItem?
    /// Whether the column is on screen; set by the window as it slides the column in or out.
    @ObservationIgnored var isShown: Bool {
        didSet { if isShown != oldValue { schedule() } }
    }

    /// After a page change, the shown column waits for the page's motion (`PageStackView.crossfade`) to be under way.
    static let shownDelay = 0.2

    init(workspace: WorkspaceController, isShown: Bool) {
        self.workspace = workspace
        self.isShown = isShown
        PageStackView.watchInput()
        catchUp(waitingForStill: false)
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = workspace?.layout.activeTab
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.schedule()
                self.observe()
            }
        }
    }

    private func schedule(after delay: Double? = nil) {
        work?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.catchUp(waitingForStill: !self.isShown)
        }
        self.work = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (delay ?? (isShown ? Self.shownDelay : PageStackView.idleDelay)), execute: work)
    }

    private func catchUp(waitingForStill: Bool) {
        work = nil
        guard let workspace else { return }
        if waitingForStill {
            let still = ProcessInfo.processInfo.systemUptime - PageStackView.lastInput
            if still < PageStackView.idleDelay {
                schedule(after: max(0.25, PageStackView.idleDelay - still))
                return
            }
        }
        let active = workspace.layout.activeTab
        let context = active.map { workspace.context(for: $0) }
        guard active?.id != tab?.id || active?.resource != tab?.resource || context !== self.context else { return }
        tab = active
        self.context = context
    }
}

/// One tab's column: the view's own groups, then the plugins' sections, each under its title.
private struct InspectorTabBody: View {
    let lead: (@MainActor @Sendable () -> AnyView)?
    let sections: [InspectorSection]
    let resource: Resource
    var panels: [Panel] = []

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorStyle.groupSpacing) {
            // Sections with a negative order lead the view's own groups (a daily note's calendar).
            ForEach(sections.filter { $0.order < 0 }) { section(_: $0) }
            if let lead { lead() }
            ForEach(sections.filter { $0.order >= 0 }) { section(_: $0) }
            ForEach(panels) { panel in
                InspectorGroup(panel.title) { panel.makeView() }
            }
        }
    }

    private func section(_ section: InspectorSection) -> some View {
        InspectorGroup(section.title) { section.makeView(resource) }
            .id(section.id)
    }
}

/// What the column shows with no tab open, as an empty task list does: a small drawing of a page and its details,
/// a title and a line, a little above the middle.
private struct InspectorColumnEmpty: View {
    @Environment(\.themeTokens) private var theme
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            PrintIllustration(.page).frame(width: 96, height: 96)
                .frame(width: 112, height: 96)
                .padding(.bottom, 16)
            Text("No note open")
                .font(.ui(size: 15, weight: .semibold))
                .foregroundStyle(theme.text)
            Text("Open a note to see its details here.")
                .font(.ui(size: 12))
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 200)
                .padding(.top, 4)
            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 8)
        .onAppear { withAnimation(Motion.resolved(Motion.Spring.standard.animation)) { appeared = true } }
        .accessibilityElement(children: .combine)
    }
}

