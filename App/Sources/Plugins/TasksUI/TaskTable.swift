import AppKit
import PluginKitUI
import SwiftUI
import TasksPlugin

/// The task list's groups and rows in AppKit: a scroll view whose document places a header per group and a row per
/// task by hand, only the ones near the screen alive and reused as it scrolls.
///
/// A SwiftUI stack of rows built hundreds of views when the list opened (1.1 s for 665 tasks), and a lazy one still
/// took ~100 ms (docs/APPKIT.md).
struct TaskTable: NSViewRepresentable {
    let groups: [TaskBoard.Group]
    let collapsed: Set<String>
    let today: String
    let toggleGroup: (String) -> Void
    let toggle: (TaskItem) -> Void
    let open: (TaskItem) -> Void
    @Environment(\.themeTokens) private var theme

    func makeNSView(context: Context) -> TaskScrollView {
        let view = TaskScrollView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: TaskScrollView, context: Context) {
        view.document.update(TaskDocumentView.State(
            groups: groups, collapsed: collapsed, today: today, theme: theme,
            toggleGroup: toggleGroup, toggle: toggle, open: open
        ))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TaskScrollView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }
}

final class TaskScrollView: NSScrollView {
    let document = TaskDocumentView()

    init() {
        super.init(frame: .zero)
        drawsBackground = false
        contentView.drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        hasHorizontalScroller = false
        horizontalScrollElasticity = .none
        automaticallyAdjustsContentInsets = false
        documentView = document
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: contentView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var mouseDownCanMoveWindow: Bool { false }

    override func tile() {
        super.tile()
        document.widthChanged(contentView.bounds.width)
    }

    @objc private func scrolled() { document.showVisible(animated: false) }
}

final class TaskDocumentView: NSView {
    struct State {
        var groups: [TaskBoard.Group]
        var collapsed: Set<String>
        var today: String
        var theme: ThemeTokens
        var toggleGroup: (String) -> Void
        var toggle: (TaskItem) -> Void
        var open: (TaskItem) -> Void
    }

    /// A header or a row, where it goes.
    private enum Item: Hashable {
        case header(String)
        case row(String)
    }

