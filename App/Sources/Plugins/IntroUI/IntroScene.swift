import PluginKitUI
import AppKit
import SwiftUI

/// The intro at one instant: a pure function of the time since it began, so a test can draw any frame. The timings:
///
/// - 0 to 2.6 s: the desktop dims and a fog of soft paintings rises over the whole screen.
/// - 3 to 7.4 s: "presents" fades in on the light painting.
/// - 7.4 to 10.4 s: the screen-wide painting lowers its top edge then shrinks into a window card while the moon and
///   the wordmark rise from below; a post passing in the foreground wipes in a stormy painting (8.3 s).
/// - 11.4 to 13.2 s: a second pass of the post reveals the painting in focus; the moon and the wordmark blur away.
/// - 16 to 17.6 s: the welcome page sweeps in from the left over the painting.
struct IntroScene: View {
    /// Seconds since the intro began.
    let time: Double
    let assets: IntroAssets
    /// The welcome window's page during onboarding, in its points: it sweeps in. Nil for the plain
    /// intro.
    var onboarding: AnyView?

    /// The welcome window's size, centred on the screen.
    static let cardSize = CGSize(width: 928, height: 544)
    /// The welcome picture carries its own shadow: the window sits at this rect in its 974 × 590 points.
    static let welcomeWindow = CGRect(x: 23, y: 19, width: 928, height: 544)
    /// When the welcome page has fully arrived; the intro waits there.
    static let welcomeStart: Double = 16.0
    static let settled: Double = 17.6

