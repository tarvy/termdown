import Foundation
import TermDownCore
import TermDownRender
import XCTest

import TermDownRender
@testable import TermDownInteraction

final class ReviewKeysTests: XCTestCase {
  private func marked(_ h: Harness) -> [String] {
    let bytes = Array(h.model.source.utf8)
    return h.model.review.marks.marks.map { String(decoding: bytes[$0.range], as: UTF8.self) }
  }

  private func reviewing(_ markdown: String) -> Harness {
    var h = Harness(markdown)
    h.connectAgent()
    h.key(.char("m"))
    return h
  }

  private func select(_ needle: String, in h: inout Harness) {
    h.run(h.model.setSelection(h.range(of: needle)))
  }

  func testMTurnsReviewOnWithASnapshotAndOffClearingMarks() {
    var h = Harness("Some text here.\n")
    h.connectAgent()
    let on = h.key(.char("m"))
    XCTAssertTrue(h.model.review.isOn)
    XCTAssertEqual(h.model.review.snapshot, "Some text here.\n")
    XCTAssertTrue(on.contains(.reviewLaunched))
    XCTAssertNotNil(h.model.status.message)
    select("text", in: &h)
    h.key(.char("1"))
    XCTAssertEqual(h.model.review.marks.count, 1)
    h.key(.char("m"))
    XCTAssertTrue(h.model.review.isOn, "marks are kept until the discard is confirmed")
    let off = h.key(.char("y"))
    XCTAssertFalse(h.model.review.isOn)
    XCTAssertTrue(h.model.review.marks.isEmpty)
    XCTAssertFalse(off.contains(.reviewLaunched))
    XCTAssertTrue(off.contains { if case .redraw = $0 { true } else { false } }, "the cleared band is redrawn")
  }

  func testADigitMarksTheSelectedSourceAndRedrawsIt() {
    var h = reviewing("An intro — then **bold target** and more.\n")
    select("target", in: &h)
    let effects = h.key(.char("1"))
    XCTAssertEqual(marked(h), ["target"], "the mark is the exact source bytes, past the em dash and markup")
    XCTAssertEqual(h.model.review.marks.marks.first?.type, "delete")
    XCTAssertTrue(effects.contains { if case .redraw = $0 { true } else { false } })
    XCTAssertEqual(h.model.renderedReviewMarks, [RenderedReviewMark(rendered: h.range(of: "target")!, color: "#ef4444")])
  }

  func testDigitsDoNothingWithReviewModeOff() {
    var h = Harness("Some text here.\n")
    select("text", in: &h)
    for digit in "123456789" { XCTAssertEqual(h.key(.char(digit)), []) }
    XCTAssertTrue(h.model.review.marks.isEmpty)
    XCTAssertNil(h.model.noteField)
  }

  func testADigitsOnlySelectionDoesNotAnnotate() {
    var h = reviewing("Revenue grew 40% this year.\n")
    select("40%", in: &h)
    h.key(.char("2"))
    XCTAssertTrue(h.model.review.marks.isEmpty)
  }

  func testNineAsksForANoteAndEnterRecordsIt() {
    var h = reviewing("Some text here.\n")
    select("text", in: &h)
    h.key(.char("9"))
    XCTAssertEqual(h.model.noteField, "")
    XCTAssertNil(h.model.status.findField, "the note is typed in a floating dialog, not the status bar")
    XCTAssertEqual(
      h.model.noteDialog,
      NoteDialogContent(
        title: "Note", prompt: "Instruction for this passage:", excerpt: "text", text: "", color: "#9ca3af"))
    h.keys("say copy")
    h.send(.paste(" instead"))
    h.key(.backspace)
    XCTAssertEqual(h.model.noteDialog?.text, "say copy instea")
    h.key(.enter)
    XCTAssertNil(h.model.noteField)
    XCTAssertNil(h.model.noteDialog)
    XCTAssertEqual(marked(h), ["text"])
    XCTAssertEqual(h.model.review.marks.marks.first?.type, "note")
    XCTAssertEqual(h.model.review.marks.marks.first?.note, "say copy instea")
  }

