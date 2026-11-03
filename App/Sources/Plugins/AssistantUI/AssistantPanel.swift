import AssistantPlugin
import PluginKitUI
import SwiftUI
import ThinkingOrbsKit

/// The open panel: Craft's header (history, the chat's title, new chat and close), the conversation or the
/// suggestions, and the composer card.
struct AssistantPanel: View {
    @Bindable var model: AssistantModel
    @Environment(\.themeTokens) private var theme
    @Environment(\.craftColors) private var colors

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.chat.messages.isEmpty {
                Spacer(minLength: 0)
                // Craft leaves this room empty; Loam puts its orb at rest there.
                ThinkingOrb(state: .breathing, size: .px64)
                    // The print look draws the orb in the accent.
                    .environment(\.orbTint, theme.accent)
                    .opacity(0.8)
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
                Suggestions(model: model)
            } else {
                Conversation(model: model)
                    .environment(\.openURL, OpenURLAction { url in
                        guard url.scheme == "loam-note" else { return .systemAction }
                        model.openLink(url.absoluteString.dropFirst("loam-note:".count).removingPercentEncoding ?? "")
                        return .handled
                    })
            }
            if model.selection != nil, !model.isBusy {
                SelectionActions(model: model)
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
            if model.isBusy, model.approval == nil {
                ThinkingPill(state: MessageView.orbState(model.chat.messages.last))
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
            Composer(model: model)
                .padding(12)
        }
        .animation(CraftStyle.hover, value: model.isBusy)
        .foregroundStyle(colors.ink)
        .onExitCommand { model.menu != nil ? (model.menu = nil) : model.toggle() }
    }

    private var header: some View {
        ZStack {
            HStack(spacing: 0) {
                CraftIconButton(symbol: "line.3.horizontal", size: 28, corner: 8, symbolSize: 15,
                                label: "Conversation History") {
                    model.refreshHistory()
                    model.menu = model.menu == .history ? nil : .history
                }
                .menuAnchor(.history)
                Spacer()
                if !model.chat.messages.isEmpty {
                    CraftIconButton(symbol: "square.and.pencil", symbolSize: 15, label: "New Chat") {
                        model.startNewChat()
                    }
                }
                CraftIconButton(symbol: "xmark", symbolSize: 14, label: "Close") { model.toggle() }
            }
            TitleCapsule(title: model.chat.title)
                .frame(maxWidth: 260)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .frame(height: 48, alignment: .top)
    }
}

private struct TitleCapsule: View {
    let title: String
    @Environment(\.craftColors) private var colors

    var body: some View {
        Text(title)
            .font(CraftStyle.font(13, .semibold))
            .tracking(CraftStyle.tracking)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(ThemeCapsule().fill(colors.capsuleFill))
            .overlay(ThemeCapsule().strokeBorder(colors.capsuleStroke, lineWidth: 1))
            .contentTransition(.opacity)
            .animation(CraftStyle.hover, value: title)
    }
}

// MARK: Suggestions

/// The empty chat: saved prompts and Loam's own suggestions, three at first and "Show N More".
private struct Suggestions: View {
    @Bindable var model: AssistantModel
    @Environment(\.craftColors) private var colors

    struct Item: Identifiable {
        let id: String
        let symbol: String
        let title: String
        let prompt: String
    }

    static let builtIn: [Item] = [
        Item(id: "summarize", symbol: "doc.plaintext", title: "Summarize This Note",
             prompt: "Summarize the note I am looking at in a few bullet points."),
        Item(id: "related", symbol: "magnifyingglass", title: "Find Related Notes",
             prompt: "Find the notes related to the one I am looking at and link them with [[wikilinks]]."),
        Item(id: "overview", symbol: "binoculars", title: "Get an Overview",
             prompt: "Give me an overview of what is in my vault: its main folders, topics and recent work."),
        Item(id: "organize", symbol: "square.grid.2x2", title: "Organize by Topic",
             prompt: "Suggest how to organize my notes by topic. Do not move anything yet: show me the plan first."),
        Item(id: "today", symbol: "checklist", title: "Plan My Day",
             prompt: "Look at my open tasks and today's daily note, and write a short plan for today in it."),
    ]

