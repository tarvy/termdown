import Foundation
import XCTest

@testable import TermDownInteraction

final class ReviewMarksTests: XCTestCase {
  private func range(of needle: String, in source: String, occurrence: Int = 0) -> Range<Int> {
    let bytes = Array(source.utf8)
    let target = Array(needle.utf8)
    var found = 0
    for start in 0...(bytes.count - target.count) where Array(bytes[start..<(start + target.count)]) == target {
      if found == occurrence { return start..<(start + target.count) }
      found += 1
    }
    fatalError("\(needle) not found")
  }

  private func slice(_ mark: ReviewMark, _ source: String) -> String {
    String(decoding: Array(source.utf8)[mark.range], as: UTF8.self)
  }

  func testAnEmDashBeforeTheMarkGivesUTF16Columns() throws {
    let source = "Title\nWe ship — fast and safe.\n"
    var marks = ReviewMarks()
    marks.add(range(of: "fast", in: source), type: "cringe", label: "Cringe")
    let annotation = try XCTUnwrap(marks.annotations(in: Array(source.utf8)).first)
    XCTAssertEqual(annotation.line, 2)
    XCTAssertEqual(annotation.colFrom, 10, "the em dash is one UTF-16 unit, not three bytes")
    XCTAssertEqual(annotation.endLine, 2)
    XCTAssertEqual(annotation.colTo, 14)
    XCTAssertEqual(annotation.text, "fast")
  }

  func testARepeatedPhraseGetsOccurrenceTwo() throws {
    let source = "We shipped fast. We shipped fast.\n"
    var marks = ReviewMarks()
    marks.add(range(of: "shipped fast", in: source, occurrence: 1), type: "awkward", label: "Awkward")
    let annotation = try XCTUnwrap(marks.annotations(in: Array(source.utf8)).first)
    XCTAssertEqual(annotation.occurrence, 2)
    XCTAssertEqual(annotation.colFrom, 20)
  }

  func testAThreeLineSelectionSpansLinesWithTheRightContext() throws {
    let source = "Intro.\nFirst line here.\nSecond line.\nThird line ends.\nOutro.\n"
    var marks = ReviewMarks()
    let start = range(of: "line here", in: source).lowerBound
    let end = range(of: "Third", in: source).upperBound
    marks.add(start..<end, type: "shorten", label: "Shorten")
    let annotation = try XCTUnwrap(marks.annotations(in: Array(source.utf8)).first)
    XCTAssertEqual(annotation.text, "line here.\nSecond line.\nThird")
    XCTAssertEqual(annotation.context, "First line here.\nSecond line.\nThird line ends.")
    XCTAssertEqual(annotation.line, 2)
    XCTAssertEqual(annotation.colFrom, 6)
    XCTAssertEqual(annotation.endLine, 4)
    XCTAssertEqual(annotation.colTo, 5)
    XCTAssertEqual(annotation.occurrence, 1)
  }

  func testAnnotationsKeepPressOrderAndEncodeTheContractKeys() throws {
    let source = "Alpha beta gamma.\n"
    var marks = ReviewMarks()
    marks.add(range(of: "gamma", in: source), type: "note", label: "Note...", note: "why?")
    marks.add(range(of: "Alpha", in: source), type: "delete", label: "Delete")
    let annotations = marks.annotations(in: Array(source.utf8))
    XCTAssertEqual(annotations.map(\.seq), [1, 2])
    let json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(annotations[1])) as? [String: Any])
    XCTAssertEqual(
      Set(json.keys),
      ["type", "label", "text", "note", "context", "line", "col_from", "end_line", "col_to", "occurrence", "seq"])
    XCTAssertTrue(json["note"] is NSNull, "note is written as null, not left out")
  }

  func testAMarkWhoseTextIsDeletedIsDropped() {
    let source = "Keep this. Drop this. Keep that.\n"
    var marks = ReviewMarks()
    marks.add(range(of: "Drop this.", in: source), type: "delete", label: "Delete")
    let edited = "Keep this.  Keep that.\n"
    marks.remap(from: Array(source.utf8), to: Array(edited.utf8))
    XCTAssertTrue(marks.isEmpty)
  }

  func testAMarkAfterAnInsertionShifts() throws {
    let source = "One two three.\n"
    var marks = ReviewMarks()
    marks.add(range(of: "three", in: source), type: "expand", label: "Add detail")
    let edited = "Zero, one two three.\n"
    marks.remap(from: Array(source.utf8), to: Array(edited.utf8))
    XCTAssertEqual(slice(try XCTUnwrap(marks.marks.first), edited), "three")
  }

  func testAMarkBeforeAChangeStays() throws {
    let source = "One two three.\n"
    var marks = ReviewMarks()
    marks.add(range(of: "One", in: source), type: "expand", label: "Add detail")
    let edited = "One two three and four.\n"
    marks.remap(from: Array(source.utf8), to: Array(edited.utf8))
    XCTAssertEqual(try XCTUnwrap(marks.marks.first).range, 0..<3)
  }

  func testAMarkPartlyInsideAReplacedSpanClamps() throws {
    let source = "The quick brown fox jumps.\n"
    var marks = ReviewMarks()
    marks.add(range(of: "quick brown", in: source), type: "shorten", label: "Shorten")
    marks.add(range(of: "fox jumps", in: source), type: "overstated", label: "Overstated")
    // "brown fox" becomes "red cat": the first mark keeps its start, the second keeps its end.
    let edited = "The quick red cat jumps.\n"
    marks.remap(from: Array(source.utf8), to: Array(edited.utf8))
    XCTAssertEqual(marks.marks.map { slice($0, edited) }, ["quick ", " jumps"])
  }

  func testAMarkCoveringAReplacedSpanTakesTheNewText() throws {
    let source = "The quick brown fox.\n"
    var marks = ReviewMarks()
    marks.add(range(of: "quick brown fox", in: source), type: "shorten", label: "Shorten")
    let edited = "The quick red fox.\n"
    marks.remap(from: Array(source.utf8), to: Array(edited.utf8))
    XCTAssertEqual(slice(try XCTUnwrap(marks.marks.first), edited), "quick red fox")
  }

  func testTypingRightAtAMarksStartStaysOutsideIt() throws {
    let source = "Say hello.\n"
    var marks = ReviewMarks()
    marks.add(range(of: "hello", in: source), type: "cringe", label: "Cringe")
    let edited = "Say Xhello.\n"
    marks.remap(from: Array(source.utf8), to: Array(edited.utf8))
    XCTAssertEqual(slice(try XCTUnwrap(marks.marks.first), edited), "hello")
  }

  func testAnEmptyRangeAddsNoMark() {
    var marks = ReviewMarks()
    XCTAssertNil(marks.add(3..<3, type: "delete", label: "Delete"))
    XCTAssertTrue(marks.isEmpty)
  }

  func testSameRangeAndTypeReplaces() {
    var marks = ReviewMarks()
    let first = marks.add(0..<4, type: "source", label: "Source?")
    let again = marks.add(0..<4, type: "source", label: "Source?", note: "newer")
    XCTAssertEqual(marks.count, 1)
    XCTAssertEqual(again?.seq, first?.seq, "the replacement keeps the old seq")
    XCTAssertEqual(marks.marks.first?.note, "newer")
    marks.add(0..<4, type: "cringe", label: "Cringe")
    XCTAssertEqual(marks.count, 2)
    XCTAssertEqual(marks.marks.last?.seq, (first?.seq ?? 0) + 1, "a new mark still gets the next seq")
  }
}
