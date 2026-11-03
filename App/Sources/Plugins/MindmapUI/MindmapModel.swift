import AppKit
import Foundation
import Observation
import PluginKitUI
import SwiftUI

/// The plugin's shared state: the vault, the editor and the workspace, and the open mindmap tabs it refreshes.
@MainActor
final class MindmapStore {
    let vault: VaultAccess
    let editor: @MainActor () -> (any EditorService)?
    let workspace: @MainActor () -> (any Workspace)?
    /// The folders plugins own, so a new map never lands in one (set by the plugin).
    var managedFolders: @MainActor () -> ManagedFolders = { ManagedFolders() }
    /// New maps the user may leave untouched; set by the plugin.
    var drafts: UntouchedDrafts?
    private var tabs: [WeakTab] = []

    init(
        vault: VaultAccess,
        editor: @escaping @MainActor () -> (any EditorService)?,
        workspace: @escaping @MainActor () -> (any Workspace)?
    ) {
        self.vault = vault
        self.editor = editor
        self.workspace = workspace
    }

    /// The model of a tab: the same one each time SwiftUI rebuilds the tab's view.
    func makeTab(_ view: ViewContext) -> MindmapTabModel {
        if let existing = live.first(where: { $0.context === view }) { return existing }
        let tab = MindmapTabModel(store: self, view: view)
        tabs.removeAll { $0.tab == nil }
        tabs.append(WeakTab(tab: tab))
        return tab
    }

    /// The live text of a note: the editor's while it has the note open (unsaved typing included), else the file.
    func text(of path: String) -> String? {
        editor()?.text(of: path) ?? (try? vault.read(path))
    }

    private var live: [MindmapTabModel] {
        tabs.removeAll { $0.tab == nil }
        return tabs.compactMap(\.tab)
    }

    /// The map whose key view has the keyboard: the one the map's shortcuts act on.
    var keyboardTab: MindmapTabModel? { live.first { $0.hasKeyboardNow } }

    /// The map a command acts on: the one with the keyboard, else the focused tab's.
    var commandTab: MindmapTabModel? { keyboardTab ?? live.first { $0.context.isActive } }

    /// `DocumentTextChanged`.
    func documentChanged(_ path: String) {
        formats[path] = nil
        for tab in live where tab.path == path { tab.refresh() }
    }

    /// `VaultChanged`.
    func vaultChanged(_ paths: [String]) {
        for path in paths { formats[path] = nil }
        for tab in live where paths.contains(tab.path) { tab.refresh() }
    }

    /// `NotesMoved`: each tab keeps following its note under the new path.
    func moved(_ moves: [String: String]) {
        for (old, new) in moves {
            formats[old] = nil
            formats[new] = nil
        }
        for tab in live { tab.moved(moves) }
    }

    // MARK: - Mindmap notes

    enum Format: Equatable {
        /// Not a mindmap: sections (`##` headings) or no list at all.
        case none
        /// A `# title` and a list: it can be shown as a map.
        case compatible
        /// Flagged `mindmap-plugin:` in its frontmatter: it opens as a map.
        case flagged

        var isCompatible: Bool { self != .none }
    }

    /// What the view types ask for each note, the sidebar for each row: read once per note until it changes.
    private var formats: [String: Format] = [:]

    func format(of resource: Resource) -> Format {
        guard resource.kind == .file, resource.pathExtension == "md" else { return .none }
        if let known = formats[resource.path] { return known }
        let format = text(of: resource.path).map(Self.format(ofText:)) ?? .none
        formats[resource.path] = format
        return format
    }

    static func format(ofText text: String) -> Format {
        if MindmapDocument.hasFlag(text) { return .flagged }
        guard MindmapDocument.isMindmapNote(text) else { return .none }
        return MindmapDocument.parse(text, title: "").root.children.isEmpty ? .none : .compatible
    }

    /// The note of a map whose central topic is edited when its tab opens: the map just created.
    var editsRootOnOpen: String?

    /// Creates a mindmap note in `folder` and opens it with its central topic being edited.
    @discardableResult
    func createMap(in folder: String, title: String? = nil) throws -> String {
        let name = title ?? "Mindmap"
        let path = MindmapPlugin.freePath(folder: folder, name: name, vault: vault)
        let template = "---\n\(MindmapDocument.flag): basic\n---\n\n# \(name)\n"
        try vault.write(path, template)
        drafts?.remember(path, template: template)
        formats[path] = .flagged
        editsRootOnOpen = path
        workspace()?.open(.file(path), placement: .replace)
        return path
    }

    private struct WeakTab {
        weak var tab: MindmapTabModel?
    }
}

/// What a mindmap tab saves: its folded branches (as topic paths, which survive a relaunch) and its layout when
/// the note cannot store it.
struct MindmapTabState: Codable, Equatable {
    var folded: [String] = []
    var layout: MindmapLayoutMode?
}

/// One topic as drawn: a value made with the layout, so views never see the tree half changed.
struct MindmapSceneTopic: Identifiable, Equatable {
    let id: String
    let text: String
    let parentID: String?
    let placement: MindmapPlacement
    /// Where the edge to this topic starts: the parent's placement, or the previous topic on a timeline.
    let source: MindmapPlacement?
    let parentFrame: CGRect?
    let childCount: Int
    let descendantCount: Int
}

/// Where a dragged topic lands: on a topic (as its last child), or before or after it among its siblings. `side`
/// is the side of the central topic a main topic lands on (1 right, -1 left), when it is one.
struct MindmapDropTarget: Equatable {
    enum Mode: Equatable { case inside, before, after }
    let id: String
    let mode: Mode
    var side: Int?
}

/// One mindmap tab: the note's tree, its layout, the selection, the topic being edited and the camera.
@MainActor
@Observable
final class MindmapTabModel {
    /// The note shown; it follows a rename.
    private(set) var path: String
    /// Nil when the note cannot be read.
    private(set) var root: MindTopic?
    /// False for a note with sections (`##` headings): the map shows them but cannot write the note back.
    private(set) var isEditable = true
    private(set) var placements: [String: MindmapPlacement] = [:]
    /// What the views draw, rebuilt with the layout.
    private(set) var scene: [MindmapSceneTopic] = [] {
        didSet {
            guard scene != oldValue else { return }
            Self.revisions &+= 1
            sceneRevision = Self.revisions
        }
    }
    /// Changes with what the map shows: a picture of the map (`MindmapPicture`) is drawn again then. Counted for all
    /// the maps together: a model made again for the same note (a board's card left, a slide presented) starts
    /// past every picture drawn before, never on one of a map as it was before its last change.
    @ObservationIgnored private(set) var sceneRevision = 0
    private static var revisions = 0
    private(set) var mode: MindmapLayoutMode = .mindmap
    private(set) var folded: Set<String> = []
    /// How many main topics (the central topic's children) are on the right, the others on the left: the note's
    /// `mindmap-right:`, else the balanced split, then kept as the topics move so none jumps across. The note gets
    /// `mindmap-right:` only once a topic is put on a side on purpose (`choosesSides`); until then the split lives
    /// here, and the map is balanced again when it opens.
    private(set) var split = 0

    private(set) var selection: Set<String> = []
    /// The topic the keyboard acts on: the last one clicked or reached.
    private(set) var focusID: String?
    private(set) var editingID: String?
    var draft = "" {
        didSet { if editingID != nil, draft != oldValue { relayout(animated: false) } }
    }

    /// The camera: world (0, 0) is drawn at `offset`, at `scale`.
    var offset: CGSize = .zero
    var scale: CGFloat = 1
    var viewSize: CGSize = .zero

