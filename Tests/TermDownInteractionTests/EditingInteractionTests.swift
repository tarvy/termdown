import CoreGraphics
import Foundation
import TermDownCore
import TermDownLayout
import XCTest

@testable import TermDownInteraction

final class EditingInteractionTests: XCTestCase {
  private func saves(_ effects: [InteractionEffect]) -> [String] {
    effects.compactMap { if case .save(let request) = $0 { request.text } else { nil } }
  }

  func testIEntersEditingAndDrawsACaretInTheText() throws {
    var h = Harness("# Title\n\nSome **bold** words here.\n")
    h.key(.char("i"))
    XCTAssertTrue(h.model.isEditing)
    let caret = try XCTUnwrap(h.model.overlay.caret)
    XCTAssertGreaterThan(caret.height, 10)
    XCTAssertEqual(h.model.status.editor, "editing")
    // Escape leaves editing and removes the caret; nothing was changed, so nothing is saved.
    let effects = h.key(.escape)
    XCTAssertFalse(h.model.isEditing)
    XCTAssertNil(h.model.overlay.caret)
    XCTAssertEqual(saves(effects), [])
  }

  func testTypingEditsTheSourceRevealsMarkupAndSavesOnEscape() throws {
    var h = Harness("Some **bold** words.\n")
    h.key(.char("i"))
    XCTAssertEqual(h.model.edit?.caret, 0)
    for _ in 0..<5 { h.key(.right) }  // "Some " then into the revealed **
    XCTAssertEqual(h.model.edit?.caret, 5)
    XCTAssertTrue((h.layout.prepared.text as String).contains("**bold**"), "syntax shows at the caret")
    h.keys("very ")
    XCTAssertEqual(h.model.edit?.source, "Some very **bold** words.\n")
    XCTAssertEqual(h.model.status.editor, "editing, unsaved")
    XCTAssertTrue((h.layout.prepared.text as String).contains("very **bold**"), "the caret touches the ** so it shows")
    h.key(.left)
    XCTAssertFalse((h.layout.prepared.text as String).contains("**"), "one step left of the bold, ** hides again")
    h.key(.right)
    h.key(.command("z"))
    XCTAssertEqual(h.model.edit?.source, "Some very**bold** words.\n")
    let effects = h.key(.escape)
    XCTAssertEqual(saves(effects), ["Some very**bold** words.\n"])
    XCTAssertEqual(h.model.source, "Some very**bold** words.\n")
  }

  func testClickPlacesTheCaretAtTheSourceOffset() throws {
    var h = Harness("First paragraph.\n\nSecond paragraph with words.\n")
    h.key(.char("i"))
    let range = try XCTUnwrap(h.layout.range(of: "words"))
    let rect = try XCTUnwrap(h.layout.rects(for: range).first?.rect)
    h.mouse(.press, at: CGPoint(x: rect.minX + 1, y: rect.midY))
    h.mouse(.release, at: CGPoint(x: rect.minX + 1, y: rect.midY))
    let source = Array("First paragraph.\n\nSecond paragraph with words.\n".utf8)
    XCTAssertEqual(h.model.edit?.caret, source.firstRange(of: Array("words".utf8))?.lowerBound)
    XCTAssertNotNil(h.model.overlay.caret)
  }

  func testAClickOnTextStartsEditingThereWithoutPressingI() throws {
    var h = Harness("First paragraph.\n\nSecond paragraph with words.\n")
    let range = try XCTUnwrap(h.layout.range(of: "words"))
    let rect = try XCTUnwrap(h.layout.rects(for: range).first?.rect)
    h.mouse(.press, at: CGPoint(x: rect.minX + 1, y: rect.midY))
    h.mouse(.release, at: CGPoint(x: rect.minX + 1, y: rect.midY))
    XCTAssertTrue(h.model.isEditing)
    let source = Array("First paragraph.\n\nSecond paragraph with words.\n".utf8)
    XCTAssertEqual(h.model.edit?.caret, source.firstRange(of: Array("words".utf8))?.lowerBound)
    let caret = try XCTUnwrap(h.model.overlay.caret)
    XCTAssertEqual(caret.width, max(h.layout.prepared.typography.backingScale.rounded(), 1), "a native 1pt caret")
  }

