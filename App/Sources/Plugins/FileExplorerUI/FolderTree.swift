import AppKit
import PluginKitUI
import SwiftUI

/// The rows of "Folders" in AppKit: one view placed by hand per row near the screen, moved by Core Animation when
/// a folder opens or closes.
///
/// The SwiftUI rows (an `onHover`, a tap, a drag, a drop and a menu each) cost 70 ms a frame while a folder of 35
/// notes unfolded: SwiftUI laid the whole sidebar out and hit-tested every row for the hover at each step of the
/// slide (docs/APPKIT.md). Here a step costs nothing on the main thread: the rows' layers move on the render server.
struct FolderTree: NSViewRepresentable {
    let model: ExplorerModel
    let state: FolderTreeView.State

    func makeNSView(context: Context) -> FolderTreeView {
        let view = FolderTreeView(model: model)
        view.update(state, animated: false)
        return view
    }

    func updateNSView(_ view: FolderTreeView, context: Context) {
        view.update(state, animated: !context.transaction.disablesAnimations && context.transaction.animation != nil)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FolderTreeView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 200, height: CGFloat(state.rows.count) * SidebarStyle.rowHeight)
    }
}

/// What a row shows, read in the section's body so SwiftUI tracks what it depends on (the folders' styles, the
/// open folders, the selection).
struct FolderTreeRow: Equatable {
    enum Icon: Equatable {
        /// The default folder, which opens like Arc's (`AnimatedFolderIcon`), in the user's colour if any.
        case folder(custom: Color?)
        /// One of the sidebar's drawn icons (a plugin's folder, a note's view type).
        case glyph(String)
        /// A folder's icon the user picked, or a symbol without a drawn glyph.
        case folderIcon(FolderIcon)
        case symbol(String)
    }

    let path: String
    let depth: Int
    let title: String
    let kind: ExplorerModel.Kind
    let icon: Icon
    let isOpen: Bool

    var isFolder: Bool { kind == .folder }
    /// The symbol the drag's ghost shows.
    var dragSymbol: String {
        switch icon {
        case .folder, .folderIcon: "folder"
        case .glyph(let name), .symbol(let name): name
        }
    }

    @MainActor
    static func rows(_ rows: [ExplorerModel.Row], model: ExplorerModel) -> [FolderTreeRow] {
        rows.map { row in
            let item = row.item
            let open = model.expanded.contains(item.path)
            let icon: Icon
            if item.kind == .folder {
                switch model.icon(forFolder: item.path, open: open) {
                case .symbol(let name) where name.hasPrefix("folder"):
                    icon = .folder(custom: FolderTint.custom(for: item.path))
                case .symbol(let name) where SidebarGlyph.named(for: name) != nil:
                    icon = .glyph(name)
                case let other:
                    icon = .folderIcon(other)
                }
            } else {
                let symbol = item.kind == .note ? model.symbol(forNote: item.path) : model.symbol(forFile: item.path)
                icon = SidebarGlyph.named(for: symbol) != nil ? .glyph(symbol) : .symbol(symbol)
            }
            return FolderTreeRow(path: item.path, depth: row.depth, title: model.title(of: item), kind: item.kind,
                                 icon: icon, isOpen: open)
        }
    }
}

final class FolderTreeView: NSView {
    struct State: Equatable {
        var rows: [FolderTreeRow]
        var selected: String?
        var renaming: String?
        var stylingFolder: String?
        /// The place of each row in the folder opened last, for its cascade.
        var cascade: [String: Int]
        var theme: ThemeTokens
    }

    static let dragType = NSPasteboard.PasteboardType(DragPayload.type.identifier)