    private var state: State?
    private var width: CGFloat = 0
    private var frames: [(item: Item, frame: CGRect)] = []
    private var groupsByID: [String: TaskBoard.Group] = [:]
    private var tasksByID: [String: (task: TaskItem, showsNote: Bool)] = [:]
    private var liveHeaders: [String: TaskGroupHeaderView] = [:]
    private var liveRows: [String: TaskRowView] = [:]
    private var headerPool: [TaskGroupHeaderView] = []
    private var rowPool: [TaskRowView] = []

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    func update(_ new: State) {
        let old = state
        state = new
        groupsByID = Dictionary(new.groups.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        tasksByID = [:]
        for group in new.groups {
            for task in group.tasks { tasksByID[task.id] = (task, group.notePath == nil) }
        }
        let changed = old.map { $0.groups != new.groups || $0.collapsed != new.collapsed } ?? false
        if old?.theme != new.theme {
            for view in Array(liveRows.values) + rowPool { view.theme = new.theme }
            for view in Array(liveHeaders.values) + headerPool { view.theme = new.theme }
        }
        relayout(animated: changed)
    }

    func widthChanged(_ newWidth: CGFloat) {
        guard newWidth != width else { return }
        width = newWidth
        relayout(animated: false)
    }

    /// The reading column (`pageColumn(.reading)`): at most 760 wide, with the page's side margin, centred.
    private var column: (x: CGFloat, width: CGFloat) {
        let inner = max(0, min(PageWidth.reading.maxWidth, width - 2 * PageMetrics.edge))
        return ((width - inner) / 2, inner)
    }

    static let headerHeight: CGFloat = Space.xl + 24 + Space.xs

    private func relayout(animated: Bool) {
        guard let state, width > 0 else { return }
        let (x, inner) = column
        var frames: [(Item, CGRect)] = []
        var y: CGFloat = 0
        for group in state.groups {
            frames.append((.header(group.id), CGRect(x: x, y: y, width: inner, height: Self.headerHeight)))
            y += Self.headerHeight
            guard !state.collapsed.contains(group.id) else { continue }
            for task in group.tasks {
                let height = TaskRowView.height(of: task, showsNote: group.notePath == nil)
                frames.append((.row(task.id), CGRect(x: x, y: y, width: inner, height: height)))
                y += height
            }
        }
        self.frames = frames
        let height = max(y + Space.xxl, superview?.bounds.height ?? 0)
        if frame.size != NSSize(width: width, height: height) { setFrameSize(NSSize(width: width, height: height)) }
        showVisible(animated: animated)
    }

    func showVisible(animated: Bool) {
        guard let state, let clip = enclosingScrollView?.contentView else { return }
        let visible = clip.bounds.insetBy(dx: 0, dy: -400)
        var wantedHeaders = Set<String>(), wantedRows = Set<String>()
        let animate = animated && !Motion.reduceMotion
        func place(_ view: NSView, _ frame: CGRect, isNew: Bool) {
            if isNew {
                view.frame = frame
                if animate {
                    view.alphaValue = 0
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = Motion.Spring.standard.duration
                        view.animator().alphaValue = 1
                    }
                }
            } else if view.frame != frame {
                if animate {
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = Motion.Spring.standard.duration
                        context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
                        view.animator().frame = frame
                    }
                } else {
                    view.frame = frame
                }
            }
        }
        for (item, frame) in frames where frame.intersects(visible) {
            switch item {
            case .header(let id):
                guard let group = groupsByID[id] else { continue }
                wantedHeaders.insert(id)
                let isNew = liveHeaders[id] == nil
                let view = liveHeaders[id] ?? headerPool.popLast() ?? {
                    let made = TaskGroupHeaderView()
                    addSubview(made)
                    return made
                }()
                view.theme = state.theme
                view.show(group, collapsed: state.collapsed.contains(id)) { [weak self] in self?.state?.toggleGroup(id) }
                view.isHidden = false
                liveHeaders[id] = view
                place(view, frame, isNew: isNew)
            case .row(let id):
                guard let entry = tasksByID[id] else { continue }
                wantedRows.insert(id)
                let isNew = liveRows[id] == nil
                let view = liveRows[id] ?? rowPool.popLast() ?? {
                    let made = TaskRowView()
                    addSubview(made)
                    return made
                }()
                view.theme = state.theme
                view.show(entry.task, today: state.today, showsNote: entry.showsNote,
                          toggle: { [weak self] in self?.state?.toggle(entry.task) },
                          open: { [weak self] in self?.state?.open(entry.task) })
                view.isHidden = false
                liveRows[id] = view
                place(view, frame, isNew: isNew)
            }
        }
        for (id, view) in liveHeaders where !wantedHeaders.contains(id) {
            liveHeaders[id] = nil
            view.isHidden = true
            headerPool.append(view)
        }
        for (id, view) in liveRows where !wantedRows.contains(id) {
            liveRows[id] = nil
            view.isHidden = true
            view.setHovered(false)
            rowPool.append(view)
        }
    }
}

// MARK: - Header