  func testCommandBackspaceDeletesToTheLineStartAndOptionBackspaceAWord() {
    var h = Harness("one two three four\n")
    h.key(.char("i"))
    for _ in 0..<13 { h.key(.right) }  // after "one two three"
    h.key(.modified(.backspace, .alt))
    XCTAssertEqual(h.model.edit?.source, "one two  four\n")
    h.key(.modified(.backspace, .control))
    XCTAssertEqual(h.model.edit?.source, "one  four\n")
    h.key(.modified(.backspace, .command))
    XCTAssertEqual(h.model.edit?.source, " four\n", "Cmd-Backspace removes to the start of the line")
    h.key(.modified(.delete, .command))
    XCTAssertEqual(h.model.edit?.source, " \n", "Cmd-Delete removes to the end of the line")
    h.key(.command("z"))
    XCTAssertEqual(h.model.edit?.source, " four\n")
  }

  func testCommandZoomKeysWorkWhileEditingAndDoNotTypeCharacters() {
    var h = Harness("Some text to zoom.\n")
    h.key(.char("i"))
    h.key(.command("-"))
    XCTAssertEqual(h.model.zoom, 0.9)
    XCTAssertEqual(h.model.edit?.source, "Some text to zoom.\n", "zoom keys do not insert text")
    XCTAssertTrue(h.model.isEditing)
    h.key(.command("="))
    h.key(.command("="))
    XCTAssertEqual(h.model.zoom, 1.1)
    h.key(.command("0"))
    XCTAssertEqual(h.model.zoom, 1)
    XCTAssertNotNil(h.model.overlay.caret, "the caret is placed again after each zoom layout")
  }

  func testDraggingWhileEditingMovesTheCaretWithThePointerAndStopsTheBlink() throws {
    var h = Harness("First paragraph.\n\nSecond paragraph with words.\n")
    h.key(.char("i"))
    let start = h.point(of: "Second", at: 0)
    let end = h.point(of: "words", at: 1)
    h.mouse(.press, at: start)
    h.mouse(.motion, at: end)
    let wordsRange = try XCTUnwrap(h.layout.range(of: "words"))
    let expected = try XCTUnwrap(h.layout.caretRect(atRendered: wordsRange.upperBound, width: h.model.caretWidth))
    XCTAssertEqual(h.model.overlay.caret, expected, "the caret rides the drag's head before the button is up")
    XCTAssertNil(h.model.blinkDeadline, "no blinking during a drag")
    h.mouse(.release, at: end)
    let source = Array("First paragraph.\n\nSecond paragraph with words.\n".utf8)
    XCTAssertEqual(h.model.edit?.caret, source.firstRange(of: Array("words".utf8))?.upperBound)
    XCTAssertEqual(h.model.edit?.selectedSource, "Second paragraph with words")
    XCTAssertNotNil(h.model.blinkDeadline, "the blink resumes on release")
  }

  func testOptionClickWhileEditingExtendsFromTheCaret() throws {
    var h = Harness("one two three four\n")
    h.key(.char("i"))
    for _ in 0..<3 { h.key(.right) }  // after "one"
    let target = h.point(of: "three", at: 1)
    h.mouse(.press, at: target, modifiers: [.alt])
    h.mouse(.release, at: target, modifiers: [.alt])
    XCTAssertEqual(h.model.edit?.selectedSource, " two three")
    XCTAssertEqual(h.model.edit?.caret, 13, "the caret is at the click and the anchor stayed at the old caret")
    let before = h.point(of: "one", at: 0)
    h.mouse(.press, at: before, modifiers: [.alt])
    h.mouse(.release, at: before, modifiers: [.alt])
    XCTAssertEqual(h.model.edit?.selectedSource, "one", "option-clicking before the anchor selects back from it")
    h.key(.right)
    XCTAssertNil(h.model.edit?.selection, "a plain move collapses it")
  }

  func testShiftClickExtendsTooWhenATerminalDeliversIt() throws {
    var h = Harness("one two three four\n")
    h.key(.char("i"))
    for _ in 0..<3 { h.key(.right) }
    let target = h.point(of: "three", at: 1)
    h.mouse(.press, at: target, modifiers: [.shift])
    h.mouse(.release, at: target, modifiers: [.shift])
    XCTAssertEqual(h.model.edit?.selectedSource, " two three")
  }

