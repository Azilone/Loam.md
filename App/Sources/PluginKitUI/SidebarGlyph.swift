import AppKit
import SwiftUI

/// The sidebar's icons, drawn one by one in the folder's manner (`AnimatedFolderIcon`): a tinted back plane, a lighter
/// front plane, a 1.2 stroke on an 18 point grid and a faint shadow. Each has one mechanical gesture: half of it under
/// the pointer, all of it when what it stands for opens, back when it closes. 250 ms on Core Animation's default
/// curve, nothing that bounces; Reduce Motion keeps them still. A plugin gives its own symbol a glyph with
/// `SidebarGlyph.register`; any other symbol draws as its SF Symbol, with the same lift under the pointer.
public struct SidebarIcon: View {
    let symbol: String
    let color: Color
    let ground: Color
    var size: CGFloat
    /// Nil: the row's (`sidebarRow`), read from the environment.
    var hoveredOverride: Bool?
    var activeOverride: Bool?
    @Environment(\.sidebarRowHovered) private var rowHovered
    @Environment(\.sidebarRowSelected) private var rowSelected
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(_ symbol: String, color: Color, ground: Color, size: CGFloat = SidebarStyle.iconSize, hovered: Bool? = nil, active: Bool? = nil) {
        self.symbol = symbol
        self.color = color
        self.ground = ground
        self.size = size
        self.hoveredOverride = hovered
        self.activeOverride = active
    }

    private var hovered: Bool { hoveredOverride ?? rowHovered }
    private var active: Bool { activeOverride ?? rowSelected }

    public var body: some View {
        if let glyph = SidebarGlyph.named(for: symbol) {
            SidebarGlyphRepresentable(glyph: glyph, amount: active ? 1 : hovered ? SidebarGlyph.peek : 0,
                                      color: color, ground: ground, size: size)
                .frame(width: size, height: size)
        } else {
            // The glyphs' gesture, for a symbol with none: a small lift, all of it when open.
            let amount = reduceMotion ? 0 : active ? 1 : hovered ? SidebarGlyph.peek : 0
            Image(symbol: symbol).foregroundStyle(color)
                .scaleEffect(1 + 0.08 * amount)
                .offset(y: -SidebarGlyph.travel * 0.5 * amount)
                .animation(.easeInOut(duration: 0.25), value: amount)
        }
    }
}

public extension EnvironmentValues {
    /// Whether the pointer is over the sidebar row around (`sidebarRow`): its icon answers.
    @Entry var sidebarRowHovered = false
    /// Whether the sidebar row around is selected: its icon stands open.
    @Entry var sidebarRowSelected = false
}

public extension ThemeTokens {
    /// What a sidebar row's icon sits on: the accent of the selected row, else the sidebar.
    func sidebarGround(selected: Bool) -> Color {
        if selected { return accent }
        return palette.sidebar.map(Color.init) ?? Color(nsColor: .windowBackgroundColor)
    }
}

/// One of the sidebar's drawn icons: pieces that move with the gesture's amount (0 at rest, `peek` under the
/// pointer, 1 open), each holding shapes and smaller pieces.
@MainActor
public struct SidebarGlyph {
    /// How far the gesture goes under the pointer.
    public static let peek: CGFloat = 0.6

    public enum Style: Sendable { case stroke, back, front, ink }

    public struct Shape {
        var path: CGPath
        var style: Style
        /// The opacity at rest and open.
        var opacity: (rest: CGFloat, open: CGFloat) = (1, 1)
        /// Whether the stroke draws itself again as the icon is hovered or opens.
        var redraws = false
        /// The bar's place in a wave of light, as the icon is hovered or opens.
        var wave: Int?
    }

    public struct Piece {
        var origin = CGPoint.zero
        var move = CGPoint.zero
        var turn: CGFloat = 0
        /// Added to the scale when open: 0.2 makes it 1.2 times larger.
        var grow = CGSize.zero
        var shapes: [Shape] = []
        var pieces: [Piece] = []
    }

    let root: Piece

    /// How far every glyph's most moving point goes when it opens, in points of its grid: the same for all, so none
    /// is louder than another (the folder's front moves about as much).
    public static let travel: CGFloat = 1.8

    /// How much farther than `travel` this glyph goes: a whole shape turning about its centre (a gear, the sync
    /// arrows) or a lid tilting reads smaller than a part that slides, so it goes farther to look as lively.
    let gain: CGFloat

