import CoreGraphics
import Foundation
import TermDownCore
import TermDownRender
import XCTest

@testable import TermDownInteraction

final class MarksListTests: XCTestCase {
  private func select(_ needle: String, in h: inout Harness) {
    h.run(h.model.setSelection(h.range(of: needle)))
  }

  private func mark(_ needle: String, with digit: Character, in h: inout Harness) {
    select(needle, in: &h)
    h.key(.char(digit))
  }

  private func reviewing(_ markdown: String) -> Harness {
    var h = Harness(markdown)
    h.connectAgent()
    h.key(.char("m"))
    return h
  }

  private func bytes(_ h: Harness, _ range: Range<Int>) -> String {
    String(decoding: Array(h.model.source.utf8)[range], as: UTF8.self)
  }

  func testMOpensListInDocumentOrder() {
    var h = reviewing("Alpha one.\n\nBeta two.\n\nGamma three.\n")
    mark("Gamma", with: "3", in: &h)
    mark("Alpha", with: "1", in: &h)
    mark("Beta", with: "2", in: &h)
    XCTAssertTrue(h.key(.char("M")).contains(.redrawAll))
    let list = try! XCTUnwrap(h.model.marksList)
    XCTAssertEqual(list.rows.map(\.quote), ["Alpha", "Beta", "Gamma"], "sorted by where each mark starts")
    XCTAssertEqual(list.rows.map(\.key), ["1", "2", "3"])
    XCTAssertEqual(list.rows.map(\.label), ["Delete", "Awkward", "Cringe"])
    XCTAssertEqual(list.rows.map(\.color), ["#ef4444", "#f97316", "#eab308"])
    XCTAssertEqual(list.rows.map(\.line), [1, 3, 5])
    XCTAssertEqual(list.selected, 0)
    XCTAssertEqual(list.pass, 1)
    XCTAssertEqual(MarksList.header(list), "Marks · 3 · pass 1")
    XCTAssertEqual(MarksList.footer, "↑↓ move · Enter jump · x delete · 1-9 retype · n note · Esc close")
    XCTAssertEqual(h.key(.escape), [.redrawAll])
    XCTAssertNil(h.model.marksList)
    h.key(.char("M"))
    XCTAssertNotNil(h.model.marksList)
    h.key(.char("M"))
    XCTAssertNil(h.model.marksList)
  }

  func testMOutsideReviewOrWithoutMarksExplainsItself() {
    var h = Harness("Some text.\n")
    h.key(.char("M"))
    XCTAssertNil(h.model.marksList)
    XCTAssertEqual(h.model.status.message?.text, "Review is off: m starts it")
    var reviewing = reviewing("Some text.\n")
    reviewing.key(.char("M"))
    XCTAssertNil(reviewing.model.marksList)
    XCTAssertEqual(reviewing.model.status.message?.text, "No marks yet: select text, then 1-9")
  }

  func testTheListTakesKeysBeforeTheViewDoes() {
    var h = reviewing("Alpha one.\n\nBeta two.\n")
    mark("Alpha", with: "1", in: &h)
    h.key(.char("M"))
    XCTAssertEqual(h.key(.char("d")), [], "d does not scroll behind the list")
    XCTAssertEqual(h.key(.char("s")), [], "s does not submit behind the list")
    XCTAssertEqual(h.key(.ctrl("c")), [.quit])
  }

  func testEnterJumpsAndSelects() {
    var h = reviewing(longDocument())
    mark("Paragraph 60", with: "1", in: &h)
    mark("Paragraph 3 ", with: "2", in: &h)
    XCTAssertEqual(h.model.offset, 0)
    h.key(.char("M"))
    XCTAssertEqual(h.model.marksList?.rows.map(\.quote).first, "Paragraph 3")
    h.key(.down)
    XCTAssertEqual(h.model.marksList?.selected, 1)
    let effects = h.key(.enter)
    XCTAssertNil(h.model.marksList)
    XCTAssertTrue(effects.contains(.redrawAll))
    XCTAssertEqual(h.model.selection, h.range(of: "Paragraph 60"))
    let rect = h.layout.rects(for: h.range(of: "Paragraph 60")!).first!.rect
    XCTAssertGreaterThan(h.model.offset, 0)
    XCTAssertGreaterThanOrEqual(rect.minY, h.model.offset)
    XCTAssertLessThanOrEqual(rect.maxY, h.model.offset + h.model.geometry.contentHeight)
    XCTAssertEqual(h.model.review.marks.count, 2, "jumping keeps the marks")
  }

