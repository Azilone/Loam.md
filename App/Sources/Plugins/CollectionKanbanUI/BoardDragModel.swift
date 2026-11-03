import AppKit
import Observation
import PluginKitUI
import SwiftUI

/// A card in the hand: where it is, where it would land, and how it settles when let go.
///
/// The card the user takes stays in the board as its own ghost, placed at the gap (the index the hand is over);
/// a copy of it follows the pointer above everything (`HeldCardLayer`). Only `gap` changes the layout of the board,
/// so only it is animated as a layout; `heldTopLeft` is read by the copy alone and follows the pointer 1:1.
@MainActor
@Observable
final class BoardDragModel {
    enum Phase: Equatable {
        case idle
        /// The card is in the hand.
        case holding
        /// Let go: the card slides into the ghost's frame, then the move is written.
        case settling
    }

    struct Gap: Equatable {
        var column: Int
        var index: Int
    }

    private(set) var phase = Phase.idle
    private(set) var heldPath: String?
    /// Where the held card would land: its column and index among that column's other cards.
    private(set) var gap: Gap?
    /// The top-left of the card in the hand, in content coordinates.
    private(set) var heldTopLeft = CGPoint.zero
    private(set) var heldSize = CGSize.zero
    /// Degrees; the card leans into its sideways movement.
    private(set) var tilt = 0.0

    // What the board tells the model.
    @ObservationIgnored var cardFrames: [String: CGRect] = [:]
    @ObservationIgnored var headerHeight: CGFloat = 26
    @ObservationIgnored var scroll = BoardScroll()
    @ObservationIgnored var scrollTo: (CGFloat) -> Void = { _ in }
    /// Writes the move: the held path, the column, the index among that column's other cards.
    @ObservationIgnored var commitMove: (String, Int, Int) -> Void = { _, _, _ in }

    @ObservationIgnored private var columns: [[String]] = []
    @ObservationIgnored private var pointer = CGPoint.zero
    @ObservationIgnored private var grab = CGSize.zero
    @ObservationIgnored private var velocity = CGSize.zero
    @ObservationIgnored private var lastMove: CFTimeInterval = 0
    @ObservationIgnored private var settle: Settle?
    @ObservationIgnored private var cursorPushed = false
    @ObservationIgnored private var rejected = false

    private struct Settle {
        var start: CFTimeInterval
        /// Where the card was when let go, from the ghost's frame.
        var offset: CGSize
        var velocity: CGSize
    }

    var isHolding: Bool { phase != .idle }
    var needsFrames: Bool { phase != .idle }

    private static var spring: Spring {
        Spring(duration: Motion.Spring.settle.duration, bounce: Motion.Spring.settle.bounce)
    }

    // MARK: Gesture

    /// Called for every event of the board's drag gesture; picks up a card on the first one that starts on a card.
    func changed(start: CGPoint, location: CGPoint, velocity: CGSize, columns: @autoclosure () -> [[String]]) {
        if phase == .idle || phase == .settling {
            guard !rejected else { return }
            guard pickUp(at: start, columns: columns()) else {
                rejected = true
                return
            }
        }
        pointer = location
        self.velocity = velocity
        lastMove = CACurrentMediaTime()
        follow()
    }

    func ended(velocity: CGSize) {
        defer { rejected = false }
        guard phase == .holding else { return }
        self.velocity = velocity
        guard !Motion.reduceMotion, let path = heldPath, let ghost = cardFrames[path] else {
            land()
            return
        }
        phase = .settling
        settle = Settle(
            start: CACurrentMediaTime(),
            offset: CGSize(width: heldTopLeft.x - ghost.minX, height: heldTopLeft.y - ghost.minY),
            velocity: velocity)
    }

    // MARK: Picking up

    private func pickUp(at start: CGPoint, columns: [[String]]) -> Bool {
        let content = CGPoint(x: start.x + scroll.offset, y: start.y)
        if phase == .settling, let path = heldPath, let ghost = cardFrames[path] {
            // Taken again before it landed: carry on from where the card is, with the same gap.
            let shown = shownTopLeft(ghost: ghost, now: CACurrentMediaTime())
            guard CGRect(origin: shown, size: heldSize).contains(content) else {
                land()
                return pickUp(at: start, columns: columns)
            }
            settle = nil
            phase = .holding
            heldTopLeft = shown
            grab = CGSize(width: content.x - shown.x, height: content.y - shown.y)
            return true
        }
        guard let path = columns.joined().first(where: { cardFrames[$0]?.contains(content) == true }),
              let frame = cardFrames[path],
              let column = columns.firstIndex(where: { $0.contains(path) }),
              let index = columns[column].firstIndex(of: path)
        else { return false }
        self.columns = columns
        heldSize = frame.size
        heldTopLeft = frame.origin
        grab = CGSize(width: content.x - frame.minX, height: content.y - frame.minY)
        tilt = 0
        withAnimation(Motion.resolved(Motion.Spring.lift.animation)) {
            heldPath = path
            gap = Gap(column: column, index: index)
            phase = .holding
        }
        Haptics.levelChange()
        Sounds.play(.pickedUp)
        if !cursorPushed {
            NSCursor.closedHand.push()
            cursorPushed = true
        }
        return true
    }