    /// The glyph `root` draws, its gesture scaled to `travel` times `gain`. A glyph whose gesture only lights or draws
    /// (a waveform, a check) keeps it as it is.
    init(root: Piece, gain: CGFloat = 1) {
        var root = root
        for _ in 0..<3 {
            let measured = Self.travel(of: root, under: .identity)
            guard measured > 0.01 else { break }
            root = Self.scaled(root, by: Self.travel * gain / measured)
        }
        self.root = root
        self.gain = gain
    }

    /// How far the glyph's most moving point goes when it opens.
    var measuredTravel: CGFloat { Self.travel(of: root, under: .identity) }

    private static func travel(of piece: Piece, under parent: CGAffineTransform) -> CGFloat {
        let transform = CGAffineTransform(translationX: piece.origin.x + piece.move.x, y: piece.origin.y + piece.move.y)
            .rotated(by: piece.turn * .pi / 180)
            .scaledBy(x: 1 + piece.grow.width, y: 1 + piece.grow.height)
            .translatedBy(x: -piece.origin.x, y: -piece.origin.y)
            .concatenating(parent)
        var farthest: CGFloat = 0
        for shape in piece.shapes {
            shape.path.applyWithBlock { element in
                let count: Int = switch element.pointee.type {
                case .moveToPoint, .addLineToPoint: 1
                case .addQuadCurveToPoint: 2
                case .addCurveToPoint: 3
                default: 0
                }
                for index in 0..<count {
                    let point = element.pointee.points[index], moved = point.applying(transform)
                    farthest = max(farthest, hypot(moved.x - point.x, moved.y - point.y))
                }
            }
        }
        return piece.pieces.reduce(farthest) { max($0, travel(of: $1, under: transform)) }
    }

    private static func scaled(_ piece: Piece, by factor: CGFloat) -> Piece {
        var piece = piece
        piece.move = CGPoint(x: piece.move.x * factor, y: piece.move.y * factor)
        piece.turn *= factor
        piece.grow = CGSize(width: piece.grow.width * factor, height: piece.grow.height * factor)
        piece.pieces = piece.pieces.map { scaled($0, by: factor) }
        return piece
    }

    private static var registered: [String: SidebarGlyph] = [:]

    /// Gives a plugin's symbol a glyph drawn in the sidebar's manner, from SVG path data on the 18 point grid:
    /// `fill`, if any, as the tinted back plane, `outline` as the 1.2 stroke over it. Under the pointer the glyph
    /// lifts and grows a little, as the app's own do. Loam's own glyphs win for the symbols they cover.
    public static func register(_ symbol: String, outline: String, fill: String? = nil) {
        var shapes: [Shape] = []
        if let fill { shapes.append(Shape(path: SVGPath.path(fill), style: .back)) }
        shapes.append(Shape(path: SVGPath.path(outline), style: .stroke))
        registered[symbol] = SidebarGlyph(root: Piece(pieces: [
            Piece(origin: CGPoint(x: 9, y: 15), move: CGPoint(x: 0, y: -1), grow: CGSize(width: 0.08, height: 0.08), shapes: shapes),
        ]))
    }

    /// The glyph for an SF Symbol name of a sidebar row, nil when neither the sidebar nor a plugin has one.
    public static func named(for symbol: String) -> SidebarGlyph? {
        let name = symbol.hasSuffix(".fill") ? String(symbol.dropLast(5)) : symbol
        switch name {
        case "magnifyingglass": return search
        case "doc.on.doc": return notes
        case "checkmark.circle", "checklist": return tasks
        case "square.stack.3d.up": return projects
        case "calendar": return calendar
        case "flame": return habits
        case "waveform": return meetings
        case "point.3.connected.trianglepath.dotted": return graph
        case "rectangle.3.group", "rectangle.on.rectangle", "rectangle.on.rectangle.angled": return boards
        case "scribble.variable", "scribble": return drawings
        case LoamSymbol.mindmap: return mindmaps
        case "paperclip": return attachment
        case "star": return star
        case "clock": return recent
        case "doc", "doc.text": return note
        case "ellipsis": return more
        case "gearshape": return settings
        case "trash": return trash
        case "arrow.triangle.2.circlepath": return sync
        case "sidebar.leading", "sidebar.left": return sidebar
        case "plus": return plus
        case "tray": return inbox
        case "loam.vault": return vault
        default: return registered[symbol] ?? registered[name]
        }
    }
}

