import CoreGraphics
import Foundation
import TermDownCore
import TermDownLayout
import XCTest

@testable import TermDownInteraction

final class RawBlockEditingTests: XCTestCase {
  let markdown = "Intro text.\n\n```swift\nlet x = 1\n```\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n> [!NOTE]\n> Alert body.\n\nOutro.\n"

  private var text: String { "" }

  func testArrowingIntoACodeBlockShowsItsSourceAndTypingEditsIt() throws {
    var h = Harness(markdown)
    h.key(.char("i"))
    h.key(.end)
    XCTAssertEqual(h.model.edit?.caret, 11)
    XCTAssertFalse((h.layout.prepared.text as String).contains("```"), "code renders normally while the caret is away")
    h.key(.right)
    XCTAssertEqual(h.model.edit?.caret, 13, "the caret enters the code block at its fence")
    XCTAssertTrue((h.layout.prepared.text as String).contains("```swift\nlet x = 1\n```"), "raw source under the caret")
    h.key(.down)
    h.key(.end)
    h.keys("0")
    XCTAssertTrue(h.model.edit!.source.contains("let x = 10\n```"))
    h.key(.down)
    h.key(.down)
    XCTAssertFalse((h.layout.prepared.text as String).contains("```"), "leaving the block renders it as code again")
  }

  func testClickingATableEntersItsSource() throws {
    var h = Harness(markdown)
    h.key(.char("i"))
    let cell = (h.layout.prepared.text as NSString).range(of: "2")
    let rect = try XCTUnwrap(h.layout.rects(for: cell.location..<(cell.location + 1)).first?.rect)
    h.mouse(.press, at: CGPoint(x: rect.midX, y: rect.midY))
    h.mouse(.release, at: CGPoint(x: rect.midX, y: rect.midY))
    let caret = try XCTUnwrap(h.model.edit?.caret)
    let tableStart = Array(markdown.utf8).firstRange(of: Array("| a |".utf8))!.lowerBound
    XCTAssertGreaterThanOrEqual(caret, tableStart)
    XCTAssertTrue((h.layout.prepared.text as String).contains("|---|---|"), "the table shows as source")
  }

  func testAlertsAreRawUnderTheCaret() throws {
    let session = EditSession(source: markdown)
    let alert = Array(markdown.utf8).firstRange(of: Array("> [!NOTE]".utf8))!.lowerBound
    XCTAssertEqual(session.block(containing: alert + 3)?.isRaw, true)
    XCTAssertTrue(session.isStop(alert + 3))
  }
}