/// A group's header: a chevron that turns when the group folds, the note's icon for a note's group, the title in
/// bold (the accent for Overdue) and how many tasks it holds.
final class TaskGroupHeaderView: NSView {
    var theme: ThemeTokens = .standard { didSet { if theme != oldValue { refresh() } } }
    private var group: TaskBoard.Group?
    private var collapsed = false
    private var action: (() -> Void)?
    private let chevron = CALayer()
    private let label = CardTextView()

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        chevron.contentsGravity = .center
        layer?.addSublayer(chevron)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ group: TaskBoard.Group, collapsed: Bool, action: @escaping () -> Void) {
        let changed = group != self.group || collapsed != self.collapsed
        self.group = group
        self.action = action
        let turning = self.collapsed != collapsed
        self.collapsed = collapsed
        if changed { refresh(turning: turning) }
    }

    private var color: NSColor {
        guard let group else { return NSColor(theme.text) }
        if group.isOverdue { return NSColor(theme.accent) }
        return theme.palette.heading.map { NSColor(Color($0)) } ?? NSColor(theme.text)
    }

    private func refresh(turning: Bool = false) {
        guard let group else { return }
        let color = self.color
        let text = NSMutableAttributedString()
        if group.notePath != nil, let icon = tintedSymbol("doc.text", size: 12, weight: .medium, color: color) {
            let attachment = NSTextAttachment()
            attachment.image = icon
            attachment.bounds = CGRect(x: 0, y: -2, width: icon.size.width, height: icon.size.height)
            text.append(NSAttributedString(attachment: attachment))
            text.append(NSAttributedString(string: "  "))
        }
        text.append(NSAttributedString(string: group.title.uiLocalized, attributes: [
            .font: NSFont.ui(size: UIType.emphasis.size, weight: .bold), .kern: -0.15, .foregroundColor: color,
        ]))
        let count = NSFont.theme(theme.monoFamily, size: (UIType.body.size * 0.78).rounded(), weight: .medium)
        text.append(NSAttributedString(string: "  \(group.tasks.count)", attributes: [
            .font: count, .foregroundColor: NSColor(theme.marker), .kern: count.pointSize * 0.09,
        ]))
        label.attributed = text
        label.maxLines = 1
        setAccessibilityLabel("\(group.title.uiLocalized), \(group.tasks.count)")
        // An image's points are its pixels over the layer's scale: at 1 a Retina image showed twice its size.
        chevron.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        chevron.contents = tintedSymbol("chevron.down", size: UIType.caption.size, weight: .bold, color: color)
        // A folded group's chevron points right (the layer is flipped: a negative turn reads clockwise).
        let angle: CGFloat = collapsed ? -.pi / 2 : 0
        if turning, !Motion.reduceMotion {
            let turn = CASpringAnimation(perceptualDuration: Motion.Spring.smooth.duration, bounce: 0)
            turn.keyPath = "transform.rotation.z"
            turn.fromValue = collapsed ? 0 : -CGFloat.pi / 2
            turn.toValue = angle
            chevron.add(turn, forKey: "turn")
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chevron.setValue(angle, forKeyPath: "transform.rotation.z")
        CATransaction.commit()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // 24 points of room above, then the 24-point row with a 12-point inset, as the SwiftUI button had.
        let row = CGRect(x: 0, y: Space.xl, width: bounds.width, height: 24)
        chevron.frame = CGRect(x: Space.m, y: row.minY + 5, width: 14, height: 14)
        CATransaction.commit()
        let x = Space.m + 14 + 8
        let height = label.height(for: bounds.width - x - Space.m)
        label.frame = CGRect(x: x, y: row.midY - height / 2, width: bounds.width - x - Space.m, height: height)
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        if Motion.reduceMotion { action?() } else { Motion.with(Motion.Spring.smooth.animation) { action?() } }
    }

    override func mouseDown(with event: NSEvent) {}

    override func accessibilityPerformPress() -> Bool {
        action?()
        return true
    }
}

// MARK: - Row

/// A task on two lines, as Craft lists it: a round checkbox, the text (an icon first for a high priority), then
/// when it is due ("3 days late" in the accent), its note and its tags as capsules. The checkbox toggles the task,
/// a click on the rest opens its note on its line.
final class TaskRowView: NSView {
    var theme: ThemeTokens = .standard { didSet { if theme != oldValue { refresh() } } }
    private var task: TaskItem?
    private var today = ""
    private var showsNote = true
    private var toggle: (() -> Void)?
    private var open: (() -> Void)?
    private let box = TaskCheckBoxView()
    private let title = CardTextView()
    private let meta = TaskMetaView()
    private let hover = CALayer()
    private var tracking: NSTrackingArea?
    private var pressedBox = false

    static let boxSize: CGFloat = 22
    static let textX = Space.m + boxSize + Space.m

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        hover.opacity = 0
        hover.cornerCurve = .continuous
        layer?.addSublayer(hover)
        addSubview(box)
        addSubview(title)
        addSubview(meta)
        title.maxLines = 1
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static func hasMeta(_ task: TaskItem, showsNote: Bool) -> Bool { task.due != nil || showsNote || !task.tags.isEmpty }

    /// A row's height: 8 points above and below, a 22-point line, and the meta line 6 points under it.
    static func height(of task: TaskItem, showsNote: Bool) -> CGFloat {
        Space.s + 22 + (hasMeta(task, showsNote: showsNote) ? Space.xs + 2 + 22 : 0) + Space.s
    }

    func show(_ task: TaskItem, today: String, showsNote: Bool, toggle: @escaping () -> Void, open: @escaping () -> Void) {
        self.toggle = toggle
        self.open = open
        guard task != self.task || today != self.today || showsNote != self.showsNote else { return }
        let checking = self.task?.id == task.id && self.task?.done != task.done
        self.task = task
        self.today = today
        self.showsNote = showsNote
        refresh()
        box.setChecked(task.done, animated: checking)
    }

