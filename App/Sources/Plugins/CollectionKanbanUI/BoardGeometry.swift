import CoreGraphics

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
    /// A column's pill and count, with the room under them.
    static let headerHeight: CGFloat = 25
    /// "+" under a column's cards.
    static let plusHeight: CGFloat = 40
    /// The inline field that becomes a card.
    static let fieldHeight: CGFloat = 43

    static var cardWidth: CGFloat { column - 2 * padding }
    static func columnX(_ index: Int) -> CGFloat { CGFloat(index) * (column + spacing) }
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

/// Where every part of the board goes: the columns side by side, each with its header, its cards in order, the
/// inline field and "+" under them, then "+" for a new column. Pure numbers, so the drag and the tests use it as the
/// view does.
struct BoardPlacement: Equatable {
    struct Column: Equatable {
        var background: CGRect
        var header: CGRect
        var cards: [String: CGRect]
        var field: CGRect?
        var plus: CGRect

        /// The same column moved sideways by `dx` (a column in the hand).
        func shifted(by dx: CGFloat) -> Column {
            Column(background: background.offsetBy(dx: dx, dy: 0), header: header.offsetBy(dx: dx, dy: 0),
                   cards: cards.mapValues { $0.offsetBy(dx: dx, dy: 0) }, field: field?.offsetBy(dx: dx, dy: 0),
                   plus: plus.offsetBy(dx: dx, dy: 0))
        }
    }

    var columns: [Column]
    var addColumn: CGRect
    var size: CGSize

    /// `lists` are the columns' cards, top to bottom (the card in the hand at its gap); `height` gives a card's.
    static func place(lists: [[String]], height: (String) -> CGFloat, fieldColumn: Int? = nil) -> BoardPlacement {
        var columns: [Column] = []
        var tallest: CGFloat = 0
        for (index, list) in lists.enumerated() {
            let x = BoardMetrics.columnX(index) + BoardMetrics.padding
            var y = BoardMetrics.padding
            func put(_ height: CGFloat) -> CGRect {
                defer { y += height + BoardMetrics.itemSpacing }
                return CGRect(x: x, y: y, width: BoardMetrics.cardWidth, height: height)
            }
            let header = put(BoardMetrics.headerHeight)
            var cards: [String: CGRect] = [:]
            for path in list { cards[path] = put(height(path)) }
            let field = fieldColumn == index ? put(BoardMetrics.fieldHeight) : nil
            let plus = put(BoardMetrics.plusHeight)
            let columnHeight = max(BoardMetrics.minColumnHeight, y - BoardMetrics.itemSpacing + BoardMetrics.padding)
            columns.append(Column(
                background: CGRect(x: BoardMetrics.columnX(index), y: 0, width: BoardMetrics.column, height: columnHeight),
                header: header, cards: cards, field: field, plus: plus))
            tallest = max(tallest, columnHeight)
        }
        let trailing = lists.isEmpty ? 0 : BoardMetrics.columnX(lists.count)
        return BoardPlacement(
            columns: columns,
            addColumn: CGRect(x: trailing, y: 0, width: BoardMetrics.addColumn, height: BoardMetrics.addColumn),
            size: CGSize(width: trailing + BoardMetrics.addColumn, height: tallest + BoardMetrics.bottom))
    }

    /// A card's frame, wherever it is.
    func frame(of path: String) -> CGRect? {
        for column in columns { if let frame = column.cards[path] { return frame } }
        return nil
    }
}