    let model: ExplorerModel
    private(set) var state: State?
    private var frames: [String: CGRect] = [:]
    private var order: [String] = []
    private var rowsByPath: [String: FolderTreeRow] = [:]
    private var live: [String: FolderRowView] = [:]
    private var pool: [FolderRowView] = []
    private weak var observedClip: NSClipView?
    /// The row a drag is over, and the folder it would drop into.
    private var targeted: String?
    /// Where a drag near a row's top or bottom edge would put the item: beside that row, shown by a line.
    private var insertion: (path: String, after: Bool)?
    private let insertionLine = CALayer()
    private var holdOpen: Task<Void, Never>?
    private var popover: NSPopover?
    /// The pointer, tracked by the tree rather than by each row: a row that slid or scrolled away under a still
    /// pointer never heard it leave, and kept its tint.
    private var hoverTracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    init(model: ExplorerModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        insertionLine.isHidden = true
        insertionLine.cornerRadius = 1
        insertionLine.zPosition = 10
        insertionLine.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
        layer?.addSublayer(insertionLine)
        registerForDraggedTypes([Self.dragType])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: Updating

    func update(_ new: State, animated: Bool) {
        let old = state
        guard old != new else { return }
        state = new
        rowsByPath = Dictionary(new.rows.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        order = new.rows.map(\.path)
        var frames: [String: CGRect] = [:]
        for (index, row) in new.rows.enumerated() {
            frames[row.path] = CGRect(x: 0, y: CGFloat(index) * SidebarStyle.rowHeight, width: bounds.width,
                                      height: SidebarStyle.rowHeight)
        }
        self.frames = frames
        if old?.theme != new.theme { for view in Array(live.values) + pool { view.theme = new.theme } }
        let moved = old.map { $0.rows.map(\.path) != new.rows.map(\.path) } ?? false
        place(animated: animated && moved)
        showStyling()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        guard widthChanged else { return }
        for key in frames.keys { frames[key]?.size.width = newSize.width }
        place(animated: false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeScrolling()
        place(animated: false)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        observeScrolling()
    }

    /// Rows are made only near the sidebar's visible part, so a folder of a thousand notes opens as fast as one of
    /// ten: the rest come as the sidebar scrolls.
    private func observeScrolling() {
        guard let clip = enclosingScrollView?.contentView, clip !== observedClip else { return }
        if let observedClip {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: observedClip)
        }
        observedClip = clip
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: clip)
    }

    @objc private func scrolled() { place(animated: false) }

    /// The part of the tree to fill with rows: the visible part with a screen of margin.
    private var wantedRect: CGRect {
        guard let clip = enclosingScrollView?.contentView else { return bounds.insetBy(dx: 0, dy: -2000) }
        let visible = convert(clip.bounds, from: clip)
        return visible.insetBy(dx: -50, dy: -max(600, visible.height))
    }

    private func place(animated: Bool) {
        guard let state else { return }
        let wanted = wantedRect
        let animate = animated && window != nil
        let reduce = Motion.reduceMotion
        var kept = Set<String>()
        for path in order {
            guard let frame = frames[path], let row = rowsByPath[path] else { continue }
            let near = frame.intersects(wanted)
            if !near, live[path] == nil { continue }
            kept.insert(path)
            let isNew = live[path] == nil
            let view = live[path] ?? dequeue()
            live[path] = view
            view.theme = state.theme
            view.show(row, selected: state.selected == path, renaming: state.renaming == path,
                      targeted: targeted == path, animated: animate)
            if isNew {
                view.setFrame(frame)
                if animate {
                    if let index = state.cascade[path] {
                        view.enter(delay: Motion.stagger(index: index, reduceMotion: reduce), reduceMotion: reduce)
                    } else {
                        view.fadeIn()
                    }
                }
            } else if view.frame.origin != frame.origin || view.frame.size != frame.size {
                if animate { view.slide(to: frame, reduceMotion: reduce) } else { view.setFrame(frame) }
            }
            if !near, !animate { kept.remove(path) }
        }
        for (path, view) in live where !kept.contains(path) {
            live[path] = nil
            if animate, rowsByPath[path] == nil {
                view.leave { [weak self, weak view] in
                    guard let self, let view, !self.live.values.contains(where: { $0 === view }) else { return }
                    self.recycle(view)
                }
            } else {
                recycle(view)
            }
        }
        if let renaming = state.renaming, let view = live[renaming] { view.focusRename() }
        updateHover()
    }

    private func dequeue() -> FolderRowView {
        if let view = pool.popLast() {
            view.isHidden = false
            return view
        }
        let view = FolderRowView(tree: self)
        addSubview(view)
        return view
    }

    private func recycle(_ view: FolderRowView) {
        view.reset()
        view.isHidden = true
        pool.append(view)
    }

    /// The row under `point` (in this view), from the frames: rows not made yet count too.
    private func path(at point: NSPoint) -> String? {
        guard point.y >= 0 else { return nil }
        let index = Int(point.y / SidebarStyle.rowHeight)
        return order.indices.contains(index) ? order[index] : nil
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) { updateHover(event.locationInWindow) }
    override func mouseMoved(with event: NSEvent) { updateHover(event.locationInWindow) }
    override func mouseExited(with event: NSEvent) { setHovered(nil) }

    /// The row under the pointer (`location`, in the window; nil: where it is now): after it moves, and after the
    /// rows move under it.
    private func updateHover(_ location: NSPoint? = nil) {
        guard let window else { return setHovered(nil) }
        let point = convert(location ?? window.mouseLocationOutsideOfEventStream, from: nil)
        let visible = enclosingScrollView.map { convert($0.contentView.bounds, from: $0.contentView) } ?? bounds
        let inside = visible.intersection(bounds).contains(point) && window.isVisible
        setHovered(inside ? path(at: point) : nil)
    }

    private func setHovered(_ path: String?) {
        for (rowPath, view) in live { view.setHovered(rowPath == path) }
    }

    // MARK: The style popover

    /// "Icon & Color…" opens a popover beside the folder's icon while `stylingFolder` names it.
    private func showStyling() {
        guard let state else { return }
        guard let path = state.stylingFolder, let view = live[path] else {
            if let popover, popover.isShown { popover.performClose(nil) }
            return
        }
        if let popover, popover.isShown { return }
        let picker = FolderStylePicker(model: model, path: path).environment(\.themeTokens, state.theme)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: picker)
        popover.delegate = self
        self.popover = popover
        popover.show(relativeTo: view.iconFrame, of: view, preferredEdge: .maxX)
    }

