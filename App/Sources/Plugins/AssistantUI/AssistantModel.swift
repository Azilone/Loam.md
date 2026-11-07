import AppKit
import AssistantPlugin
import Foundation
import Observation
import PluginKit
import PluginKitUI
import SwiftUI

/// What the bubble and the panel show: open or not, the chat on screen, the draft, the context and the menus. It
/// mirrors the `assistant` engine, which tells it each time a chat changes.
@MainActor
@Observable
final class AssistantModel {
    enum Menu: Equatable {
        case history, agent, mode, context
        /// Typed in the field: `/` for saved prompts, `@` for notes and folders, as in Craft.
        case slash, mention
    }

    /// A `/` or `@` being typed at the end of the draft, and what follows it.
    struct Trigger: Equatable {
        let symbol: Character
        let query: String
        /// Where the trigger starts in the draft.
        let start: String.Index
    }

    /// A row of the `/` or `@` menu.
    struct InlineItem: Identifiable, Equatable {
        enum Action: Equatable {
            case prompt(String), createPrompt, note(String), folder(String), thisNote, allNotes
        }
        let id: String
        let symbol: String
        let title: String
        var subtitle: String?
        var section: String?
        let action: Action
    }

    let engine: AssistantEngine
    var isOpen = false
    /// The chat on screen; a new, empty one until the first prompt.
    private(set) var chat: Chat
    private(set) var isBusy = false
    private(set) var approval: AgentApproval?
    var draft = ""
    var menu: Menu?
    var showsAllSuggestions = false
    /// The highlighted row of the `/` or `@` menu.
    var highlighted = 0
    /// The note the user is looking at, offered as context (Craft's chip above the field).
    private(set) var activeNote: String?
    /// The user removed the chip of the active note.
    var dismissedActiveNote = false
    /// Notes and folders added with "+".
    var extraContext: [String] = []
    /// The passage last selected in a note, sent with the next prompt.
    var selection: NoteSelection?
    /// Images pasted or dropped for the next prompt: vault paths the engine keeps (`AssistantEngine.attach`).
    private(set) var images: [String] = []
    private(set) var history: [Chat] = []
    private(set) var statuses: [AgentStatus] = []
    private(set) var prompts: [SavedPrompt] = []

    var defaultAgent: () -> (AgentKind, String, AgentMode) = { (.claude, "", .auto) }

    /// The agent new chats start with (the setting's, or the one picked with `auto`).
    func defaultAgentKind() -> AgentKind { defaultAgent().0 }
    var openNote: (String) -> Void = { _ in }
    var openSettings: () -> Void = {}
    var listFolders: () -> [String] = { [] }
    var listNotes: () -> [String] = { [] }
    /// Shows the saved prompts in the quick pick and sends the one chosen.
    var pickPrompt: () -> String = { "none" }

    @ObservationIgnored private var stopObserving: (@Sendable () -> Void)?

    init(engine: AssistantEngine) {
        self.engine = engine
        chat = Chat(agent: .claude)
        stopObserving = engine.observe { [weak self] id in
            Task { @MainActor in self?.engineChanged(id) }
        }
    }

    func close() {
        stopObserving?()
    }

    /// The panel opened: a fresh look at the agents and prompts, a new chat when none is on screen.
    func open() {
        if chat.messages.isEmpty { startNewChat() }
        isOpen = true
        refreshPrompts()
        refreshAgents()
    }

    func toggle() {
        if isOpen {
            isOpen = false
            menu = nil
        } else {
            open()
        }
    }

    func startNewChat() {
        let (agent, model, mode) = defaultAgent()
        let carried = chat.messages.isEmpty ? chat : nil
        chat = engine.newChat(agent: carried?.agent ?? agent, model: carried?.model ?? model,
                              mode: carried?.mode ?? mode)
        draft = ""
        extraContext = []
        dismissedActiveNote = false
        showsAllSuggestions = false
        sync()
    }

    func show(_ id: String) {
        guard let found = engine.chat(id) else { return }
        chat = found
        menu = nil
        sync()
    }

    func delete(_ id: String) {
        engine.delete(id)
        if id == chat.id { startNewChat() }
        history = engine.allChats().filter { !$0.messages.isEmpty }
    }

    // MARK: Composer

    /// The notes sent with the next prompt.
    var context: [String] {
        var notes: [String] = []
        if let activeNote, !dismissedActiveNote { notes.append(activeNote) }
        for path in extraContext where !notes.contains(path) { notes.append(path) }
        return notes
    }

    var canSend: Bool { (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty) && !isBusy }

    func send() {
        send(draft)
    }

