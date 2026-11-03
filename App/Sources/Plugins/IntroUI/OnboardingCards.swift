import AppKit
import ObsidianImportPlugin
import PluginKitUI
import SwiftUI

/// Every card after the welcome, on one template: the step capsules, the serif title and one sentence, the choice, the
/// main button, a footnote, Back; on the right the night art and what the choice does: the real app in the look and
/// with the plugins picked, the agent at work in a terminal, Obsidian's notes going into Loam. Moving between cards
/// slides only what changes: the capsules grow, the window stays and changes its picture, the words slide 24 points.
struct OnboardingStage: View {
    @Bindable var model: IntroOnboarding

    private var step: IntroSetup.Step {
        if case .step(let step) = model.phase { step } else { .folder }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Onb.night
            OnbNightArt()
            art
            OnbSteps(count: model.stepCount, current: model.stepIndex).place(OnbGrid.edge, OnbGrid.markerY)
            words
                .id(step)
                .transition(slide)
            actions.place(OnbGrid.edge, OnbGrid.actionY)
            footnote.place(OnbGrid.edge, OnbGrid.footnoteY)
            OnbBackButton(enabled: model.canGoBack, action: model.back)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, OnbGrid.backBottom)
                .place(OnbGrid.edge, 0)
        }
        .frame(width: IntroScene.cardSize.width, height: IntroScene.cardSize.height, alignment: .topLeading)
        .environment(\.colorScheme, .dark)
    }

    /// The words of a card arrive from the side the user goes to, 24 points, and leave faster than they come.
    private var slide: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(x: model.forward ? 24 : -24)),
            removal: .opacity.animation(Motion.exit)
        )
    }

    // MARK: Words

    private var words: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(OnbType.title(30))
                    .tracking(-0.3)
                    .foregroundStyle(Onb.ink)
                    .frame(height: 36, alignment: .leading)
                Text(sentence)
                    .font(OnbType.text(14))
                    .foregroundStyle(Onb.soft)
                    .lineSpacing(4)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: OnbGrid.columnWidth, alignment: .leading)
                    .padding(.top, 12)
            }
            .place(OnbGrid.edge, OnbGrid.titleY)
            choice.place(OnbGrid.edge, OnbGrid.choiceY)
        }
    }

    private var agent: String { model.agentName ?? String(localized: "Your agent") }

    private var title: String {
        switch step {
        case .folder: String(localized: "Where do your notes live?")
        case .agent: String(localized: "Bring your agent")
        case .migrate: String(localized: "Bring your notes")
        case .plugins: String(localized: "What is Loam for?")
        case .look: String(localized: "Pick a look")
        }
    }

    private var sentence: String {
        let name = model.chosenVault?.name ?? "Obsidian"
        return switch step {
        case .folder: String(localized: "One folder of Markdown files. In iCloud Drive, it is on all your Macs.")
        case .agent: String(localized: "Claude Code, Codex and others read and write your notes through Loam.")
        case .migrate:
            model.chosenVault == nil
                ? String(localized: "Your agent moves them in from any app.")
                : String(localized: "Your agent moves \(name) in, or notes from any other app.")
        case .plugins: String(localized: "Every feature is a plugin. Start with a set; change it in Settings > Plugins.")
        case .look: String(localized: "Change it any time in Settings > Appearance.")
        }
    }

    @ViewBuilder
    private var choice: some View {
        switch step {
        case .folder: FolderChoice(model: model)
        case .agent: AgentChoice(setup: model.setup)
        case .migrate: AgentCopyButton(model: model)
        case .plugins: PresetChoice(setup: model.setup)
        case .look: LookChoice(setup: model.setup)
        }
    }

    private var footnote: some View {
        Text(footnoteText)
            .font(OnbType.text(12))
            .foregroundStyle(Onb.muted)
            .frame(height: 18, alignment: .leading)
            .id(step)
            .transition(.opacity)
    }

    private var footnoteText: String {
        switch step {
        case .folder: String(localized: "Loam never changes a file outside it.")
        case .agent: String(localized: "Turn it off and nothing is installed.")
        case .migrate: String(localized: "Then paste it into Claude Code, Codex or any agent.")
        case .plugins: String(localized: "The window on the right shows the sidebar you get.")
        case .look: String(localized: "The window on the right wears the look you pick.")
        }
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: 16) {
            OnbMainButton(title: mainTitle, action: model.primary)
            if let secondary = secondaryTitle {
                OnbTextButton(title: secondary, action: model.secondary)
            }
        }
        .frame(height: 38)
    }

    private var mainTitle: String {
        switch step {
        case .migrate: String(localized: "Continue")
        case .look: String(localized: "Open Loam")
        default: String(localized: "Continue")
        }
    }

    private var secondaryTitle: String? {
        switch step {
        case .folder: nil
        case .migrate: nil
        default: String(localized: "Skip")
        }
    }

    // MARK: Art

    /// The app window on the art, the same one from card to card; the agent's card trades it for a terminal where
    /// the agent works, the migration's for the apps the notes can come from.
    @ViewBuilder
    private var art: some View {
        ZStack(alignment: .topLeading) {
            switch step {
            case .agent:
                OnbTerminal()
                    .place(520, 200)
                    .transition(.opacity.combined(with: .offset(y: 12)))
            case .migrate:
                SourcesArt(obsidian: model.chosenVault != nil)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            default:
                OnbAppShot(name: shot)
                    .place(OnbGrid.window.minX, OnbGrid.window.minY)
                    .transition(.opacity.combined(with: .offset(y: 12)))
            }
        }
        .animation(Motion.Spring.smooth.animation, value: step)
        .allowsHitTesting(false)
    }

    /// The picture of the app for the card: the plugins chosen, then the look.
    private var shot: String {
        switch step {
        case .look: "look-\(model.setup.look)"
        case .plugins: "plugins-\(model.setup.preset)"
        default: "plugins-everything"
        }
    }
}