  func testClickingARowJumpsAndClickingOutsideCloses() {
    var h = reviewing(longDocument())
    mark("Paragraph 60", with: "1", in: &h)
    h.key(.char("M"))
    let list = try! XCTUnwrap(h.model.marksList)
    let view = MarksList(content: list, backingScale: h.model.typography.backingScale)
    let area = CGRect(x: 0, y: 0, width: h.model.geometry.width, height: h.model.geometry.contentHeight)
    let row = view.rowRect(0, in: area)
    h.paneMouse(.press, x: Int(row.midX), y: Int(row.midY))
    XCTAssertNil(h.model.marksList)
    XCTAssertEqual(h.model.selection, h.range(of: "Paragraph 60"))

    h.key(.char("M"))
    h.paneMouse(.press, x: 2, y: Int(area.height) - 2)
    XCTAssertNil(h.model.marksList, "a click away from the panel closes it")
  }

  func testXDeletesAndClamps() {
    var h = reviewing("Alpha one.\n\nBeta two.\n\nGamma three.\n")
    mark("Alpha", with: "1", in: &h)
    mark("Beta", with: "2", in: &h)
    mark("Gamma", with: "3", in: &h)
    h.key(.char("M"))
    h.key(.down)
    h.key(.down)
    XCTAssertEqual(h.model.marksList?.selected, 2)
    let effects = h.key(.char("x"))
    XCTAssertTrue(effects.contains(.redrawAll))
    XCTAssertEqual(h.model.marksList?.rows.map(\.quote), ["Alpha", "Beta"])
    XCTAssertEqual(h.model.marksList?.selected, 1, "the selection moves to the new last row")
    XCTAssertEqual(h.model.review.marks.count, 2)
    h.key(.char("x"))
    h.key(.char("x"))
    XCTAssertNil(h.model.marksList, "deleting the only row closes the list")
    XCTAssertTrue(h.model.review.marks.isEmpty)
    XCTAssertTrue(h.model.review.isOn)
  }

  func testDeletingAMiddleRowKeepsTheSelectionOnTheSameIndex() {
    var h = reviewing("Alpha one.\n\nBeta two.\n\nGamma three.\n")
    mark("Alpha", with: "1", in: &h)
    mark("Beta", with: "2", in: &h)
    mark("Gamma", with: "3", in: &h)
    h.key(.char("M"))
    h.key(.down)
    h.key(.char("x"))
    XCTAssertEqual(h.model.marksList?.rows.map(\.quote), ["Alpha", "Gamma"])
    XCTAssertEqual(h.model.marksList?.selected, 1)
  }

  func testDigitRetypesAndNoteOnlyForNotes() {
    var h = reviewing("Alpha one.\n\nBeta two.\n")
    mark("Alpha", with: "1", in: &h)
    h.key(.char("M"))
    h.key(.char("3"))
    XCTAssertEqual(h.model.review.marks.marks.first?.type, "cringe")
    XCTAssertEqual(h.model.review.marks.marks.first?.label, "Cringe")
    XCTAssertEqual(h.model.marksList?.rows.first?.key, "3")
    XCTAssertEqual(h.model.marksList?.rows.first?.color, "#eab308")

    h.key(.char("n"))
    XCTAssertNil(h.model.noteField)
    XCTAssertEqual(h.model.status.message?.text, "Notes are for 9 marks: press 9 to make this a note")

    h.key(.char("9"))
    XCTAssertEqual(h.model.noteField, "")
    XCTAssertNotNil(h.model.marksList, "the list stays open under the note field")
    h.keys("say hi")
    h.key(.enter)
    XCTAssertNil(h.model.noteField)
    XCTAssertEqual(h.model.review.marks.marks.first?.type, "note")
    XCTAssertEqual(h.model.review.marks.marks.first?.note, "say hi")
    XCTAssertEqual(h.model.marksList?.rows.first?.note, "say hi")
    XCTAssertEqual(h.model.marksList?.rows.first?.key, "9")
    XCTAssertEqual(h.key(.char("d")), [], "the list has its keys back and swallows the view's keys")

    h.key(.char("1"))
    let mark = h.model.review.marks.marks.first
    XCTAssertEqual(mark?.type, "delete")
    XCTAssertNil(mark?.note)
    XCTAssertEqual(h.model.status.message?.text, "Note dropped")
    XCTAssertNil(h.model.marksList?.rows.first?.note)
  }