  func testPCopiesTheFilePathRelativeToTheWorkspace() {
    XCTAssertEqual(
      ViewerInteraction.relativePath(of: URL(fileURLWithPath: "/Users/me/vault/notes/a.md"), in: ["/Users/me/vault", "/Users/me/vault/notes"]),
      "notes/a.md", "the outermost root wins")
    XCTAssertEqual(
      ViewerInteraction.relativePath(of: URL(fileURLWithPath: "/tmp/x.md"), in: ["/Users/me/vault"]), "/tmp/x.md",
      "a file outside every root copies as an absolute path")
    var h = Harness("Some text.\n")
    h.model.workspaceFolders = ["/docs"]
    let effects = h.key(.char("p"))
    XCTAssertTrue(effects.contains { if case .writeClipboard(let text, _) = $0 { text == "guide.md" } else { false } }, "\(effects)")
  }

  func testShiftArrowsSelectAndCopyGivesMarkdownSource() throws {
    var h = Harness("Plain *it* end.\n")
    h.key(.char("i"))
    for _ in 0..<6 { h.key(.modified(.right, .shift)) }
    XCTAssertEqual(h.model.edit?.selectedSource, "Plain ")
    XCTAssertNotNil(h.model.overlay.selection)
    h.key(.modified(.right, .shift))
    h.key(.modified(.right, .shift))
    h.key(.modified(.right, .shift))
    h.key(.modified(.right, .shift))
    XCTAssertEqual(h.model.edit?.selectedSource, "Plain *it*")
    h.key(.command("c"))
    XCTAssertEqual(h.clipboard.last, "Plain *it*")
  }

  func testUpAndDownMoveBetweenLinesKeepingTheColumn() throws {
    var h = Harness("Alpha line one.\n\nBravo line two.\n\nCharlie three.\n")
    h.key(.char("i"))
    for _ in 0..<3 { h.key(.right) }
    h.key(.down)
    let source = "Alpha line one.\n\nBravo line two.\n\nCharlie three.\n"
    XCTAssertEqual(h.model.edit?.caret, 17 + 3, "same column in the next paragraph")
    h.key(.down)
    XCTAssertEqual(Double(h.model.edit?.caret ?? 0), Double(34 + 3), accuracy: 1, "proportional glyphs: within one")
    h.key(.up)
    XCTAssertEqual(h.model.edit?.caret, 17 + 3)
    _ = source
  }

  /// An empty item ("- " or "- [ ] ") has no text of its own, but the caret reaches it by arrow and by click.
  func testUpDownAndClickReachEmptyListItems() throws {
    let source = "## Notes\n\n- \n\n## Decisions\n\n- \n\n## Action items\n\n- [ ] \n"
    let bytes = Array(source.utf8)
    func itemStop(after heading: String) -> Int {
      let at = bytes.firstRange(of: Array(heading.utf8))!.upperBound
      return bytes[at...].firstRange(of: Array("- ".utf8))!.lowerBound + (heading == "Action items" ? 6 : 2)
    }
    var h = Harness(source)
    h.key(.char("i"))
    XCTAssertEqual(h.model.edit?.caret, 3, "starts in the first heading")
    h.key(.down)
    XCTAssertEqual(h.model.edit?.caret, itemStop(after: "Notes"), "down from a heading lands in the empty item below")
    let decisions = bytes.firstRange(of: Array("Decisions".utf8))!
    h.key(.down)
    XCTAssertTrue(decisions.contains(h.model.edit?.caret ?? -1), "then the next heading")
    h.key(.down)
    XCTAssertEqual(h.model.edit?.caret, itemStop(after: "Decisions"))
    h.key(.up)
    XCTAssertTrue(decisions.contains(h.model.edit?.caret ?? -1), "up leaves it again")
    h.key(.up)
    XCTAssertEqual(h.model.edit?.caret, itemStop(after: "Notes"), "and up from a heading lands in the item above")
    // A click to the right of an empty task item's checkbox puts the caret in that item.
    let heading = try XCTUnwrap(h.layout.rects(for: try XCTUnwrap(h.layout.range(of: "Action items"))).first?.rect)
    let line = try XCTUnwrap(
      h.layout.fragments.filter { $0.lineTop >= heading.maxY - 0.5 }.min { $0.lineTop < $1.lineTop }, "the item has a line")
    let point = CGPoint(x: heading.minX + 60, y: (line.lineTop + line.lineBottom) / 2)
    h.mouse(.press, at: point)
    h.mouse(.release, at: point)
    XCTAssertEqual(h.model.edit?.caret, itemStop(after: "Action items"))
    h.keys("Ship it")
    XCTAssertEqual(h.model.edit?.source, source.replacingOccurrences(of: "- [ ] \n", with: "- [ ] Ship it\n"))
  }

