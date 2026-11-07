import AppKit
import SwiftUI

/// The shared vocabulary of motion: named springs, durations, distances and the "Reduce motion" fallback, so that no
/// surface invents its own numbers. `docs/design/MOTION.md` says which token each surface uses and why.
///
/// The rules the tokens encode: springs are short and settle in a third of a second; only what is light and
/// playful overshoots (a checkmark, a toast), never a page or a sidebar; what leaves is faster than what arrives;
/// what follows the pointer is interactive (it never lags behind the hand); under "Reduce motion" every movement
/// becomes a short fade.
public enum Motion {
    // MARK: Springs

    /// A spring described by what a person feels: how long it takes to settle, and how much it overshoots.
    public struct Spring: Hashable, Sendable {
        /// Seconds until it has all but settled.
        public let duration: Double
        /// 0 settles without overshoot; 0.3 is a clear, playful overshoot.
        public let bounce: Double

        public init(duration: Double, bounce: Double) {
            self.duration = duration
            self.bounce = bounce
        }

        public var animation: Animation { .spring(duration: duration, bounce: bounce) }

        /// A small control answering a press or a click: a toggle's knob, a selected segment.
        public static let tap = Spring(duration: 0.20, bounce: 0)
        /// What changes place or size: cards sorted, a card moving to another column, tabs added or closed.
        public static let standard = Spring(duration: 0.34, bounce: 0.12)
        /// A view replacing another, a field opening, a page's content changing: no overshoot.
        public static let smooth = Spring(duration: 0.40, bounce: 0)
        /// A side column sliding in or out: a quick start and a long settle, no bounce (Craft's slide).
        public static let slide = Spring(duration: 0.50, bounce: 0)
        /// Something light arriving with life: a checkbox's mark, a toast, a badge.
        public static let pop = Spring(duration: 0.30, bounce: 0.28)
        /// A popover, a menu, a palette arriving: grows from its origin with a hint of overshoot.
        public static let overlay = Spring(duration: 0.28, bounce: 0.10)
        /// A card rising under the pointer, and putting itself back.
        public static let lift = Spring(duration: 0.30, bounce: 0.18)
        /// A divider or a dragged item falling onto a key position.
        public static let settle = Spring(duration: 0.30, bounce: 0.28)
    }

    /// What follows the pointer while it drags (a card held, a divider pulled): barely springy, so the object stays
    /// under the hand and only the let-go is soft.
    public static let follow = Animation.interactiveSpring(response: 0.16, dampingFraction: 0.9)

    // MARK: Fades

    /// Hover and focus colours, a control's highlight.
    public static let hover = Animation.easeOut(duration: 0.12)
    /// What replaces movement under "Reduce motion", and the cross-fade of two views.
    public static let fade = Animation.easeOut(duration: 0.12)
    /// Two pages or two states of one page replacing each other (a tab switch).
    public static let crossfade = Animation.easeOut(duration: 0.16)
    /// Something leaving: faster than it arrived, and eased in (it accelerates away).
    public static let exit = Animation.easeIn(duration: 0.12)
    /// A quiet state change on a large surface (an edge's glass appearing, a toolbar going translucent).
    public static let ambient = Animation.easeOut(duration: 0.22)

    // MARK: Distances

    /// Sizes and offsets of the movements, in points or ratios.
    public enum Metrics {
        /// A row or card appearing starts this much smaller, anchored where it comes from.
        public static let enterScale: CGFloat = 0.96
        /// A popover, a menu or a palette starts this much smaller, anchored at its origin.
        public static let overlayScale: CGFloat = 0.94
        /// A small control while pressed.
        public static let pressScale: CGFloat = 0.97
        /// A toast rises this far while it fades in.
        public static let toastRise: CGFloat = 12
        /// The delay between neighbours of a cascade, and the most that cascade ever waits in total.
        public static let stagger: Double = 0.03
        public static let maxStagger: Double = 0.24
    }

    /// The delay of item `index` in a cascade (a folder unfolding, a menu's rows): grows by `Metrics.stagger` and
    /// never passes `Metrics.maxStagger`, so a long list does not make you wait. Zero under "Reduce motion".
    public static func stagger(index: Int, reduceMotion: Bool = Motion.reduceMotion) -> Double {
        guard !reduceMotion else { return 0 }
        return min(Double(max(index, 0)) * Metrics.stagger, Metrics.maxStagger)
    }

    // MARK: Hover

    /// How a card looks under the pointer: a little bigger, lifted, turned toward the pointer, its shadow deeper.
    public struct HoverPose: Equatable, Sendable {
        public var scale: CGFloat
        /// Points the card rises (negative `y` offset).
        public var lift: CGFloat
        /// The most it turns, in degrees; the real angle follows where the pointer is (`tilt(pointerX:)`).
        public var maxTilt: Double
        /// 0 is the resting shadow, 1 the deepest.
        public var shadow: Double

        public init(scale: CGFloat, lift: CGFloat, maxTilt: Double, shadow: Double) {
            self.scale = scale
            self.lift = lift
            self.maxTilt = maxTilt
            self.shadow = shadow
        }

        public static let rest = HoverPose(scale: 1, lift: 0, maxTilt: 0, shadow: 0)
        /// Folder pages and the gallery: a card of a note or a folder.
        public static let card = HoverPose(scale: 1.02, lift: 3, maxTilt: 1.2, shadow: 1)
        /// A kanban card: smaller, so a column of them stays calm.
        public static let compact = HoverPose(scale: 1.01, lift: 1.5, maxTilt: 0.6, shadow: 1)