    // MARK: Dropping

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.availableType(from: [Self.dragType]) != nil else { return [] }
        let point = convert(sender.draggingLocation, from: nil)
        let beside = insertion(at: point, dragged: draggedPath(sender))
        setInsertion(beside)
        setTargeted(beside == nil ? path(at: point) : nil)
        return .move
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        setTargeted(nil)
        setInsertion(nil)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        setTargeted(nil)
        setInsertion(nil)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let point = convert(sender.draggingLocation, from: nil)
        let target = path(at: point)
        let beside = insertion(at: point, dragged: draggedPath(sender))
        setTargeted(nil)
        setInsertion(nil)
        guard let string = sender.draggingPasteboard.string(forType: Self.dragType),
              let payload = DragPayload(string: string) else { return false }
        defer { DragSession.shared.end() }
        if let beside, case .resource(let resource) = payload {
            model.place(resource.path, beside: beside.path, after: beside.after)
            return true
        }
        guard let target, let row = rowsByPath[target] else { return false }
        model.drop(payload, into: row.isFolder ? row.path : VaultPath.directory(of: row.path))
        return true
    }

    /// The vault path being dragged, when it is a file or a folder.
    private func draggedPath(_ sender: any NSDraggingInfo) -> String? {
        guard let string = sender.draggingPasteboard.string(forType: Self.dragType),
              case .resource(let resource)? = DragPayload(string: string), resource.kind != .virtual else { return nil }
        return resource.path
    }

    /// The edge of a row the pointer is near, where a drop puts the item beside that row rather than in it: the top
    /// or bottom quarter of a folder (an open folder's bottom is its first child's top), the top or bottom half of a
    /// note. Nil over a folder's middle, or for a row inside the item dragged.
    private func insertion(at point: NSPoint, dragged: String?) -> (path: String, after: Bool)? {
        guard let dragged, let path = path(at: point), let row = rowsByPath[path],
              path != dragged, !path.hasPrefix(dragged + "/") else { return nil }
        let y = point.y.truncatingRemainder(dividingBy: SidebarStyle.rowHeight) / SidebarStyle.rowHeight
        if !row.isFolder { return (path, y >= 0.5) }
        if y < 0.25 { return (path, false) }
        if y > 0.75, !row.isOpen { return (path, true) }
        return nil
    }

    private func setInsertion(_ new: (path: String, after: Bool)?) {
        guard new?.path != insertion?.path || new?.after != insertion?.after else { return }
        insertion = new
        guard let new, let index = order.firstIndex(of: new.path), let row = rowsByPath[new.path] else {
            insertionLine.isHidden = true
            return
        }
        if let theme = state?.theme { insertionLine.backgroundColor = NSColor(theme.accent).cgColor }
        let x = SidebarStyle.rowPadding + CGFloat(row.depth) * (SidebarStyle.iconSize + SidebarStyle.iconGap)
        let y = CGFloat(index + (new.after ? 1 : 0)) * SidebarStyle.rowHeight
        insertionLine.frame = CGRect(x: x, y: y - 1, width: max(0, bounds.width - x - SidebarStyle.rowPadding), height: 2)
        insertionLine.isHidden = false
        Haptics.alignment()
    }

    /// The row a drag hovers takes the drop's look; a closed folder held under it opens after a moment, as in Finder,
    /// so a note can go deeper.
    private func setTargeted(_ path: String?) {
        guard path != targeted else { return }
        let old = targeted
        targeted = path
        holdOpen?.cancel()
        for changed in [old, path].compactMap({ $0 }) {
            guard let view = live[changed], let row = rowsByPath[changed], let state else { continue }
            view.show(row, selected: state.selected == changed, renaming: state.renaming == changed,
                      targeted: targeted == changed, animated: true)
        }
        guard let path, let row = rowsByPath[path], row.isFolder else { return }
        Haptics.alignment()
        holdOpen = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self, !Task.isCancelled, self.targeted == path, !self.model.expanded.contains(path) else { return }
            self.model.toggle(path)
        }
    }

    // MARK: The menu

    func menu(for row: FolderTreeRow) -> NSMenu {
        let model = model
        let path = row.path
        let folder = row.isFolder ? path : VaultPath.directory(of: path)
        let resource: Resource = row.isFolder ? .folder(path) : .file(path)
        let menu = NSMenu()
        menu.addItem(ActionMenuItem("New Note") { model.newNote(in: folder) })
        for item in model.newItems() {
            menu.addItem(ActionMenuItem(item.title, symbol: item.symbol, localized: false) {
                item.create(ExplorerModel.newNoteFolder(folder))
            })
        }
        menu.addItem(ActionMenuItem("New Folder") { model.newFolder(in: folder) })
        menu.addItem(.separator())
        if row.isFolder {
            menu.addItem(ActionMenuItem("Icon & Color…") { model.stylingFolder = path })
        }
        menu.addItem(ActionMenuItem(model.isFavorite(path) ? "Remove from Favorites" : "Add to Favorites") {
            model.toggleFavorite(path)
        })
        let actions = model.actions(resource)
        if !actions.isEmpty {
            menu.addItem(.separator())
            for action in actions {
                menu.addItem(ActionMenuItem(action.title, symbol: action.symbol, localized: false) { action.perform(resource) })
            }
        }
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Rename") { model.beginRename(path) })
        menu.addItem(ActionMenuItem("Move to…") { model.askMove(path) })
        menu.addItem(ActionMenuItem("Reveal in Finder") { model.revealInFinder(path) })
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Delete…") { model.requestDelete(path) })
        return menu
    }
}

