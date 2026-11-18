import Foundation
import TermDownDocument
import XCTest

@testable import TermDownInteraction

final class EditSessionTests: XCTestCase {
  private func stops(_ session: EditSession, forward: Bool) -> [Int] {
    var session = session
    var visited: [Int] = []
    while true {
      let before = session.caret
      session.moveHorizontally(forward: forward, word: false, extend: false)
      if session.caret == before { break }
      visited.append(session.caret)
      if visited.count > 200 { break }
    }
    return visited
  }

  func testArrowsStepThroughRevealedMarkupOneCharacterAtATime() {
    let session = EditSession(source: "x **bold** y\n", caret: 0)
    XCTAssertEqual(session.caret, 0)
    XCTAssertEqual(stops(session, forward: true), Array(1...12))
    var end = session
    end.move(to: 12, extend: false)
    XCTAssertEqual(stops(end, forward: false), Array((0...11).reversed()))
  }

  func testHeadingStartsAfterItsHashesAndRevealsThemToTheLeft() {
    var session = EditSession(source: "# Title\n\nBody\n")
    XCTAssertEqual(session.caret, 2, "the first stop is the first visible character")
    session.moveHorizontally(forward: false, word: false, extend: false)
    XCTAssertEqual(session.caret, 1)
    session.moveHorizontally(forward: false, word: false, extend: false)
    XCTAssertEqual(session.caret, 0)
    session.move(to: 7, extend: false)
    session.moveHorizontally(forward: true, word: false, extend: false)
    XCTAssertEqual(session.caret, 9, "past the heading's end the caret goes to the next block, not into the blank line")
  }

  func testTypingInsertsAtTheCaretAndUndoCoalescesAWord() {
    var session = EditSession(source: "Hello world\n", caret: 5)
    for character in " there" { session.insert(String(character)) }
    XCTAssertEqual(session.source, "Hello there world\n")
    XCTAssertEqual(session.caret, 11)
    XCTAssertTrue(session.isDirty)
    session.undo()
    XCTAssertEqual(session.source, "Hello  world\n", "the word after the space is one step")
    session.undo()
    XCTAssertEqual(session.source, "Hello world\n")
    session.redo()
    session.redo()
    XCTAssertEqual(session.source, "Hello there world\n")
  }

  func testSpaceTypedAtTheEndOfAParagraphKeepsTheCaretAfterIt() {
    for source in ["First sentence.\n", "First sentence.", "First sentence.\n\nNext paragraph.\n"] {
      var session = EditSession(source: source, caret: 15)
      XCTAssertEqual(session.caret, 15)
      session.insert(" ")
      XCTAssertEqual(session.caret, 16, "the caret moves past the typed space in \(source.debugDescription)")
      for character in "Next" { session.insert(String(character)) }
      XCTAssertTrue(session.source.hasPrefix("First sentence. Next"), session.source.debugDescription)
      XCTAssertEqual(session.caret, 20)
    }
  }

  func testSpaceTypedAtTheEndOfAListItemHeadingAndQuoteKeepsTheCaretAfterIt() {
    for (source, caret, expected) in [
      ("- item\n", 6, "- item x\n"), ("# Title\n", 7, "# Title x\n"), ("> quote\n", 7, "> quote x\n"),
    ] {
      var session = EditSession(source: source, caret: caret)
      session.insert(" ")
      session.insert("x")
      XCTAssertEqual(session.source, expected)
      XCTAssertEqual(session.caret, caret + 2)
    }
  }

  func testTrailingSpacesAreShownOnlyWhileTheCaretIsInThem() {
    let session = EditSession(source: "End.  \n", caret: 4)
    XCTAssertEqual(session.projection(of: session.blocks[0], caret: 4).text, "End.  ")
    XCTAssertEqual(session.projection(of: session.blocks[0], caret: nil).text, "End.")
  }

  func testSelectionReplaceAndDelete() {
    var session = EditSession(source: "one two three\n", caret: 4)
    session.moveHorizontally(forward: true, word: true, extend: true)
    XCTAssertEqual(session.selection, 4..<7)
    XCTAssertEqual(session.selectedSource, "two")
    session.insert("2")
    XCTAssertEqual(session.source, "one 2 three\n")
    session.moveHorizontally(forward: false, word: true, extend: true)
    session.deleteBackward()
    XCTAssertEqual(session.source, "one  three\n")
  }

  func testBackspaceDeletesRevealedMarkupAndJoinsBlocks() {
    var session = EditSession(source: "**b** x\n", caret: 5)
    session.deleteBackward()
    XCTAssertEqual(session.source, "**b* x\n")
    var join = EditSession(source: "First\n\nSecond\n", caret: 7)
    join.deleteBackward()
    XCTAssertEqual(join.source, "FirstSecond\n")
    XCTAssertEqual(join.caret, 5)
  }

  func testEnterStartsParagraphsListItemsAndQuotes() {
    var paragraph = EditSession(source: "Para here\n", caret: 4)
    paragraph.newParagraph()
    XCTAssertEqual(paragraph.source, "Para\n\n here\n")
    var list = EditSession(source: "- one\n", caret: 5)
    list.newParagraph()
    XCTAssertEqual(list.source, "- one\n- \n")
    XCTAssertEqual(list.caret, 8, "the caret sits in the new empty item")
    list.newParagraph()
    XCTAssertEqual(list.source, "- one\n\n", "Enter on an empty item ends the list")
    var ordered = EditSession(source: "1. a\n", caret: 4)
    ordered.newParagraph()
    XCTAssertEqual(ordered.source, "1. a\n2. \n")
    var task = EditSession(source: "- [x] done\n", caret: 10)
    task.newParagraph()
    XCTAssertEqual(task.source, "- [x] done\n- [ ] \n")
    var quote = EditSession(source: "> quoted\n", caret: 8)
    quote.newParagraph()
    XCTAssertEqual(quote.source, "> quoted\n>\n> \n")
  }

  func testBackspaceAtAnItemStartRemovesTheMarker() {
    var session = EditSession(source: "- one\n- two\n", caret: 8)
    XCTAssertEqual(session.caret, 8)
    session.deleteBackward()
    XCTAssertEqual(session.source, "- one\ntwo\n")
  }

  func testBlankLinesAreStopsAndTypingThereMakesAParagraph() {
    var session = EditSession(source: "Para\n", caret: 4)
    session.newParagraph()
    XCTAssertEqual(session.source, "Para\n\n\n")
    XCTAssertEqual(session.caret, 6)
    XCTAssertTrue(session.isStop(6))
    session.insert("x")
    XCTAssertEqual(session.source, "Para\n\nx\n")
    XCTAssertEqual(session.blocks.count, 2)
  }

  func testPasteIsOneUndoStepAndKeepsCRLF() {
    var session = EditSession(source: "a\r\nb\r\n", caret: 1)
    session.paste("X\nY")
    XCTAssertEqual(session.source, "aX\r\nY\r\nb\r\n")
    session.undo()
    XCTAssertEqual(session.source, "a\r\nb\r\n")
  }

  func testSoftLineContinuationSkipsTheQuotePrefix() {
    let session = EditSession(source: "> one\n> two\n", caret: 5)
    var moved = session
    moved.moveHorizontally(forward: true, word: false, extend: false)
    XCTAssertEqual(moved.caret, 8, "after the line break the caret lands past '> '")
  }
}
