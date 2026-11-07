import AppKit
import PluginKit

/// A developer tool: plays a script of key presses, clicks and window snapshots inside the running app, so a change
/// can be checked in the real window without driving the screen. Off unless `LOAM_SCRIPT` names a script file.
///
/// One step per line, `#` starts a comment:
///
///     wait 1.5                  seconds
///     key cmd+n                 a shortcut, as `.loam/config.json` writes them (return, delete, shift+tab, up...)
///     type Hello world          characters, one key press each
///     click 300 200             a click at a point of the window, from its top-left corner (AppKit views only)
///     tap 300 200               like click, but straight to the view (works while the app is in the background);
///                               `tap` takes optional `cmd` or `option` before the numbers: `tap cmd 300 200`
///     direct-click 300 200      a click handed to the view under the point itself, so a text view takes it even while
///                               the app is in the background (a posted click would only bring its window forward)
///     drag 300 200 600 200      a press, a move and a release
///     shot /tmp/a.png           the window as a PNG
///     burst cmd+t /tmp/a 6 40   a shortcut, then 6 window PNGs (/tmp/a-0.png...) 40 ms apart: an animation's frames
///     log /tmp/log.txt          appends the key window's first responder, the visible windows and the open tabs
///     ls Inbox /tmp/ls.txt      appends the files of a vault folder (empty ones marked) to a file
///     shots /tmp/open 12 40 1   12 shots 40 ms apart (an animation's frames) at 1 pixel per point (the last number,
///                               optional, smaller is quicker), /tmp/open-00.png on, their times in /tmp/open.txt;
///                               the next step runs right away, so put it after the step to film
///     frames /tmp/f.txt 1       records for 1 second, from now, the time between the window's frames (dropped
///                               frames show as long ones) and writes them with a summary; the next step runs at once
///     press 300 200             the button goes down there (then `move`, `shot`..., `release`)
///     move 600 200              the pressed pointer moves there, in 10 steps
///     release 600 200           the button comes up there
///     size 1000 700             resizes the window's content, to check narrow layouts
///     activate                  brings the app to the front (SwiftUI ignores clicks while it is inactive)
///     front                     puts the window above the others without activating the app: macOS slows the
///                               frames of a hidden window, so `frames` needs it in view
///     run sidebar.toggle-leading  runs a command (`run mindmap.open path=Map.md` with arguments)
///     until /tmp/go 60          waits until the file exists (60 s at most), while the real pointer acts
///     untilpressed 60           waits until the real mouse button is down (60 s at most): `shots` then films a drag
///     settings plugins/files    opens the settings window on a pane (`appearance`, `plugins`, `plugins/<id>`...);
///                               the steps after it act on that window
///     window main               the steps after it act on the main window again (`window settings`: on Settings)
///     sheet                     the steps after it act on the sheet (an alert) of that window, until `window`
///     paste-file /tmp/a.pdf     pastes files (paths split by `|`) into the focused editor, from a private pasteboard
///     paste-image /tmp/a.png    pastes a picture's bytes, as a screenshot copied to the clipboard
///     drop-file 400 300 /tmp/a.mov  drops files (paths split by `|`) on the editor at a point of the window
///     scroll 600 400 300        scrolls the scroll view under a point of the window down by 300 points (up when negative)
///     shot-settings /tmp/s.png  the settings window as a PNG; `click-settings 300 200` clicks in it
///     quit
@MainActor
enum ScriptDriver {
    static func startIfAsked(settings: SettingsNavigation, session: @escaping @MainActor () -> ShellSession?) {
        guard let path = ProcessInfo.processInfo.environment["LOAM_SCRIPT"],
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let steps = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        navigation = settings
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            for step in steps { await run(step, session: session()) }
        }
    }

    private static var navigation: SettingsNavigation?
    /// Whether the steps act on the settings window rather than the main one.
    private static var targetsSettings = false
    /// Whether they act on that window's sheet.
    private static var targetsSheet = false

    /// The window the steps act on: the settings window after `settings`, else (or once it is closed) the main one;
    /// after `sheet`, its sheet while it has one.
    private static var window: NSWindow? {
        let base: NSWindow?
        if targetsSettings,
           let settings = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("Settings") == true && $0.isVisible }) {
            base = settings
        } else {
            base = NSApp.windows.first { AppModel.isNotebookWindow($0) && $0.isVisible }
                ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
        }
        return targetsSheet ? base?.attachedSheet ?? base : base
    }

    /// Clicks the app menu's Settings item, as Cmd+, does.
    private static func openSettingsWindow() {
        guard let menu = NSApp.mainMenu?.items.first?.submenu,
              let index = menu.items.firstIndex(where: { $0.keyEquivalent == "," }) else { return }
        menu.performActionForItem(at: index)
    }

    private static func run(_ step: String, session: ShellSession?) async {
        let parts = step.split(separator: " ", maxSplits: 1).map(String.init)
        let argument = parts.count > 1 ? parts[1] : ""
        let numbers = argument.split(separator: " ").compactMap { Double($0) }
        switch parts[0] {
        case "settings":
            navigation?.open(path: argument)
            openSettingsWindow()
            targetsSettings = true
            targetsSheet = false
            try? await Task.sleep(for: .milliseconds(700))
            return
        case "window":
            targetsSettings = argument == "settings"
            targetsSheet = false
            return
        case "sheet":
            targetsSheet = true
            return
        // Neither needs a window: a script whose window was closed still waits and quits.
        case "wait":
            try? await Task.sleep(for: .seconds(numbers.first ?? 0.5))
            return
        case "quit":
            // After the frames being filmed or recorded.
            await filmed?.value
            await FrameRecorder.finished()
            // A sheet or alert refuses to let the app terminate: dismiss them first.
            for window in NSApp.windows { if let sheet = window.attachedSheet { window.endSheet(sheet) } }
            NSApp.terminate(nil)
            return
        default:
            break
        }
        let words = argument.split(separator: " ")
        var modifiers: NSEvent.ModifierFlags = []
        if words.contains("cmd") { modifiers.insert(.command) }
        if words.contains("option") { modifiers.insert(.option) }
        guard let window else { return }
        if !window.isKeyWindow { window.makeKey() }
        switch parts[0] {
        case "untilpressed":
            let limit = Date().addingTimeInterval(numbers.first ?? 60)
            while NSEvent.pressedMouseButtons & 1 == 0, Date() < limit {
                try? await Task.sleep(for: .milliseconds(10))
            }
        case "until":
            let file = argument.split(separator: " ").first.map(String.init) ?? ""
            let limit = Date().addingTimeInterval(numbers.last ?? 60)
            while !FileManager.default.fileExists(atPath: file), Date() < limit {
                try? await Task.sleep(for: .milliseconds(100))
            }
        case "key":
            if let shortcut = KeyShortcut(parsing: argument) { press(shortcut, in: window) }
            try? await Task.sleep(for: .milliseconds(150))
        case "type":
            for character in argument {
                send(characters: String(character), keyCode: 0, flags: [], in: window)
                try? await Task.sleep(for: .milliseconds(20))
            }
            try? await Task.sleep(for: .milliseconds(150))
        case "click" where numbers.count == 2:
            mouse(.leftMouseDown, at: numbers[0], numbers[1], in: window)
            mouse(.leftMouseUp, at: numbers[0], numbers[1], in: window)
            try? await Task.sleep(for: .milliseconds(250))
        case "tap" where numbers.count == 2:
            // A click handed straight to the view under the point, for an app that is not in front (it ignores
            // posted clicks). For clicks the view handles at once (a pill, a button); a click on plain text would
            // wait inside AppKit's tracking loop for a mouse-up that comes after.
            let point = NSPoint(x: numbers[0], y: (window.contentView?.frame.height ?? 0) - numbers[1])
            if let view = window.contentView?.hitTest(point),
               let event = NSEvent.mouseEvent(
                with: .leftMouseDown, location: point, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: Self.nextEventNumber(), clickCount: 1, pressure: 1
               ) {
                view.mouseDown(with: event)
            }
            try? await Task.sleep(for: .milliseconds(300))
        case "direct-click" where numbers.count == 2:
            let height = window.contentView?.frame.height ?? window.frame.height
            let point = NSPoint(x: numbers[0], y: height - numbers[1])
            if let view = window.contentView?.superview?.hitTest(point) ?? window.contentView?.hitTest(point),
               let down = mouseEvent(.leftMouseDown, at: point, in: window) {
                // The release waits in the queue, where the view's tracking loop finds it.
                if let up = mouseEvent(.leftMouseUp, at: point, in: window) { NSApp.postEvent(up, atStart: false) }
                view.mouseDown(with: down)
            }
            try? await Task.sleep(for: .milliseconds(250))
        case "drag" where numbers.count == 4:
            mouse(.leftMouseDown, at: numbers[0], numbers[1], in: window)
            await moveMouse(to: numbers[2], numbers[3], in: window)
            mouse(.leftMouseUp, at: numbers[2], numbers[3], in: window)
            try? await Task.sleep(for: .milliseconds(300))
        case "burst":
            let words = argument.split(separator: " ").map(String.init)
            if words.count == 4, let shortcut = KeyShortcut(parsing: words[0]), let count = Int(words[2]),
               let gap = Int(words[3]) {
                press(shortcut, in: window)
                for i in 0..<count {
                    snapshot(window, to: "\(words[1])-\(i).png")
                    try? await Task.sleep(for: .milliseconds(gap))
                }
            }
        case "press" where numbers.count == 2:
            mouse(.leftMouseDown, at: numbers[0], numbers[1], in: window)
            try? await Task.sleep(for: .milliseconds(100))
        case "move" where numbers.count == 2:
            await moveMouse(to: numbers[0], numbers[1], in: window)
            try? await Task.sleep(for: .milliseconds(150))
        case "release" where numbers.count == 2:
            mouse(.leftMouseUp, at: numbers[0], numbers[1], in: window)
            try? await Task.sleep(for: .milliseconds(300))
        case "shot":
            snapshot(window, to: argument)
        case "shots":
            let words = argument.split(separator: " ").map(String.init)
            guard words.count >= 3, let count = Int(words[1]), let interval = Double(words[2]) else { break }
            let scale = words.count > 3 ? Double(words[3]).map { CGFloat($0) } : nil
            filmed = Task { await film(window, prefix: words[0], count: count, interval: interval, scale: scale) }
        case "frames":
            let words = argument.split(separator: " ").map(String.init)
            guard let path = words.first else { break }
            FrameRecorder.start(in: window, seconds: words.count > 1 ? Double(words[1]) ?? 1 : 1, to: path)
        case "log":
            var line = "responder: \(String(describing: window.firstResponder.map { type(of: $0) })) frame: \(NSStringFromRect(window.frame))"
            if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor {
                line += " editing: \(String(describing: editor.delegate.map { type(of: $0) }))"
            }
            line += " visible: \(window.occlusionState.contains(.visible)) active: \(NSApp.isActive)"
            // For `screencapture -l <number>`, which shows the window as it is on screen.
            line += " number: \(window.windowNumber) key: \(window.isKeyWindow)"
            let others = NSApp.windows.filter { $0 !== window && $0.isVisible }
                .map { "\(type(of: $0)) \(NSStringFromRect($0.frame)) alpha \($0.alphaValue)" }
            if !others.isEmpty { line += " windows: \(others)" }
            if let session {
                line += " active: \(session.workspace.layout.activeTab?.resource.path ?? "-")"
                line += " chrome: \(session.workspace.chrome)"
                line += " layout: \(session.workspace.layout)"
            }
            for text in views(in: window.contentView?.superview).compactMap({ $0 as? NSTextView }) where text.isEditable && text.enclosingScrollView != nil {
                line += "\ntext: scrollY \(text.enclosingScrollView!.contentView.bounds.minY) height \(text.frame.height) "
                    + "visible \(text.enclosingScrollView!.contentView.bounds.height) selection \(text.selectedRange()) length \(text.string.utf16.count)"
            }
            // The players in the window, which a snapshot cannot show (their pictures are drawn by the system).
            for player in views(in: window.contentView?.superview).filter({ NSStringFromClass(type(of: $0)).contains("AVPlayerView") }) {
                let ready = (player.value(forKey: "readyForDisplay") as? Bool) == true
                line += "\nplayer: \(player.convert(player.bounds, to: nil)) ready: \(ready) hidden: \(player.isHiddenOrHasHiddenAncestor)"
            }
            append(line + "\n", to: argument)
        case "ls":
            let items = argument.split(separator: " ", maxSplits: 1).map(String.init)
            if items.count == 2, let session {
                let folder = session.rootURL.appendingPathComponent(items[0])
                let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
                let lines = names.map { name -> String in
                    let size = (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)[.size] as? Int) ?? 0
                    return "\(name) (\(size ?? 0) bytes)"
                }
                append("\(items[0]): " + (lines.isEmpty ? "(nothing)" : lines.joined(separator: ", ")) + "\n", to: items[1])
            }
        case "run":
            // `run mindmap.open path=Inbox/Trip.md`: the command, then its arguments.
            let words = argument.split(separator: " ").map(String.init)
            var arguments: [String: String] = [:]
            for word in words.dropFirst() {
                let pair = word.split(separator: "=", maxSplits: 1).map(String.init)
                if pair.count == 2 { arguments[pair[0]] = pair[1] }
            }
            if let session, let id = words.first { _ = try? await session.run(id, arguments) }
            try? await Task.sleep(for: .milliseconds(400))
        case "size" where numbers.count == 2:
            window.setContentSize(NSSize(width: numbers[0], height: numbers[1]))
            try? await Task.sleep(for: .milliseconds(400))
        case "activate":
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(500))
        case "front":
            window.orderFrontRegardless()
            try? await Task.sleep(for: .milliseconds(300))
        case "paste-file", "paste-image":
            let rest = argument
            let pasteboard = scriptPasteboard(rest, asImage: parts[0] == "paste-image")
            // From the window's own first responder (the app may not be active, so it has no key window to send to),
            // else the first view that takes it, the editor.
            let action = Selector(("loamScriptPaste:"))
            if window.firstResponder?.tryToPerform(action, with: pasteboard) != true {
                _ = firstView(in: window.contentView?.superview, responding: action)?.perform(action, with: pasteboard)
            }
            try? await Task.sleep(for: .milliseconds(600))
        case "drop-file" where numbers.count >= 2:
            let fields = argument.split(separator: " ", maxSplits: 2).map(String.init)
            guard fields.count == 3 else { break }
            let height = window.contentView?.frame.height ?? window.frame.height
            let point = NSPoint(x: numbers[0], y: height - numbers[1])
            var view = window.contentView?.superview?.hitTest(point) ?? window.contentView?.hitTest(point)
            let action = Selector(("loamScriptDrop:"))
            while let current = view, !current.responds(to: action) { view = current.superview }
            let info: NSDictionary = ["pasteboard": scriptPasteboard(fields[2], asImage: false), "point": NSValue(point: point)]
            _ = view?.perform(action, with: info)
            try? await Task.sleep(for: .milliseconds(600))
        case "scroll" where numbers.count == 3:
            let height = window.contentView?.frame.height ?? window.frame.height
            let point = NSPoint(x: numbers[0], y: height - numbers[1])
            if let scrollView = (window.contentView?.superview?.hitTest(point) ?? window.contentView?.hitTest(point))?.enclosingScrollView,
               let document = scrollView.documentView {
                let clip = scrollView.contentView
                let maxY = max(0, document.frame.height - clip.bounds.height)
                clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(max(0, clip.bounds.minY + numbers[2]), maxY)))
                scrollView.reflectScrolledClipView(clip)
            }
            try? await Task.sleep(for: .milliseconds(400))
        case "shot-settings":
            if let settings = settingsWindow(besides: window) { snapshot(settings, to: argument) }
        case "click-settings" where numbers.count == 2:
            if let settings = settingsWindow(besides: window) {
                mouse(.leftMouseDown, at: numbers[0], numbers[1], in: settings)
                mouse(.leftMouseUp, at: numbers[0], numbers[1], in: settings)
            }
            try? await Task.sleep(for: .milliseconds(400))
        default:
            break
        }
    }

    static let keyCodes: [String: UInt16] = [
        "return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53,
        "left": 123, "right": 124, "down": 125, "up": 126, "home": 115, "end": 119, "f2": 120,
        "forwarddelete": 117,
    ]

    /// The characters AppKit reports for the named keys.
    static let namedCharacters: [String: String] = [
        "return": "\r", "tab": "\t", "space": " ", "delete": "\u{7F}", "escape": "\u{1B}",
        "left": "\u{F702}", "right": "\u{F703}", "down": "\u{F701}", "up": "\u{F700}",
        "home": "\u{F729}", "end": "\u{F72B}", "f2": "\u{F705}", "forwarddelete": "\u{F728}",
    ]

    private static func press(_ shortcut: KeyShortcut, in window: NSWindow) {
        var flags: NSEvent.ModifierFlags = []
        if shortcut.modifiers.contains(.command) { flags.insert(.command) }
        if shortcut.modifiers.contains(.shift) { flags.insert(.shift) }
        if shortcut.modifiers.contains(.option) { flags.insert(.option) }
        if shortcut.modifiers.contains(.control) { flags.insert(.control) }
        let named = namedCharacters
        // Shift-Tab types the back-tab character, as the keyboard does: text fields read it as insertBacktab.
        let backtab = shortcut.key == "tab" && flags.contains(.shift)
        let characters = backtab ? "\u{19}" : named[shortcut.key] ?? shortcut.key
        send(characters: characters, keyCode: keyCodes[shortcut.key] ?? 0, flags: flags, in: window)
    }

    private static func send(characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags, in window: NSWindow) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
            ) else { continue }
            NSApp.postEvent(event, atStart: false)
        }
    }

    /// The pressed pointer's last point, where `move` starts.
    private static var pointer: (x: Double, y: Double) = (0, 0)

    static func moveMouse(to x: Double, _ y: Double, in window: NSWindow) async {
        let start = pointer
        for i in 1...10 {
            let t = Double(i) / 10
            mouse(.leftMouseDragged, at: start.x + (x - start.x) * t, start.y + (y - start.y) * t, in: window)
            try? await Task.sleep(for: .milliseconds(30))
        }
    }

    /// A mouse event posted to the app. SwiftUI's gestures also ask `NSEvent.pressedMouseButtons`, which tells the
    /// real button: while a scripted press lasts, it says the left button is down (`ScriptedButtons`).
    static func mouse(_ type: NSEvent.EventType, at x: Double, _ y: Double, in window: NSWindow) {
        ScriptedButtons.install()
        if type == .leftMouseDown { ScriptedButtons.leftDown = true }
        if type == .leftMouseUp { ScriptedButtons.leftDown = false }
        pointer = (x, y)
        let height = window.contentView?.frame.height ?? window.frame.height
        if type == .leftMouseDown { eventNumber += 1 }
        guard let event = mouseEvent(type, at: NSPoint(x: x, y: height - y), in: window) else { return }
        NSApp.postEvent(event, atStart: false)
    }

    /// A mouse event at `point`, in window coordinates (from the bottom left).
    static func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber,
            clickCount: type == .leftMouseDragged ? 0 : 1, pressure: type == .leftMouseUp ? 0 : 1
        )
    }

    private static var eventNumber = 1000
    static func nextEventNumber() -> Int {
        eventNumber += 1
        return eventNumber
    }

    /// The shots being taken, which `quit` waits for.
    private static var filmed: Task<Void, Never>?

    /// `count` shots `interval` ms apart, from now, kept in memory and written once all are taken. A shot takes a
    /// few ms of the main thread, which the times written show.
    static func film(_ window: NSWindow, prefix: String, count: Int, interval: Double, scale: CGFloat?) async {
        let start = CACurrentMediaTime()
        var times = ""
        var shots: [NSBitmapImageRep] = []
        for index in 0..<count {
            let due = start + Double(index) * interval / 1000
            let wait = due - CACurrentMediaTime()
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            let taken = CACurrentMediaTime()
            if let rep = captureLayers(window, scale: scale) ?? capture(window) { shots.append(rep) }
            times += String(format: "%02d %.0f ms (the shot took %.0f ms)\n", index, (taken - start) * 1000,
                            (CACurrentMediaTime() - taken) * 1000)
        }
        for (index, rep) in shots.enumerated() {
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: prefix + String(format: "-%02d.png", index)))
        }
        try? times.write(toFile: prefix + ".txt", atomically: true, encoding: .utf8)
    }

    static func capture(_ window: NSWindow) -> NSBitmapImageRep? {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// The window as its layers hold it now, without drawing its views again (`capture` does, which takes the main
    /// thread for a tenth of a second and more): quick enough to film an animation. Blurs behind glass are left out.
    static func captureLayers(_ window: NSWindow, scale: CGFloat? = nil) -> NSBitmapImageRep? {
        guard let view = window.contentView?.superview ?? window.contentView, let layer = view.layer else { return nil }
        let scale = scale ?? window.backingScaleFactor
        let size = view.bounds.size
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        context.cgContext.scaleBy(x: scale, y: scale)
        // The presentation layer, which holds the animations' values in between.
        (layer.presentation() ?? layer).render(in: context.cgContext)
        return rep
    }

    /// The window as a PNG, with the popovers and menus over it drawn in place.
    static func snapshot(_ window: NSWindow, to path: String) {
        guard let rep = capture(window), let view = window.contentView?.superview ?? window.contentView else { return }
        // The window's own children (the sidebar's glass menus) take its level, and hide while the app is in the
        // background: they count whatever their level, visible or not.
        let children = window.childWindows ?? []
        let above = NSApp.windows.filter { other in
            other !== window && other.frame.intersects(window.frame)
                && (children.contains(other) || other.isVisible
                    && (other.level.rawValue > window.level.rawValue || String(describing: type(of: other)).contains("Popover")))
        }
        if !above.isEmpty, let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            let scale = CGFloat(rep.pixelsWide) / max(view.bounds.width, 1)
            context.cgContext.scaleBy(x: scale, y: scale)
            for other in above {
                guard let otherView = other.contentView?.superview ?? other.contentView,
                      let image = otherView.bitmapImageRepForCachingDisplay(in: otherView.bounds) else { continue }
                otherView.cacheDisplay(in: otherView.bounds, to: image)
                // Also on its own, for a popover that reaches past the window.
                try? image.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-popover.png")))
                let origin = NSPoint(x: other.frame.minX - window.frame.minX, y: other.frame.minY - window.frame.minY)
                image.draw(in: NSRect(origin: origin, size: other.frame.size), from: .zero, operation: .sourceOver,
                           fraction: 1, respectFlipped: true, hints: nil)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// The settings window: the visible window that is not the vault's.
    static func settingsWindow(besides main: NSWindow) -> NSWindow? {
        NSApp.windows.first { $0 !== main && $0.contentView != nil && $0.frame.width > 300 && $0.className.contains("Panel") == false && $0.isVisible }
            ?? NSApp.windows.first { $0 !== main && $0.frame.width > 300 && $0.title.contains("Plugins") }
    }

    static func views(in view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return [view] + view.subviews.flatMap { views(in: $0) }
    }

    private static func firstView(in view: NSView?, responding action: Selector) -> NSView? {
        guard let view else { return nil }
        if view.responds(to: action) { return view }
        for subview in view.subviews where !subview.isHidden {
            if let found = firstView(in: subview, responding: action) { return found }
        }
        return nil
    }

    /// A pasteboard of the script's own, so the user's clipboard is never touched: the files at `paths` (split by
    /// `|`), or the first one's bytes as PNG.
    private static func scriptPasteboard(_ paths: String, asImage: Bool) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("loam.script-driver"))
        pasteboard.clearContents()
        let urls = paths.split(separator: "|").map { URL(fileURLWithPath: String($0).trimmingCharacters(in: .whitespaces)) }
        if asImage, let url = urls.first, let data = try? Data(contentsOf: url) {
            pasteboard.setData(data, forType: .png)
        } else {
            pasteboard.writeObjects(urls as [NSURL])
        }
        return pasteboard
    }

    private static func append(_ text: String, to path: String) {
        let url = URL(fileURLWithPath: path)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

/// Records the time between the window's frames for the `frames` step, from its display link, which fires on the
/// main thread before each frame: a frame the main thread is too busy to make shows as a long interval.
@MainActor
final class FrameRecorder: NSObject {
    private static var running: [FrameRecorder] = []
    private var link: CADisplayLink?
    private var times: [CFTimeInterval] = []
    /// The main thread's CPU time at each frame: what it spent making the frame, whatever else the machine runs.
    private var cpu: [Double] = []
    /// The instructions the process ran at each frame: unlike time, they don't depend on what else runs.
    private var instructions: [UInt64] = []
    private var end: CFTimeInterval = 0
    private var path = ""
    private weak var window: NSWindow?
    private var done: CheckedContinuation<Void, Never>?

    static func start(in window: NSWindow, seconds: Double, to path: String) {
        guard let view = window.contentView else { return }
        let recorder = FrameRecorder()
        recorder.path = path
        recorder.window = window
        recorder.end = CACurrentMediaTime() + seconds
        let link = view.displayLink(target: recorder, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        recorder.link = link
        running.append(recorder)
    }

    /// Waits for the recordings still running.
    static func finished() async {
        for recorder in running where recorder.link != nil {
            await withCheckedContinuation { recorder.done = $0 }
        }
    }

    private static func processInstructions() -> UInt64 {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        return result == 0 ? usage.ri_instructions : 0
    }

    private static func threadCPUTime() -> Double {
        var time = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
        return Double(time.tv_sec) + Double(time.tv_nsec) / 1e9
    }

    @objc private func tick(_ link: CADisplayLink) {
        times.append(link.timestamp)
        cpu.append(Self.threadCPUTime())
        instructions.append(Self.processInstructions())
        guard link.timestamp >= end else { return }
        link.invalidate()
        self.link = nil
        write(expected: link.duration)
        Self.running.removeAll { $0 === self }
        done?.resume()
        done = nil
    }

    private func write(expected: CFTimeInterval) {
        let intervals = zip(times.dropFirst(), times).map { ($0 - $1) * 1000 }
        let frame = expected * 1000
        let long = intervals.filter { $0 > frame * 1.5 }
        let dropped = intervals.reduce(0) { $0 + max(0, Int(($1 / frame).rounded()) - 1) }
        var text = String(
            format: "frames %d, display %.1f ms, mean %.1f ms, max %.1f ms, long %d, dropped %d\n",
            intervals.count, frame, intervals.reduce(0, +) / Double(max(1, intervals.count)),
            intervals.max() ?? 0, long.count, dropped
        )
        let work = zip(cpu.dropFirst(), cpu).map { ($0 - $1) * 1000 }
        // The frames of the animation: those that took the main thread more than a millisecond.
        let busy = work.filter { $0 > 1 }
        text += String(
            format: "main thread per frame: mean %.1f ms over %d busy frames, max %.1f ms\n",
            busy.reduce(0, +) / Double(max(1, busy.count)), busy.count, busy.max() ?? 0
        )
        let counts = zip(instructions.dropFirst(), instructions).map { Double($0 - $1) / 1e6 }
        let busyCounts = zip(work, counts).filter { $0.0 > 1 }.map(\.1)
        text += String(
            format: "instructions per frame: mean %.1f million over %d busy frames, max %.1f million\n",
            busyCounts.reduce(0, +) / Double(max(1, busyCounts.count)), busyCounts.count, busyCounts.max() ?? 0
        )
        text += "ins " + counts.map { String(format: "%.1f", $0) }.joined(separator: " ") + "\n"
        text += "cpu " + work.map { String(format: "%.1f", $0) }.joined(separator: " ") + "\n"
        text += "occlusion \(window?.occlusionState.contains(.visible) == true ? "visible" : "hidden"), ticks \(times.count)\n"
        text += intervals.map { String(format: "%.1f", $0) }.joined(separator: " ") + "\n"
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

/// Answers `NSEvent.pressedMouseButtons` for the script while it holds the button, the real mouse otherwise.
enum ScriptedButtons {
    nonisolated(unsafe) static var leftDown = false
    nonisolated(unsafe) private static var original: IMP?

    @MainActor static func install() {
        guard original == nil,
              let method = class_getClassMethod(NSEvent.self, #selector(getter: NSEvent.pressedMouseButtons))
        else { return }
        let scripted: @convention(block) (AnyObject) -> Int = { type in
            typealias Getter = @convention(c) (AnyObject, Selector) -> Int
            let real = original.map {
                unsafeBitCast($0, to: Getter.self)(type, #selector(getter: NSEvent.pressedMouseButtons))
            } ?? 0
            return leftDown ? real | 1 : real
        }
        original = method_setImplementation(method, imp_implementationWithBlock(scripted))
    }
}
