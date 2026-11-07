import PluginKitUI
import SwiftUI
import XCTest

final class MotionTests: XCTestCase {
    private let springs: [(name: String, spring: Motion.Spring)] = [
        ("tap", .tap), ("standard", .standard), ("smooth", .smooth), ("slide", .slide),
        ("pop", .pop), ("overlay", .overlay), ("lift", .lift), ("settle", .settle),
    ]

    /// Every spring settles in a fraction of a second and overshoots little: nothing sluggish, nothing wobbly.
    func testSpringsAreShortAndLittleBouncy() {
        for (name, spring) in springs {
            XCTAssertTrue((0.15...0.5).contains(spring.duration), "\(name) duration \(spring.duration)")
            XCTAssertTrue((0...0.3).contains(spring.bounce), "\(name) bounce \(spring.bounce)")
        }
    }

    /// Pages and sidebars never overshoot; only the light, playful things may.
    func testHeavySurfacesDoNotBounce() {
        for spring in [Motion.Spring.smooth, .slide, .tap] {
            XCTAssertEqual(spring.bounce, 0)
        }
        XCTAssertGreaterThan(Motion.Spring.pop.bounce, Motion.Spring.standard.bounce)
    }

    /// The sidebar's spring is the slowest, so a slide reads as the biggest movement.
    func testSlideIsTheSlowestSpring() {
        let slowest = springs.map(\.spring.duration).max()
        XCTAssertEqual(Motion.Spring.slide.duration, slowest)
    }

    func testReduceMotionReplacesSpringsWithTheFade() {
        for (_, spring) in springs {
            XCTAssertEqual(Motion.resolved(spring.animation, reduceMotion: true), Motion.fade)
            XCTAssertEqual(Motion.resolved(spring.animation, reduceMotion: false), spring.animation)
        }
    }

    func testAppKitDurationIsCappedWhenReduced() {
        XCTAssertEqual(Motion.appKitDuration(0.5, reduceMotion: true), 0.12)
        XCTAssertEqual(Motion.appKitDuration(0.05, reduceMotion: true), 0.05)
        XCTAssertEqual(Motion.appKitDuration(0.5, reduceMotion: false), 0.5)
    }

    func testStaggerGrowsThenCapsAndVanishesWhenReduced() {
        XCTAssertEqual(Motion.stagger(index: 0, reduceMotion: false), 0)
        XCTAssertEqual(Motion.stagger(index: 2, reduceMotion: false), 0.06, accuracy: 1e-9)
        XCTAssertEqual(Motion.stagger(index: 500, reduceMotion: false), Motion.Metrics.maxStagger)
        XCTAssertEqual(Motion.stagger(index: -3, reduceMotion: false), 0)
        XCTAssertEqual(Motion.stagger(index: 4, reduceMotion: true), 0)
    }

    func testHoverPoseFallsBackToRestWhenReducedOrNotHovered() {
        XCTAssertEqual(Motion.HoverPose.card.resolved(hovered: true, reduceMotion: false), .card)
        XCTAssertEqual(Motion.HoverPose.card.resolved(hovered: false, reduceMotion: false), .rest)
        XCTAssertEqual(Motion.HoverPose.card.resolved(hovered: true, reduceMotion: true), .rest)
    }

    func testTiltFollowsThePointerAndIsClamped() {
        let pose = Motion.HoverPose.card
        XCTAssertEqual(pose.tilt(pointerX: 0), 0)
        XCTAssertEqual(pose.tilt(pointerX: 1), pose.maxTilt)
        XCTAssertEqual(pose.tilt(pointerX: -1), -pose.maxTilt)
        XCTAssertEqual(pose.tilt(pointerX: 5), pose.maxTilt)
        XCTAssertEqual(pose.tilt(pointerX: 0.25), -pose.tilt(pointerX: -0.25), accuracy: 1e-12)
        XCTAssertLessThan(Motion.HoverPose.compact.maxTilt, Motion.HoverPose.card.maxTilt)
    }