// MARK: Folder

/// The vault's folders: Documents, iCloud Drive when it is on, or one the user picks.
private struct FolderChoice: View {
    @Bindable var model: IntroOnboarding

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.folders, id: \.self) { folder in
                OnbOption(title: title(of: folder), detail: detail(of: folder), selected: selected(folder)) {
                    if case .custom(let place) = folder, place.isEmpty || selected(folder) { model.pickFolder() } else { model.folder = folder }
                }
            }
        }
    }

    private func selected(_ folder: IntroOnboarding.Folder) -> Bool {
        if case .custom(let place) = folder, place.isEmpty { return false }
        return model.folder == folder
    }

    private func title(of folder: IntroOnboarding.Folder) -> String {
        switch folder {
        case .documents: String(localized: "On this Mac")
        case .iCloud: String(localized: "iCloud Drive")
        case .custom: String(localized: "Somewhere else…")
        }
    }

    private func detail(of folder: IntroOnboarding.Folder) -> String {
        switch folder {
        case .documents: model.documentsPlace.replacingOccurrences(of: "~/", with: "")
        case .iCloud: String(localized: "iCloud Drive/\((model.iCloudPlace as NSString).lastPathComponent), on all your Macs")
        case .custom(let place): place.isEmpty ? String(localized: "Choose a folder") : place
        }
    }
}

// MARK: Agent