  func testNEditsANotesTextAndEscapeKeepsIt() {
    var h = reviewing("Alpha one.\n")
    mark("Alpha", with: "9", in: &h)
    h.keys("first")
    h.key(.enter)
    XCTAssertEqual(h.model.review.marks.marks.first?.note, "first")
    h.key(.char("M"))
    h.key(.char("n"))
    XCTAssertEqual(h.model.noteField, "first", "the field starts with the current note")
    XCTAssertEqual(h.model.status.message?.text, "Instruction for this passage:")
    h.keys(" second")
    h.key(.enter)
    XCTAssertEqual(h.model.review.marks.marks.first?.note, "first second")
    XCTAssertEqual(h.model.marksList?.rows.first?.note, "first second")

    h.key(.char("n"))
    h.keys("ignored")
    h.key(.escape)
    XCTAssertNil(h.model.noteField)
    XCTAssertEqual(h.model.review.marks.marks.first?.note, "first second")
    XCTAssertNotNil(h.model.marksList, "Esc closes the field, not the list")
    h.key(.escape)
    XCTAssertNil(h.model.marksList)
  }

  /// A note field, opened from the list or by `9`, takes the keys; a click must not land on the page under it. The
  /// wheel still scrolls.
  func testAClickWhileANoteFieldIsOpenDoesNotReachThePage() {
    var h = reviewing("Alpha one.\n\nBeta two.\n\n" + longDocument())
    mark("Alpha", with: "9", in: &h)
    h.keys("first")
    h.key(.enter)
    h.key(.char("M"))
    h.key(.char("n"))
    XCTAssertEqual(h.model.noteField, "first")
    let selection = h.model.selection
    XCTAssertEqual(h.click(h.point(of: "Beta")), [])
    XCTAssertNil(h.model.edit, "the click did not start editing the page")
    XCTAssertEqual(h.model.selection, selection)
    XCTAssertEqual(h.model.noteField, "first")
    XCTAssertNotNil(h.model.marksList)
    let top = h.model.offset
    h.mouse(.wheelDown, at: h.point(of: "Beta"))
    XCTAssertGreaterThan(h.model.offset, top, "the wheel still scrolls")
    h.key(.escape)
    h.key(.escape)
    XCTAssertNil(h.model.marksList)

    h.run(h.model.setOffset(0))
    mark("Beta", with: "9", in: &h)
    XCTAssertEqual(h.model.noteField, "")
    XCTAssertEqual(h.click(h.point(of: "Alpha")), [])
    XCTAssertNil(h.model.edit)
    XCTAssertEqual(h.model.noteField, "")
  }

  func testRetypingOntoAnExistingMarkOfThatTypeMerges() {
    var h = reviewing("Alpha one.\n")
    mark("Alpha", with: "1", in: &h)
    mark("Alpha", with: "2", in: &h)
    XCTAssertEqual(h.model.review.marks.count, 2)
    h.key(.char("M"))
    h.key(.char("2"))
    XCTAssertEqual(h.model.review.marks.count, 1, "two marks never share a range and type")
    XCTAssertEqual(h.model.marksList?.rows.count, 1)
  }

  func testListFollowsAgentEdits() {
    var h = reviewing("Alpha one.\n\nBeta two.\n\nGamma three.\n")
    mark("Alpha", with: "1", in: &h)
    mark("Beta", with: "2", in: &h)
    mark("Gamma", with: "3", in: &h)
    h.key(.char("M"))
    h.key(.down)
    h.key(.down)
    XCTAssertEqual(h.model.marksList?.selected, 2)
    h.reload("Alpha one.\n\nBeta two.\n\n.\n")
    XCTAssertEqual(h.model.marksList?.rows.map(\.quote), ["Alpha", "Beta"])
    XCTAssertEqual(h.model.marksList?.selected, 1)
    XCTAssertTrue(h.effects.contains(.redrawAll))
    // A change above shifts the rows' lines and keeps the selected mark selected.
    h.reload("New first line.\n\nAlpha one.\n\nBeta two.\n\n.\n")
    XCTAssertEqual(h.model.marksList?.rows.map(\.line), [3, 5])
    XCTAssertEqual(h.model.marksList?.selected, 1)
    XCTAssertEqual(h.model.marksList?.rows[1].quote, "Beta")
    // Every marked passage gone: the list closes.
    h.reload("Nothing is left.\n")
    XCTAssertTrue(h.model.review.marks.isEmpty)
    XCTAssertNil(h.model.marksList)
  }

