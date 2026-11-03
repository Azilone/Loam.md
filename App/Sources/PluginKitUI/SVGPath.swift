import CoreGraphics
import Foundation

/// Builds a `CGPath` from an SVG path's `d` string (M L H V C S A Z, absolute and relative), so a glyph drawn in a
/// design file can be pasted as it is. Coordinates stay as written: y goes down, as in SVG.
public enum SVGPath {
    public static func path(_ d: String) -> CGPath {
        let path = CGMutablePath()
        var scanner = Tokens(d)
        var command: Character = "M"
        var current = CGPoint.zero, start = CGPoint.zero
        var lastControl: CGPoint?

        while let next = scanner.next() {
            if case .command(let c) = next { command = c } else { scanner.pushBack(next) }
            let relative = command.isLowercase
            let origin = relative ? current : .zero
            func point() -> CGPoint {
                let x = scanner.number(), y = scanner.number()
                return CGPoint(x: origin.x + x, y: origin.y + y)
            }
            switch command.uppercased().first! {
            case "M":
                current = point(); start = current
                path.move(to: current)
                // Pairs after a move are lines.
                command = relative ? "l" : "L"
                lastControl = nil
            case "L":
                current = point(); path.addLine(to: current); lastControl = nil
            case "H":
                current.x = (relative ? current.x : 0) + scanner.number(); path.addLine(to: current); lastControl = nil
            case "V":
                current.y = (relative ? current.y : 0) + scanner.number(); path.addLine(to: current); lastControl = nil
            case "C":
                let c1 = point(), c2 = point(), end = point()
                path.addCurve(to: end, control1: c1, control2: c2)
                lastControl = c2; current = end
            case "S":
                let c1 = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                let c2 = point(), end = point()
                path.addCurve(to: end, control1: c1, control2: c2)
                lastControl = c2; current = end
            case "A":
                let rx = scanner.number(), ry = scanner.number(), rotation = scanner.number()
                let large = scanner.flag(), sweep = scanner.flag()
                let end = point()
                arc(path, from: current, to: end, rx: rx, ry: ry, rotation: rotation, large: large, sweep: sweep)
                current = end; lastControl = nil
            case "Z":
                path.closeSubpath(); current = start; lastControl = nil
            default:
                return path
            }
        }
        return path
    }

    /// An SVG elliptical arc as cubic curves (the endpoint to centre conversion of the SVG specification).
    private static func arc(_ path: CGMutablePath, from p0: CGPoint, to p1: CGPoint, rx: CGFloat, ry: CGFloat,
                            rotation: CGFloat, large: Bool, sweep: Bool) {
        var rx = abs(rx), ry = abs(ry)
        guard rx > 0, ry > 0, p0 != p1 else { path.addLine(to: p1); return }
        let phi = rotation * .pi / 180, cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy, y1 = -sinPhi * dx + cosPhi * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var coef = sqrt(max(0, num / den))
        if large == sweep { coef = -coef }
        let cx1 = coef * rx * y1 / ry, cy1 = -coef * ry * x1 / rx
        let cx = cosPhi * cx1 - sinPhi * cy1 + (p0.x + p1.x) / 2
        let cy = sinPhi * cx1 + cosPhi * cy1 + (p0.y + p1.y) / 2
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let theta1 = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi } else if sweep && delta < 0 { delta += 2 * .pi }
        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / CGFloat(segments)
        let k = 4.0 / 3.0 * tan(step / 4)
        func at(_ t: CGFloat) -> CGPoint {
            CGPoint(x: cx + rx * cos(t) * cosPhi - ry * sin(t) * sinPhi, y: cy + rx * cos(t) * sinPhi + ry * sin(t) * cosPhi)
        }
        func derivative(_ t: CGFloat) -> CGPoint {
            CGPoint(x: -rx * sin(t) * cosPhi - ry * cos(t) * sinPhi, y: -rx * sin(t) * sinPhi + ry * cos(t) * cosPhi)
        }
        var t = theta1
        for _ in 0..<segments {
            let a = at(t), b = at(t + step), da = derivative(t), db = derivative(t + step)
            path.addCurve(to: b, control1: CGPoint(x: a.x + k * da.x, y: a.y + k * da.y),
                          control2: CGPoint(x: b.x - k * db.x, y: b.y - k * db.y))
            t += step
        }
    }

    private enum Token { case command(Character), number(CGFloat) }

    /// The commands and numbers of a `d` string. Numbers may run together as SVG writes them: "1.5.5" is 1.5 and .5,
    /// "2-3" is 2 and -3; arc flags may be a single digit glued to what follows.
    private struct Tokens {
        let chars: [Character]
        var index = 0
        var pending: Token?

        init(_ d: String) { chars = Array(d) }

        mutating func pushBack(_ token: Token) { pending = token }

        mutating func skip() {
            while index < chars.count, chars[index] == " " || chars[index] == "," || chars[index] == "\n" { index += 1 }
        }

        mutating func next() -> Token? {
            if let pending { self.pending = nil; return pending }
            skip()
            guard index < chars.count else { return nil }
            let c = chars[index]
            if c.isLetter && c != "e" && c != "E" { index += 1; return .command(c) }
            return .number(readNumber())
        }

        mutating func number() -> CGFloat {
            if let pending, case .number(let n) = pending { self.pending = nil; return n }
            skip()
            return readNumber()
        }

        mutating func flag() -> Bool {
            skip()
            guard index < chars.count else { return false }
            let c = chars[index]; index += 1
            return c == "1"
        }

        private mutating func readNumber() -> CGFloat {
            var text = ""
            var seenDot = false, seenExp = false
            while index < chars.count {
                let c = chars[index]
                if c.isNumber { text.append(c) }
                else if c == "." && !seenDot && !seenExp { seenDot = true; text.append(c) }
                else if (c == "-" || c == "+") && (text.isEmpty || text.last == "e" || text.last == "E") { text.append(c) }
                else if (c == "e" || c == "E") && !seenExp && !text.isEmpty { seenExp = true; text.append(c) }
                else { break }
                index += 1
            }
            return CGFloat(Double(text) ?? 0)
        }
    }
}