  func testNineWithEscapeOrAnEmptyNoteRecordsNothing() {
    var h = reviewing("Some text here.\n")
    select("text", in: &h)
    h.key(.char("9"))
    h.keys("drop")
    h.key(.escape)
    XCTAssertNil(h.model.noteField)
    h.key(.char("9"))
    h.keys("  ")
    h.key(.enter)
    XCTAssertNil(h.model.noteField)
    XCTAssertTrue(h.model.review.marks.isEmpty)
  }

  func testURemovesTheLastMark() {
    var h = reviewing("One two three.\n")
    select("One", in: &h)
    h.key(.char("1"))
    select("three", in: &h)
    h.key(.char("3"))
    let effects = h.key(.char("U"))
    XCTAssertEqual(marked(h), ["One"])
    XCTAssertTrue(effects.contains { if case .redraw = $0 { true } else { false } })
  }

  func testXRemovesTheMarksOverlappingTheSelection() {
    var h = reviewing("One two three four.\n")
    select("One", in: &h)
    h.key(.char("1"))
    select("three", in: &h)
    h.key(.char("2"))
    select("four", in: &h)
    h.key(.char("3"))
    select("two three", in: &h)
    h.key(.char("x"))
    XCTAssertEqual(marked(h), ["One", "four"])
  }

  func testSSubmitsThePassAndFDoesNothing() {
    var h = reviewing("Some text here.\n")
    select("text", in: &h)
    h.key(.char("1"))
    XCTAssertEqual(h.key(.char("F")), [], "there is no separate finish")
    XCTAssertTrue(h.model.review.isOn)
    XCTAssertTrue(h.key(.char("s")).contains(.submitReview))
  }

  func testSubmitNeedsReviewMode() {
    var h = Harness("Some text here.\n")
    XCTAssertFalse(h.key(.char("s")).contains(.submitReview))
    XCTAssertEqual(h.model.status.message?.text, "Review is off: m starts it")
  }

  private func editSelecting(_ needle: String, in h: inout Harness) {
    h.key(.char("i"))
    let bytes = Array(h.model.source.utf8)
    let target = Array(needle.utf8)
    let lower = (0...(bytes.count - target.count)).first { Array(bytes[$0..<($0 + target.count)]) == target }!
    h.model.edit?.move(to: lower, extend: false)
    h.model.edit?.move(to: lower + target.count, extend: true)
  }

  func testEditModeDigitMarksAWordSelectionAndLeavesTheText() {
    var h = reviewing("Some text here.\n")
    editSelecting("text", in: &h)
    h.key(.char("4"))
    XCTAssertEqual(h.model.edit?.source, "Some text here.\n")
    XCTAssertEqual(marked(h), ["text"])
    XCTAssertEqual(h.model.review.marks.marks.first?.type, "shorten")
  }

  func testEditModeNoteFieldTakesTheKeysNotTheText() {
    var h = reviewing("Some text here.\n")
    editSelecting("text", in: &h)
    h.key(.char("9"))
    h.keys("cut")
    h.key(.enter)
    XCTAssertEqual(h.model.edit?.source, "Some text here.\n")
    XCTAssertEqual(h.model.review.marks.marks.first?.note, "cut")
  }

  func testEditModeDigitTypesOverAFigure() {
    var h = reviewing("Revenue grew 40% this year.\n")
    editSelecting("40%", in: &h)
    h.key(.char("5"))
    XCTAssertEqual(h.model.edit?.source, "Revenue grew 5 this year.\n")
    XCTAssertTrue(h.model.review.marks.isEmpty)
  }

  func testEditModeDigitTypesWithReviewModeOff() {
    var h = Harness("Some text here.\n")
    editSelecting("text", in: &h)
    h.key(.char("1"))
    XCTAssertEqual(h.model.edit?.source, "Some 1 here.\n")
    XCTAssertTrue(h.model.review.marks.isEmpty)
  }

  func testZeroStillResetsZoomInReviewMode() {
    var h = reviewing("Some text here.\n")
    h.key(.char("+"))
    select("text", in: &h)
    h.key(.char("0"))
    XCTAssertEqual(h.model.zoom, 1)
    XCTAssertTrue(h.model.review.marks.isEmpty)
  }

  func testMarkingClearsTheSelection() {
    var h = reviewing("Some text here.\n")
    select("text", in: &h)
    h.key(.char("3"))
    XCTAssertEqual(h.model.review.marks.count, 1)
    XCTAssertNil(h.model.selection)
    h.key(.char("3"))
    XCTAssertEqual(h.model.review.marks.count, 1, "no selection, no new mark")
    XCTAssertEqual(h.model.status.message?.text, "Select text to mark")
  }