    var body: some View {
        GeometryReader { proxy in
            let screen = proxy.size
            let card = cardRect(in: screen)
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.35 * ramp(0, 1.2) * (1 - ramp(7.6, 9.6)))
                cardContent(size: card.size)
                    .frame(width: card.width, height: card.height)
                    .clipShape(RoundedRectangle(cornerRadius: Corners.r(16 * shrink(in: screen)), style: .continuous))
                    .shadow(color: .black.opacity(0.35 * ramp(7.8, 9.4)), radius: 40, y: 18)
                    .opacity(ramp(0.6, 2.4))
                    .offset(x: card.minX, y: card.minY)
            }
            .frame(width: screen.width, height: screen.height, alignment: .topLeading)
        }
        .ignoresSafeArea()
    }

    // MARK: The card

    /// The painting's frame: the whole screen, then its top edge lowers (from 7.3 s), then its sides and bottom close
    /// in (from 8.2 s) until it is the welcome window.
    private func cardRect(in screen: CGSize) -> CGRect {
        let size = Self.cardSize
        let final = CGRect(
            x: (screen.width - size.width) / 2, y: screen.height * 0.51 - size.height / 2,
            width: size.width, height: size.height
        )
        let top = lerp(0, final.minY, ease(ramp(7.3, 10.2)))
        let sides = ease(ramp(8.2, 10.4))
        let bottom = lerp(screen.height, final.maxY, ease(ramp(8.4, 10.4)))
        let left = lerp(0, final.minX, sides)
        let right = lerp(screen.width, final.maxX, sides)
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// 0 while the card covers the screen, 1 once it is the welcome window.
    private func shrink(in screen: CGSize) -> Double { ease(ramp(8.2, 10.4)) }

    @ViewBuilder
    private func cardContent(size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            // The fog's paintings, lightening as the light comes up.
            painting(2, size: size, blur: 30)
            painting(5, size: size, blur: 30).opacity(ramp(2.2, 3.4))
            painting(6, size: size, blur: 26).opacity(ramp(4.0, 6.0))
            // The fog's pale wash, lifted as the card becomes a window.
            Color.white.opacity(0.22 * (1 - ramp(8.3, 9.4)))
            clouds(size: size).opacity(0.45 * ramp(0.6, 2.2) * (1 - ramp(8.4, 9.6)))
            // First pass of the post: the stormy painting, still soft.
            painting(1, size: size, blur: 16)
                .mask(alignment: .leading) { wipeMask(size: size, from: 8.3, to: 9.2) }
            // Second pass: the painting in focus.
            painting(0, size: size, blur: 0)
                .mask(alignment: .leading) { wipeMask(size: size, from: 11.4, to: 12.8) }
            branding(size: size)
            pole(size: size, from: 8.3, to: 9.2)
            pole(size: size, from: 11.4, to: 12.8)
            welcome(size: size)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(Color(white: 0.55))
    }

    /// One of the seven paintings, as tall as the card and panned slowly to the left.
    @ViewBuilder
    private func painting(_ index: Int, size: CGSize, blur: Double) -> some View {
        if let image = assets.landscapes[safe: index] {
            let height = size.height * 1.12
            let width = height * image.size.width / max(image.size.height, 1)
            Image(nsImage: image)
                .resizable()
                .frame(width: width, height: height)
                .offset(x: -width * (0.18 + 0.004 * time), y: -(height - size.height) / 2)
                .blur(radius: blur, opaque: true)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .clipped()
        } else {
            // Without paintings: the same light curve as a plain sky.
            let light = [0.35, 0.3, 0.45, 0.55, 0.62, 0.78, 0.86][min(index, 6)]
            LinearGradient(
                colors: [Color(white: light * 0.7), Color(white: light), Color(white: light * 0.5)],
                startPoint: .top, endPoint: .bottom
            )
            .frame(width: size.width, height: size.height)
        }
    }

    @ViewBuilder
    private func clouds(size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(assets.clouds.enumerated()), id: \.offset) { index, image in
                let width = size.width * (index == 0 ? 1.3 : 1.1)
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: width)
                    .offset(x: -width * 0.1 - time * (index == 0 ? 22 : 12), y: size.height * (index == 0 ? 0.05 : 0.25))
                    .blur(radius: 6)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
    }

    /// Where a passing post has been: the part right of the post.
    private func wipeMask(size: CGSize, from start: Double, to end: Double) -> some View {
        let x = postX(size: size, from: start, to: end)
        return Rectangle().frame(width: max(size.width - x, 0)).offset(x: x)
    }

    /// The post's left edge: from beyond the right edge to beyond the left one.
    private func postX(size: CGSize, from start: Double, to end: Double) -> CGFloat {
        let width = postWidth(size: size)
        return lerp(size.width + width * 0.2, -width * 1.2, easeInOut(ramp(start, end)))
    }

    private func postWidth(size: CGSize) -> CGFloat { size.height * 1.1 * 375 / 1096 }

    @ViewBuilder
    private func pole(size: CGSize, from start: Double, to end: Double) -> some View {
        if time > start, time < end {
            let width = postWidth(size: size)
            Group {
                if let image = assets.pole {
                    Image(nsImage: image).resizable()
                } else {
                    LinearGradient(colors: [Color(white: 0.1), Color(white: 0.25), Color(white: 0.1)], startPoint: .leading, endPoint: .trailing)
                }
            }
            .frame(width: width, height: size.height * 1.1)
            .blur(radius: 10)
            .offset(x: postX(size: size, from: start, to: end), y: -size.height * 0.05)
        }
    }

    // MARK: Branding

    @ViewBuilder
    private func branding(size: CGSize) -> some View {
        let settle = ease(ramp(7.4, 9.0))
        let blurAway = 14 * ramp(12.4, 13.2)
        // The lockup and its tagline: centred on the
        // screen, then small at the card's top.
        centred(at: CGPoint(x: size.width / 2, y: size.height * lerp(0.47, 0.11, settle)), in: size) {
            let width = size.width * lerp(0.34, 0.12, settle)
            VStack(spacing: width * 0.02) {
                mark(assets.company, width: width) {
                    Text(verbatim: "THE SECOND BRAIN").font(.custom("Didot", size: 40))
                }
                // The tagline keeps the lockup's type size: its width in the lockup's proportion.
                mark(assets.tagline, width: width * Self.taglineRatio(assets) * 0.62) {
                    Text("an open-source notebook").font(.custom("Didot", size: 20))
                }
            }
        }
        .opacity(ramp(3.0, 4.2) * (1 - ramp(12.2, 13.0)))
        // The moon rises from below the screen.
        centred(at: CGPoint(x: size.width / 2, y: size.height * lerp(1.2, 0.41, easeOut(ramp(7.4, 9.2)))), in: size) {
            IntroAppIcon(image: assets.appIcon)
                .frame(width: size.width * lerp(0.16, 0.09, ease(ramp(8.0, 9.4))))
                .shadow(color: .black.opacity(0.25), radius: 18, y: 10)
        }
        .blur(radius: blurAway)
        .opacity(1 - ramp(12.8, 14.6))
        // The wordmark follows it.
        centred(at: CGPoint(x: size.width / 2, y: size.height * lerp(1.4, 0.66, easeOut(ramp(8.2, 9.6)))), in: size) {
            // The welcome window's title font.
            Text("Loam").font(assets.title(size: 120)).foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.1).frame(width: size.width * 0.2)
        }
        .blur(radius: blurAway)
        .opacity(1 - ramp(12.4, 13.0))
    }

    @ViewBuilder
    private func mark(_ image: NSImage?, width: CGFloat, @ViewBuilder fallback: () -> some View) -> some View {
        if let image {
            // The marks are template images: drawn white, whatever the appearance.
            Image(nsImage: image).renderingMode(.template).resizable().aspectRatio(contentMode: .fit)
                .foregroundStyle(.white).frame(width: width)
        } else {
            fallback().foregroundStyle(.white).minimumScaleFactor(0.1).frame(width: width)
        }
    }

    private func centred(at point: CGPoint, in size: CGSize, @ViewBuilder _ content: () -> some View) -> some View {
        content().position(point).frame(width: size.width, height: size.height)
    }

    static func taglineRatio(_ assets: IntroAssets) -> CGFloat {
        guard let company = assets.company, let tagline = assets.tagline, company.size.width > 0 else { return 0.4 }
        return tagline.size.width / company.size.width
    }

    // MARK: Welcome

    /// The welcome page sweeping in from the left: a soft edge crossing the card.
    @ViewBuilder
    private func welcome(size: CGSize) -> some View {
        if time > Self.welcomeStart {
            let edge = lerp(-0.6, 1.0, ease(ramp(Self.welcomeStart, Self.settled)))
            Group {
                if let onboarding {
                    onboarding
                        .frame(width: Self.cardSize.width, height: Self.cardSize.height)
                        .scaleEffect(size.width / Self.cardSize.width, anchor: .topLeading)
                        .frame(width: size.width, height: size.height, alignment: .topLeading)
                } else if let image = assets.welcome {
                    let scale = size.width / Self.welcomeWindow.width
                    Image(nsImage: image).resizable()
                        .frame(width: image.size.width * scale, height: image.size.height * scale)
                        .offset(x: -Self.welcomeWindow.minX * scale, y: -Self.welcomeWindow.minY * scale)
                        .frame(width: size.width, height: size.height, alignment: .topLeading)
                        .overlay(alignment: .topLeading) { loamWelcomeText.scaleEffect(scale, anchor: .topLeading) }
                } else {
                    ZStack(alignment: .topLeading) {
                        Color.black
                        Text("Welcome to Loam").font(.custom("Didot", size: 34)).foregroundStyle(.white).padding(48)
                    }
                }
            }
            .frame(width: size.width, height: size.height)
            .mask {
                LinearGradient(
                    stops: [.init(color: .black, location: edge), .init(color: .clear, location: edge + 0.6)],
                    startPoint: .leading, endPoint: .trailing
                )
            }
        }
    }

    /// Loam's title and line, in the welcome window's points.
    private var loamWelcomeText: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Welcome to Loam")
                .font(assets.title(size: 26))
                .foregroundStyle(.white)
                .frame(height: 30, alignment: .leading)
                .padding(.top, 11)
            Text("Loam is a simple, local-first Markdown notebook,\nwhere everything beyond writing is a plugin.")
                .font(.ui(size: 13))
                .foregroundStyle(Color(white: 0.6))
                .lineSpacing(4)
                .padding(.top, 22)
            Spacer(minLength: 0)
        }
        .padding(.leading, 32)
        .frame(width: 470, height: 110, alignment: .topLeading)
        .background(Color.black)
        // Below the yellow bar.
        .offset(y: 46)
    }

    // MARK: Curves

    /// 0 before `start`, 1 after `end`, linear between.
    private func ramp(_ start: Double, _ end: Double) -> Double {
        min(max((time - start) / (end - start), 0), 1)
    }
}

private func lerp(_ a: CGFloat, _ b: CGFloat, _ p: Double) -> CGFloat { a + (b - a) * p }
/// Smooth start and end, as the card's camera moves.
private func ease(_ p: Double) -> Double { p * p * (3 - 2 * p) }
private func easeInOut(_ p: Double) -> Double { p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2 }
private func easeOut(_ p: Double) -> Double { 1 - pow(1 - p, 3) }

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