/// One switch for both: the `loam` command and the skill that tells the agents how to use it.
private struct AgentChoice: View {
    @Bindable var setup: IntroSetup

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                OnbSwitch(isOn: $setup.agentTools, label: String(localized: "Install for coding agents"))
                Text("Install for coding agents").font(OnbType.text(14, .semibold)).foregroundStyle(Onb.ink)
            }
            .frame(height: 20)
            item(symbol: TerminalGlyph(), title: Text("The ") + Text("loam").font(OnbType.mono(12)) + Text(" command"),
                 detail: String(localized: "Read, write and search notes from a terminal."))
            item(symbol: DocumentGlyph(), title: Text("A skill"),
                 detail: String(localized: "Tells Claude Code and Codex how to use it."))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: OnbGrid.choiceWidth, alignment: .leading)
        .background(Onb.raised, in: RoundedRectangle(cornerRadius: Onb.radiusCard, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Onb.radiusCard, style: .continuous).strokeBorder(Onb.line))
    }

    private func item(symbol: some Shape, title: Text, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            symbol.stroke(Onb.leaf, style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                .frame(width: 18, height: 18)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 0) {
                title.font(OnbType.text(13, .semibold)).foregroundStyle(Onb.ink).frame(height: 18)
                Text(detail).font(OnbType.text(12.5)).foregroundStyle(Onb.muted).frame(height: 18)
            }
        }
        // What is not installed fades, so the switch reads at a glance.
        .opacity(setup.agentTools ? 1 : 0.45)
        .animation(Motion.fade, value: setup.agentTools)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(Onb.line).frame(height: 1) }
        .padding(.top, 12)
    }
}

// MARK: Migration

/// One button: it copies the prompt for the user's agent, then says so; its chevron shows the prompt. The agents
/// on this Mac show in it by their own icons.
private struct AgentCopyButton: View {
    let model: IntroOnboarding
    @State private var copied = false
    @State private var hovered = false
    @State private var showsPrompt = false

    var body: some View {
        HStack(spacing: 0) {
            Button {
                model.copyPrompt()
                withAnimation(Motion.resolved(Motion.Spring.pop.animation)) { copied = true }
                Haptics.alignment()
            } label: {
                HStack(spacing: 10) {
                    Group {
                        if copied {
                            TickGlyph().stroke(Onb.leaf, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                        } else {
                            Image(systemName: "doc.on.doc").font(.system(size: 12.5))
                        }
                    }
                    .frame(width: 16, height: 16)
                    Text(copied ? "Copied, paste it" : "Let your agent set it up")
                        .font(OnbType.mono(11.5, .medium))
                        .textCase(.uppercase)
                        .tracking(0.3)
                        .lineLimit(1)
                        .fixedSize()
                        .contentTransition(.opacity)
                    Spacer(minLength: 8)
                    HStack(spacing: 4) {
                        ForEach(AppIcons.agents, id: \.self) { name in
                            if let icon = AppIcons.icon(name) {
                                Image(nsImage: icon).resizable().interpolation(.high).frame(width: 22, height: 22)
                            }
                        }
                    }
                }
                .foregroundStyle(Onb.ink)
                .padding(.leading, 16)
                .padding(.trailing, 12)
                .frame(height: 46)
                .contentShape(Rectangle())
            }
            .buttonStyle(.press)
            Rectangle().fill(Onb.line).frame(width: 1, height: 26)
            Button { showsPrompt.toggle() } label: {
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(Onb.soft)
                    .frame(width: 44, height: 46).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Show the prompt"))
            .popover(isPresented: $showsPrompt, arrowEdge: .bottom) {
                Text(model.migrationPrompt)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(width: 360, alignment: .leading)
                    .padding(14)
            }
        }
        .frame(width: OnbGrid.choiceWidth)
        .background(hovered ? Color(hex: 0x1C1C1C) : Onb.raised, in: RoundedRectangle(cornerRadius: Onb.radiusCard, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Onb.radiusCard, style: .continuous).strokeBorder(copied ? Onb.leaf.opacity(0.7) : Onb.line))
        .onHover { hovered = $0 }
        .animation(Motion.hover, value: hovered)
    }
}

/// The real icons of the apps on this Mac, by bundle id, drawn once into plain 8-bit sRGB pictures (the system's
/// come in a wide 16-bit form that turns a whole offscreen picture linear and washed out).
@MainActor
enum AppIcons {
    /// The note apps notes can come from, most likely first: only the ones on this Mac show.
    static let sources: [(name: String, bundle: String)] = [
        ("Obsidian", "md.obsidian"), ("Notion", "notion.id"), ("Apple Notes", "com.apple.Notes"),
        ("Bear", "net.shinyfrog.bear"), ("Craft", "com.lukilabs.lukiapp"), ("Evernote", "com.evernote.Evernote"),
        ("Logseq", "com.electron.logseq"), ("Things", "com.culturedcode.ThingsMac"), ("Todoist", "com.todoist.mac.Todoist"),
        ("Reminders", "com.apple.reminders"), ("Day One", "com.bloombuilt.dayone-mac"), ("Drafts", "com.agiletortoise.Drafts-OSX"),
        ("Capacities", "io.capacities.app"), ("Anytype", "io.anytype.anytype"), ("Heptabase", "app.heptabase"),
    ]
    /// The agents the prompt works with, by the apps that carry them.
    static let agentBundles: [(name: String, bundle: String)] = [
        ("Claude", "com.anthropic.claudefordesktop"), ("Codex", "com.openai.codex"), ("Cursor", "com.todesktop.230313mzl4w4u92"),
    ]

    static var agents: [String] { agentBundles.map(\.name).filter { icon($0) != nil } }
    static var installedSources: [String] { Array(sources.map(\.name).filter { icon($0) != nil }.prefix(8)) }

    private static var cache: [String: NSImage?] = [:]

    static func icon(_ name: String) -> NSImage? {
        if let cached = cache[name] { return cached }
        let bundle = (sources + agentBundles).first { $0.name == name }?.bundle
        let image = bundle
            .flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .map { sRGB(NSWorkspace.shared.icon(forFile: $0.path)) }
        cache[name] = image
        return image
    }

    static func sRGB(_ icon: NSImage) -> NSImage {
        let pixels = 256
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )?.retagging(with: .sRGB), let context = NSGraphicsContext(bitmapImageRep: rep) else { return icon }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        icon.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: 128, height: 128))
        image.addRepresentation(rep)
        return image
    }
}