// MARK: - The glyphs

private func p(_ d: String) -> CGPath { SVGPath.path(d) }

private func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r), transform: nil)
}

private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
    CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
}

private typealias S = SidebarGlyph.Shape
private typealias P = SidebarGlyph.Piece

/// A shape filled and outlined: `fill` then the stroke over it.
private func outlined(_ path: CGPath, _ fill: SidebarGlyph.Style) -> [S] {
    [S(path: path, style: fill), S(path: path, style: .stroke)]
}

extension SidebarGlyph {
    static let search = SidebarGlyph(root: P(pieces: [
        P(origin: CGPoint(x: 7.5, y: 7.5), move: CGPoint(x: -0.5, y: -0.5), turn: -14, shapes: [
            S(path: circle(7.5, 7.5, 4.9), style: .back),
            S(path: p("M5.2 6.2a2.6 2.6 0 0 1 2-1.8"), style: .stroke, opacity: (0, 1)),
            S(path: circle(7.5, 7.5, 4.9), style: .stroke),
            S(path: p("M11.1 11.1 15 15"), style: .stroke),
        ]),
    ]))

    static let notes = SidebarGlyph(root: P(pieces: [
        P(origin: CGPoint(x: 14.5, y: 14), move: CGPoint(x: 0.8, y: -0.6), turn: 7,
          shapes: outlined(rect(5.5, 2.5, 9, 11, 2.2), .back)),
        P(origin: CGPoint(x: 3.5, y: 15.5), turn: -5, shapes: outlined(rect(3, 4.8, 9, 11, 2.2), .front) + [
            S(path: p("M5.6 8.6h3.8M5.6 11.2h2.6"), style: .stroke, opacity: (0.75, 0.75)),
        ]),
    ]), gain: 1.8)

    static let tasks = SidebarGlyph(root: P(shapes: [
        S(path: circle(9, 9, 6.4), style: .front),
        S(path: circle(9, 9, 6.4), style: .back, opacity: (0, 1)),
        S(path: circle(9, 9, 6.4), style: .stroke),
        S(path: p("M6.1 9.3 8.2 11.3 12 7.1"), style: .stroke, redraws: true),
    ]))

    static let projects = SidebarGlyph(root: P(pieces: [
        P(move: CGPoint(x: 0, y: 1), shapes: [S(path: p("M2.6 12.2 9 15.6l6.4-3.4"), style: .stroke)]),
        P(shapes: [S(path: p("M2.6 9.1 9 12.5l6.4-3.4"), style: .stroke)]),
        P(move: CGPoint(x: 0, y: -1.3), shapes: outlined(p("M9 2.4 15.4 5.8 9 9.2 2.6 5.8Z"), .front)),
    ]))

    static let calendar = SidebarGlyph(root: P(shapes: [
        S(path: rect(2.5, 3.8, 13, 11.7, 2.5), style: .front),
        S(path: p("M2.5 6.3a2.5 2.5 0 0 1 2.5-2.5h8a2.5 2.5 0 0 1 2.5 2.5V7.6h-13Z"), style: .back),
        S(path: rect(2.5, 3.8, 13, 11.7, 2.5), style: .stroke),
        S(path: p("M2.5 7.6h13"), style: .stroke),
        S(path: circle(6.3, 10.6, 0.75), style: .ink, opacity: (0.45, 1)),
        S(path: circle(9, 10.6, 0.75), style: .ink, opacity: (0.45, 1)),
        S(path: circle(6.3, 13, 0.75), style: .ink, opacity: (0.45, 1)),
    ], pieces: [
        P(move: CGPoint(x: 0, y: -1.2), shapes: [S(path: p("M6.2 2.3v2.6M11.8 2.3v2.6"), style: .stroke)]),
        P(origin: CGPoint(x: 11.7, y: 10.6), grow: CGSize(width: 0.5, height: 0.5),
          shapes: [S(path: circle(11.7, 10.6, 0.75), style: .ink)]),
    ]))

    private static let flame = p("M9 2.4c1.5 3 5 5 5 8.8C14 14 11.8 16 9 16s-5-2-5-4.8c0-2.4 1.6-3.8 2.6-5 .3 1.4 1 2.2 1.8 2.4-.2-2 0-4.2.6-6.2Z")

