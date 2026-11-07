// Renders the layers of App/Resources/Loam.icon: a debossed, smoky Loam mark under frosted glass on sage-tinted paper.
// swift render-icon-layers.swift <Loam.icon/Assets> [blue]
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

let N = 1024
let out = CommandLine.arguments[1]
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ci = CIContext()
let full = CGRect(x: 0, y: 0, width: N, height: N)

func ctx() -> CGContext {
    let c = CGContext(data: nil, width: N, height: N, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.translateBy(x: 0, y: CGFloat(N)); c.scaleBy(x: 1, y: -1)
    return c
}
func rgb(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(h >> 16 & 255) / 255, green: CGFloat(h >> 8 & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: a)
}
func linear(_ c: CGContext, _ stops: [(CGFloat, CGColor)], _ a: CGPoint, _ b: CGPoint) {
    let g = CGGradient(colorsSpace: cs, colors: stops.map { $0.1 } as CFArray, locations: stops.map { $0.0 })!
    c.drawLinearGradient(g, start: a, end: b, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}
func radial(_ c: CGContext, _ stops: [(CGFloat, CGColor)], _ p: CGPoint, _ r: CGFloat) {
    let g = CGGradient(colorsSpace: cs, colors: stops.map { $0.1 } as CFArray, locations: stops.map { $0.0 })!
    c.drawRadialGradient(g, startCenter: p, startRadius: 0, endCenter: p, endRadius: r, options: [.drawsAfterEndLocation])
}
func blur(_ img: CGImage, _ r: Double) -> CGImage {
    let f = CIFilter.gaussianBlur(); f.inputImage = CIImage(cgImage: img).clampedToExtent(); f.radius = Float(r)
    return ci.createCGImage(f.outputImage!, from: full)!
}
/// Seeded, so a render gives the same icon every time.
struct Seeded: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
}
/// Soft blobs of one colour: slow waves of light or shade, or smoke.
func blobs(_ c: CGContext, _ color: UInt32, count: Int, radius: ClosedRange<CGFloat>, alpha: ClosedRange<CGFloat>, seed: UInt64) {
    var rng = Seeded(state: seed)
    for _ in 0..<count {
        let p = CGPoint(x: .random(in: -100...1124, using: &rng), y: .random(in: -100...1124, using: &rng))
        radial(c, [(0, rgb(color, .random(in: alpha, using: &rng))), (1, rgb(color, 0))], p, .random(in: radius, using: &rng))
    }
}
/// Specks of one colour: the grain of the paper, a dither.
func specks(_ c: CGContext, _ color: UInt32, count: Int, alpha: CGFloat, seed: UInt64) {
    var rng = Seeded(state: seed)
    for _ in 0..<count {
        let s = [1.0, 1.5, 2.0].randomElement(using: &rng)!
        c.setFillColor(rgb(color, .random(in: alpha * 0.3...alpha, using: &rng)))
        c.fill(CGRect(x: .random(in: 0..<1024, using: &rng), y: .random(in: 0..<1024, using: &rng), width: s, height: s))
    }
}
func save(_ img: CGImage, _ name: String) {
    try! NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name)"))
}

// The mark, traced from the reference: a pebble stem narrowing to its foot, a lens leaf, a leaf lying below.
let shift = CGAffineTransform(translationX: -493, y: -498).concatenating(CGAffineTransform(scaleX: 1.06, y: 1.06)).concatenating(CGAffineTransform(translationX: 506, y: 506))
func stem() -> CGPath { let p = CGMutablePath()
    p.move(to: CGPoint(x: 246, y: 340))
    p.addCurve(to: CGPoint(x: 322, y: 254), control1: CGPoint(x: 246, y: 284), control2: CGPoint(x: 274, y: 254))
    p.addLine(to: CGPoint(x: 438, y: 252))
    p.addCurve(to: CGPoint(x: 478, y: 300), control1: CGPoint(x: 466, y: 252), control2: CGPoint(x: 480, y: 272))
    p.addCurve(to: CGPoint(x: 296, y: 744), control1: CGPoint(x: 470, y: 520), control2: CGPoint(x: 420, y: 720))
    p.addCurve(to: CGPoint(x: 246, y: 708), control1: CGPoint(x: 262, y: 750), control2: CGPoint(x: 246, y: 738))
    p.closeSubpath(); return p.copy(using: [shift])! }
func leaf() -> CGPath { let p = CGMutablePath()
    p.move(to: CGPoint(x: 494, y: 572))
    p.addCurve(to: CGPoint(x: 720, y: 362), control1: CGPoint(x: 490, y: 456), control2: CGPoint(x: 590, y: 366))
    p.addCurve(to: CGPoint(x: 736, y: 386), control1: CGPoint(x: 732, y: 362), control2: CGPoint(x: 738, y: 372))
    p.addCurve(to: CGPoint(x: 494, y: 572), control1: CGPoint(x: 718, y: 486), control2: CGPoint(x: 620, y: 566))
    p.closeSubpath(); return p.copy(using: [shift])! }