  func testEscClearsSelectionInReview() {
    var h = reviewing("Some text here.\n")
    select("text", in: &h)
    h.key(.escape)
    XCTAssertNil(h.model.selection)
  }

  func testGoWithNothingIsRefused() {
    var h = reviewing("Some text here.\n")
    let effects = h.key(.char("s"))
    XCTAssertFalse(effects.contains(.submitReview))
    XCTAssertEqual(h.model.status.message?.text, "Nothing to send: mark text or edit the draft first")
  }

  func testSendWithMarksOrTypedEditsIsAllowed() {
    var marked = reviewing("Some text here.\n")
    select("text", in: &marked)
    marked.key(.char("1"))
    XCTAssertTrue(marked.key(.char("s")).contains(.submitReview))
    var edited = reviewing("Some text here.\n")
    edited.key(.char("i"))
    edited.key(.char("x"))
    edited.key(.escape)
    XCTAssertNotEqual(edited.model.source, edited.model.review.snapshot)
    XCTAssertTrue(edited.key(.char("s")).contains(.submitReview))
  }

  /// The pane pixel at the center of a legend key, found with a status bar built like the host's.
  private func legendCenter(_ key: String, in h: Harness) throws -> (x: Int, y: Int) {
    let geometry = h.model.geometry
    let height = StatusBar.height(cellPixelHeight: geometry.rowHeight, backingScale: 2)
    let bar = StatusBar(palette: .fallback(dark: true), backingScale: 2)
    let rect = CGRect(x: 0, y: geometry.contentHeight, width: geometry.width, height: height)
    let entry = try XCTUnwrap(bar.legendRects(h.model.status, in: rect).first { $0.key == key })
    return (Int(entry.rect.midX), Int(entry.rect.midY))
  }

  func testClickingALegendDigitMarksTheSelection() throws {
    var h = reviewing("An intro — then **bold target** and more.\n")
    select("target", in: &h)
    let point = try legendCenter("1", in: h)
    let pressed = h.paneMouse(.press, x: point.x, y: point.y)
    XCTAssertEqual(marked(h), ["target"])
    XCTAssertEqual(h.model.review.marks.marks.first?.type, "delete")
    XCTAssertTrue(pressed.contains { if case .redraw = $0 { true } else { false } })
    XCTAssertNil(h.model.selection, "the selection is spent once the mark is made")
    h.paneMouse(.release, x: point.x, y: point.y)
    XCTAssertEqual(h.model.review.marks.count, 1)
  }

  func testClickingALegendDigitMarksANumericSelectionToo() throws {
    var h = reviewing("Revenue grew 40% this year.\n")
    select("40%", in: &h)
    let point = try legendCenter("2", in: h)
    h.paneMouse(.press, x: point.x, y: point.y)
    XCTAssertEqual(marked(h), ["40%"], "a click has no digit to type, so the figure is marked")
  }

  func testClickingALegendDigitWithoutASelectionSaysSo() throws {
    var h = reviewing("Some text here.\n")
    let point = try legendCenter("1", in: h)
    h.paneMouse(.press, x: point.x, y: point.y)
    XCTAssertTrue(h.model.review.marks.isEmpty)
    XCTAssertEqual(h.model.status.message?.text, "Select text to mark")
  }

  func testClickingTheStatusBarOutsideTheLegendDoesNothing() {
    var h = reviewing("Some text here.\n")
    select("text", in: &h)
    h.paneMouse(.press, x: 1, y: Int(h.model.geometry.contentHeight) + 2)
    XCTAssertTrue(h.model.review.marks.isEmpty)
    XCTAssertNotNil(h.model.selection)
  }

  func testDAsksTheHostForTheChangesSinceTheLastPassWhileReviewing() {
    var h = reviewing("Some text here.\n")
    XCTAssertEqual(h.key(.char("D")), [.showChanges])
    XCTAssertTrue(h.model.review.isOn, "looking at the changes leaves review as it was")
  }

  func testDWorksWithReviewOff() {
    var h = Harness("Some text here.\n")
    XCTAssertEqual(h.key(.char("D")), [.showChanges], "the changes since a pass are worth seeing after review ends")
    XCTAssertFalse(h.model.review.isOn)
  }
}