    private static let flameCore = p("M9 9.9c1.2 1.2 2 2.3 2 3.5 0 1.1-.9 1.8-2 1.8s-2-.7-2-1.8c0-1.2.8-2.3 2-3.5Z")

    static let habits = SidebarGlyph(root: P(pieces: [
        P(origin: CGPoint(x: 9, y: 16), turn: -5, grow: CGSize(width: 0.04, height: 0.06),
          shapes: [S(path: flame, style: .front)], pieces: [
            P(origin: CGPoint(x: 9, y: 15.2), grow: CGSize(width: 0.3, height: 0.3), shapes: [
                S(path: flameCore, style: .back),
                // The core kindles as the flame leans.
                S(path: flameCore, style: .ink, opacity: (0, 0.45)),
            ]),
            P(shapes: [S(path: flame, style: .stroke)]),
        ]),
    ]), gain: 1.5)

    static let meetings = SidebarGlyph(root: P(shapes: [(3, 4), (6, 8), (9, 11), (12, 7), (15, 4)].enumerated().map { index, bar in
        let (x, h) = (CGFloat(bar.0), CGFloat(bar.1))
        return S(path: p("M\(x) \(9 - h / 2)V\(9 + h / 2)"), style: .stroke, wave: index)
    }))

    static let graph: SidebarGlyph = {
        let nodes: [CGPoint] = [CGPoint(x: 5, y: 5), CGPoint(x: 13, y: 6.2), CGPoint(x: 8.2, y: 13.6)]
        return SidebarGlyph(root: P(pieces: [
            P(origin: CGPoint(x: 8.7, y: 8.2), turn: 16,
              shapes: [S(path: p("M5 5 13 6.2M5 5l3.2 8.4M13 6.2l-4.8 7.2"), style: .stroke, opacity: (0.7, 0.7))],
              pieces: nodes.map { node in
                  P(origin: node, grow: CGSize(width: 0.18, height: 0.18), shapes: outlined(circle(node.x, node.y, 2), .front))
              }),
        ]))
    }()

    static let boards = SidebarGlyph(root: P(pieces: [
        P(move: CGPoint(x: 0.7, y: -0.7), shapes: outlined(rect(5.2, 2.8, 10.3, 8, 2.2), .back)),
        P(origin: CGPoint(x: 2.5, y: 15), move: CGPoint(x: -0.4, y: 0.5), turn: -4,
          shapes: outlined(rect(2.5, 6.5, 10.3, 8.6, 2.2), .front)),
    ]))

    static let drawings = SidebarGlyph(root: P(shapes: [
        S(path: p("M3 12.8C5 6 7.6 5 8.1 8.1c.5 3.4 2.4 4.3 3.9.9.9-2.1 2.4-2.4 3.4-.9"), style: .stroke, redraws: true),
        S(path: circle(15.4, 8.1, 0.9), style: .ink, opacity: (0, 1)),
    ]))

    static let mindmaps = SidebarGlyph(root: P(shapes: outlined(rect(6.3, 7.3, 5.4, 3.4, 1.7), .front), pieces: [
        P(origin: CGPoint(x: 6.5, y: 9), grow: CGSize(width: 0.14, height: 0),
          shapes: [S(path: p("M6.5 9C4.8 9 4.6 4.8 2.8 4.8M6.5 9c-1.7 0-1.9 4.2-3.7 4.2"), style: .stroke)]),
        P(origin: CGPoint(x: 11.5, y: 9), grow: CGSize(width: 0.14, height: 0),
          shapes: [S(path: p("M11.5 9c1.7 0 1.9-4.2 3.7-4.2M11.5 9c1.7 0 1.9 4.2 3.7 4.2"), style: .stroke)]),
    ]).reordered())

    static let attachment = SidebarGlyph(root: P(pieces: [
        P(origin: CGPoint(x: 10, y: 10), turn: -14, shapes: [
            S(path: p("M12.6 6.9 7.7 11.8a1.6 1.6 0 0 0 2.3 2.3l4.6-4.6a3 3 0 0 0-4.3-4.3L5.5 10a4.4 4.4 0 0 0 6.2 6.2l3.2-3.2"), style: .stroke),
        ]),
    ]))

    private static let starPath = p("M9 2.6l1.9 4 4.3.5-3.2 3 .9 4.3L9 12.3l-3.9 2.1.9-4.3-3.2-3 4.3-.5Z")