func low() -> CGPath { let p = CGMutablePath()
    p.move(to: CGPoint(x: 396, y: 744))
    p.addCurve(to: CGPoint(x: 528, y: 624), control1: CGPoint(x: 424, y: 676), control2: CGPoint(x: 470, y: 626))
    p.addLine(to: CGPoint(x: 694, y: 622))
    p.addCurve(to: CGPoint(x: 740, y: 666), control1: CGPoint(x: 724, y: 622), control2: CGPoint(x: 742, y: 640))
    p.addCurve(to: CGPoint(x: 664, y: 744), control1: CGPoint(x: 736, y: 716), control2: CGPoint(x: 708, y: 744))
    p.closeSubpath(); return p.copy(using: [shift])! }
let pieces: [(path: CGPath, foot: CGPoint, tip: CGPoint)] = [
    (stem(), CGPoint(x: 300, y: 600), CGPoint(x: 500, y: 240)),
    (leaf(), CGPoint(x: 540, y: 560), CGPoint(x: 760, y: 360)),
    (low(), CGPoint(x: 680, y: 700), CGPoint(x: 420, y: 650)),
]
func mark(_ c: CGContext) { for p in pieces { c.addPath(p.path) } }
/// Only the shadow of the mark, never its hard-edged fill: the mark is drawn off the canvas, its shadow brought back.
func markShadow(_ c: CGContext, offset: CGSize, blur: CGFloat, color: CGColor) {
    c.saveGState()
    c.setShadow(offset: CGSize(width: offset.width + 3000, height: offset.height), blur: blur, color: color)
    c.translateBy(x: -3000, y: 0); c.setFillColor(rgb(0, 1)); mark(c); c.fillPath()
    c.restoreGState()
}

struct Look { let core: UInt32, mist: UInt32, edge: UInt32, smoke: UInt32, lip: UInt32, lipAlpha: CGFloat, rim: UInt32 }

func glyph(_ look: Look, _ name: String) {
    let c = ctx()
    // The lip of the hollow: a pale halo outside the lower right edges.
    markShadow(c, offset: CGSize(width: 6, height: -8), blur: 18, color: rgb(look.lip, look.lipAlpha * 0.6))
    for p in pieces {
        c.saveGState(); c.addPath(p.path); c.clip()
        // Smoke: dense at the core, misty toward the tip.
        linear(c, [(0, rgb(look.core)), (0.3, rgb(look.core)), (1, rgb(look.mist))], p.foot, p.tip)
        blobs(c, look.smoke, count: 40, radius: 40...110, alpha: 0.15...0.45, seed: 7)
        blobs(c, look.mist, count: 18, radius: 40...100, alpha: 0.15...0.5, seed: 11)
        // Frosted edges: the glass lightens the mark where it is shallow.
        c.setShadow(offset: .zero, blur: 40, color: rgb(look.edge, 0.9))
        c.addRect(full.insetBy(dx: -200, dy: -200)); c.addPath(p.path)
        c.setFillColor(rgb(look.edge)); c.fillPath(using: .evenOdd)
        // Depth: a shadow under the upper left wall.
        c.setShadow(offset: CGSize(width: 7, height: -10), blur: 12, color: rgb(look.rim, 0.45))
        c.addRect(full.insetBy(dx: -200, dy: -200)); c.addPath(p.path); c.fillPath(using: .evenOdd)
        // The far wall catches the light.
        c.setShadow(offset: CGSize(width: -4, height: 6), blur: 9, color: rgb(look.lip, look.lipAlpha * 0.45))
        c.addRect(full.insetBy(dx: -200, dy: -200)); c.addPath(p.path); c.fillPath(using: .evenOdd)
        c.restoreGState()
    }
    c.saveGState(); mark(c); c.clip(); specks(c, look.smoke, count: 14000, alpha: 0.25, seed: 3); specks(c, 0xFFFFFF, count: 8000, alpha: 0.18, seed: 5); c.restoreGState()
    save(blur(c.makeImage()!, 1.2), name)
}

struct Paper { let sheen: UInt32, light: UInt32, mid: UInt32, deep: UInt32, glow: UInt32, glowAlpha: CGFloat, mottle: UInt32, mottleAlpha: CGFloat, fleck: UInt32, fleckAlpha: CGFloat, edge: UInt32, edgeAlpha: CGFloat, bevel: UInt32, bevelAlpha: CGFloat
             var wash: [(UInt32, CGFloat)] = [], grain: Int = 60000 }

