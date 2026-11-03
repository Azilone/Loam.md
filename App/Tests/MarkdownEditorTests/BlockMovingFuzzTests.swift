import Foundation
import XCTest
@testable import MarkdownEditor

/// Moving any block anywhere, in notes made of every kind of block, keeps the note whole: the same blocks, none glued
/// to another, no blank lines piling up.
final class BlockMovingFuzzTests: XCTestCase {
    private let pieces = [
        "# Heading", "A paragraph\nover two lines", "- item", "- [ ] task\n  - [x] nested", "1. first\n2. second",
        "> a quote\n> more", "> [!NOTE]\n> callout", "```swift\nlet a = 1\n\nlet b = 2\n```", "| a | b |\n|---|---|\n| 1 | 2 |",
        "---", "![](picture.png)", "Plain line",
    ]

    private func note(_ generator: inout some RandomNumberGenerator) -> String {
        var text = Int.random(in: 0..<4, using: &generator) == 0 ? "\n\n" : ""
        for index in 0..<Int.random(in: 2...7, using: &generator) {
            if index > 0 { text += Bool.random(using: &generator) ? "\n\n" : "\n" }
            text += pieces.randomElement(using: &generator)!
        }
        return text + (Bool.random(using: &generator) ? "\n" : "")
    }

    /// The first line of each top-level block, without its indent.
    private func firsts(_ text: String) -> [String] {
        let ns = text as NSString
        return BlockMoving.blocks(in: text).map { ns.substring(with: $0.firstLine).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "***", with: "---") }.sorted()
    }

    func testAnyMoveKeepsTheNoteWhole() {
        var generator = SystemRandomNumberGenerator()
        var moves = 0
        for _ in 0..<3000 {
            let text = note(&generator)
            let blocks = BlockMoving.blocks(in: text)
            guard let moving = blocks.randomElement(using: &generator) else { continue }
            let target = Int.random(in: 0...blocks.count, using: &generator) == 0 ? nil : blocks.randomElement(using: &generator)
            guard let edit = BlockMoving.move(moving, before: target, in: text) else { continue }
            moves += 1
            let result = edit.applied(to: text)
            let context = "moving \((text as NSString).substring(with: moving.firstLine).debugDescription) before \(target.map { (text as NSString).substring(with: $0.firstLine) }.debugDescription) in \(text.debugDescription) gave \(result.debugDescription)"
            // A moved list item may join a list and change what it nests under, but no block is lost or glued.
            XCTAssertEqual(firsts(result), firsts(text), context)
            XCTAssertFalse(result.contains("\n\n\n") && !text.contains("\n\n\n"), "blank lines pile up: \(context)")
            XCTAssertFalse(result.hasPrefix("\n") && !text.hasPrefix("\n"), "blank line on top: \(context)")
        }
        XCTAssertGreaterThan(moves, 1000)
    }
}