  func testTheListClosesWhenReviewEndsOrAPassIsSent() {
    var h = reviewing("Alpha one.\n")
    mark("Alpha", with: "1", in: &h)
    h.key(.char("M"))
    h.run(h.model.reviewSubmitted(pass: 1))
    XCTAssertNil(h.model.marksList, "no marks left to list")
    XCTAssertFalse(h.model.review.isOn)
    h.key(.char("m"))
    mark("Alpha", with: "1", in: &h)
    h.key(.char("M"))
    XCTAssertEqual(h.model.marksList?.pass, 2)
  }

  /// Review ending with the list open closes it, and the panel it leaves behind must be painted over.
  func testEndingReviewWithTheListOpenRedrawsEverything() {
    var h = reviewing("Alpha one.\n")
    mark("Alpha", with: "1", in: &h)
    h.key(.char("M"))
    XCTAssertNotNil(h.model.marksList)
    h.effects = []
    h.run(h.model.cancelReview(message: "Review is open in another viewer", at: h.now))
    XCTAssertNil(h.model.marksList)
    XCTAssertTrue(h.effects.contains(.redrawAll))
  }

  func testQuoteTruncatesOnGraphemes() {
    let family = "👩‍👩‍👧"
    let limit = MarksListRow.quoteLimit
    for padding in [limit - 3, limit - 2, limit - 1] {
      let text = String(repeating: "a", count: padding) + family + " family tail"
      let markdown = "lead " + text + "\n"
      var h = reviewing(markdown)
      mark(text, with: "1", in: &h)
      XCTAssertEqual(h.model.review.marks.count, 1)
      let before = h.model.review.marks.annotations(in: Array(markdown.utf8))
      h.key(.char("M"))
      let quote = try! XCTUnwrap(h.model.marksList?.rows.first?.quote)
      XCTAssertTrue(quote.hasSuffix("…"))
      XCTAssertEqual(quote.count, limit)
      let body = String(quote.dropLast())
      XCTAssertTrue(text.hasPrefix(body), "the quote is a whole-grapheme prefix of the text")
      let joiners = quote.unicodeScalars.filter { $0.value == 0x200D }.count
      XCTAssertTrue(joiners == 0 || joiners == 2, "the family emoji is whole or gone, never cut")
      XCTAssertEqual(before.count, 1)
      XCTAssertEqual(before[0].colFrom, "lead ".utf16.count)
      XCTAssertEqual(before[0].colTo, ("lead " + text).utf16.count)
      XCTAssertEqual(before[0].text, text, "the edits file still carries the whole text")
      XCTAssertEqual(
        h.model.review.marks.annotations(in: Array(markdown.utf8)), before, "opening the list changes nothing")
    }
  }

  func testQuoteCollapsesLineBreaksAndKeepsShortText() {
    var h = reviewing("One line\nand another.\n")
    select("One line", in: &h)
    h.key(.char("1"))
    h.run(h.model.setSelection(h.range(of: "One line\nand another.")))
    h.key(.char("2"))
    h.key(.char("M"))
    XCTAssertEqual(h.model.marksList?.rows.map(\.quote).first, "One line")
    XCTAssertFalse(h.model.marksList?.rows.contains { $0.quote.contains("\n") } ?? true)
  }

  func testUnknownTypesFallBackToGrayAndQuestionMark() {
    var h = reviewing("Alpha one.\n")
    mark("Alpha", with: "1", in: &h)
    h.model.reviewHotkeys = h.model.reviewHotkeys.filter { $0.type != "delete" }
    h.key(.char("M"))
    XCTAssertEqual(h.model.marksList?.rows.first?.key, "?")
    XCTAssertEqual(h.model.marksList?.rows.first?.color, "#9ca3af")
  }
}