    // MARK: Following

    /// The card goes where the pointer is (no animation: it is in the hand), and the gap goes where the card is.
    private func follow() {
        let content = CGPoint(x: pointer.x + scroll.offset, y: pointer.y)
        heldTopLeft = CGPoint(x: content.x - grab.width, y: content.y - grab.height)
        retarget()
    }

    private func retarget() {
        guard let path = heldPath, !columns.isEmpty else { return }
        let center = CGPoint(x: heldTopLeft.x + heldSize.width / 2, y: heldTopLeft.y + heldSize.height / 2)
        let column = BoardDragMath.column(at: center.x, count: columns.count)
        let heights = columns[column].filter { $0 != path }.map { cardFrames[$0]?.height ?? heldSize.height }
        let top = BoardMetrics.padding + headerHeight + BoardMetrics.itemSpacing
        let target = Gap(column: column, index: BoardDragMath.insertionIndex(y: center.y, top: top, heights: heights))
        guard target != gap else { return }
        // Interruptible: a new target while the neighbours still move retargets their spring from where they are.
        withAnimation(Motion.resolved(Motion.Spring.standard.animation)) { gap = target }
        Haptics.alignment()
    }

    /// Runs on every frame while a card is held or settling: scrolls the board near its edges, leans the card,
    /// and moves a settling card.
    func tick(now: CFTimeInterval, dt: CFTimeInterval) {
        switch phase {
        case .idle:
            return
        case .holding:
            let speed = BoardDragMath.autoScrollSpeed(pointerX: pointer.x, viewport: scroll.viewport)
            if speed != 0 {
                let offset = min(max(scroll.offset + speed * dt, 0), scroll.maxOffset)
                if offset != scroll.offset {
                    scroll.offset = offset
                    scrollTo(offset)
                    follow()
                }
            }
            // The lean follows the hand's speed, and relaxes by itself when the hand stops.
            let idle = now - lastMove > 0.06
            let target = Motion.reduceMotion ? 0 : BoardDragMath.tilt(velocity: idle ? 0 : velocity.width)
            let next = tilt + (target - tilt) * min(1, dt * 14)
            if abs(next - tilt) > 0.01 { tilt = next }
        case .settling:
            guard let path = heldPath, let ghost = cardFrames[path], let settle else {
                land()
                return
            }
            let elapsed = now - settle.start
            heldTopLeft = shownTopLeft(ghost: ghost, now: now)
            // Landed: on the ghost to the pixel, or the spring's last wobble, too small to see, is all that is left.
            let off = max(abs(heldTopLeft.x - ghost.minX), abs(heldTopLeft.y - ghost.minY))
            if elapsed >= Self.spring.settlingDuration || (elapsed >= Self.spring.settlingDuration * 0.6 && off < 1) {
                land()
                return
            }
            tilt *= max(0, 1 - dt * 12)
        }
    }

    private func shownTopLeft(ghost: CGRect, now: CFTimeInterval) -> CGPoint {
        guard let settle else { return heldTopLeft }
        let time = max(0, now - settle.start)
        func axis(_ offset: CGFloat, _ velocity: CGFloat) -> CGFloat {
            offset + Self.spring.value(target: -offset, initialVelocity: velocity, time: time)
        }
        return CGPoint(
            x: ghost.minX + axis(settle.offset.width, settle.velocity.width),
            y: ghost.minY + axis(settle.offset.height, settle.velocity.height))
    }

    /// Whether the card in the hand is on its way to its slot (for its shadow and size to settle with it).
    var isLanding: Bool { phase == .settling }

    // MARK: Landing

    /// The card is on its ghost: write the move, drop the ghost and the copy. The card in the board takes the
    /// copy's place at the same frame, so nothing moves.
    private func land() {
        guard let path = heldPath, let gap else {
            finish()
            return
        }
        // The counts roll and the column settles; the card and its copy swap at the same frame, without animation.
        Motion.with(Motion.Spring.standard.animation) {
            commitMove(path, gap.column, gap.index)
            finish()
        }
        Sounds.play(.dropped)
        if !Motion.reduceMotion {
            Haptics.alignment()
        }
    }

    /// Lets the held card go without moving it (the board changed under it).
    func cancel() {
        guard phase != .idle else { return }
        finish()
    }

    private func finish() {
        phase = .idle
        heldPath = nil
        gap = nil
        tilt = 0
        settle = nil
        columns = []
        if cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
    }
}