  func testEnterMakesAVisibleEmptyLineAndTypingFillsIt() throws {
    var h = Harness("Para.\n")
    h.key(.char("i"))
    h.key(.end)
    XCTAssertEqual(h.model.edit?.caret, 5)
    h.key(.enter)
    XCTAssertEqual(h.model.edit?.source, "Para.\n\n\n")
    let empty = try XCTUnwrap(h.model.overlay.caret)
    let first = try XCTUnwrap(h.layout.rects(for: try XCTUnwrap(h.layout.range(of: "Para."))).first?.rect)
    XCTAssertGreaterThan(empty.minY, first.maxY, "the caret sits on its own line below the paragraph")
    h.keys("Next")
    XCTAssertEqual(h.model.edit?.source, "Para.\n\nNext\n")
  }

  func testAutosaveFiresASecondAfterTheLastEdit() {
    var h = Harness("Text.\n")
    h.key(.char("i"))
    h.keys("A")
    XCTAssertEqual(saves(h.effects), [])
    h.now += 2 * second
    let effects = h.model.tick(at: h.now)
    XCTAssertEqual(saves(effects), ["AText.\n"])
    h.run(effects)
    XCTAssertEqual(h.model.status.editor, "editing")
  }

  func testOutsideChangeReloadsACleanSessionAndKeepsADirtyOne() {
    var h = Harness("One.\n")
    h.key(.char("i"))
    h.system.files["/docs/guide.md"] = "Two.\n"
    h.run(h.model.fileChanged(source: "Two.\n"))
    XCTAssertEqual(h.model.edit?.source, "Two.\n")
    h.keys("x")
    h.system.files["/docs/guide.md"] = "Three.\n"
    h.run(h.model.fileChanged(source: "Three.\n"))
    XCTAssertEqual(h.model.edit?.source, "xTwo.\n", "unsaved edits are kept where the same line changed")
    XCTAssertFalse(h.model.editConflict, "and saving is not frozen")
  }

  func testViewModeKeysStillWorkWithModifiedArrows() {
    var h = Harness(String(repeating: "Line of text.\n\n", count: 200))
    let before = h.model.offset
    h.key(.modified(.down, .shift))
    XCTAssertGreaterThan(h.model.offset, before)
  }
}

extension PageLayout {
  fileprivate func range(of needle: String) -> Range<Int>? {
    let found = prepared.text.range(of: needle)
    return found.location == NSNotFound ? nil : found.location..<(found.location + found.length)
  }
}

final class EditingSafetyTests: XCTestCase {
  func testOpeningAnotherFileSavesTheEditToItsOwnFile() {
    var h = Harness("A text.\n", path: "/docs/a.md", files: ["/docs/b.md": "B text.\n"])
    h.key(.char("i"))
    h.keys("x")
    h.run(h.model.open(file: URL(fileURLWithPath: "/docs/b.md"), source: "B text.\n", at: h.now))
    XCTAssertEqual(h.system.files["/docs/a.md"], "xA text.\n")
    XCTAssertEqual(h.system.files["/docs/b.md"], "B text.\n", "b.md is untouched")
    XCTAssertFalse(h.model.isEditing)
    h.now += 3 * second
    h.run(h.model.tick(at: h.now))
    XCTAssertEqual(h.system.files["/docs/b.md"], "B text.\n", "no autosave lands in the new file")
  }