extension FolderTreeView: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover, popover === self.popover else { return }
        self.popover = nil
        if let path = state?.stylingFolder, model.stylingFolder == path { model.stylingFolder = nil }
    }
}

/// A menu item that runs a closure.
final class ActionMenuItem: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, symbol: String? = nil, localized: Bool = true, run: @escaping () -> Void) {
        self.run = run
        super.init(title: localized ? title.uiLocalized : title, action: #selector(runAction), keyEquivalent: "")
        target = self
        if let symbol { image = NSImage.symbol(symbol, accessibilityDescription: nil) }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func runAction() { run() }
}

// MARK: - Row

/// A row of the tree: a folder (its icon opening with it, a chevron at the end), a note or an attachment, indented
/// by its depth. Looks as `sidebarRow` draws the SwiftUI rows: a capsule tinted under the pointer, the accent pill
/// when selected, a dashed outline and a "+" under a drop.
final class FolderRowView: NSView, NSDraggingSource, NSTextFieldDelegate {
    var theme: ThemeTokens = .standard { didSet { if theme != oldValue { refresh(animated: false) } } }
    private unowned let tree: FolderTreeView
    private var row: FolderTreeRow?
    private var selected = false
    private var renaming = false
    private var targeted = false
    private var hovered = false
    private var mouseDownEvent: NSEvent?

