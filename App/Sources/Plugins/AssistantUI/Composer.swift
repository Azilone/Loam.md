import AppKit
import AssistantPlugin
import BorderBeamKit
import PluginKitUI
import SwiftUI

/// Craft's composer card: the context chips, the message field, then "+", the agent, the mode and send. An agent's
/// question (Ask mode) takes the card's top.
struct Composer: View {
    @Bindable var model: AssistantModel
    @Environment(\.craftColors) private var colors
    @FocusState private var focused: Bool
    @State private var pasteMonitor: Any?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let approval = model.approval {
                ApprovalCard(approval: approval) { model.answer($0) }
            }
            if let blocker = agentBlocker {
                Text(blocker)
                    .font(CraftStyle.font(12))
                    .opacity(0.65)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !model.context.isEmpty || model.selection != nil || !model.images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.images, id: \.self) { path in
                            ImageChip(url: model.imageURL(path)) { model.removeImage(path) }
                                .transition(.scale(scale: 0.9).combined(with: .opacity))
                        }
                        ForEach(model.context, id: \.self) { path in
                            ContextChip(path: path) { model.removeContext(path) }
                        }
                        if let selection = model.selection {
                            SelectionChip(selection: selection) {
                                withAnimation(CraftStyle.hover) { model.selection = nil }
                            }
                            .transition(.scale(scale: 0.9).combined(with: .opacity))
                        }
                    }
                    .padding(.top, 6)
                    .padding(.trailing, 6)
                }
            }
            TextField("", text: $model.draft,
                      prompt: Text("Message Loam Assistant").foregroundStyle(colors.ink.opacity(0.4)),
                      axis: .vertical)
                .textFieldStyle(.plain)
                .font(CraftStyle.font(14))
                .tracking(-0.09)
                .lineLimit(1...8)
                .focused($focused)
                .onSubmit {
                    if model.menu == .slash || model.menu == .mention {
                        model.chooseHighlighted()
                        focused = true
                    } else {
                        model.send()
                    }
                }
                .onChange(of: model.draft) { model.draftChanged() }
                .onKeyPress(.downArrow) { inlineKey { model.moveHighlight(1) } }
                .onKeyPress(.upArrow) { inlineKey { model.moveHighlight(-1) } }
                .onKeyPress(.tab) { inlineKey { model.chooseHighlighted() } }
                .onKeyPress(.escape) { inlineKey { model.menu = nil } }
                .padding(.horizontal, 4)
                .menuAnchor(.slash)
                .menuAnchor(.mention)
                .accessibilityIdentifier("assistant.field")
            HStack(spacing: 8) {
                CraftPillButton(round: true, action: { toggle(.context) }) {
                    Image(symbol: "plus").font(.ui(size: 14))
                }
                .menuAnchor(.context)
                .help("Add Additional Context")
                .opacity(model.isBusy ? 0.5 : 1)
                CraftPillButton(action: { toggle(.agent) }) {
                    HStack(spacing: 6) {
                        AgentIcon(kind: model.chat.agent)
                        Text(agentLabel).lineLimit(1)
                        Image(symbol: "chevron.down").font(.ui(size: 9, weight: .semibold)).opacity(0.5)
                    }
                }
                .menuAnchor(.agent)
                .opacity(model.isBusy ? 0.5 : 1)
                CraftPillButton(action: { toggle(.mode) }) {
                    HStack(spacing: 6) {
                        Image(symbol: ModeIcon.symbol(model.chat.mode)).font(.ui(size: 13))
                        Text(model.chat.mode.title)
                        Image(symbol: "chevron.down").font(.ui(size: 9, weight: .semibold)).opacity(0.5)
                    }
                }
                .menuAnchor(.mode)
                // Craft greys the controls out while the agent works.
                .opacity(model.isBusy ? 0.5 : 1)
                Spacer(minLength: 0)
                sendButton
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Corners.r(12), style: .continuous).fill(colors.panel))
        .overlay(RoundedRectangle(cornerRadius: Corners.r(12), style: .continuous).strokeBorder(colors.ink.opacity(0.08), lineWidth: 1))
        // Libraries.dev's beam runs round the card while the agent works, in the send button's blue.
        .borderBeam(.md, colorVariant: .ocean, theme: .auto, active: model.isBusy && !reduceMotion, borderRadius: 12)
        .shadow(color: .black.opacity(colors.dark ? 0.3 : 0.06), radius: 20, y: 16)
        .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
            for provider in providers {
                if provider.canLoadObject(ofClass: URL.self) {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url, AssistantModel.imageExtensions.contains(url.pathExtension.lowercased()) else { return }
                        Task { @MainActor in model.attachImage(at: url) }
                    }
                }
            }
            return true
        }
        .onAppear {
            focused = true
            // ⌘V with an image on the pasteboard: a thumbnail, not the file's path in the field.
            pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard focused, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                      event.charactersIgnoringModifiers == "v", model.attachImages(from: .general) else { return event }
                return nil
            }
        }
        .onDisappear {
            if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }
            pasteMonitor = nil
        }
        .onChange(of: model.isOpen) { if model.isOpen { focused = true } }
    }

    /// Keys for the `/` and `@` menus while one is open; the field keeps them otherwise.
    private func inlineKey(_ action: () -> Void) -> KeyPress.Result {
        guard model.menu == .slash || model.menu == .mention else { return .ignored }
        action()
        return .handled
    }

    private func toggle(_ menu: AssistantModel.Menu) {
        if menu == .agent { model.refreshAgents() }
        model.menu = model.menu == menu ? nil : menu
    }

    /// The model when one is picked, else the agent: "Haiku", "GPT-6-Luna", "Claude Code".
    private var agentLabel: String {
        let chosen = model.chat.model
        guard !chosen.isEmpty else { return model.chat.agent.name }
        let known = (model.status(model.chat.agent)?.models ?? []) + model.chat.agent.models
        let name = known.first { $0.id == chosen }?.name ?? chosen
        // "deepseek/deepseek-v4.1-flash" from OpenRouter: the model, without its maker.
        return name.split(separator: "/").last.map(String.init) ?? name
    }

    /// Why sending would fail, before trying: the agent is missing or signed out.
    private var agentBlocker: String? {
        guard let status = model.status(model.chat.agent) else { return nil }
        switch status.state {
        case .missing: return "\(status.kind.name) is not installed. In a terminal: \(status.kind.installHint)"
        case .signedOut: return "\(status.kind.name) is signed out. In a terminal: \(status.kind.loginCommand)"
        case .ready: return nil
        }
    }

    @ViewBuilder private var sendButton: some View {
        if model.isBusy {
            Button { model.stop() } label: {
                Image(symbol: "stop.circle.fill")
                    .font(.ui(size: 24))
                    .foregroundStyle(colors.ink)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .help("Stop")
            .transition(.opacity.combined(with: .scale(scale: 0.8)))
        } else {
            Button { model.send() } label: {
                Image(symbol: "arrow.up")
                    .font(.ui(size: 13, weight: .bold))
                    .foregroundStyle(colors.sendInk)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(colors.send))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .opacity(model.canSend ? 1 : 0)
            .scaleEffect(model.canSend ? 1 : 0.8)
            .animation(CraftStyle.hover, value: model.canSend)
            .disabled(!model.canSend)
            .help("Send")
            .accessibilityIdentifier("assistant.send")
        }
    }
}

