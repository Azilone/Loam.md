import Foundation

/// What a debug request asks for, checked: a request with a missing or ill-typed parameter never reaches the app's
/// main thread. `request` is the inverse of `init(request:)`, so a Swift client and the tests write requests the way
/// the app reads them.
public enum DebugCommand: Hashable, Sendable {
    /// Where a pointer command acts: a point of the window (points from its top-left corner), or an element found in
    /// the accessibility tree by identifier or label (its centre).
    public enum Target: Hashable, Sendable {
        case point(x: Double, y: Double)
        case id(String)
        case label(String)
    }

    /// How a window picture is made: `view` draws the views again (exact, slow), `layers` renders the layers as they
    /// are now (fast, for film strips; blurs behind glass are left out).
    public enum CaptureMode: String, Sendable { case view, layers }

    case help
    case ping
    /// The instance, the window, the open vault and tab.
    case info
    /// Opens a vault-relative path (or a virtual page such as `graph:`) in the window.
    case open(path: String, placement: String)
    /// Types characters, one key press each (`\n` is Return).
    case type(text: String)
    /// A shortcut or a named key: `cmd+n`, `return`, `shift+tab`.
    case key(shortcut: String, repeats: Int)
    /// `window`: `settings` or `sheet` instead of the main window, as for `screenshot`.
    case click(Target, clicks: Int, modifiers: [String], window: String? = nil)
    case hover(Target)
    case drag(from: Target, to: Target)
    /// The button goes down, the pressed pointer moves, the button comes up: a drag in three steps, to film or
    /// look at it half way. `drag` is the same in one.
    case press(Target)
    case move(Target)
    case release(Target)
    /// Scrolls the scroll view under a point down by `dy` points (up when negative). With `forMs`, posts a trackpad
    /// scroll of `dy` points per frame for that long instead, through the event queue, to measure scrolling. With
    /// `command`, the scroll holds ⌘ (a canvas zooms).
    case scroll(at: Target, dy: Double, forMs: Int = 0, window: String? = nil, command: Bool = false)
    /// Sets the content size. With `live`, drags the window's right edge to the width instead, in `live` steps a
    /// frame apart, as a person resizing it does: AppKit's own live resize (`inLiveResize`), not one `setFrame`.
    case window(width: Double?, height: Double?, front: Bool?, live: Int? = nil)
    case theme(String)
    case reduceMotion(Bool)
    /// The accessibility tree, or only the elements matching `find` (a case-insensitive part of an id, label,
    /// role or value).
    case ax(depth: Int, find: String?)
    /// What is under a point: the accessibility element and the chain of views.
    case hit(Target)
    /// The text, selection and scroll position of the editor.
    case editor
    case screenshot(path: String, mode: CaptureMode, scale: Double?, window: String?)
    /// `count` pictures `intervalMs` apart; `then` runs first (not waited for): the animation to film.
    case film(prefix: String, count: Int, intervalMs: Int, scale: Double?, then: DebugRequest?)
    /// Runs a command of the palette (`mindmap.open`).
    case run(command: String, arguments: [String: String])
    case wait(ms: Int)
    case quit

    public static let names = [
        "help", "ping", "info", "open", "type", "key", "click", "hover", "drag", "press", "move", "release", "scroll", "window", "theme",
        "reduce-motion", "ax", "hit", "editor", "screenshot", "film", "run", "wait", "quit",
    ]

    public init(request: DebugRequest) throws {
        func string(_ name: String) throws -> String {
            guard let value = request[name]?.string else { throw DebugError.missing(name) }
            return value
        }
        func number(_ name: String) throws -> Double {
            guard let value = request[name]?.double else { throw DebugError.missing(name) }
            return value
        }
        /// `x`/`y`, `axid` (an accessibility identifier; `id` is the request's own) or `label`, with a `2` suffix for the
        /// second end of a drag: `x2`, `y2`, `axid2`, `label2`.
        func target(_ suffix: String = "") throws -> Target {
            if let x = request["x" + suffix]?.double, let y = request["y" + suffix]?.double { return .point(x: x, y: y) }
            if let id = request["axid" + suffix]?.string { return .id(id) }
            if let label = request["label" + suffix]?.string { return .label(label) }
            throw DebugError.missing("x and y, axid or label")
        }
        switch request.cmd {
        case "help": self = .help
        case "ping": self = .ping
        case "info": self = .info
        case "open": self = .open(path: try string("path"), placement: request["placement"]?.string ?? "replace")
        case "type": self = .type(text: try string("text"))
        case "key": self = .key(shortcut: try string("keys"), repeats: max(1, request["repeat"]?.int ?? 1))
        case "click":
            self = .click(
                try target(), clicks: min(3, max(1, request["clicks"]?.int ?? 1)),
                modifiers: request["modifiers"]?.array?.compactMap(\.string) ?? [],
                window: request["window"]?.string
            )
        case "hover": self = .hover(try target())
        case "drag": self = .drag(from: try target(), to: try target("2"))
        case "press": self = .press(try target())
        case "move": self = .move(try target())
        case "release": self = .release(try target())
        case "scroll":
            self = .scroll(
                at: try target(), dy: try number("dy"), forMs: max(0, request["for"]?.int ?? 0), window: request["window"]?.string,
                command: request["command"]?.bool ?? false
            )
        case "window":
            self = .window(
                width: request["width"]?.double, height: request["height"]?.double, front: request["front"]?.bool,
                live: request["live"]?.int
            )
        case "theme":
            let value = try string("value")
            guard ["light", "dark", "auto"].contains(value) else { throw DebugError.missing("value (light, dark or auto)") }
            self = .theme(value)
        case "reduce-motion":
            guard let on = request["value"]?.bool else { throw DebugError.missing("value (true or false)") }
            self = .reduceMotion(on)
        case "ax": self = .ax(depth: request["depth"]?.int ?? 12, find: request["find"]?.string)
        case "hit": self = .hit(try target())
        case "editor": self = .editor
        case "screenshot":
            let mode = request["mode"]?.string.flatMap(CaptureMode.init(rawValue:)) ?? .view
            self = .screenshot(path: try string("path"), mode: mode, scale: request["scale"]?.double, window: request["window"]?.string)
        case "film":
            var then: DebugRequest?
            if let nested = request["then"] {
                guard let data = try? JSONEncoder().encode(nested) else { throw DebugError.missing("then") }
                then = try DebugCoding.decodeRequest(data)
            }
            self = .film(
                prefix: try string("prefix"), count: min(200, max(1, request["count"]?.int ?? 6)),
                intervalMs: max(0, request["interval"]?.int ?? 50), scale: request["scale"]?.double, then: then
            )
        case "run":
            var arguments: [String: String] = [:]
            for (name, value) in request["args"]?.object ?? [:] { arguments[name] = value.string ?? "\(value.double ?? 0)" }
            self = .run(command: try string("command"), arguments: arguments)
        case "wait": self = .wait(ms: max(0, Int(try number("ms"))))
        case "quit": self = .quit
        default: throw DebugError.unknownCommand(request.cmd)
        }
    }