        /// The pose to draw: this one while hovered, the rest pose otherwise, and always the rest pose under
        /// "Reduce motion" (the card changes its ring and shadow colour only).
        public func resolved(hovered: Bool, reduceMotion: Bool = Motion.reduceMotion) -> HoverPose {
            hovered && !reduceMotion ? self : .rest
        }

        /// The angle, in degrees, for a pointer at `pointerX` across the card (-1 left edge, 0 centre, 1 right
        /// edge): the card dips toward the pointer, so it feels pressed from there. Clamped to ±`maxTilt`.
        public func tilt(pointerX: Double) -> Double {
            maxTilt * min(max(pointerX, -1), 1)
        }
    }

    // MARK: Scroll edges

    /// The glass at the top and bottom of a scroll area. It is not on or off: it grows with how far the content has
    /// moved under the edge, over `rampDistance` points, so a scroll start feels continuous.
    public enum EdgeGlass {
        /// How tall the faded or blurred band is.
        public static let length: CGFloat = 32
        /// The scroll distance over which the effect goes from nothing to full.
        public static let rampDistance: CGFloat = 56
        /// The blur radius at full strength, in points.
        public static let maxBlur: CGFloat = 14

        /// The strength, 0...1, of an edge with `distance` points of content beyond it: eased, so it starts gently
        /// and has no visible step at either end.
        public static func progress(distance: CGFloat, ramp: CGFloat = rampDistance) -> Double {
            guard ramp > 0 else { return distance > 0 ? 1 : 0 }
            let t = Double(min(max(distance / ramp, 0), 1))
            return t * t * (3 - 2 * t)
        }
    }

    // MARK: Reduce motion

    /// Whether the system asks to reduce motion. For code outside views (AppKit panels, timers); a view reads
    /// `@Environment(\.accessibilityReduceMotion)` or uses `motion(_:value:)`, which do it for it.
    public static var reduceMotion: Bool { reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Set by the agent debug channel (debug builds) to run one instance with "Reduce motion" on or off whatever the
    /// system says; nil follows the system. The SwiftUI modifiers below read it next to their environment value.
    nonisolated(unsafe) public static var reduceMotionOverride: Bool?

    /// Set by the shell while a sidebar shows or hides with its slide (`Spring.slide`), never under "Reduce motion".
    /// A page is laid out once at its new width as the slide starts: an AppKit view that centres its content in it
    /// (the editor's column) plays the move to the new centre with the slide instead of jumping there.
    @MainActor public static var isSidebarSliding = false

    /// `animation`, or the short fade when motion is reduced.
    public static func resolved(_ animation: Animation, reduceMotion: Bool = Motion.reduceMotion) -> Animation {
        reduceMotion ? fade : animation
    }

    /// The duration to give an AppKit animation (`NSAnimationContext`, a window's fade): `duration`, or the fade's
    /// length when motion is reduced, since a fade is what remains.
    public static func appKitDuration(_ duration: TimeInterval, reduceMotion: Bool = Motion.reduceMotion) -> TimeInterval {
        reduceMotion ? min(duration, 0.12) : duration
    }

    /// Runs `body` in an animation that falls back to the short fade under "Reduce motion".
    @discardableResult
    public static func with<Result>(_ animation: Animation, _ body: () throws -> Result) rethrows -> Result {
        try withAnimation(resolved(animation), body)
    }

    // MARK: Transitions

    /// A row, a card or a field appearing: a little smaller, growing from `anchor`, fading in.
    public static func enter(from anchor: UnitPoint = .top) -> AnyTransition {
        .opacity.combined(with: .scale(scale: Metrics.enterScale, anchor: anchor))
    }

    /// A popover, a menu or a palette appearing: grows from the point it came from. Leaves with a fade.
    public static func overlay(from anchor: UnitPoint) -> AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .scale(scale: Metrics.overlayScale, anchor: anchor)), removal: .opacity)
    }

    /// A toast: rises from the bottom edge while fading in, sinks and fades out.
    public static var toast: AnyTransition {
        .opacity.combined(with: .offset(y: Metrics.toastRise))
    }

    /// Fading out in place.
    public static var leave: AnyTransition { .opacity }
}

extension View {
    /// `animation(_:value:)` with a named spring; the short fade under "Reduce motion".
    public func motion<Value: Equatable>(_ spring: Motion.Spring = .standard, value: Value) -> some View {
        modifier(MotionAnimation(animation: spring.animation, value: value))
    }

    /// `animation(_:value:)` with any animation (a fade token, `Motion.follow`); the short fade under
    /// "Reduce motion".
    public func motion<Value: Equatable>(_ animation: Animation, value: Value) -> some View {
        modifier(MotionAnimation(animation: animation, value: value))
    }

    /// `transition(_:)` that falls back to a fade under "Reduce motion".
    public func motionTransition(_ transition: AnyTransition) -> some View {
        modifier(MotionTransition(transition: transition))
    }
}

private struct MotionAnimation<Value: Equatable>: ViewModifier {
    let animation: Animation
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(Motion.resolved(animation, reduceMotion: reduceMotion || Motion.reduceMotion), value: value)
    }
}

private struct MotionTransition: ViewModifier {
    let transition: AnyTransition
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transition(reduceMotion || Motion.reduceMotion ? .opacity : transition)
    }
}
