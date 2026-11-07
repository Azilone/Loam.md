import SwiftUI

/// Pictures in Loam's print look: an action or a kind of page drawn as a small object with gradients, a stipple of
/// fine dots and a field of dots behind it. Drawn, not shipped as pictures, so they take the accent, the appearance
/// and the day. The home page's actions, the meetings' start tiles and the empty pages use them.
///
/// Any SF Symbol has one: `PrintIllustration(symbol:)` draws Loam's own picture for the symbols it knows, a plugin's
/// for the symbols it registered (`register(_:drawing:)`), and for any other the symbol itself, inked on a stippled
/// tile. A plugin's empty page or action tile looks like the app's without drawing anything.
public struct PrintIllustration: View {
    public enum Kind: Sendable, CaseIterable {
        case today, newNote, mindmap, call, people, voice, importFile, drawing, board, tasks, folder, page, habit
    }

    /// Draws a picture on the 100 x 100 board, over the field of dots, in `ink`'s colours.
    public typealias Drawing = @MainActor (inout GraphicsContext, Ink) -> Void

    private enum Content {
        case kind(Kind)
        case drawing(Drawing)
        case symbol(String)
    }

    private let content: Content
    var date = Date()
    @Environment(\.themeTokens) private var theme

    public init(_ kind: Kind, date: Date = Date()) {
        self.content = .kind(kind)
        self.date = date
    }

    /// The picture for an SF Symbol name: Loam's own, a plugin's, else the symbol inked on a stippled tile.
    @MainActor
    public init(symbol: String, date: Date = Date()) {
        if let kind = Self.kind(for: symbol) {
            content = .kind(kind)
        } else if let drawing = Self.drawings[symbol] {
            content = .drawing(drawing)
        } else {
            content = .symbol(symbol)
        }
        self.date = date
    }

    @MainActor private static var drawings: [String: Drawing] = [:]

    /// Gives `symbol` a picture of a plugin's own, used wherever the app shows that symbol as a picture. Draw with
    /// `paint(_:in:ink:seed:)` so it shares the look; Loam's own pictures win for the symbols they cover.
    @MainActor
    public static func register(_ symbol: String, drawing: @escaping Drawing) {
        drawings[symbol] = drawing
    }

    /// The picture that stands for an SF Symbol name, nil when there is none.
    public static func kind(for symbol: String) -> Kind? {
        switch symbol {
        case "calendar", "calendar.badge.clock", "calendar.day.timeline.left": .today
        case "plus", "doc.badge.plus", "square.and.pencil": .newNote
        case LoamSymbol.mindmap, "point.3.connected.trianglepath.dotted": .mindmap
        case "phone", "phone.fill": .call
        case "person.2", "person.2.fill": .people
        case "waveform", "mic", "mic.fill": .voice
        case "square.and.arrow.down", "tray.and.arrow.down": .importFile
        case "scribble", "scribble.variable", "pencil.tip": .drawing
        case "rectangle.on.rectangle.angled", "square.on.square.dashed", "rectangle.3.group": .board
        case "checklist", "checkmark.circle", "checkmark.square": .tasks
        case "folder", "folder.fill": .folder
        case "doc", "doc.text", "note.text": .page
        case "flame", "flame.fill", "drop": .habit
        default: nil
        }
    }

