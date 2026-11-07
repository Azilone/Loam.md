#if DEBUG || LOAM_AGENT_BRIDGE
import AppKit
import Carbon
import DebugProtocol
import Foundation
import PluginKit
import PluginKitUI

/// Carries out the debug channel's commands inside this process: synthesised events delivered straight to this
/// instance's own window (so it needs neither the keyboard focus nor the screen), window pictures drawn from the
/// views, and reads of the accessibility tree and the editor. Everything takes its coordinates in points from the
/// top-left corner of the window's content.
@MainActor
final class DebugDriver {
    let instance: DebugInstance
    private let settings: SettingsNavigation
    private let session: @MainActor () -> ShellSession?
    /// The pressed pointer, between `press` and `release`.
    private var pointer: NSPoint?
    private var eventNumber = 5000

    init(instance: DebugInstance, settings: SettingsNavigation, session: @escaping @MainActor () -> ShellSession?) {
        self.instance = instance
        self.settings = settings
        self.session = session
    }

    // MARK: Dispatch

    func handle(_ request: DebugRequest) async -> DebugResponse {
        if let window = try? mainWindow() { FrameMeter.startIfAsked(in: window) }
        do {
            let command = try DebugCommand(request: request)
            return .success(try await run(command, request: request), id: request.id)
        } catch {
            return .failure(String(describing: error), id: request.id)
        }
    }