  func testAnOutsideChangeOnOtherLinesIsMergedAndAutosaved() {
    var h = Harness("One.\nTwo.\nThree.\n")
    h.key(.char("i"))
    h.keys("x")
    h.system.files["/docs/guide.md"] = "One.\nTwo.\nTHREE.\n"
    h.run(h.model.fileChanged(source: "One.\nTwo.\nTHREE.\n"))
    XCTAssertEqual(h.model.edit?.source, "xOne.\nTwo.\nTHREE.\n", "the agent's line and the person's edit both survive")
    XCTAssertFalse(h.model.editConflict)
    XCTAssertEqual(h.model.edit?.caret, 1, "the caret stays after the typed x")
    h.now += second
    h.run(h.model.tick(at: h.now))
    XCTAssertEqual(h.system.files["/docs/guide.md"], "xOne.\nTwo.\nTHREE.\n", "autosave keeps going")
    XCTAssertFalse(h.model.edit!.isDirty)
    h.key(.escape)
    XCTAssertFalse(h.model.isEditing, "nothing is stuck")
  }

  func testWhenBothChangeTheSameLineThePersonsTextWinsAndSavesStillHappen() {
    var h = Harness("Mine.\nSame.\n")
    h.key(.char("i"))
    h.keys("x")
    h.system.files["/docs/guide.md"] = "Theirs.\nSame.\n"
    h.run(h.model.fileChanged(source: "Theirs.\nSame.\n"))
    XCTAssertEqual(h.model.edit?.source, "xMine.\nSame.\n")
    XCTAssertFalse(h.model.editConflict)
    XCTAssertTrue(h.model.status.message?.text.contains("Kept your text") == true, "\(String(describing: h.model.status.message))")
    h.now += second
    h.run(h.model.tick(at: h.now))
    XCTAssertEqual(h.system.files["/docs/guide.md"], "xMine.\nSame.\n")
  }

  func testAMergeIsOneUndoStep() {
    var h = Harness("A.\nB.\n")
    h.key(.char("i"))
    h.keys("x")
    h.run(h.model.fileChanged(source: "A.\nBB.\n"))
    XCTAssertEqual(h.model.edit?.source, "xA.\nBB.\n")
    h.key(.command("z"))
    XCTAssertEqual(h.model.edit?.source, "xA.\nB.\n", "undo steps back over the merge")
  }

  func testCmdRTakesTheFilesVersion() {
    var h = Harness("Mine.\n")
    h.key(.char("i"))
    h.keys("x")
    h.run(h.model.takeDiskVersion("Theirs.\n"))
    XCTAssertEqual(h.model.edit?.source, "Theirs.\n")
    XCTAssertFalse(h.model.edit!.isDirty)
  }

  func testTheEchoOfOurSaveIsIgnoredButALaterRevertIsNot() {
    var h = Harness("X.\n")
    h.key(.char("i"))
    h.keys("a")
    h.key(.command("s"))
    XCTAssertEqual(h.system.files["/docs/guide.md"], "aX.\n")
    h.run(h.model.fileChanged(source: "aX.\n"))
    XCTAssertFalse(h.model.editConflict, "our own save coming back")
    h.run(h.model.fileChanged(source: "Y.\n"))
    XCTAssertEqual(h.model.edit?.source, "Y.\n")
    h.run(h.model.fileChanged(source: "aX.\n"))
    XCTAssertEqual(h.model.edit?.source, "aX.\n", "a revert to the earlier text is still a change")
  }

  func testARefusedSaveKeepsEditing() {
    var h = Harness("Mine.\n")
    h.key(.char("i"))
    h.keys("x")
    h.system.files["/docs/guide.md"] = "Changed behind our back.\n"
    h.key(.escape)
    XCTAssertTrue(h.model.isEditing)
    XCTAssertEqual(h.model.edit?.source, "xMine.\n")
  }

  func testRefusedFilesCannotEnterEditing() {
    var h = Harness("Text.\n")
    h.model.setEditRefusal("guide.md is not UTF-8; editing in place is off")
    h.key(.char("i"))
    XCTAssertFalse(h.model.isEditing)
  }

  func testBackspaceDoesNotDeleteReferenceDefinitions() {
    let source = "Para one\n\n[ref]: https://x\n\nPara two\n"
    var session = EditSession(source: source, caret: Array(source.utf8).firstRange(of: Array("Para two".utf8))!.lowerBound)
    session.deleteBackward()
    XCTAssertTrue(session.source.contains("[ref]: https://x"))
  }

  func testBackspaceAfterAFenceDoesNotJoinOntoIt() {
    let source = "```\ncode\n```\n\nPara\n"
    var session = EditSession(source: source, caret: Array(source.utf8).firstRange(of: Array("Para".utf8))!.lowerBound)
    session.deleteBackward()
    XCTAssertEqual(session.source, source)
  }