    /// A drag in progress: the topics moved, where the pointer is (in the view), where it holds the topic (from
    /// the topic's centre), and where they would land.
    private(set) var dragging: [String] = []
    private(set) var dragLocation: CGPoint?
    private(set) var dragGrab: CGSize = .zero
    private(set) var dropTarget: MindmapDropTarget?
    /// The rubber band of a selection drag, in view coordinates.
    private(set) var marquee: CGRect?
    var showsShortcuts = false
    /// The text field selects the whole text rather than putting the caret at its end: a new map's placeholder title.
    @ObservationIgnored var selectsAllWhenEditing = false
    /// Whether the map has the keyboard (its key view is the first responder), and a counter the view watches to
    /// take it.
    var hasKeyboard = false
    private(set) var focusRequest = 0
    /// The map's key view, to tell whether it has the keyboard right now (`hasKeyboardNow`).
    @ObservationIgnored weak var keyView: NSView?

    @ObservationIgnored weak var undoManager: UndoManager?
    @ObservationIgnored private var document: MindmapDocument?
    @ObservationIgnored private var parents: [String: MindTopic] = [:]
    @ObservationIgnored private var topics: [String: MindTopic] = [:]
    @ObservationIgnored private var newTopicID: String?
    /// The topic focused before a new one was added: focused again if the new one is abandoned.
    @ObservationIgnored private var newTopicOrigin: String?
    @ObservationIgnored private var editSnapshot: Snapshot?
    /// The edit was started by typing over the topic's text: Escape puts the text back, as in a spreadsheet cell.
    @ObservationIgnored private var editTypedOver = false
    @ObservationIgnored private var lastWritten: String?
    /// The change being made puts a main topic on a side on purpose (a drop, ⌘← ⌘→): the note keeps the sides.
    @ObservationIgnored private var choosesSides = false
    @ObservationIgnored private var branchSlots: [String: Int] = [:]
    @ObservationIgnored private var sizeCache: [String: CGSize] = [:]
    @ObservationIgnored private var fitted = false
    @ObservationIgnored private var marqueeBase: Set<String> = []
    /// Sides given to main topics by the change being made, for `settleSides`.
    @ObservationIgnored private var pendingSides: [String: Int] = [:]
    @ObservationIgnored private unowned let store: MindmapStore
    @ObservationIgnored private let view: ViewContext
    var context: ViewContext { view }

    static let minScale: CGFloat = 0.1
    static let maxScale: CGFloat = 4
    static let spring = Motion.Spring.standard.animation

    init(store: MindmapStore, view: ViewContext) {
        self.store = store
        self.view = view
        path = MindmapPlugin.notePath(of: view.resource) ?? ""
        refresh()
        if store.editsRootOnOpen == path, let root {
            store.editsRootOnOpen = nil
            startEdit(root.id)
            selectsAllWhenEditing = true
        } else if let root {
            // The central topic is selected, so the first Tab, Return or arrow acts on it.
            selection = [root.id]
            focusID = root.id
        }
        if let state = view.state(MindmapTabState.self) {
            if let layout = state.layout, document?.layout == nil { mode = layout }
            folded = Set(state.folded.compactMap(topicID(forPath:)))
            relayout(animated: false)
        }
    }

    var title: String { Resource.file(path).name }

    // MARK: - Reading the note

    func refresh() {
        guard !path.isEmpty, let text = store.text(of: path) else {
            root = nil
            placements = [:]
            return
        }
        if text == lastWritten, root != nil { return }
        let keptSides = document != nil && document?.rightCount == nil
        let editable = MindmapDocument.isMindmapNote(text)
        let next: MindTopic
        var newMode = mode
        if editable {
            let parsed = MindmapDocument.parse(text, title: title)
            document = parsed
            next = parsed.root
            if let layout = parsed.layout { newMode = layout }
        } else {
            document = nil
            next = Self.outline(MindmapTree.build(text: text, title: title))
        }
        // A note that leaves the sides to the map keeps the ones it shows, while it has as many main topics.
        let newSplit = keptSides && editable && document?.rightCount == nil
            && root?.children.count == next.children.count
            ? split : noteSplit(next)
        if let root, root.sameContent(as: next), isEditable == editable, newMode == mode, newSplit == split { return }
        if root == nil { fitted = false }
        if let root { MindmapDocument.reuseIDs(from: root, into: next) }
        isEditable = editable
        mode = newMode
        split = newSplit
        if !editable { cancelEdit() }
        install(next)
        // A topic being edited that the new tree no longer has (an unsaved one, or one removed from outside).
        if let id = editingID, topics[id] == nil { resetEditState() }
        relayout(animated: root != nil)
    }

    private func resetEditState() {
        editingID = nil
        newTopicID = nil
        editSnapshot = nil
        editTypedOver = false
    }

    /// The split the note asks for (`mindmap-right:`), else the balanced one.
    private func noteSplit(_ root: MindTopic) -> Int {
        min(document?.rightCount ?? balancedSplit(root), root.children.count)
    }

    private func balancedSplit(_ root: MindTopic) -> Int {
        MindmapLayout.balancedSplit(root) { topic, depth in self.size(of: topic.text, depth: depth) }
    }

    func moved(_ moves: [String: String]) {
        guard let new = moves[path] else { return }
        path = new
        refresh()
    }

    /// A note with sections as a tree of topics, read only.
    private static func outline(_ node: MindmapNode) -> MindTopic {
        MindTopic(node.text, children: node.children.map(outline), id: node.key)
    }

    private func install(_ new: MindTopic) {
        root = new
        topics = [:]
        parents = [:]
        func walk(_ topic: MindTopic) {
            topics[topic.id] = topic
            for child in topic.children {
                parents[child.id] = topic
                walk(child)
            }
        }
        walk(new)
        selection = selection.filter { topics[$0] != nil }
        if let focusID, topics[focusID] == nil { self.focusID = selection.first }
        folded = folded.filter { topics[$0] != nil }
        if let editingID, topics[editingID] == nil { self.editingID = nil }
        // Views see the new tree with `relayout`, once every topic has its place.
    }

    func topic(_ id: String) -> MindTopic? { topics[id] }
    func parent(of id: String) -> MindTopic? { parents[id] }

    /// The topics drawn, parents first, so edges and topics stack in a stable order.
    var visibleTopics: [MindTopic] {
        guard let root else { return [] }
        var result: [MindTopic] = []
        func walk(_ topic: MindTopic) {
            result.append(topic)
            if topic === root || !folded.contains(topic.id) { topic.children.forEach(walk) }
        }
        walk(root)
        return result
    }

    // MARK: - Layout

    func setMode(_ new: MindmapLayoutMode) {
        guard new != mode else { return }
        if isEditable, document != nil {
            mutate { $0.document?.setLayout(new) }
        }
        mode = new
        if new == .mindmap, let root { split = noteSplit(root) }
        saveState()
        relayout(animated: true)
        fit(animated: true)
    }