    /// The request that reads back as this command.
    public var request: DebugRequest {
        func point(_ target: Target, _ suffix: String = "") -> [String: DebugValue] {
            switch target {
            case .point(let x, let y): ["x" + suffix: .number(x), "y" + suffix: .number(y)]
            case .id(let id): ["axid" + suffix: .string(id)]
            case .label(let label): ["label" + suffix: .string(label)]
            }
        }
        switch self {
        case .help: return DebugRequest(cmd: "help")
        case .ping: return DebugRequest(cmd: "ping")
        case .info: return DebugRequest(cmd: "info")
        case .open(let path, let placement): return DebugRequest(cmd: "open", params: ["path": .string(path), "placement": .string(placement)])
        case .type(let text): return DebugRequest(cmd: "type", params: ["text": .string(text)])
        case .key(let shortcut, let repeats): return DebugRequest(cmd: "key", params: ["keys": .string(shortcut), "repeat": .number(Double(repeats))])
        case .click(let target, let clicks, let modifiers, let window):
            var params = point(target)
            params["clicks"] = .number(Double(clicks))
            if !modifiers.isEmpty { params["modifiers"] = .array(modifiers.map { .string($0) }) }
            if let window { params["window"] = .string(window) }
            return DebugRequest(cmd: "click", params: params)
        case .hover(let target): return DebugRequest(cmd: "hover", params: point(target))
        case .drag(let from, let to): return DebugRequest(cmd: "drag", params: point(from).merging(point(to, "2")) { $1 })
        case .press(let target): return DebugRequest(cmd: "press", params: point(target))
        case .move(let target): return DebugRequest(cmd: "move", params: point(target))
        case .release(let target): return DebugRequest(cmd: "release", params: point(target))
        case .scroll(let at, let dy, let forMs, let window, let command):
            var params = point(at)
            params["dy"] = .number(dy)
            if forMs > 0 { params["for"] = .number(Double(forMs)) }
            if let window { params["window"] = .string(window) }
            if command { params["command"] = .bool(true) }
            return DebugRequest(cmd: "scroll", params: params)
        case .window(let width, let height, let front, let live):
            var params: [String: DebugValue] = [:]
            if let live { params["live"] = .number(Double(live)) }
            if let width { params["width"] = .number(width) }
            if let height { params["height"] = .number(height) }
            if let front { params["front"] = .bool(front) }
            return DebugRequest(cmd: "window", params: params)
        case .theme(let value): return DebugRequest(cmd: "theme", params: ["value": .string(value)])
        case .reduceMotion(let on): return DebugRequest(cmd: "reduce-motion", params: ["value": .bool(on)])
        case .ax(let depth, let find):
            var params: [String: DebugValue] = ["depth": .number(Double(depth))]
            if let find { params["find"] = .string(find) }
            return DebugRequest(cmd: "ax", params: params)
        case .hit(let target): return DebugRequest(cmd: "hit", params: point(target))
        case .editor: return DebugRequest(cmd: "editor")
        case .screenshot(let path, let mode, let scale, let window):
            var params: [String: DebugValue] = ["path": .string(path), "mode": .string(mode.rawValue)]
            if let scale { params["scale"] = .number(scale) }
            if let window { params["window"] = .string(window) }
            return DebugRequest(cmd: "screenshot", params: params)
        case .film(let prefix, let count, let intervalMs, let scale, let then):
            var params: [String: DebugValue] = ["prefix": .string(prefix), "count": .number(Double(count)), "interval": .number(Double(intervalMs))]
            if let scale { params["scale"] = .number(scale) }
            if let then, let data = try? DebugCoding.encode(then) as Data, let value = try? JSONDecoder().decode(DebugValue.self, from: data) {
                params["then"] = value
            }
            return DebugRequest(cmd: "film", params: params)
        case .run(let command, let arguments):
            return DebugRequest(cmd: "run", params: ["command": .string(command), "args": .object(arguments.mapValues { .string($0) })])
        case .wait(let ms): return DebugRequest(cmd: "wait", params: ["ms": .number(Double(ms))])
        case .quit: return DebugRequest(cmd: "quit")
        }
    }
}