    private let fill = CALayer()
    private let pill = CALayer()
    private let dash = CAShapeLayer()
    private let plus = CALayer()
    private let chevron = CALayer()
    private let iconBox = NSView()
    private var folderGlyph: FolderGlyphView?
    private var drawnGlyph: (name: String, view: SidebarGlyphView)?
    private let iconImage = CALayer()
    private let title = NSTextField(labelWithString: "")
    private var field: NSTextField?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(tree: FolderTreeView) {
        self.tree = tree
        super.init(frame: CGRect(x: 0, y: 0, width: 200, height: SidebarStyle.rowHeight))
        wantsLayer = true
        layer?.masksToBounds = false
        for layer in [fill, pill, dash, plus, chevron, iconImage] {
            layer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        }
        fill.cornerCurve = .continuous
        pill.contentsGravity = .resize
        pill.isHidden = true
        dash.fillColor = nil
        dash.lineWidth = 1
        dash.lineDashPattern = [4, 3]
        dash.opacity = 0
        plus.contentsGravity = .center
        plus.opacity = 0
        chevron.contentsGravity = .center
        chevron.opacity = 0
        iconImage.contentsGravity = .center
        layer?.addSublayer(pill)
        layer?.addSublayer(fill)
        layer?.addSublayer(dash)
        iconBox.wantsLayer = true
        iconBox.layer?.masksToBounds = false
        iconBox.layer?.addSublayer(iconImage)
        addSubview(iconBox)
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.cell?.truncatesLastVisibleLine = true
        addSubview(title)
        layer?.addSublayer(chevron)
        layer?.addSublayer(plus)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Content

    func show(_ row: FolderTreeRow, selected: Bool, renaming: Bool, targeted: Bool, animated: Bool) {
        let changed = row != self.row || selected != self.selected || targeted != self.targeted || renaming != self.renaming
        guard changed else { return }
        let opening = self.row?.path == row.path && self.row?.isOpen != row.isOpen
        self.row = row
        self.selected = selected
        self.targeted = targeted
        self.renaming = renaming
        refresh(animated: animated, turning: opening)
    }

    func reset() {
        row = nil
        hovered = false
        mouseDownEvent = nil
        layer?.removeAllAnimations()
        alphaValue = 1
        endRename()
    }

    private var onAccent: Bool { selected && !targeted }

    private func refresh(animated: Bool, turning: Bool = false) {
        guard let row else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        for layer in [pill, plus, chevron, iconImage] { layer.contentsScale = scale }
        setAccessibilityLabel(row.title)

        title.isHidden = renaming
        title.font = NSFont.ui(size: SidebarStyle.fontSize, weight: selected ? .bold : .medium)
        title.textColor = onAccent ? NSColor(theme.onAccent) : NSColor(theme.text).withAlphaComponent(SidebarStyle.titleOpacity)
        title.stringValue = row.title
        if renaming { beginRename() } else { endRename() }

        let accessory = NSColor(theme.sidebarAccessory(selected: onAccent))
        let chevronImage = tintedSymbol("chevron.right", size: 11, weight: .semibold, color: accessory.withAlphaComponent(accessory.alphaComponent * 0.6))
        chevron.contents = row.isFolder ? chevronImage : nil
        plus.contents = tintedSymbol("plus", size: 11, weight: .semibold, color: NSColor(theme.accent))
        dash.strokeColor = NSColor(theme.accent).withAlphaComponent(0.7).cgColor
        refreshIcon(animated: animated)
        refreshGround(animated: animated)
        refreshChevron(turning: turning && animated)
        needsLayout = true
    }

    private func refreshGround(animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.12)
        let color: NSColor = if targeted {
            NSColor(theme.accent).withAlphaComponent(0.14)
        } else if selected {
            NSColor(theme.text).withAlphaComponent(SidebarStyle.selectedOpacity)
        } else if hovered {
            NSColor(theme.accent).withAlphaComponent(0.08)
        } else {
            .clear
        }
        fill.backgroundColor = onAccent ? NSColor.clear.cgColor : color.cgColor
        dash.opacity = targeted ? 1 : 0
        plus.opacity = targeted ? 1 : 0
        CATransaction.commit()
        pill.isHidden = !onAccent
        if onAccent { pill.contents = SidebarPillImage.image(size: bounds.size, theme: theme, scale: pill.contentsScale) }
    }

