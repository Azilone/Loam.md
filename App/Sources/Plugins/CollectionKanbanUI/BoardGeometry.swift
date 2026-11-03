import SwiftUI

/// Sizes of the board, in points.
enum BoardMetrics {
    static let column: CGFloat = 270
    /// Between two columns.
    static let spacing: CGFloat = 12
    /// Inside a column, around its content.
    static let padding: CGFloat = 10
    /// Between the header, the cards and "+" of a column.
    static let itemSpacing: CGFloat = 8
    static let minColumnHeight: CGFloat = 420
    /// The "+" that adds a column.
    static let addColumn: CGFloat = 32
    /// Room under the board for the shadows.
    static let bottom: CGFloat = 8

    static var cardWidth: CGFloat { column - 2 * padding }
    static func columnX(_ index: Int) -> CGFloat { CGFloat(index) * (column + spacing) }
}

/// The two coordinate spaces of the board: where the pointer is (the visible part, it does not scroll with the
/// columns) and where the cards are (the columns' own, so a card keeps its frame while the board scrolls).
enum BoardSpace {
    static var viewport: NamedCoordinateSpace { .named("loam.board.viewport") }
    static var content: NamedCoordinateSpace { .named("loam.board.content") }
}

/// The numbers behind a drag, free of views so they can be tested.
enum BoardDragMath {
    /// The column under `x` (content coordinates): the one whose span, with the gap after it, holds `x`.
    static func column(at x: CGFloat, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let index = Int((x / (BoardMetrics.column + BoardMetrics.spacing)).rounded(.down))
        return min(max(index, 0), count - 1)
    }

    /// Where a held card goes in a column: how many of its other cards (`heights`, top to bottom, packed) have
    /// their middle above `y`. `top` is where the first card starts. The cards are measured as if the gap were
    /// closed, so the answer depends on the pointer only and never on the cards moving out of the way (that would
    /// make the gap flicker between two places).
    static func insertionIndex(y: CGFloat, top: CGFloat, heights: [CGFloat]) -> Int {
        var cursor = top
        var index = 0
        for height in heights {
            if y < cursor + height / 2 { break }
            cursor += height + BoardMetrics.itemSpacing
            index += 1
        }
        return index
    }

    /// Points per second the board scrolls while a card is held at `pointerX` (viewport coordinates): 0 in the
    /// middle, growing with the square of how deep the pointer is in the `edge` band, negative to the left.
    static func autoScrollSpeed(pointerX: CGFloat, viewport: CGFloat, edge: CGFloat = 88, maxSpeed: CGFloat = 1200) -> CGFloat {
        guard viewport > 2 * edge else { return 0 }
        func ramp(_ depth: CGFloat) -> CGFloat {
            let t = min(max(depth / edge, 0), 1)
            return t * t
        }
        if pointerX < edge { return -maxSpeed * ramp(edge - pointerX) }
        if pointerX > viewport - edge { return maxSpeed * ramp(pointerX - (viewport - edge)) }
        return 0
    }

    /// The angle, in degrees, of a held card moving sideways at `velocity` points per second: it leans into the
    /// movement, never more than `maxTilt`.
    static func tilt(velocity: CGFloat, maxTilt: Double = 4) -> Double {
        let degrees = Double(velocity) / 220
        return min(max(degrees, -maxTilt), maxTilt)
    }
}

/// What a view of the board is, so the layout knows where to put it.
enum BoardRole: Hashable {
    case background(column: Int)
    case header(column: Int)
    /// The `index`th card of the column, the card in the hand (its ghost) included.
    case card(column: Int, index: Int)
    /// The inline field that is about to become a card.
    case field(column: Int)
    case plus(column: Int)
    case addColumn

    var column: Int? {
        switch self {
        case .background(let column), .header(let column), .card(let column, _), .field(let column), .plus(let column):
            column
        case .addColumn: nil
        }
    }
}

struct BoardRoleKey: LayoutValueKey {
    static let defaultValue = BoardRole.addColumn
}

extension View {
    func boardRole(_ role: BoardRole) -> some View {
        layoutValue(key: BoardRoleKey.self, value: role)
    }
}

/// Puts every part of the board where it belongs from its role alone: the columns side by side, each with its
/// header, its cards in order, the inline field and "+".
///
/// One layout holds all the cards (rather than one stack per column) so a card keeps its identity when it changes
/// column: moving it by the menu, by editing its field in the note or by dragging is only a new role, and
/// SwiftUI slides it there. The neighbours of a card in the hand part the same way, the ghost taking its new index.
struct BoardLayout: Layout {
    struct Result {
        var frames: [CGRect]
        var size: CGSize
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        measure(subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = measure(subviews)
        for (index, subview) in subviews.enumerated() {
            let frame = result.frames[index]
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }

    private struct Parts {
        var background: Int?
        var header: Int?
        var cards: [(index: Int, subview: Int)] = []
        var field: Int?
        var plus: Int?
    }

    private func measure(_ subviews: Subviews) -> Result {
        var frames = Array(repeating: CGRect.zero, count: subviews.count)
        var columns: [Int: Parts] = [:]
        var addColumn: Int?
        for (index, subview) in subviews.enumerated() {
            switch subview[BoardRoleKey.self] {
            case .background(let column): columns[column, default: Parts()].background = index
            case .header(let column): columns[column, default: Parts()].header = index
            case .card(let column, let position): columns[column, default: Parts()].cards.append((position, index))
            case .field(let column): columns[column, default: Parts()].field = index
            case .plus(let column): columns[column, default: Parts()].plus = index
            case .addColumn: addColumn = index
            }
        }

        let count = (columns.keys.max() ?? -1) + 1
        let card = ProposedViewSize(width: BoardMetrics.cardWidth, height: nil)
        var tallest: CGFloat = 0
        for column in 0..<count {
            guard let parts = columns[column] else { continue }
            let x = BoardMetrics.columnX(column) + BoardMetrics.padding
            var y = BoardMetrics.padding
            func put(_ subview: Int) {
                let size = subviews[subview].sizeThatFits(card)
                frames[subview] = CGRect(x: x, y: y, width: BoardMetrics.cardWidth, height: size.height)
                y += size.height + BoardMetrics.itemSpacing
            }
            if let header = parts.header { put(header) }
            for entry in parts.cards.sorted(by: { $0.index < $1.index }) { put(entry.subview) }
            if let field = parts.field { put(field) }
            if let plus = parts.plus { put(plus) }
            let height = max(BoardMetrics.minColumnHeight, y - BoardMetrics.itemSpacing + BoardMetrics.padding)
            if let background = parts.background {
                frames[background] = CGRect(x: BoardMetrics.columnX(column), y: 0, width: BoardMetrics.column, height: height)
            }
            tallest = max(tallest, height)
        }

        let trailing = count > 0 ? BoardMetrics.columnX(count) : 0
        if let addColumn {
            frames[addColumn] = CGRect(x: trailing, y: 0, width: BoardMetrics.addColumn, height: BoardMetrics.addColumn)
        }
        return Result(
            frames: frames,
            size: CGSize(width: trailing + BoardMetrics.addColumn, height: tallest + BoardMetrics.bottom))
    }
}

/// What the scroll view reports, kept apart from the view so a drag can read it between two renders.
struct BoardScroll: Equatable {
    var offset: CGFloat = 0
    var content: CGFloat = 0
    var viewport: CGFloat = 0

    var maxOffset: CGFloat { max(0, content - viewport) }
}