    static let star = SidebarGlyph(root: P(pieces: [
        P(origin: CGPoint(x: 9, y: 9.4), turn: 10, grow: CGSize(width: 0.06, height: 0.06), shapes: [
            S(path: starPath, style: .front),
            S(path: starPath, style: .back, opacity: (0, 1)),
            S(path: starPath, style: .stroke),
        ]),
    ]))

    static let recent = SidebarGlyph(root: P(shapes: outlined(circle(9, 9, 6.4), .front), pieces: [
        P(origin: CGPoint(x: 9, y: 9), turn: 90, shapes: [S(path: p("M9 9V5.4"), style: .stroke)]),
        P(origin: CGPoint(x: 9, y: 9), turn: 8, shapes: [S(path: p("M9 9l2.4 1.4"), style: .stroke)]),
    ]))

    private static let page = p("M5 2.5h5.3L14 6.2V13a2.5 2.5 0 0 1-2.5 2.5H5A2.5 2.5 0 0 1 2.5 13V5A2.5 2.5 0 0 1 5 2.5Z")

    static let note = SidebarGlyph(root: P(shapes: outlined(page, .front), pieces: [
        P(origin: CGPoint(x: 14, y: 2.5), grow: CGSize(width: 0.35, height: 0.35), shapes: [
            S(path: p("M10.3 2.5V5a1.2 1.2 0 0 0 1.2 1.2H14Z"), style: .back),
            S(path: p("M10.3 2.5V5a1.2 1.2 0 0 0 1.2 1.2H14"), style: .stroke),
        ]),
        P(shapes: [S(path: p("M5.4 9.4h4.6M5.4 12h3"), style: .stroke, opacity: (0.7, 0.7))]),
    ]))

    static let more = SidebarGlyph(root: P(pieces: [(-1, 4.5), (0, 9), (1, 13.5)].map { side, x in
        P(move: CGPoint(x: CGFloat(side) * 0.7, y: 0), shapes: [S(path: circle(CGFloat(x), 9, 1.1), style: .ink)])
    }))

    /// A gear of eight teeth around (9, 9).
    private static let gear: CGPath = {
        let path = CGMutablePath()
        let teeth = 8, outer: CGFloat = 6.6, inner: CGFloat = 5.1, width = CGFloat.pi / CGFloat(teeth)
        for tooth in 0..<teeth {
            let a = CGFloat(tooth) / CGFloat(teeth) * 2 * .pi
            let corners: [(CGFloat, CGFloat)] = [(a - width * 0.42, inner), (a - width * 0.26, outer), (a + width * 0.26, outer),
                                                 (a + width * 0.42, inner), (a + width * 0.58, inner)]
            for (index, corner) in corners.enumerated() {
                let point = CGPoint(x: 9 + cos(corner.0) * corner.1, y: 9 + sin(corner.0) * corner.1)
                tooth == 0 && index == 0 ? path.move(to: point) : path.addLine(to: point)
            }
        }
        path.closeSubpath()
        return path
    }()

    static let settings = SidebarGlyph(root: P(pieces: [
        P(origin: CGPoint(x: 9, y: 9), turn: 45, shapes: outlined(gear, .front)),
        P(shapes: outlined(circle(9, 9, 2.1), .back)),
    ]), gain: 2.4)

    private static let bin = p("M4.3 6.6h9.4l-.7 7.4a1.8 1.8 0 0 1-1.8 1.6H6.8A1.8 1.8 0 0 1 5 14Z")

    static let trash = SidebarGlyph(root: P(pieces: [
        P(origin: CGPoint(x: 3, y: 4.8), move: CGPoint(x: 0, y: -0.8), turn: -12, shapes: [
            S(path: p("M2.8 4.8h12.4M7 4.8V3.6c0-.6.5-1.1 1.1-1.1h1.8c.6 0 1.1.5 1.1 1.1v1.2"), style: .stroke),
        ]),
        P(shapes: outlined(bin, .front) + [S(path: p("M7.6 9v4M10.4 9v4"), style: .stroke, opacity: (0.7, 0.7))]),
    ]), gain: 1.8)

    static let sync = SidebarGlyph(root: P(pieces: [
        P(origin: CGPoint(x: 9, y: 9), turn: 90, shapes: [
            S(path: p("M14.6 7.6A5.8 5.8 0 0 0 4 6.2M3.4 10.4A5.8 5.8 0 0 0 14 11.8"), style: .stroke),
            S(path: p("M4 3.4v2.8h2.8M14 14.6v-2.8h-2.8"), style: .stroke),
        ]),
    ]), gain: 3)