    private func refresh() {
        guard let task else { return }
        box.theme = theme
        let font = NSFont.ui(size: UIType.emphasis.size, weight: .medium)
        let color = task.done ? NSColor(theme.secondaryText) : NSColor(theme.text)
        let text = NSMutableAttributedString()
        if task.priority == .high, let icon = tintedSymbol("exclamationmark.2", size: 12, weight: .semibold, color: NSColor(theme.warning)) {
            let attachment = NSTextAttachment()
            attachment.image = icon
            attachment.bounds = CGRect(x: 0, y: -1, width: icon.size.width, height: icon.size.height)
            text.append(NSAttributedString(attachment: attachment))
            text.append(NSAttributedString(string: " "))
        }
        let body = NotePreviewText.inline(TaskBoard.displayText(task), font: font, color: color, theme: theme)
        body.addAttribute(.kern, value: -0.2, range: NSRange(location: 0, length: body.length))
        if task.done {
            body.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .strikethroughColor: NSColor(theme.secondaryText)],
                               range: NSRange(location: 0, length: body.length))
        }
        text.append(body)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
        title.attributed = text
        meta.show(task, today: today, showsNote: showsNote, theme: theme)
        meta.isHidden = !Self.hasMeta(task, showsNote: showsNote)
        hover.backgroundColor = NSColor(theme.fillHover).cgColor
        toolTip = "Open \(task.path), line \(task.line)"
        setAccessibilityLabel(task.text)
        setAccessibilityValue(task.done ? "done" : "not done")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hover.frame = bounds
        hover.cornerRadius = Radius.m
        CATransaction.commit()
        box.frame = CGRect(x: Space.m, y: Space.s - 1, width: Self.boxSize, height: Self.boxSize)
        let textWidth = max(0, bounds.width - Self.textX - Space.m)
        title.frame = CGRect(x: Self.textX, y: Space.s + 1, width: textWidth, height: 20)
        meta.frame = CGRect(x: Self.textX, y: Space.s + 22 + Space.xs + 2, width: textWidth, height: 22)
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        // Its own bounds: `.inVisibleRect` reaches past a view that does not clip (see `NativeCardView`).
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    func setHovered(_ hovered: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        hover.opacity = hovered ? 1 : 0
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pressedBox = box.frame.insetBy(dx: -4, dy: -4).contains(point)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        if pressedBox {
            toggle?()
        } else if point.x >= Self.textX {
            open?()
        }
    }

    override func accessibilityPerformPress() -> Bool {
        toggle?()
        return true
    }
}

/// The task's box, as the editor draws it: a rounded square or a circle (`tasks.checkbox`), ringed in the theme's
/// checkbox border, filled with a tick when done; the tick pops in.
final class TaskCheckBoxView: NSView {
    var theme: ThemeTokens = .standard { didSet { if theme != oldValue { draw() } } }
    private var checked = false
    private let ring = CAShapeLayer()
    private let fill = CAShapeLayer()
    private let tick = CALayer()

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(ring)
        layer?.addSublayer(fill)
        layer?.addSublayer(tick)
        ring.fillColor = nil
        tick.contentsGravity = .center
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setChecked(_ checked: Bool, animated: Bool) {
        self.checked = checked
        draw()
        guard animated, checked, !Motion.reduceMotion else { return }
        let pop = CASpringAnimation(perceptualDuration: Motion.Spring.pop.duration, bounce: Motion.Spring.pop.bounce)
        pop.keyPath = "transform.scale"
        pop.fromValue = 0.4
        pop.toValue = 1
        tick.add(pop, forKey: "pop")
    }

    override func layout() {
        super.layout()
        draw()
    }