func background(_ p: Paper, _ name: String) {
    let c = ctx()
    linear(c, [(0, rgb(p.light)), (0.5, rgb(p.mid)), (1, rgb(p.deep))], CGPoint(x: 120, y: 60), CGPoint(x: 900, y: 1000))
    // Colour moving through the glass.
    for (i, w) in p.wash.enumerated() { blobs(c, w.0, count: 7, radius: 260...460, alpha: (w.1 * 0.5)...w.1, seed: UInt64(50 + i * 7)) }
    // Uneven glass: slow waves of light and shade.
    blobs(c, p.mottle, count: 26, radius: 120...300, alpha: 0...p.mottleAlpha, seed: 21)
    blobs(c, p.sheen, count: 22, radius: 100...260, alpha: 0...p.mottleAlpha * 0.8, seed: 23)
    // Thickness: the glass darkens toward its edges, and catches the light in the upper left.
    radial(c, [(0, rgb(p.glow, p.glowAlpha)), (0.45, rgb(p.glow, p.glowAlpha * 0.6)), (1, rgb(p.glow, 0))], CGPoint(x: 220, y: 190), 190)
    // The thick glass edge: a soft shade inside the rim (the rim itself is drawn by the system). Only the shadow lands on
    // the tile: the shape that casts it lies outside the tile's corners.
    let tile = CGPath(roundedRect: full, cornerWidth: 240, cornerHeight: 240, transform: nil)
    c.saveGState(); c.addPath(tile); c.clip()
    c.setShadow(offset: .zero, blur: 70, color: rgb(p.edge, p.edgeAlpha))
    c.addRect(full.insetBy(dx: -400, dy: -400)); c.addPath(tile)
    c.setFillColor(rgb(p.edge, 1)); c.fillPath(using: .evenOdd)
    c.restoreGState()
    // The glass bends around the hollow: shade below left of the mark, a pale ridge around it.
    markShadow(c, offset: CGSize(width: -14, height: -26), blur: 60, color: rgb(p.edge, p.edgeAlpha * 0.9))
    // Paper grain under the glass.
    specks(c, p.fleck, count: p.grain, alpha: p.fleckAlpha, seed: 31)
    specks(c, 0xFFFFFF, count: 40000, alpha: p.fleckAlpha * 1.5, seed: 37)
    save(c.makeImage()!, name)
}

if CommandLine.arguments.dropFirst(2).first == "blue" {
    // The Dither theme's icon: the same glass tinted blue-grey, the mark in Loam blue.
    glyph(Look(core: 0x2B4FC4, mist: 0xC3CCE6, edge: 0xD6D7DE, smoke: 0x1A3596, lip: 0xFFFFFF, lipAlpha: 0.75, rim: 0x14245E), "glyph-green.png")
    glyph(Look(core: 0x8FA8F0, mist: 0xD6E0FA, edge: 0x1B2A5E, smoke: 0xE4EBFF, lip: 0x000000, lipAlpha: 0.5, rim: 0x070D24), "glyph.png")
    background(Paper(sheen: 0xF2F5FC, light: 0xDDE2EE, mid: 0xC9D0E2, deep: 0xA9B3CC, glow: 0xF8FAFF, glowAlpha: 0.9, mottle: 0x7E8AAA, mottleAlpha: 0.28,
                     fleck: 0x3E4866, fleckAlpha: 0.16, edge: 0x6C789A, edgeAlpha: 0.5, bevel: 0xFFFFFF, bevelAlpha: 0.8,
                     wash: [(0xE6DFCF, 0.3), (0x9AAAD6, 0.3)], grain: 110000), "background-light.png")
    background(Paper(sheen: 0x2C3E78, light: 0x1A2550, mid: 0x111A3C, deep: 0x090F26, glow: 0xB4C6FF, glowAlpha: 0.14, mottle: 0x000000, mottleAlpha: 0.3,
                     fleck: 0xC6D2F5, fleckAlpha: 0.08, edge: 0x000000, edgeAlpha: 0.5, bevel: 0x8FA8F0, bevelAlpha: 0.25), "background.png")
    exit(0)
}
glyph(Look(core: 0x616B5B, mist: 0xCBCCC0, edge: 0xD8D5C9, smoke: 0x434D3C, lip: 0xFFFFFF, lipAlpha: 0.75, rim: 0x2F362C), "glyph-green.png")
glyph(Look(core: 0xA9BEA6, mist: 0xD4DFCF, edge: 0x2E3D31, smoke: 0xE6EEE2, lip: 0x000000, lipAlpha: 0.5, rim: 0x0C120D), "glyph.png")
background(Paper(sheen: 0xF6F8EE, light: 0xDFE3D2, mid: 0xCDD3BD, deep: 0xB2BBA0, glow: 0xFAFCF2, glowAlpha: 0.9, mottle: 0x8E9A7A, mottleAlpha: 0.28,
                 fleck: 0x4E5A42, fleckAlpha: 0.16, edge: 0x7C886A, edgeAlpha: 0.5, bevel: 0xFFFFFF, bevelAlpha: 0.8,
                 wash: [(0xE6D9B4, 0.35), (0x9FB08C, 0.3)], grain: 110000), "background-light.png")
background(Paper(sheen: 0x3A5040, light: 0x23312A, mid: 0x18231C, deep: 0x0F1712, glow: 0xB9D2BB, glowAlpha: 0.14, mottle: 0x000000, mottleAlpha: 0.3,
                 fleck: 0xC9D6C6, fleckAlpha: 0.08, edge: 0x000000, edgeAlpha: 0.5, bevel: 0x9DB89F, bevelAlpha: 0.25), "background.png")