    private func run(_ command: DebugCommand, request: DebugRequest) async throws -> DebugValue? {
        switch command {
        case .help:
            return .array(DebugCommand.names.map { .string($0) })
        case .ping:
            return ["pong": true, "pid": .number(Double(getpid()))]
        case .info:
            return info()
        case .open(let path, let placement):
            return try await open(path, placement: placement)
        case .type(let text):
            let window = try mainWindow()
            for character in text {
                if character == "\n" { try key("return", in: window) } else { try send(characters: String(character), keyCode: 0, flags: [], in: window) }
            }
            return try await settled(["typed": .number(Double(text.count))])
        case .key(let shortcut, let repeats):
            // As a keyboard: to the window on top when the notebook is put away (the intro over the desktop).
            let main = try mainWindow()
            let window = main.isVisible ? main : (try? self.window(named: "top")) ?? main
            for _ in 0..<repeats { try key(shortcut, in: window) }
            return try await settled(["key": .string(shortcut)])
        case .click(let target, let clicks, let modifiers, let name):
            let window = try window(named: name)
            // An inactive app's window is not key, and a text view ignores the click that would only make it key.
            if !window.isKeyWindow { window.makeKey() }
            let point = try resolve(target, in: window)
            click(at: point, clicks: clicks, flags: flags(modifiers), in: window)
            return try await settled(["x": .number(point.x), "y": .number(point.y)])
        case .hover(let target):
            let window = try mainWindow()
            let point = try resolve(target, in: window)
            await hover(at: point, in: window)
            return try await settled(["x": .number(point.x), "y": .number(point.y)])
        case .drag(let from, let to):
            let window = try mainWindow()
            await drag(from: try resolve(from, in: window), to: try resolve(to, in: window), in: window)
            return try await settled(nil, ms: 300)
        case .press(let target):
            let window = try mainWindow()
            let point = try resolve(target, in: window)
            pointer = point
            FrameMeter.mark("press")
            deliver(mouse(.leftMouseDown, at: point, in: window), in: window)
            return try await settled(nil)
        case .move(let target):
            let window = try mainWindow()
            let end = try resolve(target, in: window)
            guard let start = pointer else { throw DebugError.failed("Nothing pressed: send \"press\" first.") }
            FrameMeter.mark("move")
            await moveSteps(from: start, to: end, in: window)
            pointer = end
            return try await settled(nil)
        case .release(let target):
            let window = try mainWindow()
            let point = try resolve(target, in: window)
            pointer = nil
            FrameMeter.mark("release")
            deliver(mouse(.leftMouseUp, at: point, in: window), in: window)
            return try await settled(nil, ms: 300)
        case .scroll(let target, let dy, let forMs, let name, let command):
            let window = try window(named: name)
            let point = try resolve(target, in: window)
            if forMs > 0 {
                await glide(at: point, by: dy, forMs: forMs, command: command, in: window)
                return try await settled(["scrolled": true])
            }
            let moved = scroll(at: point, by: dy, in: window)
            return try await settled(["scrolled": .bool(moved)], ms: 200)
        case .window(let width, let height, let front, let live):
            let window = try mainWindow()
            if let live, let width {
                let steps = await liveResize(window, toWidth: width, steps: max(1, live))
                if front == true { window.orderFrontRegardless() }
                var result = info()
                if case .object(var object) = result {
                    // The main thread's time for each step: layout, display and the commit of its layers, in ms.
                    object["stepsMs"] = .array(steps.map { .number(($0 * 10).rounded() / 10) })
                    result = .object(object)
                }
                return try await settled(result, ms: 300)
            } else if width != nil || height != nil {
                let size = window.contentView?.frame.size ?? .zero
                window.setContentSize(NSSize(width: width ?? Double(size.width), height: height ?? Double(size.height)))
            }
            if front == true { window.orderFrontRegardless() }
            return try await settled(info(), ms: 300)
        case .theme(let value):
            guard let session = session() else { throw DebugError.failed("No vault is open.") }
            try session.themes.setAppearance(value == "auto" ? nil : ThemeAppearance(rawValue: value))
            return try await settled(["theme": .string(value)], ms: 300)
        case .reduceMotion(let on):
            Motion.reduceMotionOverride = on
            return try await settled(["reduceMotion": .bool(on)], ms: 100)
        case .ax(let depth, let find):
            let window = try mainWindow()
            let access = DebugAccessibility(window: window)
            if let find { return .array(access.find(find).map { access.json(of: $0) }) }
            return access.tree(depth: depth)
        case .hit(let target):
            let window = try mainWindow()
            return hit(at: try resolve(target, in: window), in: window)
        case .editor:
            return try editorState(in: try mainWindow())
        case .screenshot(let path, let mode, let scale, let name):
            return try screenshot(path: path, mode: mode, scale: scale, window: try window(named: name))
        case .film(let prefix, let count, let intervalMs, let scale, let then):
            let window = try mainWindow()
            if let then {
                let answer = await handle(then)
                if !answer.ok { throw DebugError.failed("film: \(answer.error ?? "the command failed")") }
            }
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: prefix).deletingLastPathComponent(), withIntermediateDirectories: true
            )
            await ScriptDriver.film(window, prefix: prefix, count: count, interval: Double(intervalMs), scale: scale.map { CGFloat($0) })
            return [
                "frames": .array((0..<count).map { .string(prefix + String(format: "-%02d.png", $0)) }),
                "times": .string(prefix + ".txt"),
            ]
        case .run(let id, let arguments):
            guard let session = session() else { throw DebugError.failed("No vault is open.") }
            do {
                FrameMeter.mark("run \(id)")
                let output = try await session.run(id, arguments)
                return try await settled(["output": .string(output)], ms: 300)
            } catch ShellError.unknownCommand {
                throw DebugError.failed("No command \"\(id)\".")
            }
        case .wait(let ms):
            try? await Task.sleep(for: .milliseconds(ms))
            return nil
        case .quit:
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                for window in NSApplication.shared.windows { if let sheet = window.attachedSheet { window.endSheet(sheet) } }
                NSApplication.shared.terminate(nil)
            }
            return ["quitting": true]
        }
    }

    /// A short pause so the UI has reacted when the answer comes back, then `result`.
    private func settled(_ result: DebugValue?, ms: Int = 80) async throws -> DebugValue? {
        try? await Task.sleep(for: .milliseconds(ms))
        return result
    }

    // MARK: Windows

    private func mainWindow() throws -> NSWindow { try window(named: nil) }

    /// `main` (default), `settings`, `sheet` (the main window's sheet), `top`: the highest visible window, such as
    /// the intro over the desktop, or `id:IDENTIFIER`: a panel by its accessibility identifier.
    private func window(named name: String?) throws -> NSWindow {
        let main = NSApplication.shared.windows.first { AppModel.isNotebookWindow($0) && $0.contentView != nil }
        switch name ?? "main" {
        case "main":
            guard let main else { throw DebugError.failed("The window is not up yet.") }
            return main
        case "sheet":
            guard let sheet = main?.attachedSheet else { throw DebugError.failed("The window has no sheet.") }
            return sheet
        case "settings":
            guard let main, let settings = ScriptDriver.settingsWindow(besides: main) else {
                throw DebugError.failed("No settings window: run {\"cmd\":\"run\",\"command\":\"…\"} or open it with the menu first.")
            }
            return settings
        case "top":
            let visible = NSApplication.shared.windows.filter { $0.isVisible && $0.contentView != nil }
            guard let top = visible.max(by: { $0.level.rawValue < $1.level.rawValue }) else {
                throw DebugError.failed("No window is up.")
            }
            return top
        case let name where name.hasPrefix("id:"):
            // A plugin's own panel, by its accessibility identifier (`id:capture.panel`).
            let id = String(name.dropFirst(3))
            guard let window = NSApplication.shared.windows.first(where: { $0.accessibilityIdentifier() == id && $0.isVisible }) else {
                throw DebugError.failed("No visible window \(id).")
            }
            return window
        default:
            throw DebugError.failed("Unknown window \"\(name ?? "")\": main, settings, sheet, top or id:IDENTIFIER.")
        }
    }

    private func info() -> DebugValue {
        var info: [String: DebugValue] = [
            "instance": .string(instance.name),
            "pid": .number(Double(getpid())),
            "bundleId": .string(Bundle.main.bundleIdentifier ?? ""),
            "socket": .string(instance.socketPath),
            "appActive": .bool(NSApplication.shared.isActive),
            "reduceMotion": .bool(Motion.reduceMotion),
            "accessibilityEnabled": .bool(NSApplication.shared.isAccessibilityEnabled()),
        ]
        if let window = try? mainWindow() {
            info["window"] = [
                "number": .number(Double(window.windowNumber)),
                "title": .string(window.title),
                "frame": DebugAccessibility.rect(window.frame),
                "content": ["w": .number(Double(window.contentView?.frame.width ?? 0)), "h": .number(Double(window.contentView?.frame.height ?? 0))],
                "key": .bool(window.isKeyWindow),
                "visible": .bool(window.occlusionState.contains(.visible)),
                "scale": .number(window.backingScaleFactor),
                "appearance": .string(window.effectiveAppearance.name.rawValue),
                "firstResponder": .string(window.firstResponder.map { String(describing: type(of: $0)) } ?? ""),
                // Menus and bars floating over it (the `/` menu, the format bar), in screen coordinates.
                "children": .array((window.childWindows ?? []).map {
                    ["class": .string(String(describing: type(of: $0))), "frame": DebugAccessibility.rect($0.frame)]
                }),
            ]
        }
        if let session = session() {
            info["vault"] = .string(session.rootURL.path)
            info["activeResource"] = .string(session.workspace.layout.activeTab?.resource.path ?? "")
            info["safeMode"] = .bool(session.isSafeMode)
        }
        return .object(info)
    }

    func writeState() {
        let state = info()
        try? FileManager.default.createDirectory(at: instance.directory, withIntermediateDirectories: true)
        try? DebugCoding.encode(state).write(to: URL(fileURLWithPath: instance.statePath))
    }

    // MARK: Opening

    private func open(_ path: String, placement: String) async throws -> DebugValue? {
        guard let session = session() else { throw DebugError.failed("No vault is open.") }
        guard let placement = Placement(rawValue: placement) else { throw DebugError.failed("placement: replace, newTab or beside.") }
        let resource: Resource
        if let colon = path.firstIndex(of: ":"), !path[..<colon].contains("/") {
            resource = .virtual(path)
        } else {
            var isDirectory: ObjCBool = false
            let url = session.rootURL.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                throw DebugError.failed("No such file in the vault: \(path)")
            }
            resource = isDirectory.boolValue ? .folder(path) : .file(path)
        }
        FrameMeter.mark("open \(path)")
        session.workspace.open(resource, placement: placement)
        // The page grows in; the editor takes the focus once it is up.
        try? await Task.sleep(for: .milliseconds(500))
        return ["opened": .string(resource.path), "active": .string(session.workspace.layout.activeTab?.resource.path ?? "")]
    }

    // MARK: Keyboard

    private func flags(_ modifiers: [String]) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        for name in modifiers {
            switch name.lowercased() {
            case "cmd", "command": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "option", "alt": flags.insert(.option)
            case "ctrl", "control": flags.insert(.control)
            default: break
            }
        }
        return flags
    }

    private func key(_ shortcut: String, in window: NSWindow) throws {
        FrameMeter.mark("key \(shortcut)")
        guard let parsed = KeyShortcut(parsing: shortcut) else { throw DebugError.failed("Not a shortcut: \(shortcut) (cmd+n, return, shift+tab…).") }
        var flags: NSEvent.ModifierFlags = []
        if parsed.modifiers.contains(.command) { flags.insert(.command) }
        if parsed.modifiers.contains(.shift) { flags.insert(.shift) }
        if parsed.modifiers.contains(.option) { flags.insert(.option) }
        if parsed.modifiers.contains(.control) { flags.insert(.control) }
        // Shift-Tab types the back-tab character, as the keyboard does.
        let backtab = parsed.key == "tab" && flags.contains(.shift)
        let characters = backtab ? "\u{19}" : ScriptDriver.namedCharacters[parsed.key] ?? parsed.key
        let keyCode = ScriptDriver.keyCodes[parsed.key] ?? Self.keyCode(typing: characters) ?? 0
        try send(characters: characters, keyCode: keyCode, flags: flags, in: window)
    }

    /// The key that types `character` on the current keyboard layout, alone or with Shift: menu shortcuts are matched
    /// by key as well as by character, so `cmd+0` must press the key a keyboard would.
    private static func keyCode(typing character: String) -> UInt16? {
        guard character.count == 1,
              let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return data.withUnsafeBytes { bytes -> UInt16? in
            let layout = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress!
            for modifiers: UInt32 in [0, UInt32(shiftKey >> 8)] {
                // The main keys before the keypad's (65...92), which menus do not take for their digits.
                for code in Array(UInt16(0)..<65) + Array(UInt16(93)..<128) + Array(UInt16(65)...92) {
                    var dead: UInt32 = 0
                    var length = 0
                    var chars = [UniChar](repeating: 0, count: 4)
                    UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), modifiers, UInt32(LMGetKbdType()),
                                   OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &chars)
                    if String(utf16CodeUnits: chars, count: length) == character { return code }
                }
            }
            return nil
        }
    }

    /// A key down and up, handed to the application's own event dispatch (monitors, menu key equivalents, then the
    /// window's first responder), synchronously: the app need not be active.
    private func send(characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags, in window: NSWindow) throws {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
            ) else { throw DebugError.failed("Cannot make a key event for \"\(characters)\".") }
            NSApplication.shared.sendEvent(event)
        }
    }

    // MARK: Pointer

    /// A target as a point of the window, from the top-left corner of its content.
    private func resolve(_ target: DebugCommand.Target, in window: NSWindow) throws -> NSPoint {
        switch target {
        case .point(let x, let y):
            return NSPoint(x: x, y: y)
        case .id(let id):
            guard let element = DebugAccessibility(window: window).element(id: id) else {
                throw DebugError.failed("No element with id \"\(id)\". Try {\"cmd\":\"ax\",\"find\":\"…\"}.")
            }
            return element.center
        case .label(let label):
            guard let element = DebugAccessibility(window: window).element(label: label) else {
                throw DebugError.failed("No element labelled \"\(label)\". Try {\"cmd\":\"ax\",\"find\":\"…\"}.")
            }
            return element.center
        }
    }

    /// Window coordinates (from the bottom left) of a point from the content's top left.
    private func windowPoint(_ point: NSPoint, in window: NSWindow) -> NSPoint {
        NSPoint(x: point.x, y: (window.contentView?.frame.height ?? window.frame.height) - point.y)
    }

    private func mouse(
        _ type: NSEvent.EventType, at point: NSPoint, clickCount: Int = 1, flags: NSEvent.ModifierFlags = [], in window: NSWindow
    ) -> NSEvent? {
        if type == .leftMouseDown { eventNumber += 1 }
        return NSEvent.mouseEvent(
            with: type, location: windowPoint(point, in: window), modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: eventNumber, clickCount: type == .leftMouseDragged || type == .mouseMoved ? 0 : clickCount,
            pressure: type == .leftMouseUp || type == .mouseMoved ? 0 : 1
        )
    }

    /// Hands a mouse event to the application's dispatch. SwiftUI's gestures also ask `NSEvent.pressedMouseButtons`,
    /// which `ScriptedButtons` answers for while a scripted press lasts.
    private func deliver(_ event: NSEvent?, in window: NSWindow) {
        guard let event else { return }
        ScriptedButtons.install()
        if event.type == .leftMouseDown { ScriptedButtons.leftDown = true }
        if event.type == .leftMouseUp { ScriptedButtons.leftDown = false }
        NSApplication.shared.sendEvent(event)
    }

    private func click(at point: NSPoint, clicks: Int, flags: NSEvent.ModifierFlags, in window: NSWindow) {
        FrameMeter.mark("click")
        for count in 1...clicks {
            // The release waits in the queue first, where a view's mouse tracking loop finds it.
            if let up = mouse(.leftMouseUp, at: point, clickCount: count, flags: flags, in: window) {
                NSApplication.shared.postEvent(up, atStart: false)
            }
            let down = mouse(.leftMouseDown, at: point, clickCount: count, flags: flags, in: window)
            // A window that is not key (the app is in the background) only becomes key on a click, and a view that
            // does not take the first mouse (a text view) never sees it: hand the press to the view under it.
            if !window.isKeyWindow, let down, let view = window.contentView?.superview?.hitTest(down.locationInWindow),
               !view.acceptsFirstMouse(for: down) {
                ScriptedButtons.install()
                ScriptedButtons.leftDown = true
                if view.acceptsFirstResponder { window.makeFirstResponder(view) }
                view.mouseDown(with: down)
                ScriptedButtons.leftDown = false
            } else {
                deliver(down, in: window)
            }
        }
    }

    /// The tracking areas the pointer was last inside, to send them `mouseExited` when it leaves.
    private var hovered: [(area: NSTrackingArea, view: NSView)] = []

    /// A pointer move to `point`. The window server turns a real pointer's motion into `mouseEntered`/`mouseExited`
    /// for tracking areas (what SwiftUI's hover and AppKit's rollovers listen to); a synthesised move has no such
    /// help, so the entering and leaving are sent to the areas' owners here, then the move itself.
    private func hover(at point: NSPoint, in window: NSWindow) async {
        window.acceptsMouseMovedEvents = true
        let location = windowPoint(point, in: window)
        var inside: [(area: NSTrackingArea, view: NSView)] = []
        for view in ScriptDriver.views(in: window.contentView?.superview) where !view.isHiddenOrHasHiddenAncestor {
            let local = view.convert(location, from: nil)
            for area in view.trackingAreas where area.options.contains(.mouseEnteredAndExited) || area.options.contains(.mouseMoved) {
                let rect = area.options.contains(.inVisibleRect) ? view.visibleRect : area.rect
                if rect.contains(local) { inside.append((area, view)) }
            }
        }
        func event(_ type: NSEvent.EventType, _ area: NSTrackingArea) -> NSEvent? {
            eventNumber += 1
            return NSEvent.enterExitEvent(
                with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber,
                // `NSEvent.trackingArea` reads the area from the user data pointer.
                trackingNumber: Int(bitPattern: Unmanaged.passUnretained(area).toOpaque()),
                userData: Unmanaged.passUnretained(area).toOpaque()
            )
        }
        for old in hovered where !inside.contains(where: { $0.area === old.area }) {
            if let exit = event(.mouseExited, old.area) { notify(old.area.owner, "mouseExited:", exit) }
        }
        for new in inside where !hovered.contains(where: { $0.area === new.area }) {
            if let enter = event(.mouseEntered, new.area) { notify(new.area.owner, "mouseEntered:", enter) }
        }
        hovered = inside
        for entry in inside where entry.area.options.contains(.mouseMoved) {
            if let moved = mouse(.mouseMoved, at: point, in: window) { notify(entry.area.owner, "mouseMoved:", moved) }
        }
        // SwiftUI also reads where the pointer is from the window itself, not only from the event: say it is here.
        ScriptedPointer.install()
        ScriptedPointer.location[window.windowNumber] = location
        // The hosting views take the move to find what is under it.
        var view = window.contentView?.superview?.hitTest(location) ?? window.contentView?.hitTest(location)
        while let current = view {
            if let moved = mouse(.mouseMoved, at: point, in: window) { current.mouseMoved(with: moved) }
            view = current.superview
        }
        deliver(mouse(.mouseMoved, at: point, in: window), in: window)
    }

    /// Sends a tracking area's owner the event, whatever its class: SwiftUI's owners (`PointerBridge`) are plain
    /// objects that implement the `mouseEntered:` family without being responders.
    private func notify(_ owner: Any?, _ selector: String, _ event: NSEvent) {
        guard let owner = owner as? NSObject, owner.responds(to: Selector(selector)) else { return }
        owner.perform(Selector(selector), with: event)
    }

    private func moveSteps(from start: NSPoint, to end: NSPoint, in window: NSWindow) async {
        for step in 1...10 {
            let t = Double(step) / 10
            let point = NSPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            deliver(mouse(.leftMouseDragged, at: point, in: window), in: window)
            try? await Task.sleep(for: .milliseconds(30))
        }
    }

    private func drag(from start: NSPoint, to end: NSPoint, in window: NSWindow) async {
        // The whole gesture is queued before the press, so a view that tracks the pointer in its own loop (text
        // selection) finds it there instead of waiting for events this single-threaded driver cannot send.
        for step in 1...10 {
            let t = Double(step) / 10
            let point = NSPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            if let dragged = mouse(.leftMouseDragged, at: point, in: window) { NSApplication.shared.postEvent(dragged, atStart: false) }
        }
        if let up = mouse(.leftMouseUp, at: end, in: window) { NSApplication.shared.postEvent(up, atStart: false) }
        let down = mouse(.leftMouseDown, at: start, in: window)
        // As for a click: a window that is not key gives a text view no press, so a selection drag would do nothing.
        if !window.isKeyWindow, let down, let view = window.contentView?.superview?.hitTest(down.locationInWindow),
           !view.acceptsFirstMouse(for: down) {
            if view.acceptsFirstResponder { window.makeFirstResponder(view) }
            view.mouseDown(with: down)
        } else {
            deliver(down, in: window)
        }
        try? await Task.sleep(for: .milliseconds(100))
    }

    /// Resizes the window to `width` in `steps` frames inside AppKit's own live resize, as a drag of its edge does:
    /// `inLiveResize` is true for every view meanwhile, `viewWillStartLiveResize`/`viewDidEndLiveResize` and the
    /// window's notifications come as they do for a person's drag. A synthesised drag of the edge cannot: AppKit's
    /// resize loop ends at once unless the whole drag is already queued, and then takes it in one or two steps.
    @discardableResult
    private func liveResize(_ window: NSWindow, toWidth width: Double, steps: Int) async -> [Double] {
        var times: [Double] = []
        let start = Selector(("_startLiveResize")), end = Selector(("_endLiveResize"))
        let live = window.responds(to: start) && window.responds(to: end)
        let from = window.frame
        let target = window.frameRect(forContentRect: NSRect(origin: .zero, size: NSSize(
            width: width, height: window.contentView?.frame.height ?? from.height
        ))).width
        FrameMeter.mark("live resize")
        if live { window.perform(start) }
        for step in 1...steps {
            var frame = from
            frame.size.width = (from.width + (target - from.width) * Double(step) / Double(steps)).rounded()
            let begin = CACurrentMediaTime()
            window.setFrame(frame, display: true)
            CATransaction.flush()
            times.append((CACurrentMediaTime() - begin) * 1000)
            try? await Task.sleep(for: .milliseconds(16))
        }
        if live { window.perform(end) }
        return times
    }

    /// Scrolls the nearest scroll view that can move, from the one under `point` outwards.
    private func scroll(at point: NSPoint, by dy: Double, in window: NSWindow) -> Bool {
        let location = windowPoint(point, in: window)
        guard var view = window.contentView?.superview?.hitTest(location) ?? window.contentView?.hitTest(location) else { return false }
        // Nothing scrolls there (a canvas): a trackpad scroll event instead, for its event monitors.
        guard view.enclosingScrollView != nil else { return postScroll(at: location, by: dy, in: window) }
        while true {
            if let scrollView = view.enclosingScrollView, let document = scrollView.documentView {
                let clip = scrollView.contentView
                let maxY = max(0, document.frame.height - clip.bounds.height)
                if maxY > 0 {
                    clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(max(0, clip.bounds.minY + dy), maxY)))
                    scrollView.reflectScrolledClipView(clip)
                    return true
                }
                view = scrollView.superview ?? scrollView
                if scrollView.superview == nil { return false }
            } else {
                return false
            }
        }
    }

    /// A trackpad scroll of `dy` points per frame (120 Hz) for `forMs`, with its began/changed/ended phases, handed to
    /// the view under the point as the window would (a posted event has no window and goes nowhere). Over a canvas
    /// (no scroll view there), the events go through the app's dispatch instead, for its event monitors. `command`
    /// holds ⌘ (a canvas zooms).
    private func glide(at point: NSPoint, by dy: Double, forMs: Int, command: Bool = false, in window: NSWindow) async {
        let location = windowPoint(point, in: window)
        guard let view = window.contentView?.superview?.hitTest(location) ?? window.contentView?.hitTest(location) else { return }
        let screen = window.convertPoint(toScreen: location)
        let height = NSScreen.screens.first?.frame.height ?? 0
        let frames = max(2, forMs * 120 / 1000)
        let clock = ContinuousClock()
        let start = clock.now
        for frame in 0..<frames {
            let phase: Int64 = frame == 0 ? 1 : frame == frames - 1 ? 4 : 2
            if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(-dy), wheel2: 0, wheel3: 0) {
                cg.location = CGPoint(x: screen.x, y: height - screen.y)
                cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
                if command { cg.flags = .maskCommand }
                if let event = NSEvent(cgEvent: cg) {
                    if view.enclosingScrollView == nil {
                        // The app's event monitors first (a SwiftUI canvas pans in one); a made event has no window,
                        // so the app's dispatch stops there: the view under the point gets it too.
                        NSApp.sendEvent(event)
                        if event.window == nil { view.scrollWheel(with: event) }
                    } else {
                        view.scrollWheel(with: event)
                    }
                }
            }
            try? await clock.sleep(until: start + .microseconds(Int64(frame + 1) * 1_000_000 / 120))
        }
    }

    /// Posts a precise (trackpad) scroll of `dy` points at a window point, as the event queue would deliver it.
    private func postScroll(at location: NSPoint, by dy: Double, in window: NSWindow) -> Bool {
        let screen = window.convertPoint(toScreen: location)
        let height = NSScreen.screens.first?.frame.height ?? 0
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(-dy), wheel2: 0, wheel3: 0)
        else { return false }
        cg.location = CGPoint(x: screen.x, y: height - screen.y)
        guard let event = NSEvent(cgEvent: cg) else { return false }
        NSApp.postEvent(event, atStart: false)
        return true
    }

    // MARK: Reading

    private func hit(at point: NSPoint, in window: NSWindow) -> DebugValue {
        let location = windowPoint(point, in: window)
        var chain: [DebugValue] = []
        var view = window.contentView?.superview?.hitTest(location) ?? window.contentView?.hitTest(location)
        while let current = view, chain.count < 40 {
            chain.append(.string(String(describing: type(of: current))))
            view = current.superview
        }
        let screen = window.convertPoint(toScreen: location)
        let access = DebugAccessibility(window: window)
        var result: [String: DebugValue] = ["views": .array(chain)]
        var areas: [DebugValue] = []
        for view in ScriptDriver.views(in: window.contentView?.superview) where !view.isHiddenOrHasHiddenAncestor {
            let local = view.convert(location, from: nil)
            for area in view.trackingAreas {
                let rect = area.options.contains(.inVisibleRect) ? view.visibleRect : area.rect
                if rect.contains(local) {
                    areas.append(["view": .string(String(String(describing: type(of: view)).prefix(60))), "owner": .string(area.owner.map { String(describing: type(of: $0)) } ?? "nil"), "options": .number(Double(area.options.rawValue))])
                }
            }
        }
        result["trackingAreas"] = .array(areas)
        // The pointer as it stands, after a `hover` here: what the views under it set.
        let pointers: [(NSCursor, String)] = [
            (.arrow, "arrow"), (.iBeam, "iBeam"), (.pointingHand, "pointingHand"), (.openHand, "openHand"),
            (.closedHand, "closedHand"), (.resizeLeftRight, "resizeLeftRight"), (.resizeUpDown, "resizeUpDown"),
        ]
        result["pointer"] = .string(pointers.first { $0.0 == NSCursor.current }?.1 ?? "other")
        if let element = window.contentView?.accessibilityHitTest(screen) {
            result["element"] = access.json(of: access.element(for: element as AnyObject))
        }
        return .object(result)
    }

    private func editorState(in window: NSWindow) throws -> DebugValue {
        let texts = ScriptDriver.views(in: window.contentView?.superview).compactMap { $0 as? NSTextView }
            .filter { $0.isEditable && !$0.isFieldEditor && $0.enclosingScrollView != nil }
        guard !texts.isEmpty else { throw DebugError.failed("No editor is open.") }
        func describe(_ text: NSTextView) -> [String: DebugValue] {
            let selection = text.selectedRange()
            let ns = text.string as NSString
            let before = ns.substring(to: min(selection.location, ns.length))
            let line = before.components(separatedBy: "\n").count
            let column = before.components(separatedBy: "\n").last?.utf16.count ?? 0
            var object: [String: DebugValue] = [
                "text": .string(text.string),
                "length": .number(Double(ns.length)),
                "selection": ["location": .number(Double(selection.location)), "length": .number(Double(selection.length)), "line": .number(Double(line)), "column": .number(Double(column))],
                "selectedText": .string(selection.length > 0 ? ns.substring(with: selection) : ""),
                "focused": .bool(window.firstResponder === text),
                "class": .string(String(describing: type(of: text))),
            ]
            // Where the caret is drawn, in the text view (points from its top-left corner).
            if selection.length == 0, let window = text.window {
                let screen = text.firstRect(forCharacterRange: selection, actualRange: nil)
                let local = text.convert(window.convertFromScreen(screen), from: nil)
                object["caret"] = ["x": .number(Double(local.minX)), "y": .number(Double(local.minY)), "h": .number(Double(local.height))]
            }
            if let scrollView = text.enclosingScrollView {
                object["scrollY"] = .number(scrollView.contentView.bounds.minY)
                object["contentHeight"] = .number(text.frame.height)
                object["viewportHeight"] = .number(scrollView.contentView.bounds.height)
                // Where the page is: its scroll view in the window (from the content's top left), the clip view's
                // bounds and the text view's frame in it, and the column's left inset.
                func rect(_ r: NSRect) -> DebugValue {
                    ["x": .number(r.minX), "y": .number(r.minY), "w": .number(r.width), "h": .number(r.height)]
                }
                var inWindow = scrollView.convert(scrollView.bounds, to: nil)
                inWindow.origin.y = (window.contentView?.frame.height ?? 0) - inWindow.maxY
                object["page"] = [
                    "scrollView": rect(inWindow), "clipBounds": rect(scrollView.contentView.bounds),
                    "textFrame": rect(text.frame), "inset": .number(text.textContainerInset.width),
                ]
            }
            return object
        }
        let main = texts.first { window.firstResponder === $0 } ?? texts[0]
        var state = describe(main)
        if texts.count > 1 { state["editors"] = .array(texts.map { .object(describe($0)) }) }
        return .object(state)
    }

    private func screenshot(path: String, mode: DebugCommand.CaptureMode, scale: Double?, window: NSWindow) throws -> DebugValue {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let rep: NSBitmapImageRep?
        switch mode {
        case .view:
            // Also draws the popovers and menus over the window, in place (and on their own, `-popover.png`).
            ScriptDriver.snapshot(window, to: path)
            rep = NSBitmapImageRep(data: (try? Data(contentsOf: url)) ?? Data())
        case .layers:
            rep = ScriptDriver.captureLayers(window, scale: scale.map { CGFloat($0) })
            if let png = rep?.representation(using: .png, properties: [:]) { try png.write(to: url) }
        }
        guard let rep, FileManager.default.fileExists(atPath: path) else { throw DebugError.failed("Cannot draw the window.") }
        return [
            "path": .string(path), "width": .number(Double(rep.pixelsWide)), "height": .number(Double(rep.pixelsHigh)),
            "mode": .string(mode.rawValue),
        ]
    }
}

/// Answers `NSWindow.mouseLocationOutsideOfEventStream` with the point of the last scripted `hover` of that window
/// (in window coordinates), the real pointer otherwise.
enum ScriptedPointer {
    nonisolated(unsafe) static var location: [Int: NSPoint] = [:]
    nonisolated(unsafe) private static var original: IMP?

    @MainActor static func install() {
        guard original == nil,
              let method = class_getInstanceMethod(NSWindow.self, #selector(getter: NSWindow.mouseLocationOutsideOfEventStream))
        else { return }
        let scripted: @convention(block) (NSWindow) -> NSPoint = { window in
            if let point = location[window.windowNumber] { return point }
            typealias Getter = @convention(c) (AnyObject, Selector) -> NSPoint
            return original.map {
                unsafeBitCast($0, to: Getter.self)(window, #selector(getter: NSWindow.mouseLocationOutsideOfEventStream))
            } ?? .zero
        }
        original = method_setImplementation(method, imp_implementationWithBlock(scripted))
    }
}
#endif