  func testEnterInCodeInsertsOneLineWithItsIndentation() {
    let source = "- a\n\n  ```\n  codemore\n  ```\n"
    var session = EditSession(source: source, caret: Array(source.utf8).firstRange(of: Array("more".utf8))!.lowerBound)
    session.newParagraph()
    XCTAssertEqual(session.source, "- a\n\n  ```\n  code\n  more\n  ```\n")
  }

  func testEnterOnAListContinuationLineKeepsItsIndentation() {
    let source = "- a\n  bc\n"
    var session = EditSession(source: source, caret: 7)
    XCTAssertEqual(session.caret, 7)
    session.newParagraph()
    XCTAssertEqual(session.source, "- a\n  b\n\n  c\n")
  }

  func testMarkerLikeTextOnAContinuationLineIsNotAList() {
    let source = "the year\n2024. was good\n"
    var session = EditSession(source: source, caret: 18)
    session.newParagraph()
    XCTAssertFalse(session.source.contains("2025."))
  }

  func testReloadKeepsTheCaretInItsText() {
    var session = EditSession(source: "Top.\n\nWhere I type.\n", caret: 12)
    session.reload("New line above.\n\nTop.\n\nWhere I type.\n")
    XCTAssertEqual(session.caret, 12 + 17, "the caret moves with the text after the inserted lines")
  }
}

final class CaretBlinkTests: XCTestCase {
  func testTheCaretBlinksAndTypingMakesItSolid() throws {
    var h = Harness("Some text.\n")
    h.key(.char("i"))
    let rect = try XCTUnwrap(h.model.overlay.caret)
    h.now += 600_000_000
    h.run(h.model.tick(at: h.now))
    XCTAssertNil(h.model.overlay.caret, "hidden half of the blink")
    h.now += 600_000_000
    h.run(h.model.tick(at: h.now))
    XCTAssertEqual(h.model.overlay.caret, rect, "shown again")
    h.now += 600_000_000
    h.run(h.model.tick(at: h.now))
    XCTAssertNil(h.model.overlay.caret)
    h.keys("x")
    XCTAssertNotNil(h.model.overlay.caret, "typing shows the caret at once")
    h.key(.escape)
    let deadline = h.model.nextDeadline
    XCTAssertTrue(deadline == nil || deadline! > h.now + 2_000_000_000 || h.model.isEditing == false)
  }

}

final class ReviewFormattingTests: XCTestCase {

  private func reviewEditing(
    _ markdown: String, select needle: String? = nil, caretIn: String? = nil, at inner: Int = 0
  ) -> Harness {
    var h = Harness(markdown)
    h.connectAgent()
    h.key(.char("m"))
    h.key(.char("i"))
    let bytes = Array(markdown.utf8)
    if let needle, let start = bytes.firstRange(of: Array(needle.utf8))?.lowerBound {
      h.model.edit?.move(to: start, extend: false)
      h.model.edit?.move(to: start + needle.utf8.count, extend: true)
    } else if let caretIn, let start = bytes.firstRange(of: Array(caretIn.utf8))?.lowerBound {
      h.model.edit?.move(to: start + inner, extend: false)
    }
    return h
  }

  func testCommandBWrapsTheSelectionInBoldAndAgainUnwrapsIt() {
    var h = reviewEditing("Say word here.\n", select: "word")
    h.key(.command("b"))
    XCTAssertEqual(h.model.edit?.source, "Say **word** here.\n")
    XCTAssertEqual(h.model.edit?.selectedSource, "word", "the word stays selected")
    h.key(.command("b"))
    XCTAssertEqual(h.model.edit?.source, "Say word here.\n")
    XCTAssertEqual(h.model.edit?.selectedSource, "word")
  }

  func testCommandBWithACaretInAWordWrapsThatWord() {
    var h = reviewEditing("Say word here.\n", caretIn: "word", at: 2)
    h.key(.command("b"))
    XCTAssertEqual(h.model.edit?.source, "Say **word** here.\n")
    XCTAssertNil(h.model.edit?.selection)
    h.keys("!")
    XCTAssertEqual(h.model.edit?.source, "Say **wo!rd** here.\n", "the caret kept its place in the word")
  }