    private func refreshChevron(turning: Bool) {
        guard let row, row.isFolder else { return }
        let angle: CGFloat = row.isOpen ? .pi / 2 : 0
        if turning, !Motion.reduceMotion {
            let turn = CASpringAnimation(perceptualDuration: Motion.Spring.tap.duration, bounce: 0)
            turn.keyPath = "transform.rotation.z"
            turn.fromValue = row.isOpen ? 0 : CGFloat.pi / 2
            turn.toValue = angle
            chevron.add(turn, forKey: "turn")
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chevron.setValue(angle, forKeyPath: "transform.rotation.z")
        CATransaction.commit()
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        chevron.opacity = hovered || row.isOpen ? 1 : 0
        CATransaction.commit()
    }

    /// The icon, as `TreeRow` chose it: the opening folder, a drawn glyph, the user's symbol or emoji, or a symbol.
    private func refreshIcon(animated: Bool) {
        guard let row else { return }
        let ground: NSColor = onAccent ? NSColor(theme.accent)
            : theme.palette.sidebar.map { NSColor(Color($0)) } ?? .windowBackgroundColor
        let animate = animated && !Motion.reduceMotion
        var usesFolder = false, usesGlyph = false
        iconImage.contents = nil
        iconImage.transform = CATransform3DIdentity
        switch row.icon {
        case .folder(let custom):
            usesFolder = true
            let glyph = folderGlyph ?? {
                let made = FolderGlyphView()
                iconBox.addSubview(made)
                folderGlyph = made
                return made
            }()
            let ink: NSColor = onAccent ? NSColor(theme.onAccent).withAlphaComponent(0.9)
                : custom.map { NSColor($0) } ?? NSColor(theme.sidebarAccessory(selected: false))
            let pose: AnimatedFolderIcon.Pose = row.isOpen ? .open : hovered || targeted ? .peek : .closed
            glyph.apply(pose: pose, color: ink, ground: ground, animated: animate)
        case .glyph(let name):
            usesGlyph = true
            if drawnGlyph?.name != name, let glyph = SidebarGlyph.named(for: name) {
                drawnGlyph?.view.removeFromSuperview()
                let view = SidebarGlyphView(glyph: glyph)
                iconBox.addSubview(view)
                drawnGlyph = (name, view)
            }
            let active = row.isFolder ? row.isOpen || selected : selected
            let ink = row.isFolder && !onAccent ? NSColor(theme.sidebarAccessory(selected: false))
                : NSColor(theme.sidebarAccessory(selected: onAccent))
            drawnGlyph?.view.apply(amount: active ? 1 : hovered ? SidebarGlyph.peek : 0, color: ink, ground: ground,
                                   animated: animate)
        case .folderIcon(.symbol(let name)):
            let color = onAccent ? NSColor(theme.onAccent).withAlphaComponent(0.9) : NSColor(theme.secondaryText)
            iconImage.contents = tintedSymbol(name, size: SidebarStyle.fontSize, weight: selected ? .bold : .medium, color: color)
        case .folderIcon(.emoji(let emoji)):
            if let printed = ThemedEmoji.printed(emoji, size: SidebarStyle.fontSize, theme: theme) {
                iconImage.contents = onAccent ? Self.tinted(printed, NSColor(theme.onAccent)) : printed
                iconImage.magnificationFilter = .nearest
            }
        case .symbol(let name):
            let color = NSColor(theme.sidebarAccessory(selected: onAccent))
            iconImage.contents = tintedSymbol(name, size: SidebarStyle.fontSize, weight: selected ? .bold : .medium, color: color)
            // The glyphs' gesture, for a symbol with none: a small lift, all of it when open.
            let amount: CGFloat = Motion.reduceMotion ? 0 : selected ? 1 : hovered ? SidebarGlyph.peek : 0
            CATransaction.begin()
            CATransaction.setDisableActions(!animate)
            CATransaction.setAnimationDuration(0.25)
            var lift = CATransform3DMakeTranslation(0, -SidebarGlyph.travel * 0.5 * amount, 0)
            lift = CATransform3DScale(lift, 1 + 0.08 * amount, 1 + 0.08 * amount, 1)
            iconImage.transform = lift
            CATransaction.commit()
        }
        folderGlyph?.isHidden = !usesFolder
        drawnGlyph?.view.isHidden = !usesGlyph
    }

    private static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    // MARK: Layout

    var iconFrame: CGRect {
        let depth = CGFloat(row?.depth ?? 0)
        let x = SidebarStyle.rowPadding + depth * (SidebarStyle.iconSize + SidebarStyle.iconGap)
        return CGRect(x: x, y: (bounds.height - SidebarStyle.iconSize) / 2, width: SidebarStyle.iconSize, height: SidebarStyle.iconSize)
    }

    func setFrame(_ frame: CGRect) {
        layer?.removeAnimation(forKey: "slide")
        self.frame = frame
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let radius = Corners.pill ? bounds.height / 2 : min(SidebarStyle.radius, bounds.height / 2)
        fill.frame = bounds
        fill.cornerRadius = radius
        let margin = SidebarPillImage.margin
        pill.frame = bounds.insetBy(dx: -margin, dy: -margin)
        if !pill.isHidden { pill.contents = SidebarPillImage.image(size: bounds.size, theme: theme, scale: pill.contentsScale) }
        dash.frame = bounds
        dash.path = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius - 0.5, cornerHeight: radius - 0.5, transform: nil)
        let icon = iconFrame
        iconBox.frame = icon
        iconImage.frame = iconBox.bounds
        if let folderGlyph {
            let size = CGSize(width: 12.3 * SidebarStyle.iconScale, height: 10.4 * SidebarStyle.iconScale)
            folderGlyph.frame = CGRect(x: (icon.width - size.width) / 2, y: (icon.height - size.height) / 2,
                                       width: size.width, height: size.height)
        }
        drawnGlyph?.view.frame = iconBox.bounds
        let end = bounds.width - SidebarStyle.rowPadding
        chevron.frame = CGRect(x: end - 10, y: (bounds.height - 14) / 2, width: 10, height: 14)
        plus.frame = CGRect(x: end - 12, y: (bounds.height - 14) / 2, width: 12, height: 14)
        CATransaction.commit()
        let textX = icon.maxX + SidebarStyle.iconGap
        let textEnd = (row?.isFolder == true ? end - 10 - SidebarStyle.iconGap : end)
        let height = title.intrinsicContentSize.height
        // A label's cell draws its text 2 points in from its frame.
        title.frame = CGRect(x: textX - 2, y: (bounds.height - height) / 2, width: max(0, textEnd - textX + 2), height: height)
        if let field {
            let fieldHeight = field.intrinsicContentSize.height
            field.frame = CGRect(x: textX - 3, y: (bounds.height - fieldHeight) / 2, width: max(0, end - textX + 3), height: fieldHeight)
        }
    }