    func relayout(animated: Bool) {
        guard let root else { return }
        let editing = editingID
        let draft = draft
        // A branch keeps its colour when it changes place or side: slots are given once, in the order first seen.
        if branchSlots.isEmpty {
            for (index, child) in root.children.enumerated() { branchSlots[child.id] = index }
        } else {
            for child in root.children where branchSlots[child.id] == nil {
                branchSlots[child.id] = (branchSlots.values.max() ?? -1) + 1
            }
        }
        let slots = branchSlots
        let compute = {
            let placements = MindmapLayout.compute(
                root, mode: self.mode, folded: self.folded, rightCount: self.split, branchSlots: slots
            ) { topic, depth in
                self.size(of: topic.id == editing ? draft : topic.text, depth: depth)
            }
            self.placements = placements
            self.scene = self.visibleTopics.compactMap { topic in
                guard let placement = placements[topic.id] else { return nil }
                let parentID = self.parents[topic.id]?.id
                let sourceID = placement.edgeFrom ?? parentID
                return MindmapSceneTopic(
                    id: topic.id, text: topic.id == editing ? draft : topic.text, parentID: parentID,
                    placement: placement, source: sourceID.flatMap { placements[$0] },
                    parentFrame: parentID.flatMap { placements[$0]?.frame },
                    childCount: topic.children.count, descendantCount: topic.descendantCount
                )
            }
        }
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            Motion.with(Self.spring) { compute() }
        } else {
            compute()
        }
        if fitsContent {
            pinToContent()
            return
        }
        if !fitted, viewSize.width > 0 {
            fitted = true
            showInitially()
        }
    }

    /// Embedded (a map on a board), the map is drawn at 100 % with its own size: the host sizes its card to it and
    /// moves it with the board.
    var fitsContent: Bool { view.presentation == .embedded }

    /// Room round an embedded map, in points.
    static let contentPadding: CGFloat = 24

    /// Draws the map at 100 % from the top-left of the view and tells the host where its content is.
    private func pinToContent() {
        let bounds = MindmapLayout.bounds(placements)
        guard !bounds.isNull else { return }
        let padded = bounds.insetBy(dx: -Self.contentPadding, dy: -Self.contentPadding)
        scale = 1
        offset = CGSize(width: -padded.minX, height: -padded.minY)
        if view.contentBounds != padded { view.contentBounds = padded }
    }

    /// The first view of a map: all of it when it fits at a readable size, else the central topic at 75 %.
    private func showInitially() {
        let bounds = MindmapLayout.bounds(placements)
        guard !bounds.isNull, viewSize.width > 0 else { return }
        let fitScale = min((viewSize.width - 120) / max(bounds.width, 1), (viewSize.height - 120) / max(bounds.height, 1))
        if fitScale >= 0.75 {
            show(bounds, maxScale: 1, animated: false)
            return
        }
        let center = root.flatMap { placements[$0.id]?.frame } ?? bounds
        scale = 0.75
        offset = CGSize(width: viewSize.width / 2 - center.midX * scale, height: viewSize.height / 2 - center.midY * scale)
    }

    private func size(of text: String, depth: Int) -> CGSize {
        let key = "\(min(depth, 2))|\(text)"
        if let known = sizeCache[key] { return known }
        let measured = MindmapStyle.size(of: text, depth: depth)
        sizeCache[key] = measured
        return measured
    }

    // MARK: - Camera

    func viewResized(_ size: CGSize) {
        let old = viewSize
        viewSize = size
        if fitsContent { return }
        if !fitted, size.width > 0, !placements.isEmpty {
            fitted = true
            showInitially()
        } else if old.width > 0 {
            offset.width += (size.width - old.width) / 2
            offset.height += (size.height - old.height) / 2
        }
    }

    func screenRect(_ world: CGRect) -> CGRect {
        CGRect(x: world.minX * scale + offset.width, y: world.minY * scale + offset.height,
               width: world.width * scale, height: world.height * scale)
    }

    func worldPoint(_ screen: CGPoint) -> CGPoint {
        CGPoint(x: (screen.x - offset.width) / scale, y: (screen.y - offset.height) / scale)
    }

    func zoom(by factor: CGFloat, around point: CGPoint? = nil, animated: Bool = false) {
        guard !fitsContent else { return }
        let anchor = point ?? CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        let newScale = min(max(scale * factor, Self.minScale), Self.maxScale)
        let world = worldPoint(anchor)
        let apply = {
            self.scale = newScale
            self.offset = CGSize(width: anchor.x - world.x * newScale, height: anchor.y - world.y * newScale)
        }
        if animated { Motion.with(Motion.Spring.smooth.animation) { apply() } } else { apply() }
    }

    func setScale(_ value: CGFloat) { zoom(by: value / scale, animated: true) }

    func pan(by delta: CGSize) {
        guard !fitsContent else { return }
        offset.width += delta.width
        offset.height += delta.height
    }

    /// Shows the whole map.
    func fit(animated: Bool = true) { show(MindmapLayout.bounds(placements), maxScale: 1, animated: animated) }

    /// Zooms on the selected topics.
    func zoomToSelection() {
        let frames = selection.compactMap { placements[$0]?.frame }
        guard !frames.isEmpty else { return }
        show(frames.reduce(CGRect.null) { $0.union($1) }, maxScale: 1.6, animated: true)
    }

    private func show(_ world: CGRect, maxScale: CGFloat, animated: Bool) {
        guard !fitsContent, !world.isNull, viewSize.width > 0, viewSize.height > 0 else { return }
        let margin: CGFloat = 60
        let fitScale = min((viewSize.width - margin * 2) / max(world.width, 1),
                           (viewSize.height - margin * 2) / max(world.height, 1))
        let newScale = min(max(fitScale, Self.minScale), maxScale)
        let apply = {
            self.scale = newScale
            self.offset = CGSize(width: self.viewSize.width / 2 - world.midX * newScale,
                                 height: self.viewSize.height / 2 - world.midY * newScale)
        }
        if animated { Motion.with(Motion.Spring.smooth.animation) { apply() } } else { apply() }
    }

    /// Pans just enough to show a topic.
    func ensureVisible(_ id: String) {
        guard let frame = placements[id]?.frame, viewSize.width > 0 else { return }
        let rect = screenRect(frame)
        let margin: CGFloat = 56
        var dx: CGFloat = 0
        var dy: CGFloat = 0
        if rect.minX < margin { dx = margin - rect.minX } else if rect.maxX > viewSize.width - margin {
            dx = viewSize.width - margin - rect.maxX
        }
        if rect.minY < margin { dy = margin - rect.minY } else if rect.maxY > viewSize.height - margin {
            dy = viewSize.height - margin - rect.maxY
        }
        guard dx != 0 || dy != 0 else { return }
        Motion.with(Motion.Spring.smooth.animation) { pan(by: CGSize(width: dx, height: dy)) }
    }

    /// Makes the map's key view the first responder, so keys go to the map rather than to the note editor.
    func requestKeyboard() { focusRequest += 1 }

    /// Gives the keyboard to the map's key view now, rather than after SwiftUI's next update as `requestKeyboard`
    /// does: a topic's text field passes it on this way, so the keys typed until the next field is up are kept.
    func takeKeyboard() {
        guard let keyView, let window = keyView.window else { return requestKeyboard() }
        if window.firstResponder !== keyView { window.makeFirstResponder(keyView) }
    }

    /// The map's key view is the first responder of the key window now: the map's own shortcuts apply.
    var hasKeyboardNow: Bool {
        guard let keyView, let window = keyView.window else { return false }
        return window.isKeyWindow && window.firstResponder === keyView
    }

    // MARK: - Keyboard

    /// A key the map's key view received; true when the map used it. Most ⌘ keys are the plugin's commands
    /// (`MindmapCommands`), which the shell runs before the map sees the key; the map keeps the others, and ⌘. ⌘0
    /// for keyboards the command's key does not match. With nothing selected, the keys that add or edit a topic act
    /// on the central topic.
    func handleKey(_ key: MindmapKey, modifiers: NSEvent.ModifierFlags, isRepeat: Bool = false) -> Bool {
        let mods = modifiers.intersection(.deviceIndependentFlagsMask)
        guard editingID == nil else { return typeAhead(key, mods) }
        let shift = mods.contains(.shift)

        if mods.contains(.command) {
            switch key {
            case .character("."): foldSelection()
            case .character("0"), .character("à"): fit()
            case .character("="), .character("+"): zoom(by: 1.25, animated: true)
            case .character("-"): zoom(by: 0.8, animated: true)
            case .returnKey: openNote()
            default: return false
            }
            return true
        }
        if mods.contains(.control) { return false }
        // ⌥ with a letter types a character, which starts editing below.
        if mods.contains(.option), !key.isCharacter {
            switch key {
            case .up: moveSibling(by: -1)
            case .down: moveSibling(by: 1)
            case .returnKey:
                focusCentralIfNone()
                addSibling(above: true)
            default: return false
            }
            return true
        }
        switch key {
        case .tab:
            focusCentralIfNone()
            if shift { outdent() } else { addChild() }
        case .returnKey:
            focusCentralIfNone()
            addSibling(above: shift)
        case .space, .f2:
            // A held Space repeats: the first press opens the topic, the field takes the others.
            guard !isRepeat else { return true }
            focusCentralIfNone()
            if let id = focusID { startEdit(id) }
        case .delete: deleteSelection()
        case .up: navigate(.top)
        case .down: navigate(.bottom)
        case .left: navigate(.left)
        case .right: navigate(.right)
        case .escape:
            // Escape closes the list of shortcuts first, then clears the selection.
            if showsShortcuts { showsShortcuts = false } else { deselect() }
        case .home: if let root { select(root.id) }
        case .character(let text):
            switch text {
            case "!": fit()
            case "@": zoomToSelection()
            case "?": showsShortcuts.toggle()
            default:
                // Typing on a selected topic replaces its text, like a spreadsheet cell.
                guard isEditable, text.count == 1, key.typedText != nil else { return false }
                focusCentralIfNone()
                guard let id = focusID else { return false }
                typeOver(id, with: text)
            }
        }
        return true
    }

    /// Keys typed while a topic is edited but its text field is not up yet (SwiftUI adds it a frame or two after
    /// Tab or Return, and the map holds the keyboard meanwhile): they go to the draft, which the field takes when it
    /// comes, and Return, Tab and Escape do what they do in the field. So typing straight after Tab is never lost.
    private func typeAhead(_ key: MindmapKey, _ mods: NSEvent.ModifierFlags) -> Bool {
        guard !mods.contains(.command), !mods.contains(.control) else { return false }
        switch key {
        case .returnKey: returnWhileEditing(above: mods.contains(.shift) || mods.contains(.option))
        case .tab: if mods.contains(.shift) { backtabWhileEditing() } else { tabWhileEditing() }
        case .escape: escapeWhileEditing()
        case .delete: if !draft.isEmpty { draft.removeLast() }
        default: if let text = key.typedText { draft += text }
        }
        return true
    }

    /// With nothing selected, the central topic: what Tab, Return, Space and typing act on.
    private func focusCentralIfNone() {
        guard focusID == nil, let root else { return }
        select(root.id)
    }

    // MARK: - Selection

    func select(_ id: String, extend: Bool = false) {
        if editingID != nil, editingID != id { commitEdit() }
        if extend {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else {
            selection = [id]
        }
        focusID = id
        ensureVisible(id)
    }

    func deselect() {
        if editingID != nil { commitEdit() }
        selection = []
        focusID = nil
    }

    func selectAll() {
        selection = Set(placements.keys)
        if focusID == nil { focusID = root?.id }
    }

    func beginMarquee(extend: Bool) {
        if editingID != nil { commitEdit() }
        marqueeBase = extend ? selection : []
    }

    func updateMarquee(_ rect: CGRect) {
        marquee = rect
        var picked = marqueeBase
        for (id, placement) in placements where screenRect(placement.frame).intersects(rect) { picked.insert(id) }
        selection = picked
        focusID = picked.first
    }

    func endMarquee() { marquee = nil }

    /// Arrow keys: left and right go to the parent or the nearest child on that side, up and down to the nearest
    /// topic above or below on the same side.
    func navigate(_ direction: MindmapPlacement.Side) {
        guard let root else { return }
        guard let id = focusID, let here = placements[id], let topic = topics[id] else {
            select(root.id)
            return
        }
        var target: String?
        if mode == .timeline {
            target = nearest(from: id, here, direction)
        } else if direction == .left || direction == .right {
            let side = direction == .right ? 1 : -1
            if here.depth > 0, here.direction != side {
                target = parents[id]?.id
            } else if here.depth > 0, folded.contains(id), !topic.children.isEmpty {
                toggleFold(id)
                return
            } else {
                target = topic.children
                    .compactMap { child in placements[child.id].map { (child.id, $0) } }
                    .filter { $0.1.direction == side }
                    .min { abs($0.1.frame.midY - here.frame.midY) < abs($1.1.frame.midY - here.frame.midY) }?.0
            }
        } else if here.depth == 0 {
            target = nearest(from: id, here, direction)
        } else {
            let up = direction == .top
            var best = CGFloat.infinity
            for (other, placement) in placements where other != id && placement.direction == here.direction
                && placement.depth > 0 {
                let dy = up ? here.frame.midY - placement.frame.midY : placement.frame.midY - here.frame.midY
                guard dy > 1 else { continue }
                let score = dy + CGFloat(abs(placement.depth - here.depth)) * 10000
                    + abs(placement.frame.minX - here.frame.minX) * 0.2
                if score < best {
                    best = score
                    target = other
                }
            }
        }
        if let target { select(target) }
    }

    private func nearest(from id: String, _ here: MindmapPlacement, _ direction: MindmapPlacement.Side) -> String? {
        let (ux, uy): (CGFloat, CGFloat) = switch direction {
        case .left: (-1, 0)
        case .right: (1, 0)
        case .top: (0, -1)
        case .bottom: (0, 1)
        }
        var best = CGFloat.infinity
        var target: String?
        for (other, placement) in placements where other != id {
            let dx = placement.frame.midX - here.frame.midX
            let dy = placement.frame.midY - here.frame.midY
            let along = dx * ux + dy * uy
            guard along > 1 else { continue }
            let score = along + abs(dx * uy - dy * ux) * 2.5
            if score < best {
                best = score
                target = other
            }
        }
        return target
    }

    // MARK: - Folding

    func toggleFold(_ id: String) {
        setFolded([id], !folded.contains(id))
    }

    /// Folds (hides the branches of) or unfolds topics; the central topic and topics without children never fold.
    func setFolded(_ ids: [String], _ fold: Bool) {
        let foldable = ids.filter { id in topics[id].map { $0 !== root && !$0.children.isEmpty } ?? false }
        guard !foldable.isEmpty else { return }
        if fold { folded.formUnion(foldable) } else { folded.subtract(foldable) }
        afterFolding()
        relayout(animated: true)
    }

    /// ⌘.: folds or unfolds each selected topic.
    func foldSelection() {
        let ids = selection.filter { id in topics[id].map { $0 !== root && !$0.children.isEmpty } ?? false }
        guard !ids.isEmpty else { return }
        for id in ids { if folded.contains(id) { folded.remove(id) } else { folded.insert(id) } }
        afterFolding()
        relayout(animated: true)
    }

    /// ⌥⌘←: folds the focused topic; on a topic with nothing to fold, the branch it is in (its parent).
    func foldFocused() {
        guard let id = focusID, let topic = topics[id] else { return }
        if topic !== root, !topic.children.isEmpty, !folded.contains(id) {
            setFolded([id], true)
        } else if let parent = parents[id], parent !== root {
            setFolded([parent.id], true)
            select(parent.id)
        }
    }

    /// ⌥⌘→: unfolds the focused topic.
    func unfoldFocused() {
        guard let id = focusID else { return }
        setFolded([id], false)
    }

    func setAllFolded(_ fold: Bool) {
        guard let root else { return }
        folded = fold ? Set(root.all.filter { $0 !== root && !$0.children.isEmpty }.map(\.id)) : []
        afterFolding()
        relayout(animated: true)
        fit()
    }

    /// A topic is hidden when one of its ancestors is folded.
    func isHidden(_ id: String) -> Bool {
        var current = parents[id]
        while let parent = current {
            if folded.contains(parent.id) { return true }
            current = parents[parent.id]
        }
        return false
    }

    /// Topics a fold hid leave the selection; the focus goes to the folded topic that holds it.
    private func afterFolding() {
        selection = selection.filter { !isHidden($0) }
        if let id = focusID, isHidden(id) {
            var visible = parents[id]
            while let topic = visible, isHidden(topic.id) { visible = parents[topic.id] }
            focusID = visible?.id
            if let visible { selection.insert(visible.id) }
        }
        saveState()
    }

    // MARK: - Editing text

    func startEdit(_ id: String, replacingWith text: String? = nil) {
        guard isEditable, let topic = topics[id] else { return }
        if let editingID, editingID != id { commitEdit() }
        selection = [id]
        focusID = id
        editSnapshot = editSnapshot ?? snapshot()
        editTypedOver = false
        draft = text ?? topic.text
        editingID = id
        relayout(animated: false)
        ensureVisible(id)
    }

    /// A character typed on a selected topic: it replaces the text, like typing in a spreadsheet cell, and Escape
    /// puts the text back (`escapeWhileEditing`).
    func typeOver(_ id: String, with text: String) {
        startEdit(id, replacingWith: text)
        if editingID == id { editTypedOver = true }
    }

    /// Escape while typing: the text is kept and the topic stays selected; after typing over a topic, its text
    /// comes back instead, so a stray key never loses it.
    func escapeWhileEditing() {
        guard let id = editingID else { return }
        if editTypedOver, newTopicID != id { cancelEdit() } else { commitEdit() }
    }

    /// Ends editing: an empty new topic disappears, otherwise the text is saved. The topic stays selected.
    @discardableResult
    func commitEdit() -> Bool {
        guard let id = editingID else { return false }
        guard let topic = topics[id] else {
            resetEditState()
            return false
        }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        editingID = nil
        editTypedOver = false
        let isNew = newTopicID == id
        newTopicID = nil
        if text.isEmpty, isNew {
            removeUnsaved(topic)
            return false
        }
        let before = editSnapshot
        editSnapshot = nil
        if !text.isEmpty { topic.text = text }
        save(undoing: before, name: isNew ? "Add Topic" : "Edit Topic")
        relayout(animated: true)
        return true
    }

    func cancelEdit() {
        guard let id = editingID else { return }
        editingID = nil
        editTypedOver = false
        editSnapshot = nil
        if newTopicID == id, let topic = topics[id] {
            newTopicID = nil
            removeUnsaved(topic)
        } else {
            relayout(animated: true)
        }
    }

    private func removeUnsaved(_ topic: MindTopic) {
        let parent = parents[topic.id]
        let sides = mainSides()
        parent?.children.removeAll { $0 === topic }
        if parent === root { settleSides(before: sides) }
        install(root!)
        if let origin = newTopicOrigin, topics[origin] != nil { select(origin) } else if let parent { select(parent.id) }
        newTopicOrigin = nil
        relayout(animated: true)
    }

    /// Whether the topic being edited is a new one with no text yet.
    private var editsEmptyNewTopic: Bool {
        editingID != nil && editingID == newTopicID && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Return while typing: the text is saved and a sibling opens below (above with Shift), ready for typing. On a
    /// new topic still empty, the run ends, as a second Return ends a list: the empty topic goes away and the topic
    /// typed before it is selected.
    func returnWhileEditing(above: Bool = false) {
        guard let id = editingID else { return }
        if editsEmptyNewTopic {
            commitEdit()
            return
        }
        commitEdit()
        guard topics[id] != nil else { return }
        focusID = id
        addSibling(above: above)
    }

    /// Tab while typing: the text is saved and a child opens, ready for typing. A new topic still empty goes under
    /// the topic above it instead, as in an outline.
    func tabWhileEditing() {
        guard let id = editingID, let topic = topics[id] else { return }
        if editsEmptyNewTopic {
            if let above = previousSibling(of: topic) { moveUnsaved(topic, into: above, at: above.children.count) }
            return
        }
        commitEdit()
        guard topics[id] != nil else { return }
        focusID = id
        addChild()
    }

    /// Shift-Tab while typing: the topic moves up a level, still being typed.
    func backtabWhileEditing() {
        guard let id = editingID, let topic = topics[id], let parent = parents[id],
              let grand = parents[parent.id] else { return }
        if newTopicID == id {
            let index = grand.children.firstIndex { $0 === parent } ?? grand.children.count - 1
            moveUnsaved(topic, into: grand, at: index + 1)
            return
        }
        let draft = draft
        commitEdit()
        focusID = id
        outdent()
        startEdit(id, replacingWith: draft)
    }

    /// Moves the new topic being typed, which is not in the note yet.
    private func moveUnsaved(_ topic: MindTopic, into parent: MindTopic, at index: Int) {
        let sides = mainSides()
        parents[topic.id]?.children.removeAll { $0 === topic }
        parent.children.insert(topic, at: min(index, parent.children.count))
        settleSides(before: sides)
        if folded.remove(parent.id) != nil { saveState() }
        install(root!)
        relayout(animated: true)
        ensureVisible(topic.id)
    }

    /// The sibling drawn above a topic: the one before it in its parent's list, on the same side for a main topic.
    private func previousSibling(of topic: MindTopic) -> MindTopic? {
        guard let parent = parents[topic.id], let index = parent.children.firstIndex(where: { $0 === topic }),
              index > 0 else { return nil }
        let previous = parent.children[index - 1]
        if parent === root, keepsSides, side(of: previous.id) != side(of: topic.id) { return nil }
        return previous
    }

    // MARK: - Structure

    /// Tab: a new child of the focused topic, edited at once. A new main topic goes on the side with fewer topics.
    /// With `text`, the topic is written at once instead (agents).
    func addChild(text: String? = nil) {
        guard isEditable, let id = focusID, let parent = topics[id] else { return }
        if editingID != nil, !commitEdit(), topics[id] == nil { return }
        if folded.remove(parent.id) != nil { saveState() }
        if parent === root, keepsSides {
            let side = lighterSide()
            insertNew(in: parent, at: side == 1 ? split : parent.children.count, side: side)
        } else {
            insertNew(in: parent, at: parent.children.count)
        }
        if let text { finishNew(text) }
    }

    /// Return: a new sibling below (or above with Shift) the focused topic, on its side; a child of the central
    /// topic. With `text`, the topic is written at once instead (agents).
    func addSibling(above: Bool = false, text: String? = nil) {
        guard isEditable, let id = focusID else { return }
        if editingID != nil { commitEdit() }
        guard let topic = topics[id] else { return }
        guard let parent = parents[id] else { return addChild(text: text) }
        let index = parent.children.firstIndex { $0 === topic } ?? parent.children.count
        if parent === root, keepsSides, document?.rightCount == nil, lighterSide() != side(of: id) {
            // No side chosen yet: typing main topics one after the other keeps the map balanced.
            let side = lighterSide()
            insertNew(in: parent, at: side == 1 ? split : parent.children.count, side: side)
        } else {
            insertNew(in: parent, at: above ? index : index + 1, side: parent === root ? side(of: id) : nil)
        }
        if let text { finishNew(text) }
    }

    private func finishNew(_ text: String) {
        draft = text
        commitEdit()
    }

    private func insertNew(in parent: MindTopic, at index: Int, side: Int? = nil) {
        editSnapshot = snapshot()
        editTypedOver = false
        newTopicOrigin = focusID
        let sides = mainSides()
        let topic = MindTopic()
        parent.children.insert(topic, at: min(index, parent.children.count))
        if parent === root {
            if let side { pendingSides[topic.id] = side }
            settleSides(before: sides)
        }
        install(root!)
        newTopicID = topic.id
        selection = [topic.id]
        focusID = topic.id
        draft = ""
        editingID = topic.id
        relayout(animated: true)
        ensureVisible(topic.id)
    }

    /// The side with fewer topics: 1 for the right, -1 for the left.
    private func lighterSide() -> Int {
        var right = 0
        var left = 0
        for placement in placements.values where placement.depth > 0 {
            if placement.direction < 0 { left += 1 } else { right += 1 }
        }
        return left < right ? -1 : 1
    }

    /// Delete: removes the selected topics with their branches (never the central topic).
    func deleteSelection() {
        guard isEditable, let root else { return }
        let ids = selection.filter { $0 != root.id }
        guard !ids.isEmpty else { return }
        // The topic selected next: the previous sibling of the focused one, else its parent.
        var next: String?
        if let focus = focusID ?? ids.first, let parent = parents[focus],
           let index = parent.children.firstIndex(where: { $0.id == focus }) {
            let remaining = parent.children[..<index].filter { !ids.contains($0.id) }
            next = remaining.last?.id ?? (index + 1 < parent.children.count
                ? parent.children[(index + 1)...].first { !ids.contains($0.id) }?.id : nil) ?? parent.id
        }
        mutate(name: "Delete Topic") { _ in
            for id in ids { self.parents[id]?.children.removeAll { $0.id == id } }
        }
        while let candidate = next, topics[candidate] == nil { next = parents[candidate]?.id ?? root.id }
        selection = next.map { [$0] } ?? []
        focusID = next
    }

    /// Shift-Tab: the focused topic moves up one level, after its parent (on its parent's side).
    func outdent() {
        guard isEditable, let id = focusID, let topic = topics[id], let parent = parents[id],
              let grand = parents[parent.id] else { return }
        mutate(name: "Move Topic") { _ in
            parent.children.removeAll { $0 === topic }
            let index = grand.children.firstIndex { $0 === parent } ?? grand.children.count - 1
            grand.children.insert(topic, at: index + 1)
        }
        ensureVisible(id)
    }

    /// The focused topic moves down one level, under the sibling drawn above it (as its last child).
    func indent() {
        guard isEditable, let id = focusID, let topic = topics[id], let target = previousSibling(of: topic)
        else { return }
        mutate(name: "Move Topic") { model in
            model.parents[id]?.children.removeAll { $0 === topic }
            model.folded.remove(target.id)
            target.children.append(topic)
        }
        ensureVisible(id)
    }

    /// ⌘↑ and ⌘↓ (or ⌥): the focused topic moves among its siblings; a main topic stays on its side.
    func moveSibling(by step: Int) {
        guard isEditable, let id = focusID, let topic = topics[id], let parent = parents[id],
              let index = parent.children.firstIndex(where: { $0 === topic }) else { return }
        let target = index + step
        var range = parent.children.indices
        if parent === root, keepsSides { range = index < split ? 0 ..< split : split ..< parent.children.count }
        guard range.contains(target) else { return }
        mutate(name: "Move Topic") { _ in
            parent.children.remove(at: index)
            parent.children.insert(topic, at: target)
        }
        ensureVisible(id)
    }

    /// ⌘← and ⌘→: the focused topic moves that way. Toward the central topic it goes up a level, and a main topic
    /// crosses to the other side; away from it, it goes under the sibling above it. On a timeline, main topics move
    /// along the line.
    func moveHorizontally(_ direction: Int) {
        guard isEditable, let id = focusID, let parent = parents[id], let placement = placements[id] else { return }
        if mode == .timeline, parent === root { return moveSibling(by: direction) }
        let outward = mode == .mindmap ? placement.direction : 1
        if direction == outward {
            indent()
        } else if parent === root {
            moveToOtherSide()
        } else {
            outdent()
        }
    }

    /// The focused main topic goes to the other side of the central topic, at about the same height.
    func moveToOtherSide() {
        guard keepsSides, let root, let id = focusID, let topic = topics[id], parents[id] === root,
              let side = side(of: id) else { return }
        let y = placements[id]?.frame.midY
        mutate(name: "Move Topic") { model in
            model.placeMain([topic], side: -side, nearY: y)
            model.choosesSides = true
        }
        selection = [id]
        focusID = id
        ensureVisible(id)
    }

    /// Puts main topics on a side, among that side's topics at height `y` (at the end of the side without it). Part
    /// of a `mutate`, which settles the sides.
    private func placeMain(_ moving: [MindTopic], side: Int, nearY y: CGFloat?) {
        guard let root else { return }
        let sides = mainSides()
        for topic in moving { parents[topic.id]?.children.removeAll { $0 === topic } }
        let others = root.children.filter { sides[$0.id] == side }
        var index = side == 1 ? 0 : root.children.count
        if let y, let next = others.first(where: { (placements[$0.id]?.frame.midY ?? .infinity) > y }) {
            index = root.children.firstIndex { $0 === next } ?? index
        } else if let last = others.last {
            index = (root.children.firstIndex { $0 === last } ?? index) + 1
        }
        root.children.insert(contentsOf: moving, at: index)
        for topic in moving { pendingSides[topic.id] = side }
    }

    /// Main topics a drop puts on a side: when one was not there before (from the other side, or from deeper in the
    /// map), the side was chosen, and the note keeps it.
    private func give(_ moving: [MindTopic], side: Int, before: [String: Int]) {
        for topic in moving {
            pendingSides[topic.id] = side
            if before[topic.id] != side { choosesSides = true }
        }
    }

    // MARK: - Sides

    /// Whether the map keeps its main topics on the sides they were given: in the mindmap layout of a note it can
    /// write. Other layouts follow the note.
    private var keepsSides: Bool { mode == .mindmap && isEditable && document != nil }

    /// The side of a main topic: 1 on the right of the central topic, -1 on its left; nil for other topics.
    func side(of id: String) -> Int? {
        guard let root, let index = root.children.firstIndex(where: { $0.id == id }) else { return nil }
        return index < split ? 1 : -1
    }

    private func mainSides() -> [String: Int] {
        guard let root else { return [:] }
        var sides: [String: Int] = [:]
        for (index, topic) in root.children.enumerated() { sides[topic.id] = index < split ? 1 : -1 }
        return sides
    }

    /// After a change of the main topics: each keeps the side it had (`before`) unless the change gave it one
    /// (`pendingSides`), a new one takes the side of the topic before it, and the right side's topics come first.
    private func settleSides(before: [String: Int]) {
        defer { pendingSides = [:] }
        guard let root else { return }
        guard keepsSides else {
            // Outside the mindmap layout the sides are a count of the first main topics: a reorder or an addition
            // that would send a topic across drops `mindmap-right:`, and the map balances again.
            if document?.rightCount != nil {
                let kept = min(document?.rightCount ?? 0, root.children.count)
                let moved = root.children.enumerated().contains { index, topic in
                    before[topic.id].map { $0 != (index < kept ? 1 : -1) } ?? false
                } || root.children.count != before.count
                if moved { document?.rightCount = nil }
            }
            split = noteSplit(root)
            return
        }
        var right: [MindTopic] = []
        var left: [MindTopic] = []
        var previous = 1
        for topic in root.children {
            let side = pendingSides[topic.id] ?? before[topic.id] ?? previous
            if side < 0 { left.append(topic) } else { right.append(topic) }
            previous = side
        }
        root.children = right + left
        split = right.count
    }

    // MARK: - Drag and drop

    /// The topics a drag starting on `id` moves: the selection when it contains `id`, without topics whose
    /// ancestor also moves. `grab` is where the pointer holds the topic, from its centre, on screen.
    func beginDrag(_ id: String, grab: CGSize = .zero) {
        guard isEditable, id != root?.id else { return }
        if editingID != nil { commitEdit() }
        if !selection.contains(id) {
            selection = [id]
            focusID = id
        }
        dragGrab = grab
        dragging = selection.filter { $0 != root?.id && !hasAncestor($0, in: selection) }
            .sorted { order($0) < order($1) }
    }

    func updateDrag(to location: CGPoint) {
        guard !dragging.isEmpty else { return }
        dragLocation = location
        let target = dropTarget(at: worldPoint(location))
        guard target != dropTarget else { return }
        if target != nil { Haptics.alignment() }
        withAnimation(Motion.hover) { dropTarget = target }
    }

    func endDrag() {
        let ids = dragging
        let target = dropTarget
        dragging = []
        dropTarget = nil
        dragLocation = nil
        guard let target, !ids.isEmpty else {
            relayout(animated: true)
            return
        }
        move(ids, to: target)
    }

    /// Whether a topic moves with the drag: a dragged topic or one of its descendants.
    func isDragged(_ id: String) -> Bool {
        guard !dragging.isEmpty else { return false }
        if dragging.contains(id) { return true }
        var current = parents[id]
        while let parent = current {
            if dragging.contains(parent.id) { return true }
            current = parents[parent.id]
        }
        return false
    }

    func move(_ ids: [String], to target: MindmapDropTarget) {
        guard let root, let targetTopic = topics[target.id] else { return }
        let moving = ids.compactMap { topics[$0] }.filter { parents[$0.id] != nil }
        guard !moving.isEmpty, !moving.contains(where: { $0 === targetTopic || isAncestor($0, of: targetTopic) })
        else { return }
        if target.mode != .inside, parents[target.id] == nil { return }
        mutate(name: "Move Topic") { model in
            let sides = model.mainSides()
            for topic in moving { model.parents[topic.id]?.children.removeAll { $0 === topic } }
            switch target.mode {
            case .inside:
                model.folded.remove(targetTopic.id)
                if targetTopic === root, let side = target.side, model.keepsSides {
                    let rightCount = root.children.prefix { sides[$0.id] == 1 }.count
                    root.children.insert(contentsOf: moving, at: side == 1 ? rightCount : root.children.count)
                    model.give(moving, side: side, before: sides)
                } else {
                    targetTopic.children.append(contentsOf: moving)
                }
            case .before, .after:
                let parent = model.parents[target.id]!
                let index = parent.children.firstIndex { $0 === targetTopic } ?? parent.children.count
                parent.children.insert(contentsOf: moving, at: target.mode == .before ? index : index + 1)
                if parent === root, let side = sides[target.id] { model.give(moving, side: side, before: sides) }
            }
        }
        selection = Set(moving.map(\.id))
        focusID = moving.first?.id
    }

    /// The slot nearest the pointer (in world coordinates), so a drop always lands somewhere sensible. On the
    /// mindmap, the pointer's side of the central topic decides the side: crossing its centre line moves the slot
    /// to the other side at once. Beyond a topic's outer edge the slot is its child; over its middle too; else
    /// before or after it.
    func dropTarget(at point: CGPoint) -> MindmapDropTarget? {
        guard let root, let center = placements[root.id] else { return nil }
        let excluded = Set(dragging.flatMap { topics[$0]?.all.map(\.id) ?? [] })
        let sided = mode == .mindmap
        let side = sided && point.x < center.frame.midX ? -1 : 1
        let candidates = placements.filter { id, placement in
            !excluded.contains(id) && placement.depth > 0 && (!sided || placement.direction == side)
        }
        let rootTarget = MindmapDropTarget(id: root.id, mode: .inside, side: sided ? side : nil)
        let events = candidates.filter { $0.value.depth == 1 }
        func dx(_ frame: CGRect) -> CGFloat { max(frame.minX - point.x, 0, point.x - frame.maxX) }
        if center.frame.insetBy(dx: -10, dy: -10).contains(point) {
            if mode == .timeline {
                // The central topic starts the timeline: the first event.
                let first = events.min { $0.value.frame.minX < $1.value.frame.minX }
                return first.map { MindmapDropTarget(id: $0.key, mode: .before) } ?? rootTarget
            }
            // On the central topic: a main topic on the pointer's side, next to the nearest one there.
            guard let nearest = events
                .min(by: { abs($0.value.frame.midY - point.y) < abs($1.value.frame.midY - point.y) })
            else { return rootTarget }
            return MindmapDropTarget(id: nearest.key, mode: point.y < nearest.value.frame.midY ? .before : .after,
                                     side: sided ? side : nil)
        }
        if mode == .timeline, let axis = events.first?.value.frame.midY {
            // On the timeline's line, between events or past one: before or after the nearest event, by its middle;
            // over the event's middle, inside it.
            let band = (events.map(\.value.frame.height).max() ?? 0) / 2 + 24
            if abs(point.y - axis) <= band, let nearest = events.min(by: { dx($0.value.frame) < dx($1.value.frame) }) {
                let frame = nearest.value.frame
                if frame.contains(point), abs(point.x - frame.midX) < frame.width * 0.2 {
                    return MindmapDropTarget(id: nearest.key, mode: .inside)
                }
                return MindmapDropTarget(id: nearest.key, mode: point.x < frame.midX ? .before : .after)
            }
        }
        func distance(_ frame: CGRect) -> CGFloat {
            let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
            return (dx(frame) * dx(frame) + dy * dy).squareRoot()
        }
        guard let nearest = candidates.min(by: { distance($0.value.frame) < distance($1.value.frame) }) else {
            // Nothing on that side yet: the first topic there.
            return rootTarget
        }
        let (id, placement) = (nearest.key, nearest.value)
        let frame = placement.frame
        guard distance(frame) < 320 else { return nil }
        let mainSide = placement.depth == 1 && sided ? side : nil
        let outward: CGFloat = sided ? CGFloat(placement.direction) : 1
        let past = (point.x - (outward > 0 ? frame.maxX : frame.minX)) * outward
        if past > 6 { return MindmapDropTarget(id: id, mode: .inside) }
        if mode == .timeline, placement.depth == 1 {
            // Main topics of a timeline sit along a line: before or after is left or right.
            if frame.contains(point), abs(point.x - frame.midX) < frame.width * 0.2 {
                return MindmapDropTarget(id: id, mode: .inside)
            }
            return MindmapDropTarget(id: id, mode: point.x < frame.midX ? .before : .after)
        }
        if frame.contains(point) {
            let ratio = (point.y - frame.minY) / max(frame.height, 1)
            // Nesting needs the pointer on the topic's outer half: its inner half (towards the centre) stays a
            // sibling slot, so a drag that only changes sides never nests by accident.
            if ratio > 0.3, ratio < 0.7, (point.x - frame.midX) * outward > 0 {
                return MindmapDropTarget(id: id, mode: .inside)
            }
        }
        return MindmapDropTarget(id: id, mode: point.y < frame.midY ? .before : .after, side: mainSide)
    }

    private func hasAncestor(_ id: String, in set: Set<String>) -> Bool {
        var current = parents[id]
        while let parent = current {
            if set.contains(parent.id) { return true }
            current = parents[parent.id]
        }
        return false
    }

    private func isAncestor(_ topic: MindTopic, of other: MindTopic) -> Bool {
        var current = parents[other.id]
        while let parent = current {
            if parent === topic { return true }
            current = parents[parent.id]
        }
        return false
    }

    private func order(_ id: String) -> Int { visibleTopics.firstIndex { $0.id == id } ?? .max }

    // MARK: - Clipboard

    /// The selected branches as a Markdown list.
    func copySelection() -> String? {
        let ids = selection.filter { !hasAncestor($0, in: selection) }.sorted { order($0) < order($1) }
        guard !ids.isEmpty else { return nil }
        return MindmapDocument.markdownList(ids.compactMap { topics[$0] }.map { $0.id == root?.id ? $0 : $0 })
    }

    func cutSelection() -> String? {
        let text = copySelection()
        deleteSelection()
        return text
    }

    /// Pasted lines become children of the focused topic.
    func paste(_ text: String) {
        guard isEditable, let id = focusID ?? root?.id, let parent = topics[id] else { return }
        let new = MindmapDocument.parseFragment(text)
        guard !new.isEmpty else { return }
        mutate(name: "Paste") { _ in
            self.folded.remove(parent.id)
            parent.children.append(contentsOf: new)
        }
        selection = Set(new.map(\.id))
        focusID = new.first?.id
    }

    // MARK: - Writing

    /// The note as written, with the sides the map shows: what an undo puts back.
    private struct Snapshot {
        let text: String
        let split: Int
    }

    private func snapshot() -> Snapshot? {
        (lastWritten ?? document?.serialized()).map { Snapshot(text: $0, split: split) }
    }

    /// Applies a change to the tree, writes the note, and registers its undo.
    private func mutate(name: String = "Edit Mindmap", _ body: (MindmapTabModel) -> Void) {
        guard isEditable, root != nil else { return }
        if editingID != nil { commitEdit() }
        let before = snapshot()
        let sides = mainSides()
        body(self)
        settleSides(before: sides)
        save(undoing: before, name: name)
        relayout(animated: true)
    }

    private func save(undoing before: Snapshot?, name: String) {
        defer { choosesSides = false }
        guard var document, let root else { return }
        document.root = root
        // The note keeps the sides once one was chosen (a drop, ⌘← ⌘→): `mindmap-right:` is written then, and kept
        // up to date as main topics come and go. Other changes leave the frontmatter alone.
        if keepsSides, choosesSides || document.rightCount != nil { document.rightCount = split }
        self.document = document
        install(root)
        let text = document.serialized()
        guard text != before?.text else { return }
        write(text)
        if let before { registerUndo(restoring: before, redo: Snapshot(text: text, split: split), name: name) }
    }

    private func write(_ text: String) {
        lastWritten = text
        do {
            try store.vault.write(path, text)
        } catch {
            NSSound.beep()
        }
    }

    private func registerUndo(restoring old: Snapshot, redo new: Snapshot, name: String) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.restore(old, redo: new, name: name) }
        }
        undoManager.setActionName(name)
    }

    private func restore(_ snapshot: Snapshot, redo other: Snapshot, name: String) {
        cancelEdit()
        let previous = root
        let parsed = MindmapDocument.parse(snapshot.text, title: title)
        document = parsed
        if let previous { MindmapDocument.reuseIDs(from: previous, into: parsed.root) }
        // A note without `mindmap-right:` gets back the sides the map showed then.
        split = min(parsed.rightCount ?? snapshot.split, parsed.root.children.count)
        install(parsed.root)
        write(snapshot.text)
        registerUndo(restoring: other, redo: snapshot, name: name)
        relayout(animated: true)
    }

    // MARK: - Saved state

    private func saveState() {
        view.setState(MindmapTabState(
            folded: folded.compactMap(topicPath).sorted(),
            layout: document == nil ? mode : nil
        ))
    }

    /// A topic's texts from the root down: what folded branches are saved as.
    private func topicPath(_ id: String) -> String? {
        guard let topic = topics[id] else { return nil }
        var parts = [topic.text]
        var current = parents[id]
        while let parent = current {
            parts.insert(parent.text, at: 0)
            current = parents[parent.id]
        }
        return parts.joined(separator: "/")
    }

    private func topicID(forPath path: String) -> String? {
        topics.keys.first { topicPath($0) == path }
    }

    // MARK: - Opening the note

    /// Opens the note beside the map, the caret on the focused topic's line when it is a heading.
    func openNote() {
        store.workspace()?.open(.file(path), placement: .beside)
    }
}