/// A pasted or dropped image, as Craft shows it above the field: the picture itself, rounded, with a remove button.
struct ImageChip: View {
    let url: URL
    var size: CGFloat = 52
    let onRemove: (() -> Void)?
    @Environment(\.craftColors) private var colors
    @State private var hovered = false

    var body: some View {
        Group {
            if let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                Image(symbol: "photo").font(.ui(size: 16)).opacity(0.5)
            }
        }
        .frame(width: size, height: size)
        .background(colors.chip)
        .clipShape(RoundedRectangle(cornerRadius: Corners.r(12), style: .continuous))
        .craftInsetRing(RoundedRectangle(cornerRadius: Corners.r(12), style: .continuous), colors.ink.opacity(0.08))
        .overlay(alignment: .topTrailing) {
            if let onRemove {
                Button(action: onRemove) {
                    Image(symbol: "xmark")
                        .font(.ui(size: 8, weight: .bold))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(colors.chipRemove))
                        .craftInsetRing(Circle(), colors.ink.opacity(0.1))
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
                .opacity(hovered ? 1 : 0)
                .accessibilityLabel("Remove the image")
            }
        }
        .onHover { hovering in withAnimation(CraftStyle.hover) { hovered = hovering } }
        .help(url.lastPathComponent)
        .accessibilityIdentifier("assistant.image")
    }
}

