import PluginKitUI
import SwiftUI

/// The right sidebar: the inspector of the focused tab, as Craft's. Its tabs are the view's own (a note's "Insert",
/// a mindmap's "Style"), then "Info", made of the sections plugins add for the resource (and of the right column's
/// panels, if any plugin still registers one). The sections placed `.primary` go under the view's first tab.
///
/// The chosen tab is kept in the chrome (`trailingPanel`) by id: "Info" stays chosen from a note to a board, and a
/// tab the new view does not have falls back to its first.
struct InspectorColumn: View {
    let session: ShellSession
    let workspace: WorkspaceController
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
                .id(selected.id + "|" + (workspace.activeResource?.path ?? ""))
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
        guard let tab = workspace.layout.activeTab else { return [] }
        let resource = tab.resource
        let context = workspace.context(for: tab)
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