    // MARK: Motion

    /// A child of the folder just opened: slides down a few points from under it and fades in, after the ones above.
    func enter(delay: Double, reduceMotion: Bool) {
        guard let layer else { return }
        let begin = CACurrentMediaTime() + delay
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = reduceMotion ? 0.12 : Motion.Spring.smooth.duration * 0.6
        fade.beginTime = begin
        fade.fillMode = .backwards
        layer.add(fade, forKey: "enterFade")
        guard !reduceMotion else { return }
        let spring = CASpringAnimation(perceptualDuration: Motion.Spring.smooth.duration, bounce: 0)
        spring.keyPath = "sublayerTransform"
        spring.fromValue = CATransform3DMakeTranslation(0, -4, 0)
        spring.toValue = CATransform3DIdentity
        spring.beginTime = begin
        spring.fillMode = .backwards
        layer.add(spring, forKey: "enterMove")
    }

    func fadeIn() {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.12
        layer?.add(fade, forKey: "enterFade")
    }

    /// A row moving to its new place: the rows below a folder that opens or closes.
    func slide(to frame: CGRect, reduceMotion: Bool) {
        guard let layer else { return }
        let from = layer.presentation()?.position ?? layer.position
        self.frame = frame
        guard !reduceMotion else { return }
        let to = layer.position
        let spring = CASpringAnimation(perceptualDuration: Motion.Spring.smooth.duration, bounce: 0)
        spring.keyPath = "position"
        spring.fromValue = from
        spring.toValue = to
        layer.add(spring, forKey: "slide")
    }