/// The "Selected Text" chip: a text-cursor tile, the passage's start and end, and what it is.
struct SelectionChip: View {
    let selection: NoteSelection
    let onRemove: (() -> Void)?
    @Environment(\.craftColors) private var colors
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(symbol: "character.cursor.ibeam")
                .font(.ui(size: 13))
                .frame(width: 30, height: 36)
                .opacity(0.7)
                .background(RoundedRectangle(cornerRadius: Corners.r(6), style: .continuous).fill(colors.chipTile)
                    .shadow(color: .black.opacity(0.075), radius: 1, y: 1))
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.excerpt(selection.text))
                    .font(CraftStyle.font(13, .semibold))
                    .tracking(CraftStyle.tracking)
                Text("Selected Text")
                    .font(CraftStyle.font(12))
                    .opacity(0.6)
            }
            .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: 220, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Corners.r(16), style: .continuous).fill(colors.chip))
        .craftInsetRing(RoundedRectangle(cornerRadius: Corners.r(16), style: .continuous), colors.ink.opacity(0.05))
        .overlay(alignment: .topTrailing) {
            if let onRemove {
                Button(action: onRemove) {
                    Image(symbol: "xmark")
                        .font(.ui(size: 8, weight: .bold))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(colors.chipRemove))
                        .craftInsetRing(Circle(), colors.ink.opacity(0.1))
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
                .opacity(hovered ? 1 : 0)
                .accessibilityLabel("Remove the selected text")
            }
        }
        .onHover { hovering in withAnimation(CraftStyle.hover) { hovered = hovering } }
        .help(selection.text)
    }

    /// "The video…their own": the first and last words of a long passage.
    static func excerpt(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .replacing(/\*\*|__|~~|`|\[\[|\]\]|^#+\s|^[-*]\s/, with: "")
            .trimmingCharacters(in: .whitespaces)
        guard flat.count > 26 else { return flat }
        return flat.prefix(12).trimmingCharacters(in: .whitespaces) + "…" + flat.suffix(10).trimmingCharacters(in: .whitespaces)
    }
}

/// The actions on a selection, above the composer: Explain, Analyze, Summarize.
struct SelectionActions: View {
    let model: AssistantModel
    @Environment(\.craftColors) private var colors

    static let actions: [(symbol: String, title: String, prompt: String)] = [
        ("lightbulb", "Explain", "Explain this passage simply."),
        ("magnifyingglass", "Analyze", "Analyze this passage: what it says, what it assumes, what is missing."),
        ("text.alignleft", "Summarize", "Summarize this passage in a few bullet points."),
        ("character.bubble", "Translate", "Translate this passage into English."),
    ]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Self.actions, id: \.title) { action in
                ActionPill(symbol: action.symbol, title: action.title) { model.send(action.prompt) }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct ActionPill: View {
    let symbol: String
    let title: String
    let action: () -> Void
    @Environment(\.craftColors) private var colors
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(symbol: symbol).font(.ui(size: 12))
                Text(title).font(CraftStyle.font(13)).tracking(CraftStyle.tracking)
            }
            .opacity(hovered ? 1 : 0.7)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(ThemeCapsule().fill(hovered ? colors.hoverFill : colors.chip))
            .contentShape(ThemeCapsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(CraftStyle.hover) { hovered = hovering } }
    }
}

/// The agent's question before it acts.
private struct ApprovalCard: View {
    let approval: AgentApproval
    let answer: (AgentApproval.Option) -> Void
    @Environment(\.craftColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(approval.title)
                .font(CraftStyle.font(13, .semibold))
                .tracking(CraftStyle.tracking)
            if !approval.detail.isEmpty {
                Text(approval.detail)
                    .font(.system(size: 12, design: .monospaced))
                    .opacity(0.65)
                    .lineLimit(4)
            }
            HStack(spacing: 8) {
                ForEach(approval.options, id: \.id) { option in
                    CraftPillButton(action: { answer(option) }) { Text(option.label) }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Corners.r(10), style: .continuous).fill(colors.chip))
    }
}

/// The agent's own mark (Lobe Icons' SVGs in `Resources/Logos`): in colour where the brand has one, in the ink
/// otherwise (OpenCode, Pi).
/// A model provider's logo, or a plain mark when it has none.
struct ProviderIcon: View {
    let provider: String

    var body: some View {
        if let name = AgentLogos.provider(provider), let image = AgentLogos.image(named: name) {
            Image(nsImage: image)
                .renderingMode(AgentLogos.monochrome.contains(name) ? .template : .original)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(symbol: "cube").font(.ui(size: 11))
        }
    }
}

struct AgentIcon: View {
    let kind: AgentKind
    var size: CGFloat = 16

    var body: some View {
        if let image = AgentLogos.image(kind) {
            let mark = Image(nsImage: image)
                .renderingMode(AgentLogos.isMonochrome(kind) ? .template : .original)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
            if kind == .antigravity {
                // Google's sparkle, in its blue-to-violet.
                LinearGradient(colors: [Color(red: 0.26, green: 0.52, blue: 0.96), Color(red: 0.61, green: 0.45, blue: 0.80)],
                               startPoint: .bottomLeading, endPoint: .topTrailing)
                    .frame(width: size, height: size)
                    .mask(mark)
            } else {
                mark
            }
        } else {
            Image(symbol: "sparkle").font(.ui(size: size * 0.85))
        }
    }
}

enum AgentLogos {
    /// Marks drawn in the ink: OpenAI's (Codex), OpenCode's, Pi's, OpenRouter's, Anthropic's.
    static let monochrome: Set<String> = ["codex", "opencode", "pi", "openrouter", "anthropic", "antigravity"]

    static func isMonochrome(_ kind: AgentKind) -> Bool {
        monochrome.contains(kind.rawValue)
    }

    @MainActor static func image(_ kind: AgentKind) -> NSImage? {
        image(named: kind.rawValue)
    }

    @MainActor static func image(named name: String) -> NSImage? {
        if let cached = cache[name] { return cached }
        guard let url = bundle?.url(forResource: name, withExtension: "svg", subdirectory: "Logos"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 24, height: 24)
        image.isTemplate = monochrome.contains(name)
        cache[name] = image
        return image
    }

    /// The logo of a model provider in Pi's or OpenCode's list.
    static func provider(_ provider: String) -> String? {
        let name = provider.lowercased()
        if name.contains("openrouter") { return "openrouter" }
        if name.contains("anthropic") || name.contains("claude") { return "claude" }
        if name.contains("openai") || name.contains("codex") { return "codex" }
        if name.contains("google") || name.contains("gemini") || name.contains("vertex") { return "google" }
        if name.contains("opencode") { return "opencode" }
        return nil
    }

    @MainActor private static var cache: [String: NSImage] = [:]

    /// This module's resources, where SwiftPM's `Bundle.module` looks (the app's resources, next to the library, the
    /// build folder), without its `fatalError` when they are missing.
    static let bundle: Bundle? = {
        let name = "LoamApp_AssistantUI.bundle"
        let library = Bundle(for: AssistantModel.self)
        let places = [Bundle.main.resourceURL, library.resourceURL, Bundle.main.bundleURL,
                      library.bundleURL.deletingLastPathComponent()]
        for case let place? in places {
            if let bundle = Bundle(url: place.appendingPathComponent(name)) { return bundle }
        }
        return nil
    }()
}

enum ModeIcon {
    static func symbol(_ mode: AgentMode) -> String {
        switch mode {
        case .auto: "asterisk"
        case .ask: "checkmark.shield"
        case .readOnly: "book"
        }
    }
}