    /// With a note in the context, what to do with it (Craft's document suggestions).
    static let forNote: [Item] = [
        Item(id: "summary", symbol: "list.bullet.rectangle", title: "Create a Summary",
             prompt: "Summarize this note in a few bullet points."),
        Item(id: "clarity", symbol: "lightbulb", title: "Improve Clarity",
             prompt: "Rewrite this note to be clearer and easier to read. Keep its meaning, structure and language."),
        Item(id: "spelling", symbol: "graduationcap", title: "Improve Spelling and Grammar",
             prompt: "Fix the spelling and grammar of this note in place. Change nothing else."),
        Item(id: "shorter", symbol: "arrow.down.right.and.arrow.up.left", title: "Make It Shorter",
             prompt: "Make this note shorter without losing anything important."),
        Item(id: "translate", symbol: "globe", title: "Translate to English",
             prompt: "Translate this note into English, in place."),
        Item(id: "tasks", symbol: "checklist", title: "Extract the Tasks",
             prompt: "List the tasks hidden in this note and add them at its end as `- [ ]` lines."),
        Item(id: "format", symbol: "textformat", title: "Format This Note",
             prompt: "Format this note: clear headings, lists and tables where they help. Keep every word."),
        Item(id: "continue", symbol: "pencil.line", title: "Continue Writing",
             prompt: "Continue writing this note in its own voice, a paragraph or two."),
        Item(id: "links", symbol: "link", title: "Suggest Links",
             prompt: "Find notes related to this one and add [[wikilinks]] to them where they fit."),
        Item(id: "related", symbol: "magnifyingglass", title: "Find Related Notes",
             prompt: "Find the notes related to this one and list them with [[wikilinks]]."),
    ]

    var items: [Item] {
        let saved = model.prompts.map {
            Item(id: "prompt-\($0.id)", symbol: "text.bubble", title: $0.label, prompt: $0.prompt)
        }
        let hasNote = model.context.contains { $0.lowercased().hasSuffix(".md") }
        return saved + (hasNote ? Self.forNote : Self.builtIn)
    }

    var body: some View {
        let all = items
        let shown = model.showsAllSuggestions ? all : Array(all.prefix(3))
        VStack(alignment: .leading, spacing: 0) {
            Text("Suggestions")
                .font(CraftStyle.font(13, .semibold))
                .tracking(CraftStyle.tracking)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            ForEach(shown) { item in
                SuggestionRow(symbol: item.symbol, title: item.title, opacity: 0.65) { model.send(item.prompt) }
            }
            if all.count > 3 {
                SuggestionRow(
                    symbol: model.showsAllSuggestions ? "chevron.up" : "chevron.down",
                    title: model.showsAllSuggestions ? "Show Less" : "Show \(all.count - 3) More",
                    opacity: 0.6, height: 32, symbolSize: 11
                ) {
                    withAnimation(CraftStyle.hover) { model.showsAllSuggestions.toggle() }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SuggestionRow: View {
    let symbol: String
    let title: String
    var opacity: Double = 0.65
    var height: CGFloat = 28
    var symbolSize: CGFloat = 13
    let action: () -> Void
    @Environment(\.craftColors) private var colors
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(symbol: symbol)
                    .font(.ui(size: symbolSize))
                    .frame(width: 20, height: 20)
                Text(title)
                    .font(CraftStyle.font(13))
                    .tracking(CraftStyle.tracking)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .opacity(hovered ? 1 : opacity)
            .padding(.horizontal, 8)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: Corners.r(10), style: .continuous).fill(hovered ? colors.hoverFill : .clear))
            .contentShape(RoundedRectangle(cornerRadius: Corners.r(10), style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(CraftStyle.hover) { hovered = hovering } }
    }
}

// MARK: Conversation

private struct Conversation: View {
    @Bindable var model: AssistantModel

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(model.chat.messages) { message in
                        MessageView(message: message, isLast: message.id == model.chat.messages.last?.id,
                                    isBusy: model.isBusy, model: model)
                            .id(message.id)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .offset(y: 10)),
                                removal: .opacity
                            ))
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.automatic)
            .onChange(of: model.chat.messages.last?.text) { reader.scrollTo("end", anchor: .bottom) }
            .onChange(of: model.chat.messages.count) {
                withAnimation(.easeOut(duration: 0.2)) { reader.scrollTo("end", anchor: .bottom) }
            }
            .onAppear { reader.scrollTo("end", anchor: .bottom) }
        }
    }
}