    /// A row going away with its folder closing: a quick fade, while the rows below slide up.
    func leave(completion: @escaping () -> Void) {
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer?.presentation()?.opacity ?? 1
        fade.toValue = 0
        fade.duration = 0.12
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        layer?.add(fade, forKey: "leave")
        CATransaction.commit()
    }

    // MARK: Pointer

    /// Set by the tree, which tracks the pointer for every row.
    func setHovered(_ value: Bool) {
        guard value != hovered else { return }
        hovered = value
        refreshGround(animated: true)
        refreshChevron(turning: false)
        refreshIcon(animated: true)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownEvent, let row, !renaming else { return }
        let a = start.locationInWindow, b = event.locationInWindow
        guard hypot(b.x - a.x, b.y - a.y) > 4 else { return }
        mouseDownEvent = nil
        let resource: Resource = row.isFolder ? .folder(row.path) : .file(row.path)
        let item = NSPasteboardItem()
        item.setData(Data(DragPayload.resource(resource).string.utf8), forType: FolderTreeView.dragType)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        // What follows the pointer is the shell's ghost (`DragGhost`); AppKit's own image is a single clear pixel.
        let point = convert(a, from: nil)
        dragging.setDraggingFrame(NSRect(x: point.x, y: point.y, width: 1, height: 1), contents: NSImage(size: NSSize(width: 1, height: 1)))
        DragSession.shared.begin(.resource(resource), symbol: row.isFolder ? "folder" : row.dragSymbol)
        beginDraggingSession(with: [dragging], event: start, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownEvent = nil }
        guard mouseDownEvent != nil, !renaming, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        click(newTab: event.modifierFlags.contains(.command))
    }

    private func click(newTab: Bool) {
        guard let row, let item = itemOf(row) else { return }
        tree.model.click(item, newTab: newTab)
    }

    /// The model's item for the row: the model acts on items.
    private func itemOf(_ row: FolderTreeRow) -> ExplorerModel.Item? {
        tree.model.folderRows.first { $0.item.path == row.path }?.item
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        row.map { tree.menu(for: $0) }
    }

    override func accessibilityPerformPress() -> Bool {
        click(newTab: false)
        return true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.copy, .move, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        DragSession.shared.end()
    }

    // MARK: Renaming

    private func beginRename() {
        guard field == nil else { return }
        let field = NSTextField(string: tree.model.renameText)
        field.bezelStyle = .roundedBezel
        field.font = NSFont.ui(size: SidebarStyle.fontSize, weight: .medium)
        field.placeholderString = "Name".uiLocalized
        field.delegate = self
        field.focusRingType = .default
        addSubview(field)
        self.field = field
        needsLayout = true
    }

    /// Puts the cursor in the name field once the row is on screen; the sidebar scrolls to it (a new folder may land
    /// below the fold).
    func focusRename() {
        guard let field, window != nil, window?.firstResponder !== field.currentEditor() else { return }
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        scrollToVisible(bounds)
    }

    private func endRename() {
        guard let field else { return }
        self.field = nil
        field.delegate = nil
        field.removeFromSuperview()
    }

    func controlTextDidChange(_ notification: Notification) {
        if let field { tree.model.renameText = field.stringValue }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            tree.model.commitRename()
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            tree.model.cancelRename()
            return true
        }
        return false
    }

    /// Leaving the field (a click in the page, another window) keeps the name, as Finder does.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let row, tree.model.renaming == row.path else { return }
        tree.model.commitRename()
    }
}