  func testCommandBWithACaretInsideBoldUnwraps() {
    var h = reviewEditing("Say **bold** here.\n", caretIn: "bold", at: 2)
    h.key(.command("b"))
    XCTAssertEqual(h.model.edit?.source, "Say bold here.\n")
  }

  func testCommandBUnwrapsASelectionThatIncludesTheMarkers() {
    var h = reviewEditing("Say **bold** here.\n", select: "**bold**")
    h.key(.command("b"))
    XCTAssertEqual(h.model.edit?.source, "Say bold here.\n")
  }

  func testCommandIWrapsInItalicAndComposesWithBold() {
    var h = reviewEditing("Say word here.\n", select: "word")
    h.key(.command("i"))
    XCTAssertEqual(h.model.edit?.source, "Say *word* here.\n")
    h.key(.command("b"))
    XCTAssertEqual(h.model.edit?.source, "Say ***word*** here.\n")
    h.key(.command("i"))
    XCTAssertEqual(h.model.edit?.source, "Say **word** here.\n", "italic comes off bold text without touching the bold")
    h.key(.command("b"))
    XCTAssertEqual(h.model.edit?.source, "Say word here.\n")
  }

  func testEachFormattingChangeIsOneUndoStep() {
    var h = reviewEditing("Say word here.\n", select: "word")
    h.key(.command("b"))
    h.key(.command("i"))
    h.key(.command("z"))
    XCTAssertEqual(h.model.edit?.source, "Say **word** here.\n")
    h.key(.command("z"))
    XCTAssertEqual(h.model.edit?.source, "Say word here.\n")
  }

  func testFormattingKeysDoNothingWhileReviewIsOff() {
    var h = Harness("Say word here.\n")
    h.key(.char("i"))
    h.model.edit?.move(to: 4, extend: false)
    h.model.edit?.move(to: 8, extend: true)
    h.key(.command("b"))
    h.key(.command("k"))
    XCTAssertEqual(h.model.edit?.source, "Say word here.\n")
    XCTAssertNil(h.model.noteField)
  }

  func testFormattingIsRefusedInACodeBlock() {
    var h = reviewEditing("```\nlet word = 1\n```\n", select: "word")
    h.key(.command("b"))
    XCTAssertEqual(h.model.edit?.source, "```\nlet word = 1\n```\n")
  }

  func testCommandKPromptsForAURLAndLinksTheSelection() {
    var h = reviewEditing("Visit the site today.\n", select: "site")
    h.key(.command("k"))
    XCTAssertEqual(h.model.status.message?.text, "Link URL:")
    h.keys("example.com")
    XCTAssertEqual(h.model.status.findField, "example.com")
    XCTAssertEqual(h.model.edit?.source, "Visit the site today.\n", "nothing changes until Enter")
    h.key(.enter)
    XCTAssertEqual(h.model.edit?.source, "Visit the [site](https://example.com) today.\n")
    XCTAssertNil(h.model.noteField)
    h.key(.command("z"))
    XCTAssertEqual(h.model.edit?.source, "Visit the site today.\n", "one undo step")
  }

  func testCommandKKeepsAnExistingSchemeAndLinksTheWordAtTheCaret() {
    var h = reviewEditing("Visit the site today.\n", caretIn: "site", at: 1)
    h.key(.command("k"))
    h.keys("http://localhost:3000/a")
    h.key(.enter)
    XCTAssertEqual(h.model.edit?.source, "Visit the [site](http://localhost:3000/a) today.\n")
  }

  func testEscapeCancelsTheLinkPromptAndLeavesTheTextAlone() {
    var h = reviewEditing("Visit the site today.\n", select: "site")
    h.key(.command("k"))
    h.keys("example.com")
    h.key(.escape)
    XCTAssertEqual(h.model.edit?.source, "Visit the site today.\n")
    XCTAssertNil(h.model.noteField)
    XCTAssertTrue(h.model.isEditing, "Esc closed the prompt, not the edit session")
  }

  func testAnEmptyURLAddsNoLink() {
    var h = reviewEditing("Visit the site today.\n", select: "site")
    h.key(.command("k"))
    h.key(.enter)
    XCTAssertEqual(h.model.edit?.source, "Visit the site today.\n")
  }
}