struct MessageView: View {
    let message: ChatMessage
    let isLast: Bool
    let isBusy: Bool
    let model: AssistantModel
    @Environment(\.craftColors) private var colors

    var body: some View {
        switch message.role {
        case .user:
            VStack(alignment: .trailing, spacing: 8) {
                ForEach(message.context, id: \.self) { path in
                    ContextChip(path: path, onRemove: nil)
                }
                if let selection = message.selection {
                    SelectionChip(selection: selection, onRemove: nil)
                }
                if let images = message.images {
                    HStack(spacing: 8) {
                        ForEach(images, id: \.self) { path in
                            Button { NSWorkspace.shared.open(model.imageURL(path)) } label: {
                                ImageChip(url: model.imageURL(path), size: images.count == 1 ? 120 : 72, onRemove: nil)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Text(message.text)
                    .font(.ui(size: 16))
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: Corners.r(16), style: .continuous).fill(colors.userBubble))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 40)
        case .assistant:
            VStack(alignment: .leading, spacing: 10) {
                ForEach(message.tools) { tool in
                    ToolRow(tool: tool) { if let path = tool.path { model.openNote(path) } }
                }
                if !message.text.isEmpty {
                    MarkdownText(text: message.text)
                    if !(isLast && isBusy) {
                        CopyButton(text: message.text)
                    }
                }
                if let error = message.error {
                    Text(error)
                        .font(CraftStyle.font(13))
                        .foregroundStyle(colors.danger)
                        .textSelection(.enabled)
                }
                if !message.changes.isEmpty {
                    ChangesRow(message: message) { model.undo(message.id) } open: { model.openNote($0) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension MessageView {
    /// What the agent is doing, as one of Libraries.dev's orbs: searching while it reads or looks, composing while it
    /// writes or answers, working while it runs a command, thinking otherwise.
    static func orbState(_ message: ChatMessage?) -> OrbState {
        guard let message, message.role == .assistant else { return .breathing }
        guard let running = message.tools.last(where: { $0.state == .running }) else {
            return message.text.isEmpty ? .breathing : .composing
        }
        if running.title.hasPrefix("Edited") { return .composing }
        if running.title.hasPrefix("Read") || running.title.hasPrefix("Searched") { return .searching }
        return .working
    }
}

/// Craft's "On it…" pill above the composer while the agent works, drawn as Libraries.dev's orb pill: the orb for
/// what it is doing and its word, shimmering.
private struct ThinkingPill: View {
    let state: OrbState
    @Environment(\.themeTokens) private var theme
    @Environment(\.craftColors) private var colors

    var body: some View {
        HStack(spacing: 6) {
            ThinkingOrb(state: state, size: .px20)
                    // The print look draws the orb in the accent.
                    .environment(\.orbTint, theme.accent)
            Text(state.label)
                .font(CraftStyle.font(13))
                .tracking(CraftStyle.tracking)
                .opacity(0.6)
                .shimmering(true)
                .contentTransition(.opacity)
        }
        .padding(.leading, 6)
        .padding(.trailing, 12)
        .frame(height: 30)
        .background(ThemeCapsule().fill(colors.capsuleFill))
        .overlay(ThemeCapsule().strokeBorder(colors.capsuleStroke, lineWidth: 1))
        .animation(CraftStyle.hover, value: state)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("assistant.thinking")
    }
}

/// Craft's copy button under an answer.
private struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        CraftIconButton(symbol: copied ? "checkmark" : "doc.on.doc", size: 24, corner: 6, symbolSize: 11,
                        label: "Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
        }
        .opacity(0.6)
        .padding(.leading, -4)
    }
}

/// A step of the turn, as Craft lists them: a small circle (turning while it runs, a check once done), the step in
/// 14-point text at 60 %, a shimmer while it runs.
private struct ToolRow: View {
    let tool: ToolCall
    let action: () -> Void
    @Environment(\.craftColors) private var colors

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Group {
                    switch tool.state {
                    case .running: Image(symbol: "circle.dotted").symbolEffect(.rotate, options: .repeating)
                    case .done: Image(symbol: "checkmark.circle")
                    case .failed: Image(symbol: "exclamationmark.circle").foregroundStyle(colors.danger)
                    }
                }
                .font(.ui(size: 13))
                .frame(width: 18, height: 18)
                Text(tool.state == .running ? Self.ongoing(tool.title) : tool.title)
                    .font(CraftStyle.font(14))
                    .tracking(CraftStyle.tracking)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .shimmering(tool.state == .running)
            }
            .opacity(0.6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(tool.path == nil)
        .transition(.opacity.combined(with: .offset(y: 4)))
    }

    /// A step still running, in Craft's present tense: "Editing Plan.md", "Running ls".
    static func ongoing(_ title: String) -> String {
        for (done, now) in [("Edited ", "Editing "), ("Read ", "Reading "), ("Ran ", "Running "),
                            ("Searched ", "Searching ")] where title.hasPrefix(done) {
            return now + title.dropFirst(done.count)
        }
        return title
    }
}

/// What a turn changed, with its undo.
private struct ChangesRow: View {
    let message: ChatMessage
    let undo: () -> Void
    let open: (String) -> Void
    @Environment(\.craftColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(message.changes.count == 1 ? "1 note changed" : "\(message.changes.count) notes changed")
                    .font(CraftStyle.font(13, .semibold))
                    .tracking(CraftStyle.tracking)
                Spacer()
                if message.undone {
                    Text("Undone").font(CraftStyle.font(13)).opacity(0.6)
                } else {
                    CraftPillButton(action: undo) {
                        HStack(spacing: 4) {
                            Image(symbol: "arrow.uturn.backward")
                            Text("Undo")
                        }
                    }
                }
            }
            ForEach(message.changes, id: \.path) { change in
                Button { if change.kind != .deleted { open(change.path) } } label: {
                    HStack(spacing: 6) {
                        Image(symbol: change.kind == .added ? "doc.badge.plus" : change.kind == .deleted ? "trash"
                                : "doc.text")
                        Text(change.path).lineLimit(1).truncationMode(.middle)
                    }
                    .font(CraftStyle.font(12))
                    .opacity(0.65)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Corners.r(12), style: .continuous).fill(colors.chip))
    }
}

// MARK: Context chip

/// A note given as context: Craft's chip, a page tile, the name over its folder.
struct ContextChip: View {
    let path: String
    let onRemove: (() -> Void)?
    @Environment(\.craftColors) private var colors
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(symbol: path.hasSuffix("/") || !path.contains(".") ? "folder" : "doc.text")
                .font(.ui(size: 13))
                .frame(width: 30, height: 36)
                .opacity(0.6)
                .background(RoundedRectangle(cornerRadius: Corners.r(6), style: .continuous).fill(colors.chipTile)
                    .shadow(color: .black.opacity(0.075), radius: 1, y: 1))
                .compositingGroup()
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(CraftStyle.font(13, .semibold))
                    .tracking(CraftStyle.tracking)
                Text(folder)
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
                .accessibilityLabel("Remove")
            }
        }
        .onHover { hovering in withAnimation(CraftStyle.hover) { hovered = hovering } }
    }

    private var name: String {
        let last = (path as NSString).lastPathComponent
        return last.hasSuffix(".md") ? String(last.dropLast(3)) : last
    }

    private var folder: String {
        let folder = (path as NSString).deletingLastPathComponent
        return folder.isEmpty ? "Note" : folder
    }
}