    /// The edge glass is 0 at rest, 1 once the ramp is crossed, and never decreases in between.
    func testEdgeGlassProgress() {
        XCTAssertEqual(Motion.EdgeGlass.progress(distance: 0), 0)
        XCTAssertEqual(Motion.EdgeGlass.progress(distance: -20), 0)
        XCTAssertEqual(Motion.EdgeGlass.progress(distance: Motion.EdgeGlass.rampDistance), 1)
        XCTAssertEqual(Motion.EdgeGlass.progress(distance: 10_000), 1)
        XCTAssertEqual(Motion.EdgeGlass.progress(distance: Motion.EdgeGlass.rampDistance / 2), 0.5, accuracy: 1e-9)
        var previous = 0.0
        for step in 0...100 {
            let value = Motion.EdgeGlass.progress(distance: CGFloat(step) * Motion.EdgeGlass.rampDistance / 100)
            XCTAssertGreaterThanOrEqual(value, previous)
            previous = value
        }
        XCTAssertEqual(Motion.EdgeGlass.progress(distance: 1, ramp: 0), 1)
        XCTAssertEqual(Motion.EdgeGlass.progress(distance: 0, ramp: 0), 0)
    }

    /// The collection names are the shared tokens, not copies that could drift.
    func testCollectionMotionUsesTheSharedTokens() {
        XCTAssertEqual(CollectionMotion.layout, Motion.Spring.standard.animation)
        XCTAssertEqual(CollectionMotion.hover, Motion.hover)
        XCTAssertEqual(CollectionMotion.fade, Motion.fade)
    }

    /// A menu grows from the corner nearest its caret, a bar from the edge nearest its selection.
    func testOverlaysGrowFromTheSideTheyOpenOn() {
        XCTAssertEqual(Motion.Opening.below.menuAnchor, .topLeading)
        XCTAssertEqual(Motion.Opening.above.menuAnchor, .bottomLeading)
        XCTAssertEqual(Motion.Opening.above.barAnchor, .bottom)
        XCTAssertEqual(Motion.Opening.below.barAnchor, .top)
        XCTAssertEqual(Motion.Opening.above.barRiseSign, -Motion.Opening.below.barRiseSign)
    }

    func testOverlayMetricsAreSmallAndLeavingIsFasterThanArriving() {
        XCTAssertGreaterThan(Motion.Metrics.menuScale, Motion.Metrics.overlayScale)
        XCTAssertGreaterThan(Motion.Metrics.paletteExitScale, Motion.Metrics.overlayScale)
        XCTAssertLessThan(Motion.Metrics.toastSink, Motion.Metrics.toastRise)
        XCTAssertLessThan(Motion.Metrics.menuExit, Motion.Metrics.exitDuration)
        XCTAssertLessThan(Motion.Metrics.exitDuration, Motion.Spring.overlay.duration)
    }
}

final class CardMotionTests: XCTestCase {
    func testPointerIsNormalisedAndClamped() {
        let size = CGSize(width: 200, height: 100)
        XCTAssertEqual(CardMotion.pointer(CGPoint(x: 100, y: 50), in: size), .zero)
        XCTAssertEqual(CardMotion.pointer(CGPoint(x: 0, y: 0), in: size), CGPoint(x: -1, y: -1))
        XCTAssertEqual(CardMotion.pointer(CGPoint(x: 300, y: 150), in: size), CGPoint(x: 1, y: 1))
        XCTAssertEqual(CardMotion.pointer(CGPoint(x: 5, y: 5), in: .zero), .zero)
    }

    func testTiltFollowsThePointerAtHalfStrengthVertically() {
        let angles = CardMotion.angles(for: CGPoint(x: 1, y: -1), pose: .card)
        XCTAssertEqual(angles.y, 1.2, accuracy: 0.0001)
        XCTAssertEqual(angles.x, -0.6, accuracy: 0.0001)
        XCTAssertEqual(CardMotion.angles(for: .zero, pose: .card).y, 0)
    }

    func testCascadeOnlyCoversTheFirstCardsAndWaitsLessThanTheCap() {
        XCTAssertNil(CardMotion.cascadeDelay(index: nil, reduceMotion: false))
        XCTAssertNil(CardMotion.cascadeDelay(index: CardMotion.cascadeLimit, reduceMotion: false))
        XCTAssertEqual(CardMotion.cascadeDelay(index: 0, reduceMotion: false), 0)
        XCTAssertEqual(try XCTUnwrap(CardMotion.cascadeDelay(index: 4, reduceMotion: false)), 0.12, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(try XCTUnwrap(CardMotion.cascadeDelay(index: 11, reduceMotion: false)), Motion.Metrics.maxStagger)
        XCTAssertEqual(CardMotion.cascadeDelay(index: 5, reduceMotion: true), 0)
    }
}
