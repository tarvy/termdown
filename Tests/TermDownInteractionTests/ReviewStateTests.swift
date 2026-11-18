import Foundation
import XCTest

@testable import TermDownInteraction

final class ReviewStateTests: XCTestCase {
  private func marked(_ h: Harness) -> [String] {
    let bytes = Array(h.model.source.utf8)
    return h.model.review.marks.marks.map { String(decoding: bytes[$0.range], as: UTF8.self) }
  }

  private func mark(_ needle: String, in h: inout Harness) {
    let bytes = Array(h.model.source.utf8)
    let target = Array(needle.utf8)
    let start = (0...(bytes.count - target.count)).first { Array(bytes[$0..<($0 + target.count)]) == target }!
    h.model.review.isOn = true
    h.model.review.marks.add(start..<(start + target.count), type: "cringe", label: "Cringe")
  }

  func testReviewStateIsOffByDefault() {
    let h = Harness("Some text.\n")
    XCTAssertFalse(h.model.review.isOn)
    XCTAssertTrue(h.model.review.marks.isEmpty)
    XCTAssertNil(h.model.review.snapshot)
    XCTAssertEqual(h.model.review.pass, 0)
  }

  func testAMarkSurvivesTypingBeforeItUndoAndADiskMergeUnderIt() {
    var h = Harness("Intro line.\nThe target phrase here.\n")
    mark("target phrase", in: &h)
    h.key(.char("i"))
    h.keys("x")
    XCTAssertEqual(h.model.source, "xIntro line.\nThe target phrase here.\n")
    XCTAssertEqual(marked(h), ["target phrase"], "typing before the mark shifts it")
    h.key(.command("z"))
    XCTAssertEqual(h.model.source, "Intro line.\nThe target phrase here.\n")
    XCTAssertEqual(marked(h), ["target phrase"], "undo shifts it back")
    h.keys("y")
    h.system.files["/docs/guide.md"] = "Intro line.\nNow the target phrase here.\n"
    h.run(h.model.fileChanged(source: "Intro line.\nNow the target phrase here.\n"))
    XCTAssertEqual(h.model.source, "yIntro line.\nNow the target phrase here.\n", "the merge keeps both changes")
    XCTAssertEqual(marked(h), ["target phrase"], "the mark follows the merged line")
  }

  func testAMarkFollowsAnOutsideChangeInViewMode() {
    var h = Harness("First.\nKeep this phrase.\n")
    mark("this phrase", in: &h)
    h.reload("First, longer now.\nKeep this phrase.\n")
    XCTAssertEqual(marked(h), ["this phrase"])
  }

  func testAnOutsideChangeJoinsTheSnapshotSoOnlyHandEditsDiff() {
    var h = Harness("Intro line.\nThe target phrase here.\n")
    h.connectAgent()
    h.key(.char("m"))
    h.reload("Intro line.\nThe phrase here.\n")
    XCTAssertEqual(h.model.review.snapshot, "Intro line.\nThe phrase here.\n", "the agent's change is not a hand edit")
    h.key(.char("i"))
    h.keys("x")
    h.system.files["/docs/guide.md"] = "Intro line.\nThe phrase.\n"
    h.run(h.model.fileChanged(source: "Intro line.\nThe phrase.\n"))
    XCTAssertEqual(h.model.source, "xIntro line.\nThe phrase.\n")
    XCTAssertEqual(h.model.review.snapshot, "Intro line.\nThe phrase.\n", "unsaved typing stays out of the snapshot")
  }

  func testOpeningAnotherFileEndsTheReview() {
    var h = Harness("A text.\n", files: ["/docs/b.md": "B text.\n"])
    mark("text", in: &h)
    h.run(h.model.open(file: URL(fileURLWithPath: "/docs/b.md"), source: "B text.\n"))
    XCTAssertFalse(h.model.review.isOn)
    XCTAssertTrue(h.model.review.marks.isEmpty)
  }

  // MARK: Typed edits

  private func typed(_ h: Harness) -> [String] {
    let bytes = Array((h.model.edit?.source ?? h.model.source).utf8)
    return h.model.typedRanges.map { String(decoding: bytes[$0], as: UTF8.self) }
  }

  private func reviewing(_ markdown: String) -> Harness {
    var h = Harness(markdown)
    h.connectAgent()
    h.key(.char("m"))
    return h
  }

  private func offset(of needle: String, in text: String) -> Int {
    Array(text.utf8).firstRange(of: Array(needle.utf8))!.lowerBound
  }

  func testTypedRangesCoverExactlyTheTypedBytes() {
    let text = "First paragraph here.\n\nSecond paragraph with words.\n"
    var h = reviewing(text)
    XCTAssertEqual(h.model.typedRanges, [])
    h.key(.char("i"))
    h.model.edit?.move(to: offset(of: "paragraph with", in: text), extend: false)
    h.keys("new ")
    XCTAssertEqual(typed(h), ["new "])
    XCTAssertEqual(h.model.typedRanges.first.map { $0.count }, 4)
  }

  func testTypingInTwoPlacesOfOneParagraphGivesTwoRanges() {
    let text = "One two three four five.\n"
    var h = reviewing(text)
    h.key(.char("i"))
    h.model.edit?.move(to: offset(of: "three", in: text), extend: false)
    h.keys("big ")
    let current = h.model.edit!.source
    h.model.edit?.move(to: offset(of: "five", in: current), extend: false)
    h.keys("last ")
    // " last" and "last " are the same insertion; either is a correct reading of it.
    let ranges = typed(h)
    XCTAssertEqual(ranges.count, 2)
    XCTAssertEqual(ranges.first, "big ")
    XCTAssertEqual(ranges.last?.trimmingCharacters(in: .whitespaces), "last")
  }

  func testTypedRangesTouchingEachOtherAreOne() {
    let text = "Alpha beta.\n"
    var h = reviewing(text)
    h.key(.char("i"))
    h.model.edit?.move(to: offset(of: "beta", in: text), extend: false)
    h.keys("x")
    h.keys("y")
    XCTAssertEqual(typed(h), ["xy"])
  }

  func testAnAgentChangeElsewhereLeavesTheTypedRangeOnTheTypedText() {
    let text = "First paragraph here.\n\nSecond paragraph with words.\n"
    var h = reviewing(text)
    h.key(.char("i"))
    h.model.edit?.move(to: offset(of: "paragraph with", in: text), extend: false)
    h.keys("new ")
    let disk = "First paragraph, rewritten by the agent.\n\nSecond paragraph with words.\n"
    h.system.files["/docs/guide.md"] = disk
    h.run(h.model.fileChanged(source: disk))
    XCTAssertEqual(
      h.model.edit?.source, "First paragraph, rewritten by the agent.\n\nSecond new paragraph with words.\n")
    XCTAssertEqual(typed(h), ["new "], "the agent's rewrite is not typed")
  }

  func testTypedRangesAreEmptyWithReviewOffAndAfterAPassIsSent() {
    var h = Harness("Alpha beta.\n")
    h.key(.char("i"))
    h.keys("x")
    XCTAssertEqual(h.model.typedRanges, [], "review is off")
    h.key(.escape)
    h.connectAgent()
    h.key(.char("m"))
    XCTAssertEqual(h.model.typedRanges, [], "the snapshot is the text now")
    h.key(.char("i"))
    h.keys("y")
    XCTAssertEqual(typed(h), ["y"])
    _ = h.model.reviewSubmitted(pass: 1)
    XCTAssertEqual(h.model.typedRanges, [])
    XCTAssertFalse(h.model.review.isOn, "a sent pass ends review")
  }
}