/// Loam in the middle on a quiet night, the note apps on this Mac around it in their own icons, each linked to it;
/// Obsidian lit when it has a vault here, the others dimmed. It comes in once, in order: Loam, the links drawn out
/// from it, each app at the end of its link; then a light runs along Obsidian's link into Loam, again and again.
private struct SourcesArt: View {
    let obsidian: Bool
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.introStill) private var still

    /// When link `index` starts drawing, and how long a link takes.
    private func delay(_ index: Int) -> Double { 0.22 + Double(index) * 0.07 }
    private static let draw = 0.45

    private static let center = CGPoint(x: 690, y: 258)
    private static let radius: CGFloat = 168
    private static let icon: CGFloat = 60

    private var names: [String] { AppIcons.installedSources }
    /// Where a link starts past Loam's icon, and stops short of an app's (its label included).
    private static let inner: CGFloat = 62
    private static let outer: CGFloat = 46

    private func along(_ index: Int, _ distance: CGFloat) -> CGPoint {
        let end = point(index)
        let dx = end.x - Self.center.x, dy = end.y - Self.center.y, length = max(hypot(dx, dy), 1)
        return CGPoint(x: Self.center.x + dx / length * distance, y: Self.center.y + dy / length * distance)
    }

    private func point(_ index: Int) -> CGPoint {
        let angle = -Double.pi / 2 + Double(index) / Double(max(names.count, 1)) * 2 * .pi
        return CGPoint(x: Self.center.x + Self.radius * cos(angle), y: Self.center.y + Self.radius * sin(angle))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // The painting gives way to a plain night here, so the icons read.
            Color.black.opacity(0.82).mask(ArtFade()).frame(width: IntroScene.cardSize.width - OnbGrid.artX).place(OnbGrid.artX, 0)
            RadialGradient(colors: [Onb.leaf.opacity(0.16), .clear], center: .center, startRadius: 0, endRadius: 150)
                .frame(width: 300, height: 300)
                .position(Self.center)
            ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                let lit = name == "Obsidian" && obsidian
                // An app above Loam has its label in the way: the link stops under it.
                let stop = Self.radius - (point(index).y < Self.center.y - 1 ? Self.outer + 22 : Self.outer)
                Path { path in path.move(to: along(index, Self.inner)); path.addLine(to: along(index, stop)) }
                    .trim(from: 0, to: settled ? 1 : 0)
                    .stroke(lit ? Onb.leaf : Color.white.opacity(0.16),
                            style: StrokeStyle(lineWidth: lit ? 1.5 : 1, lineCap: .round, dash: lit ? [] : [2, 4]))
                    .animation(.easeOut(duration: Self.draw).delay(delay(index)), value: shown)
                if lit, !reduceMotion, !still {
                    FlowLight(from: along(index, stop), to: along(index, Self.inner), start: delay(index) + Self.draw)
                }
            }
            ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                let lit = name == "Obsidian" && obsidian
                VStack(spacing: 7) {
                    if let image = AppIcons.icon(name) {
                        Image(nsImage: image).resizable().interpolation(.high)
                            .frame(width: Self.icon, height: Self.icon)
                            .opacity(lit || !obsidian ? 1 : 0.55)
                            // Around the icon's drawing, which macOS insets by a tenth of its frame.
                            .overlay(
                                RoundedRectangle(cornerRadius: Self.icon * 0.82 * 0.225 + 4, style: .continuous)
                                    .strokeBorder(Onb.leaf, lineWidth: 2)
                                    .padding(Self.icon * 0.09 - 4)
                                    .opacity(lit ? 1 : 0)
                            )
                    }
                    Text(name)
                        .font(OnbType.text(11.5, lit ? .semibold : .medium))
                        .foregroundStyle(lit ? Onb.ink : Onb.soft)
                        .fixedSize()
                }
                .frame(width: 110)
                .position(x: point(index).x, y: point(index).y + 11)
                .opacity(settled ? 1 : 0)
                .scaleEffect(settled ? 1 : 0.86)
                .animation(Motion.Spring.smooth.animation.delay(delay(index) + Self.draw * 0.6), value: shown)
            }
            IntroAppIcon(image: IntroAssets.shared.appIcon.map(AppIcons.sRGB))
                .frame(width: 92, height: 92)
                .scaleEffect(settled ? 1 : 0.9)
                .opacity(settled ? 1 : 0)
                .animation(Motion.Spring.smooth.animation, value: shown)
                .position(Self.center)
        }
        .frame(width: IntroScene.cardSize.width, height: IntroScene.cardSize.height, alignment: .topLeading)
        .accessibilityHidden(true)
        .onAppear { shown = true }
    }

    /// Everything in place: at once with Reduce Motion or in a still picture.
    private var settled: Bool { shown || reduceMotion || still }
}