    private func draw() {
        let size = bounds.width
        guard size > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let rect = bounds
        let path = theme.style.checkbox == .square
            ? CGPath(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerWidth: Corners.r(size * 0.36) - 1, cornerHeight: Corners.r(size * 0.36) - 1, transform: nil)
            : CGPath(ellipseIn: rect.insetBy(dx: 1, dy: 1), transform: nil)
        ring.frame = rect
        ring.path = path
        ring.lineWidth = 2
        ring.strokeColor = (theme.palette.checkboxBorder.map { NSColor(Color($0)) } ?? NSColor(theme.secondaryText).withAlphaComponent(0.6)).cgColor
        ring.opacity = checked ? 0 : 1
        fill.frame = rect
        fill.path = theme.style.checkbox == .square
            ? CGPath(roundedRect: rect, cornerWidth: Corners.r(size * 0.36), cornerHeight: Corners.r(size * 0.36), transform: nil)
            : CGPath(ellipseIn: rect, transform: nil)
        fill.fillColor = (theme.palette.checkbox.map { NSColor(Color($0)) } ?? NSColor(theme.accent)).cgColor
        fill.opacity = checked ? 1 : 0
        tick.frame = rect
        tick.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        tick.contents = tintedSymbol("checkmark", size: size * 0.55, weight: .bold, color: .white)
        tick.opacity = checked ? 1 : 0
        CATransaction.commit()
    }
}

/// A task's second line: when it is due, its note as a capsule and its tags as capsules, drawn once.
final class TaskMetaView: CachedDrawingView {
    private var task: TaskItem?
    private var today = ""
    private var showsNote = true
    private var theme: ThemeTokens = .standard

    func show(_ task: TaskItem, today: String, showsNote: Bool, theme: ThemeTokens) {
        self.task = task
        self.today = today
        self.showsNote = showsNote
        self.theme = theme
        invalidate()
    }

    override func drawContent(in bounds: CGRect) {
        guard let task else { return }
        var x: CGFloat = 0
        let height: CGFloat = 22
        if let due = task.due {
            let late = !task.done && due < today
            let size = (UIType.label.size * 0.78).rounded()
            let font = NSFont.theme(theme.monoFamily, size: size, weight: late ? .semibold : .medium)
            let text = NSAttributedString(string: dueText(due, task: task).uppercased(), attributes: [
                .font: font, .foregroundColor: late ? NSColor(theme.accent) : NSColor(theme.marker), .kern: size * 0.09,
            ])
            let measured = text.size()
            text.draw(at: NSPoint(x: x, y: (height - measured.height) / 2))
            x += measured.width + Space.s
        }
        if showsNote {
            let font = NSFont.ui(size: UIType.label.size, weight: .semibold)
            let color = NSColor(theme.secondaryText)
            let text = NSAttributedString(string: TaskBoard.noteTitle(task.path), attributes: [.font: font, .foregroundColor: color])
            let icon = tintedSymbol("doc", size: UIType.caption.size, weight: .semibold, color: color)
            let iconWidth = icon.map { $0.size.width + Space.xs } ?? 0
            let measured = text.size()
            let width = Space.s + iconWidth + measured.width + Space.s + 2
            capsule(CGRect(x: x, y: 0, width: width, height: height), NSColor(theme.fillSubtle))
            icon?.draw(in: CGRect(x: x + Space.s, y: (height - (icon?.size.height ?? 0)) / 2, width: icon?.size.width ?? 0, height: icon?.size.height ?? 0))
            text.draw(at: NSPoint(x: x + Space.s + iconWidth, y: (height - measured.height) / 2))
            x += width + Space.s
        }
        let tagColor = theme.palette.tagText.map { NSColor(Color($0)) } ?? NSColor(theme.accent)
        let tagFill = theme.palette.tagBackground.map { NSColor(Color($0)) } ?? NSColor(theme.accent).withAlphaComponent(0.12)
        for tag in task.tags {
            let text = NSAttributedString(string: tag, attributes: [.font: NSFont.ui(size: UIType.label.size, weight: .semibold), .foregroundColor: tagColor])
            let measured = text.size()
            let width = measured.width + 22
            guard x + width <= bounds.width else { break }
            capsule(CGRect(x: x, y: 0, width: width, height: height), tagFill)
            text.draw(at: NSPoint(x: x + 11, y: (height - measured.height) / 2))
            x += width + Space.s
        }
    }

    private func capsule(_ rect: CGRect, _ color: NSColor) {
        color.setFill()
        let radius = min(Corners.cap ?? rect.height / 2, rect.height / 2)
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }

    /// "Today", the day, or for a task not done in time how late it is.
    private func dueText(_ due: String, task: TaskItem) -> String {
        if due == today { return "Today" }
        if !task.done, due < today, let late = TaskBoard.daysBetween(due, today) {
            return late == 1 ? "Yesterday" : "\(late) days late"
        }
        return TaskBoard.dayTitle(due)
    }
}