    public var body: some View {
        Canvas { context, size in
            // Drawn on a 100 x 100 board, scaled to the frame.
            let scale = min(size.width, size.height) / 100
            context.translateBy(x: (size.width - 100 * scale) / 2, y: (size.height - 100 * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            let ink = Ink(accent: theme.accent)
            Self.halo(in: &context, ink: ink)
            switch content {
            case .kind(let kind): Self.draw(kind, in: &context, ink: ink, date: date)
            case .drawing(let drawing): drawing(&context, ink)
            case .symbol(let name): Self.tile(name, in: &context, ink: ink)
            }
        }
        .accessibilityHidden(true)
    }

    private static func draw(_ kind: Kind, in context: inout GraphicsContext, ink: Ink, date: Date) {
            switch kind {
            case .today: Self.calendar(in: &context, ink: ink, date: date)
            case .newNote: Self.page(in: &context, ink: ink)
            case .mindmap: Self.mindmap(in: &context, ink: ink)
            case .call: Self.call(in: &context, ink: ink)
            case .people: Self.people(in: &context, ink: ink)
            case .voice: Self.voice(in: &context, ink: ink)
            case .importFile: Self.importFile(in: &context, ink: ink)
            case .drawing: Self.drawing(in: &context, ink: ink)
            case .board: Self.board(in: &context, ink: ink)
            case .tasks: Self.tasks(in: &context, ink: ink)
            case .folder: Self.folder(in: &context, ink: ink)
            case .page: Self.document(in: &context, ink: ink)
            case .habit: Self.habit(in: &context, ink: ink)
            }
    }

    /// The colours of a picture, from the accent.
    public struct Ink {
        public let accent: Color
        public var deep: Color { accent.mix(with: .black, by: 0.35) }
        public var light: Color { accent.mix(with: .white, by: 0.55) }
        public var paper: Color { Color(white: 0.985) }
        public var shade: Color { accent.mix(with: .white, by: 0.82) }
    }

    /// A shape as the pictures draw their objects: paper fading into the accent's shade, then stippled.
    public static func paint(_ shape: Path, in context: inout GraphicsContext, ink: Ink, seed: Int) {
        paint(shape, in: &context, from: ink.paper, to: ink.shade, stippleLight: .white.opacity(0.9),
              stippleDark: ink.accent.opacity(0.45), seed: seed)
    }

    /// Any symbol: a stippled tile, slightly turned, with the symbol inked on it in the accent's deep shade.
    private static func tile(_ name: String, in context: inout GraphicsContext, ink: Ink) {
        var turned = context
        turned.translateBy(x: 50, y: 56)
        turned.rotate(by: .degrees(-4))
        turned.translateBy(x: -50, y: -56)
        let body = Path(roundedRect: CGRect(x: 20, y: 26, width: 60, height: 60), cornerRadius: Corners.r(12))
        paint(body, in: &turned, ink: ink, seed: name.count &* 7 &+ 3)
        turned.stroke(body, with: .color(ink.accent.opacity(0.35)), lineWidth: 1)
        var symbol = turned.resolve(Image(symbol: name))
        symbol.shading = .color(ink.deep)
        let size = symbol.size
        let side: CGFloat = 30
        let scale = size.width > 0 && size.height > 0 ? min(side / size.width, side / size.height) : 1
        let box = CGSize(width: size.width * scale, height: size.height * scale)
        turned.draw(symbol, in: CGRect(x: 50 - box.width / 2, y: 56 - box.height / 2, width: box.width, height: box.height))
    }

    // MARK: Texture

    /// A field of small dots behind the picture, thinning out from its middle, as a printed shadow.
    private static func halo(in context: inout GraphicsContext, ink: Ink) {
        var dots = Path()
        for row in 0..<17 {
            for column in 0..<17 {
                let x = 6 + Double(column) * 5.5, y = 10 + Double(row) * 5.5
                let distance = hypot(x - 52, y - 58) / 48
                let keep = 1 - distance + (HalftoneNoise.hash(column, row &+ 7) - 0.5) * 0.35
                guard keep > 0.25 else { continue }
                let r = 0.35 + 0.35 * min(keep, 1)
                dots.addEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
            }
        }
        context.fill(dots, with: .color(ink.accent.opacity(0.22)))
    }

    /// Fine speckles over `shape`: light ones where the light falls (top left), darker toward the far edge, so a
    /// flat fill reads as printed stipple.
    private static func stipple(_ shape: Path, in context: inout GraphicsContext, light: Color, dark: Color, density: Double = 1, seed: Int) {
        let box = shape.boundingRect
        var lights = Path(), darks = Path()
        let count = Int(box.width * box.height * 0.9 * density)
        for i in 0..<count {
            let x = box.minX + HalftoneNoise.hash(i &* 3 &+ seed, seed &* 11) * box.width
            let y = box.minY + HalftoneNoise.hash(i &* 7 &+ seed, seed &* 5 &+ 1) * box.height
            let point = CGPoint(x: x, y: y)
            guard shape.contains(point) else { continue }
            // 0 at the lit corner, 1 at the far one.
            let side = ((x - box.minX) / box.width + (y - box.minY) / box.height) / 2
            let r = 0.22 + 0.2 * HalftoneNoise.hash(i, seed &+ 3)
            let dot = CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)
            if HalftoneNoise.hash(i &+ 13, seed) < side { darks.addEllipse(in: dot) } else { lights.addEllipse(in: dot) }
        }
        context.drawLayer { layer in
            layer.clip(to: shape)
            layer.fill(lights, with: .color(light))
            layer.fill(darks, with: .color(dark))
        }
    }

    /// A shape in a soft gradient from `from` (top left) to `to`, then stippled.
    private static func paint(_ shape: Path, in context: inout GraphicsContext, from: Color, to: Color, stippleLight: Color, stippleDark: Color, seed: Int) {
        let box = shape.boundingRect
        context.fill(shape, with: .linearGradient(
            Gradient(colors: [from, to]),
            startPoint: CGPoint(x: box.minX, y: box.minY), endPoint: CGPoint(x: box.maxX, y: box.maxY)
        ))
        stipple(shape, in: &context, light: stippleLight, dark: stippleDark, seed: seed)
    }

    // MARK: Pictures

    /// A wall calendar on today: a blue band with two rings, the month and the day, a dot, a few lines.
    private static func calendar(in context: inout GraphicsContext, ink: Ink, date: Date) {
        let body = Path(roundedRect: CGRect(x: 16, y: 22, width: 64, height: 66), cornerRadius: Corners.r(10))
        paint(body, in: &context, from: ink.paper, to: ink.shade, stippleLight: .white.opacity(0.9), stippleDark: ink.accent.opacity(0.45), seed: 1)
        // The band: the top of the body, in the accent.
        var band = Path()
        band.addRoundedRect(in: CGRect(x: 16, y: 22, width: 64, height: 18), cornerSize: CGSize(width: 10, height: 10))
        band.addRect(CGRect(x: 16, y: 32, width: 64, height: 8))
        paint(band, in: &context, from: ink.light, to: ink.accent, stippleLight: .white.opacity(0.45), stippleDark: ink.deep.opacity(0.5), seed: 2)
        // The rings.
        for x in [33.0, 63.0] {
            let ring = Path(roundedRect: CGRect(x: x - 3, y: 14, width: 6, height: 15), cornerRadius: Corners.r(3))
            context.fill(ring, with: .color(ink.accent))
            context.stroke(ring, with: .color(.white), lineWidth: 1.4)
        }
        let month = date.formatted(.dateTime.month(.abbreviated)).uppercased().replacingOccurrences(of: ".", with: "")
        let day = date.formatted(.dateTime.day())
        context.draw(
            Text(month).font(.system(size: 9, weight: .heavy)).foregroundStyle(ink.accent),
            at: CGPoint(x: 24, y: 50), anchor: .leading
        )
        context.draw(
            Text(day).font(.system(size: 25, weight: .heavy)).kerning(-0.8).foregroundStyle(ink.deep),
            at: CGPoint(x: 23, y: 66), anchor: .leading
        )
        context.fill(Path(ellipseIn: CGRect(x: 66, y: 45, width: 7, height: 7)), with: .color(ink.accent))
        // A few dotted lines of what the day holds.
        var lines = Path()
        for (row, width) in [(79.0, 34.0), (83.0, 22.0)] {
            var x = 24.0
            while x < 24 + width {
                lines.addRect(CGRect(x: x, y: row, width: 1.6, height: 1))
                x += 2.6
            }
        }
        context.fill(lines, with: .color(ink.accent.opacity(0.55)))
    }

    /// A new page: a blue sheet behind, a white one with lines in front, and a round plus over its corner.
    private static func page(in context: inout GraphicsContext, ink: Ink) {
        var back = context
        back.translateBy(x: 40, y: 50)
        back.rotate(by: .degrees(-10))
        let behind = Path(roundedRect: CGRect(x: -26, y: -32, width: 50, height: 62), cornerRadius: Corners.r(8))
        paint(behind, in: &back, from: ink.light, to: ink.accent, stippleLight: .white.opacity(0.5), stippleDark: ink.deep.opacity(0.5), seed: 3)
        let front = Path(roundedRect: CGRect(x: 36, y: 22, width: 48, height: 62), cornerRadius: Corners.r(8))
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: ink.deep.opacity(0.25), radius: 3, x: -1, y: 2))
            layer.fill(front, with: .color(ink.paper))
        }
        paint(front, in: &context, from: ink.paper, to: ink.shade, stippleLight: .white.opacity(0.9), stippleDark: ink.accent.opacity(0.35), seed: 4)
        for (row, width) in [(34.0, 28.0), (42.0, 32.0), (50.0, 24.0), (58.0, 16.0)] {
            context.fill(Path(roundedRect: CGRect(x: 44, y: row, width: width, height: 3), cornerRadius: Corners.r(1.5)), with: .color(ink.light))
        }
        let badge = Path(ellipseIn: CGRect(x: 64, y: 62, width: 26, height: 26))
        paint(badge, in: &context, from: ink.accent, to: ink.deep, stippleLight: .white.opacity(0.35), stippleDark: ink.deep.opacity(0.4), seed: 5)
        var plus = Path()
        plus.addRoundedRect(in: CGRect(x: 75.6, y: 68.5, width: 2.8, height: 13), cornerSize: CGSize(width: 1.4, height: 1.4))
        plus.addRoundedRect(in: CGRect(x: 70.5, y: 73.6, width: 13, height: 2.8), cornerSize: CGSize(width: 1.4, height: 1.4))
        context.fill(plus, with: .color(.white))
    }

    /// A mindmap: a large node in the middle, branches to smaller ones, one of them pale.
    private static func mindmap(in context: inout GraphicsContext, ink: Ink) {
        let center = CGPoint(x: 52, y: 54)
        let nodes: [(CGPoint, CGFloat, Bool)] = [
            (CGPoint(x: 50, y: 20), 8.5, false), (CGPoint(x: 20, y: 40), 9.5, true), (CGPoint(x: 85, y: 50), 7.5, false),
            (CGPoint(x: 28, y: 78), 8.5, false), (CGPoint(x: 76, y: 84), 8, false),
        ]
        var branches = Path()
        for (point, _, _) in nodes {
            branches.move(to: center)
            branches.addLine(to: point)
        }
        context.stroke(branches, with: .color(ink.accent), style: StrokeStyle(lineWidth: 3.2, lineCap: .round))
        for (index, (point, radius, pale)) in nodes.enumerated() {
            sphere(at: point, radius: radius, pale: pale, in: &context, ink: ink, seed: 10 + index)
        }
        sphere(at: center, radius: 15, pale: false, in: &context, ink: ink, seed: 20)
    }

    /// A ball lit from the top left: a radial gradient, then stipple.
    private static func sphere(at point: CGPoint, radius: CGFloat, pale: Bool, in context: inout GraphicsContext, ink: Ink, seed: Int) {
        let shape = Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: 2 * radius, height: 2 * radius))
        let light = pale ? Color.white : ink.light
        let dark = pale ? ink.shade : ink.deep
        context.fill(shape, with: .radialGradient(
            Gradient(colors: [light, pale ? ink.shade : ink.accent, dark]),
            center: CGPoint(x: point.x - radius * 0.35, y: point.y - radius * 0.4), startRadius: 0, endRadius: radius * 1.5
        ))
        stipple(shape, in: &context, light: .white.opacity(pale ? 0.9 : 0.4), dark: (pale ? ink.accent : ink.deep).opacity(0.45), density: 1.6, seed: seed)
    }

    // MARK: More pictures

    /// A white sheet with lines, stippled, as the new page's front sheet.
    private static func sheet(_ rect: CGRect, lines: [Double], in context: inout GraphicsContext, ink: Ink, seed: Int) {
        let shape = Path(roundedRect: rect, cornerRadius: 7)
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: ink.deep.opacity(0.22), radius: 3, x: -1, y: 2))
            layer.fill(shape, with: .color(ink.paper))
        }
        paint(shape, in: &context, from: ink.paper, to: ink.shade, stippleLight: .white.opacity(0.9), stippleDark: ink.accent.opacity(0.35), seed: seed)
        for (index, width) in lines.enumerated() {
            let row = rect.minY + 12 + Double(index) * 8
            context.fill(Path(roundedRect: CGRect(x: rect.minX + 8, y: row, width: width, height: 3), cornerRadius: 1.5), with: .color(ink.light))
        }
    }

    /// A lit disc of the accent, as the new page's plus badge.
    private static func badge(at center: CGPoint, radius: CGFloat, in context: inout GraphicsContext, ink: Ink, seed: Int) {
        let disc = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
        paint(disc, in: &context, from: ink.accent, to: ink.deep, stippleLight: .white.opacity(0.35), stippleDark: ink.deep.opacity(0.4), seed: seed)
    }

    /// A phone handset standing on its own, as the other pictures' objects: lit from the top left, stippled, with two
    /// arcs of sound beside its ear.
    private static func call(in context: inout GraphicsContext, ink: Ink) {
        var handset = Path()
        // Ear piece, top left.
        handset.move(to: CGPoint(x: 22, y: 26))
        handset.addQuadCurve(to: CGPoint(x: 34, y: 16), control: CGPoint(x: 24, y: 17))
        handset.addLine(to: CGPoint(x: 42, y: 32))
        handset.addQuadCurve(to: CGPoint(x: 38, y: 40), control: CGPoint(x: 43, y: 37))
        // The grip's inner curve.
        handset.addQuadCurve(to: CGPoint(x: 58, y: 62), control: CGPoint(x: 42, y: 55))
        handset.addQuadCurve(to: CGPoint(x: 66, y: 58), control: CGPoint(x: 63, y: 57))
        // Mouth piece, bottom right.
        handset.addLine(to: CGPoint(x: 82, y: 66))
        handset.addQuadCurve(to: CGPoint(x: 72, y: 80), control: CGPoint(x: 83, y: 78))
        // The back's outer curve.
        handset.addQuadCurve(to: CGPoint(x: 22, y: 26), control: CGPoint(x: 22, y: 76))
        handset.closeSubpath()
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: ink.deep.opacity(0.25), radius: 3, x: 0, y: 2))
            layer.fill(handset, with: .color(ink.accent))
        }
        paint(handset, in: &context, from: ink.light, to: ink.deep, stippleLight: .white.opacity(0.4), stippleDark: ink.deep.opacity(0.45), seed: 30)
        // Sound, beside the ear piece.
        for (index, radius) in [12.0, 21.0].enumerated() {
            var arc = Path()
            arc.addArc(center: CGPoint(x: 56, y: 32), radius: radius, startAngle: .degrees(-80), endAngle: .degrees(10), clockwise: false)
            context.stroke(arc, with: .color(index == 0 ? ink.accent : ink.light),
                           style: StrokeStyle(lineWidth: 4, lineCap: .round))
        }
    }

    /// Two people, the one in front darker, lit from the top left.
    private static func people(in context: inout GraphicsContext, ink: Ink) {
        for (x, pale, seed) in [(62.0, true, 31), (42.0, false, 32)] {
            sphere(at: CGPoint(x: x, y: 38), radius: 11, pale: pale, in: &context, ink: ink, seed: seed)
            let body = Path(roundedRect: CGRect(x: x - 18, y: 54, width: 36, height: 30), cornerRadius: 15)
            paint(body, in: &context, from: pale ? ink.paper : ink.light, to: pale ? ink.shade : ink.accent,
                  stippleLight: .white.opacity(0.6), stippleDark: ink.deep.opacity(0.4), seed: seed + 10)
        }
    }

    /// A voice wave: rounded bars of the accent, tallest in the middle.
    private static func voice(in context: inout GraphicsContext, ink: Ink) {
        let heights: [Double] = [16, 30, 48, 62, 44, 56, 34, 20]
        for (index, height) in heights.enumerated() {
            let x = 18 + Double(index) * 9
            let bar = Path(roundedRect: CGRect(x: x, y: 52 - height / 2, width: 6, height: height), cornerRadius: 3)
            paint(bar, in: &context, from: ink.light, to: index % 3 == 0 ? ink.deep : ink.accent,
                  stippleLight: .white.opacity(0.45), stippleDark: ink.deep.opacity(0.4), seed: 40 + index)
        }
    }

    /// A tray with a page dropping into it and an arrow.
    private static func importFile(in context: inout GraphicsContext, ink: Ink) {
        sheet(CGRect(x: 32, y: 14, width: 36, height: 44), lines: [20, 16, 22], in: &context, ink: ink, seed: 50)
        var tray = Path()
        tray.move(to: CGPoint(x: 16, y: 58))
        tray.addLine(to: CGPoint(x: 30, y: 58))
        tray.addLine(to: CGPoint(x: 36, y: 66))
        tray.addLine(to: CGPoint(x: 64, y: 66))
        tray.addLine(to: CGPoint(x: 70, y: 58))
        tray.addLine(to: CGPoint(x: 84, y: 58))
        tray.addLine(to: CGPoint(x: 84, y: 84))
        tray.addLine(to: CGPoint(x: 16, y: 84))
        tray.closeSubpath()
        paint(tray, in: &context, from: ink.light, to: ink.accent, stippleLight: .white.opacity(0.45), stippleDark: ink.deep.opacity(0.45), seed: 51)
        var arrow = Path()
        arrow.move(to: CGPoint(x: 50, y: 30))
        arrow.addLine(to: CGPoint(x: 50, y: 52))
        arrow.move(to: CGPoint(x: 42, y: 45))
        arrow.addLine(to: CGPoint(x: 50, y: 53))
        arrow.addLine(to: CGPoint(x: 58, y: 45))
        context.stroke(arrow, with: .color(ink.accent), style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
    }

    /// A sheet with a loop of ink across it and a pencil.
    private static func drawing(in context: inout GraphicsContext, ink: Ink) {
        sheet(CGRect(x: 18, y: 16, width: 58, height: 68), lines: [], in: &context, ink: ink, seed: 60)
        var stroke = Path()
        stroke.move(to: CGPoint(x: 26, y: 62))
        stroke.addCurve(to: CGPoint(x: 50, y: 40), control1: CGPoint(x: 28, y: 36), control2: CGPoint(x: 48, y: 30))
        stroke.addCurve(to: CGPoint(x: 40, y: 60), control1: CGPoint(x: 52, y: 52), control2: CGPoint(x: 38, y: 66))
        stroke.addCurve(to: CGPoint(x: 68, y: 52), control1: CGPoint(x: 44, y: 52), control2: CGPoint(x: 60, y: 46))
        context.stroke(stroke, with: .color(ink.accent), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
        var pencil = context
        pencil.translateBy(x: 74, y: 62)
        pencil.rotate(by: .degrees(40))
        let body = Path(roundedRect: CGRect(x: -5, y: -26, width: 10, height: 30), cornerRadius: 2)
        paint(body, in: &pencil, from: ink.light, to: ink.deep, stippleLight: .white.opacity(0.4), stippleDark: ink.deep.opacity(0.4), seed: 61)
        var tip = Path()
        tip.move(to: CGPoint(x: -5, y: 4))
        tip.addLine(to: CGPoint(x: 0, y: 13))
        tip.addLine(to: CGPoint(x: 5, y: 4))
        pencil.fill(tip, with: .color(ink.shade))
    }

    /// Cards pinned on a board: a pale board, two white cards and a blue one.
    private static func board(in context: inout GraphicsContext, ink: Ink) {
        let ground = Path(roundedRect: CGRect(x: 12, y: 18, width: 76, height: 64), cornerRadius: 8)
        paint(ground, in: &context, from: ink.shade, to: ink.light.opacity(0.7), stippleLight: .white.opacity(0.7), stippleDark: ink.accent.opacity(0.3), seed: 70)
        sheet(CGRect(x: 20, y: 26, width: 28, height: 22), lines: [14], in: &context, ink: ink, seed: 71)
        sheet(CGRect(x: 52, y: 30, width: 28, height: 26), lines: [16, 10], in: &context, ink: ink, seed: 72)
        let blue = Path(roundedRect: CGRect(x: 26, y: 54, width: 30, height: 20), cornerRadius: 5)
        paint(blue, in: &context, from: ink.light, to: ink.accent, stippleLight: .white.opacity(0.45), stippleDark: ink.deep.opacity(0.4), seed: 73)
    }

    /// A list of tasks: boxes, the first two ticked.
    private static func tasks(in context: inout GraphicsContext, ink: Ink) {
        sheet(CGRect(x: 20, y: 14, width: 60, height: 72), lines: [], in: &context, ink: ink, seed: 80)
        for row in 0..<3 {
            let y = 26 + Double(row) * 18
            let box = Path(roundedRect: CGRect(x: 28, y: y, width: 11, height: 11), cornerRadius: 2.5)
            if row < 2 {
                context.fill(box, with: .color(ink.accent))
                var tick = Path()
                tick.move(to: CGPoint(x: 30.5, y: y + 5.5))
                tick.addLine(to: CGPoint(x: 33, y: y + 8))
                tick.addLine(to: CGPoint(x: 37, y: y + 3))
                context.stroke(tick, with: .color(.white), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            } else {
                context.stroke(box, with: .color(ink.light), lineWidth: 1.6)
            }
            context.fill(Path(roundedRect: CGRect(x: 45, y: y + 4, width: row == 1 ? 20 : 26, height: 3), cornerRadius: 1.5),
                         with: .color(row < 2 ? ink.light.opacity(0.6) : ink.light))
        }
    }

    /// A folder with a sheet sticking out of it.
    private static func folder(in context: inout GraphicsContext, ink: Ink) {
        var back = Path()
        back.addRoundedRect(in: CGRect(x: 14, y: 24, width: 72, height: 58), cornerSize: CGSize(width: 7, height: 7))
        back.addRoundedRect(in: CGRect(x: 14, y: 18, width: 30, height: 14), cornerSize: CGSize(width: 5, height: 5))
        paint(back, in: &context, from: ink.accent, to: ink.deep, stippleLight: .white.opacity(0.35), stippleDark: ink.deep.opacity(0.4), seed: 90)
        sheet(CGRect(x: 24, y: 28, width: 46, height: 30), lines: [26, 18], in: &context, ink: ink, seed: 91)
        let front = Path(roundedRect: CGRect(x: 14, y: 42, width: 72, height: 40), cornerRadius: 7)
        paint(front, in: &context, from: ink.light, to: ink.accent, stippleLight: .white.opacity(0.45), stippleDark: ink.deep.opacity(0.4), seed: 92)
    }

    /// A page of text, a blue sheet behind it.
    private static func document(in context: inout GraphicsContext, ink: Ink) {
        var back = context
        back.translateBy(x: 42, y: 50)
        back.rotate(by: .degrees(-8))
        let behind = Path(roundedRect: CGRect(x: -26, y: -32, width: 50, height: 62), cornerRadius: 7)
        paint(behind, in: &back, from: ink.light, to: ink.accent, stippleLight: .white.opacity(0.45), stippleDark: ink.deep.opacity(0.45), seed: 95)
        sheet(CGRect(x: 32, y: 20, width: 48, height: 62), lines: [30, 26, 32, 18, 24], in: &context, ink: ink, seed: 96)
    }

    /// A flame over a row of days, the last ones ticked: a streak.
    private static func habit(in context: inout GraphicsContext, ink: Ink) {
        var flame = Path()
        flame.move(to: CGPoint(x: 50, y: 12))
        flame.addCurve(to: CGPoint(x: 72, y: 54), control1: CGPoint(x: 58, y: 26), control2: CGPoint(x: 74, y: 36))
        flame.addCurve(to: CGPoint(x: 50, y: 74), control1: CGPoint(x: 72, y: 66), control2: CGPoint(x: 62, y: 74))
        flame.addCurve(to: CGPoint(x: 28, y: 54), control1: CGPoint(x: 38, y: 74), control2: CGPoint(x: 28, y: 66))
        flame.addCurve(to: CGPoint(x: 40, y: 32), control1: CGPoint(x: 28, y: 44), control2: CGPoint(x: 34, y: 38))
        flame.addCurve(to: CGPoint(x: 50, y: 12), control1: CGPoint(x: 42, y: 26), control2: CGPoint(x: 50, y: 20))
        flame.closeSubpath()
        paint(flame, in: &context, from: ink.light, to: ink.deep, stippleLight: .white.opacity(0.45), stippleDark: ink.deep.opacity(0.45), seed: 100)
        let core = Path(ellipseIn: CGRect(x: 42, y: 50, width: 16, height: 20))
        paint(core, in: &context, from: ink.paper, to: ink.shade, stippleLight: .white.opacity(0.9), stippleDark: ink.accent.opacity(0.3), seed: 101)
        for day in 0..<5 {
            let rect = CGRect(x: 20 + Double(day) * 13, y: 82, width: 9, height: 9)
            context.fill(Path(ellipseIn: rect), with: .color(day >= 2 ? ink.accent : ink.light.opacity(0.5)))
        }
    }
}