    static let sidebar = SidebarGlyph(root: P(shapes: [S(path: rect(2.5, 3.5, 13, 11, 2.5), style: .front)], pieces: [
        P(origin: CGPoint(x: 2.5, y: 9), grow: CGSize(width: -0.4, height: 0),
          shapes: [S(path: p("M5 3.5h2.4v11H5A2.5 2.5 0 0 1 2.5 12V6A2.5 2.5 0 0 1 5 3.5Z"), style: .back)]),
        P(shapes: [S(path: rect(2.5, 3.5, 13, 11, 2.5), style: .stroke)]),
        P(move: CGPoint(x: -1.95, y: 0), shapes: [S(path: p("M7.4 3.5v11"), style: .stroke)]),
    ]))

    /// An arrow drops into the tray.
    static let inbox = SidebarGlyph(root: P(pieces: [
        P(move: CGPoint(x: 0, y: 1.8), shapes: [S(path: p("M9 1.6v5.6M6.8 5.2 9 7.4l2.2-2.2"), style: .stroke)]),
        P(shapes: [
            S(path: p("M2.5 10.5h3.6l.9 1.6h4l.9-1.6h3.6V13a2.5 2.5 0 0 1-2.5 2.5H5A2.5 2.5 0 0 1 2.5 13Z"), style: .front),
            S(path: p("M5 6.2 2.5 10.5V13A2.5 2.5 0 0 0 5 15.5h8a2.5 2.5 0 0 0 2.5-2.5v-2.5L13 6.2M2.5 10.5h3.6l.9 1.6h4l.9-1.6h3.6"),
              style: .stroke),
        ]),
    ]))

    /// A safe whose dial turns, as if to open it.
    static let vault = SidebarGlyph(root: P(shapes: outlined(rect(2.5, 2.8, 13, 11.6, 2.5), .front) + [
        S(path: p("M5.4 14.4v1.2M12.6 14.4v1.2"), style: .stroke),
        S(path: p("M2.5 6.2h1.2M2.5 11h1.2"), style: .stroke, opacity: (0.7, 0.7)),
    ], pieces: [
        P(origin: CGPoint(x: 9.4, y: 8.6), turn: 90, shapes: outlined(circle(9.4, 8.6, 3), .back) + [
            S(path: p("M9.4 8.6V5.6M9.4 8.6l2.6 1.5M9.4 8.6l-2.6 1.5"), style: .stroke),
        ]),
    ]), gain: 2.4)

    static let plus = SidebarGlyph(root: P(pieces: [
        P(origin: CGPoint(x: 9, y: 9), turn: 90, shapes: [S(path: p("M9 4v10M4 9h10"), style: .stroke)]),
    ]))
}

private extension SidebarGlyph.Piece {
    /// The piece with its own shapes drawn after its pieces: a centre over the branches that leave it.
    func reordered() -> SidebarGlyph.Piece {
        SidebarGlyph.Piece(origin: origin, move: move, turn: turn, grow: grow, shapes: [],
                           pieces: pieces + [SidebarGlyph.Piece(shapes: shapes)])
    }
}

// MARK: - Drawing

struct SidebarGlyphRepresentable: NSViewRepresentable {
    let glyph: SidebarGlyph
    let amount: CGFloat
    let color: Color
    let ground: Color
    let size: CGFloat

    func makeNSView(context: Context) -> SidebarGlyphView {
        let view = SidebarGlyphView(glyph: glyph)
        view.apply(amount: amount, color: NSColor(color), ground: NSColor(ground), animated: false)
        return view
    }

    func updateNSView(_ view: SidebarGlyphView, context: Context) {
        let animated = !context.transaction.disablesAnimations && !Motion.reduceMotion
        view.apply(amount: amount, color: NSColor(color), ground: NSColor(ground), animated: animated)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SidebarGlyphView, context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }
}

/// The layers of a `SidebarGlyph`, on its 18 point grid scaled to the view.
final class SidebarGlyphView: NSView {
    private let glyph: SidebarGlyph
    /// The grid: y goes down, as in the design file.
    private let grid = CALayer()
    /// Each piece's layer, with the piece, in drawing order.
    private var pieces: [(layer: CALayer, piece: SidebarGlyph.Piece)] = []
    private var shapes: [(layer: CAShapeLayer, shape: SidebarGlyph.Shape)] = []
    private var amount: CGFloat = 0