    func send(_ text: String) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty || !images.isEmpty, !isBusy else { return }
        let context = context
        let selection = selection
        let images = images
        draft = ""
        extraContext = []
        self.selection = nil
        self.images = []
        let engine = engine
        let id = chat.id
        Task { await engine.send(id, prompt: prompt, context: context, selection: selection, images: images) }
    }

    // MARK: Images

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "bmp"]

    /// Takes the images on `pasteboard` (files, or a picture copied from a screenshot or a page), as Craft does with
    /// a paste. False when there is none: the field pastes the text.
    func attachImages(from pasteboard: NSPasteboard) -> Bool {
        let files = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter { Self.imageExtensions.contains($0.pathExtension.lowercased()) }
        if !files.isEmpty {
            files.forEach { attachImage(at: $0) }
            return true
        }
        guard let image = NSImage(pasteboard: pasteboard), let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return false }
        keep(png, extension: "png")
        return true
    }

    func attachImage(at url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        keep(data, extension: url.pathExtension)
    }

    func removeImage(_ path: String) {
        withAnimation(CraftStyle.hover) { images.removeAll { $0 == path } }
    }

    func imageURL(_ path: String) -> URL { engine.vault.appendingPathComponent(path) }

    private func keep(_ data: Data, extension ext: String) {
        guard let path = try? engine.attach(image: data, extension: ext) else { return }
        withAnimation(CraftStyle.hover) { images.append(path) }
    }

    /// A file dropped on the field, or a path pasted as text, arrives as its path: an image's becomes a thumbnail.
    private func takeImagePaths() {
        let pattern = /(?i)(?:^|\s)(\/[^\n]*?\.(?:png|jpe?g|gif|webp|heic|tiff?|bmp))(?=\s|$)/
        var text = draft
        var found = false
        for match in draft.matches(of: pattern).reversed() {
            let path = String(match.output.1)
            guard FileManager.default.fileExists(atPath: path) else { continue }
            attachImage(at: URL(fileURLWithPath: path))
            text.removeSubrange(match.range)
            found = true
        }
        if found { draft = text.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func stop() {
        let engine = engine
        let id = chat.id
        Task { await engine.cancel(id) }
    }

    func answer(_ option: AgentApproval.Option) {
        let engine = engine
        let id = chat.id
        Task { await engine.answer(id, option: option) }
    }

    /// Opens the note a `[[link]]` names: a path, or a note's name anywhere in the vault.
    func openLink(_ target: String) {
        let name = target.hasSuffix(".md") ? String(target.dropLast(3)) : target
        let notes = listNotes()
        if let exact = notes.first(where: { $0 == name + ".md" }) ?? notes.first(where: {
            (($0 as NSString).lastPathComponent as NSString).deletingPathExtension.caseInsensitiveCompare(
                (name as NSString).lastPathComponent) == .orderedSame
        }) {
            openNote(exact)
        }
    }

    func undo(_ messageID: String) {
        try? engine.undo(chat.id, messageID: messageID)
    }

    func choose(agent: AgentKind, model: String = "") {
        menu = nil
        engine.configure(chat.id, agent: agent, model: model)
        sync()
    }

    func choose(mode: AgentMode) {
        menu = nil
        engine.configure(chat.id, mode: mode)
        sync()
    }

    /// A new passage selected in a note replaces the last one; collapsing the selection in the note drops it.
    /// Clicking into the panel leaves the note's selection as it is, so it survives that.
    func selectionChanged(path: String, text: String) {
        let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard !empty || selection != nil else { return }
        withAnimation(CraftStyle.hover) { selection = empty ? nil : NoteSelection(path: path, text: text) }
    }

    func setActiveNote(_ path: String?) {
        guard path != activeNote else { return }
        activeNote = path
        dismissedActiveNote = false
    }

    func addContext(_ path: String) {
        menu = nil
        if !extraContext.contains(path) { extraContext.append(path) }
    }

    func removeContext(_ path: String) {
        if path == activeNote {
            dismissedActiveNote = true
        } else {
            extraContext.removeAll { $0 == path }
        }
    }

    // MARK: `/` and `@`

    /// The `/` (at the start of the field) or `@` (after a space) the draft ends with, if any.
    var trigger: Trigger? {
        guard let index = draft.lastIndex(where: { $0 == "@" || $0 == "/" }) else { return nil }
        let symbol = draft[index]
        let query = String(draft[draft.index(after: index)...])
        guard !query.contains("\n"), query.count <= 40 else { return nil }
        let before = draft[..<index]
        if symbol == "/" {
            guard before.trimmingCharacters(in: .whitespaces).isEmpty, !query.contains(" ") else { return nil }
        } else {
            guard before.isEmpty || before.last?.isWhitespace == true else { return nil }
            guard query.split(separator: " ").count <= 3 else { return nil }
        }
        return Trigger(symbol: symbol, query: query, start: index)
    }

    /// Opens or closes the `/` and `@` menus as the draft changes.
    func draftChanged() {
        takeImagePaths()
        if let trigger {
            let wanted: Menu = trigger.symbol == "/" ? .slash : .mention
            if menu != wanted {
                if trigger.symbol == "/" { refreshPrompts() }
                menu = wanted
            }
            highlighted = min(highlighted, max(0, inlineItems.count - 1))
        } else if menu == .slash || menu == .mention {
            menu = nil
            highlighted = 0
        }
    }

    var inlineItems: [InlineItem] {
        guard let trigger else { return [] }
        let query = trigger.query.trimmingCharacters(in: .whitespaces)
        if trigger.symbol == "/" {
            let prompts = Fuzzy.rank(prompts, query: query) { $0.label }.map {
                InlineItem(id: "prompt-\($0.id)", symbol: "text.bubble", title: $0.label, subtitle: nil,
                           section: "Saved Prompts", action: .prompt($0.prompt))
            }
            return prompts + [InlineItem(id: "create", symbol: "plus", title: "Create Custom Prompt", action: .createPrompt)]
        }
        let folders = listFolders()
        if query.isEmpty {
            var items: [InlineItem] = []
            if activeNote != nil {
                items.append(InlineItem(id: "this", symbol: "doc.text", title: "This Note", section: "Focus on…",
                                        action: .thisNote))
            }
            items.append(InlineItem(id: "all", symbol: "doc.on.doc", title: "All Notes", section: "Focus on…",
                                    action: .allNotes))
            items += folders.prefix(6).map {
                InlineItem(id: "folder-\($0)", symbol: "folder", title: $0, section: "Folders", action: .folder($0))
            }
            return items
        }
        let notes = Fuzzy.rank(listNotes(), query: query) { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
            .prefix(8).map { path -> InlineItem in
                let folder = (path as NSString).deletingLastPathComponent
                return InlineItem(id: "note-\(path)", symbol: "doc.text",
                                  title: ((path as NSString).lastPathComponent as NSString).deletingPathExtension,
                                  subtitle: folder.isEmpty ? nil : folder, section: "Notes", action: .note(path))
            }
        let matchingFolders = Fuzzy.rank(folders, query: query) { $0 }.prefix(3).map {
            InlineItem(id: "folder-\($0)", symbol: "folder", title: $0, section: "Folders", action: .folder($0))
        }
        return Array(notes) + Array(matchingFolders)
    }

    func moveHighlight(_ step: Int) {
        let count = inlineItems.count
        guard count > 0 else { return }
        highlighted = (highlighted + step + count) % count
    }

    func chooseHighlighted() {
        let items = inlineItems
        guard items.indices.contains(highlighted) else { return }
        choose(items[highlighted])
    }

    /// What a row of the `/` or `@` menu does: a prompt fills the field, a note or folder becomes a chip and its
    /// name stays in the text, as Craft's mentions.
    func choose(_ item: InlineItem) {
        guard let trigger else { return }
        let head = String(draft[..<trigger.start])
        menu = nil
        highlighted = 0
        switch item.action {
        case .prompt(let prompt):
            draft = prompt
        case .createPrompt:
            draft = head
            openSettings()
        case .note(let path):
            draft = head + item.title + " "
            addContext(path)
        case .folder(let folder):
            draft = head + folder + " "
            addContext(folder + "/")
        case .thisNote:
            draft = head
            dismissedActiveNote = false
        case .allNotes:
            draft = head
            dismissedActiveNote = true
            extraContext = []
        }
    }

    // MARK: Agents and prompts

    func status(_ kind: AgentKind) -> AgentStatus? {
        statuses.first { $0.kind == kind }
    }

    func refreshAgents() {
        let catalog = engine.catalog
        if let cached = catalog.statuses {
            statuses = cached
            fallBackToAReadyAgent()
        }
        Task.detached {
            let fresh = catalog.refresh()
            await MainActor.run { [weak self] in
                self?.statuses = fresh
                self?.fallBackToAReadyAgent()
            }
        }
    }

    /// An empty chat whose agent cannot run (missing, signed out) moves to the one the user pays for, else the
    /// first that can.
    func fallBackToAReadyAgent() {
        guard chat.messages.isEmpty, let current = status(chat.agent), current.state != .ready,
              let ready = AgentCatalog.preferred(statuses) ?? statuses.first(where: { $0.state == .ready })?.kind else { return }
        engine.configure(chat.id, agent: ready)
        sync()
    }

    func refreshPrompts() {
        prompts = engine.prompts.all()
    }

    func refreshHistory() {
        history = engine.allChats().filter { !$0.messages.isEmpty }
    }

    // MARK: Engine

    private func engineChanged(_ id: String) {
        if id == chat.id { sync() }
        if menu == .history { refreshHistory() }
    }

    private func sync() {
        if let fresh = engine.chat(chat.id) {
            if fresh.messages.count != chat.messages.count {
                // A new message rises into place, as in Craft.
                Motion.with(Motion.Spring.standard.animation) {
                    chat = fresh
                }
            } else {
                chat = fresh
            }
        }
        isBusy = engine.isBusy(chat.id)
        approval = engine.approval(chat.id)
    }
}