/// A soft light running along a link, from an app into Loam, every few seconds: the notes on their way.
private struct FlowLight: View {
    let from: CGPoint
    let to: CGPoint
    /// Seconds after it appears that the first run starts.
    let start: Double
    @State private var began = Date.now

    var body: some View {
        TimelineView(.animation) { context in
            let elapsed = context.date.timeIntervalSince(began) - start
            let period = 2.6, run = 1.3
            let t = elapsed < 0 ? -1 : elapsed.truncatingRemainder(dividingBy: period) / run
            if t >= 0, t <= 1 {
                // Eased along the link, fading in and out at its ends.
                let eased = t * t * (3 - 2 * t)
                let fade = min(t / 0.2, (1 - t) / 0.2, 1)
                Circle()
                    .fill(Onb.leaf)
                    .frame(width: 6, height: 6)
                    .shadow(color: Onb.leaf, radius: 6)
                    .opacity(fade)
                    .position(x: from.x + (to.x - from.x) * eased, y: from.y + (to.y - from.y) * eased)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: Plugins

private struct PresetChoice: View {
    @Bindable var setup: IntroSetup

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(IntroSetup.presets) { preset in
                OnbOption(title: preset.name, detail: preset.detail, selected: setup.preset == preset.id) {
                    setup.preset = preset.id
                }
            }
        }
    }
}

// MARK: Look

private struct LookChoice: View {
    @Bindable var setup: IntroSetup

    var body: some View {
        LazyVGrid(columns: [GridItem(.fixed(166), spacing: 8), GridItem(.fixed(166), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(IntroSetup.looks) { look in
                LookTile(look: look, selected: setup.look == look.id) { setup.look = look.id }
            }
        }
        .frame(width: OnbGrid.choiceWidth, alignment: .leading)
    }
}

/// A look: the corner of Loam wearing it (its sidebar and the top of a page), its name, a tick when chosen.
private struct LookTile: View {
    let look: IntroSetup.Look
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topLeading) {
                Onb.raised
                Group {
                    if let image = OnbShots.image("look-\(look.id)") {
                        // The window's top-left corner, at half its size.
                        Image(nsImage: image).resizable().interpolation(.high)
                            .frame(width: OnbGrid.window.width / 2, height: OnbGrid.window.height / 2)
                            .frame(width: 166, height: 54, alignment: .topLeading)
                    } else {
                        Onb.sand
                    }
                }
                .frame(width: 166, height: 54, alignment: .topLeading)
                .clipped()
                Text(look.name)
                    .font(OnbType.text(13, .semibold))
                    .foregroundStyle(Onb.ink)
                    .frame(height: 34)
                    .place(12, 54)
                Circle().fill(Onb.forest)
                    .overlay(TickGlyph().stroke(Onb.paper, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)))
                    .frame(width: 16, height: 16)
                    .scaleEffect(selected ? 1 : 0.4)
                    .opacity(selected ? 1 : 0)
                    .place(166 - 10 - 16, 88 - 9 - 16)
            }
            .frame(width: 166, height: 88, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: Onb.radiusCard, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Onb.radiusCard, style: .continuous)
                    .strokeBorder(selected ? Onb.forest : (hovered ? Onb.hoverLine : Onb.line), lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: Onb.radiusCard, style: .continuous))
        }
        .buttonStyle(.press)
        .onHover { hovered = $0 }
        .animation(Motion.hover, value: hovered)
        .animation(Motion.Spring.pop.animation, value: selected)
        .accessibilityLabel(Text(look.name))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A terminal window: a frame, a prompt and a line (24-unit grid).
private struct TerminalGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path(roundedRect: CGRect(origin: p(3.5, 5), size: CGSize(width: 17 * s, height: 14 * s)), cornerRadius: 3 * s)
        path.move(to: p(8, 10)); path.addLine(to: p(10.5, 12)); path.addLine(to: p(8, 14))
        path.move(to: p(13, 14)); path.addLine(to: p(16.5, 14))
        return path
    }
}

/// A page with a folded corner and two lines (24-unit grid).
private struct DocumentGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        path.move(to: p(13, 3.5))
        path.addLine(to: p(8, 3.5))
        path.addArc(tangent1End: p(5, 3.5), tangent2End: p(5, 6.5), radius: 3 * s)
        path.addLine(to: p(5, 17.5))
        path.addArc(tangent1End: p(5, 20.5), tangent2End: p(8, 20.5), radius: 3 * s)
        path.addLine(to: p(16, 20.5))
        path.addArc(tangent1End: p(19, 20.5), tangent2End: p(19, 17.5), radius: 3 * s)
        path.addLine(to: p(19, 9.5))
        path.closeSubpath()
        path.move(to: p(13, 3.5)); path.addLine(to: p(13, 7.5))
        path.addArc(tangent1End: p(13, 9.5), tangent2End: p(15, 9.5), radius: 2 * s)
        path.addLine(to: p(19, 9.5))
        path.move(to: p(9, 14.5)); path.addLine(to: p(15, 14.5))
        path.move(to: p(9, 17.5)); path.addLine(to: p(13, 17.5))
        return path
    }
}