    init(glyph: SidebarGlyph) {
        self.glyph = glyph
        super.init(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
        wantsLayer = true
        layer?.masksToBounds = false
        // The folder's faint shadow, so the drawn icons sit as it does.
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.13
        layer?.shadowRadius = 0.9
        layer?.shadowOffset = CGSize(width: 0, height: -0.5)
        grid.isGeometryFlipped = true
        grid.anchorPoint = .zero
        grid.bounds = CGRect(x: 0, y: 0, width: 18, height: 18)
        layer?.addSublayer(grid)
        build(glyph.root, in: grid)
        place(amount: 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func build(_ piece: SidebarGlyph.Piece, in parent: CALayer) {
        let layer = CALayer()
        layer.bounds = CGRect(x: 0, y: 0, width: 18, height: 18)
        layer.anchorPoint = CGPoint(x: piece.origin.x / 18, y: piece.origin.y / 18)
        layer.position = piece.origin
        parent.addSublayer(layer)
        pieces.append((layer, piece))
        for shape in piece.shapes {
            let shapeLayer = CAShapeLayer()
            shapeLayer.frame = layer.bounds
            shapeLayer.path = shape.path
            shapeLayer.lineCap = .round
            shapeLayer.lineJoin = .round
            if shape.style == .stroke {
                shapeLayer.fillColor = nil
                shapeLayer.lineWidth = 1.2
            }
            layer.addSublayer(shapeLayer)
            shapes.append((shapeLayer, shape))
        }
        for child in piece.pieces { build(child, in: layer) }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let scale = bounds.width / 18
        grid.position = CGPoint(x: 0, y: 0)
        grid.transform = CATransform3DMakeScale(scale, scale, 1)
        CATransaction.commit()
    }

    func apply(amount: CGFloat, color: NSColor, ground: NSColor, animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let ink = color.usingColorSpace(.sRGB) ?? color, base = ground.usingColorSpace(.sRGB) ?? ground
        let back = (base.blended(withFraction: 0.15, of: ink) ?? base).cgColor
        let front = (base.blended(withFraction: 0.06, of: ink) ?? base).cgColor
        for (layer, shape) in shapes {
            switch shape.style {
            case .stroke: layer.strokeColor = ink.cgColor
            case .back: layer.fillColor = back
            case .front: layer.fillColor = front
            case .ink: layer.fillColor = ink.cgColor
            }
        }
        CATransaction.commit()

        guard amount != self.amount else { return }
        let opening = amount > self.amount
        self.amount = amount
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.25)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .default))
        place(amount: amount)
        CATransaction.commit()
        if animated && opening { play() }
    }

    /// Every piece and shape where the gesture puts it at `amount`.
    private func place(amount t: CGFloat) {
        for (layer, piece) in pieces {
            var transform = CATransform3DMakeTranslation(piece.move.x * t, piece.move.y * t, 0)
            transform = CATransform3DRotate(transform, piece.turn * t * .pi / 180, 0, 0, 1)
            transform = CATransform3DScale(transform, 1 + piece.grow.width * t, 1 + piece.grow.height * t, 1)
            layer.transform = transform
        }
        for (layer, shape) in shapes {
            layer.opacity = Float(shape.opacity.rest + (shape.opacity.open - shape.opacity.rest) * t)
        }
    }

    /// The moments a gesture has besides moving: a stroke drawing itself again, a waveform lighting up bar by bar.
    private func play() {
        let now = CACurrentMediaTime()
        for (layer, shape) in shapes {
            if shape.redraws {
                let draw = CABasicAnimation(keyPath: "strokeEnd")
                draw.fromValue = 0
                draw.toValue = 1
                draw.duration = 0.42
                draw.timingFunction = CAMediaTimingFunction(name: .default)
                layer.add(draw, forKey: "redraw")
            }
            if let index = shape.wave {
                let light = CAKeyframeAnimation(keyPath: "opacity")
                light.values = [1, 0.5, 1]
                light.keyTimes = [0, 0.4, 1]
                light.duration = 0.5
                light.beginTime = now + Double(index) * 0.06
                light.timingFunction = CAMediaTimingFunction(name: .default)
                layer.add(light, forKey: "wave")
            }
        }
    }
}