/// The look of topics, shared by the views and the layout's measurements.
enum MindmapStyle {
    static func font(depth: Int) -> NSFont {
        switch depth {
        case 0: .systemFont(ofSize: 19, weight: .semibold)
        case 1: .systemFont(ofSize: 15, weight: .medium)
        default: .systemFont(ofSize: 14, weight: .regular)
        }
    }

    static func padding(depth: Int) -> EdgeInsets {
        switch depth {
        case 0: EdgeInsets(top: 11, leading: 22, bottom: 11, trailing: 22)
        case 1: EdgeInsets(top: 7, leading: 14, bottom: 7, trailing: 14)
        default: EdgeInsets(top: 3, leading: 6, bottom: 5, trailing: 6)
        }
    }

    static func maxTextWidth(depth: Int) -> CGFloat { depth == 0 ? 300 : 250 }

    /// The text shown for a topic: its inline Markdown rendered, wikilinks shown by their name.
    static func attributed(_ text: String) -> AttributedString {
        let links = text.replacingOccurrences(
            of: "\\[\\[([^\\]|]+)\\|([^\\]]+)\\]\\]", with: "$2", options: .regularExpression)
            .replacingOccurrences(of: "\\[\\[([^\\]]+)\\]\\]", with: "$1", options: .regularExpression)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: links, options: options)) ?? AttributedString(links)
    }

    static func plain(_ text: String) -> String { String(attributed(text).characters) }

    static func size(of text: String, depth: Int) -> CGSize {
        let shown = plain(text)
        let font = font(depth: depth)
        let bounds = (shown.isEmpty ? "Topic" : shown).boundingRect(
            with: CGSize(width: maxTextWidth(depth: depth), height: 10_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let padding = padding(depth: depth)
        let minWidth: CGFloat = depth == 0 ? 120 : 40
        return CGSize(
            width: max(ceil(bounds.width) + padding.leading + padding.trailing + 4, minWidth),
            height: ceil(bounds.height) + padding.top + padding.bottom
        )
    }

    /// Branch colours, in the order of the central topic's children.
    static let branchColors: [Color] = [
        Color(nsColor: .systemBlue), Color(nsColor: .systemPurple), Color(nsColor: .systemPink),
        Color(nsColor: .systemOrange), Color(nsColor: .systemGreen), Color(nsColor: .systemTeal),
        Color(nsColor: .systemRed), Color(nsColor: .systemYellow),
    ]

    static func color(branch: Int, accent: Color) -> Color {
        branch < 0 ? accent : branchColors[branch % branchColors.count]
    }
}
