import CoreGraphics
import Foundation
import TermDownDocument
import XCTest

@testable import TermDownLayout

final class EditingPrepareTests: XCTestCase {
  func testEditingWithoutCaretRendersExactlyLikeViewMode() throws {
    for name in ["sample", "readme"] {
      let markdown = try fixture(name)
      let view = PreparedDocument(markdown: markdown)
      let edit = PreparedDocument(markdown: markdown, editing: EditingOptions())
      XCTAssertEqual(edit.text as String, view.text as String, name)
      XCTAssertFalse(edit.editRegions.isEmpty, name)
      for region in edit.editRegions where region.range.count == region.projection.length {
        XCTAssertEqual(edit.text.substring(with: NSRange(location: region.range.lowerBound, length: region.range.count)),
          region.projection.text)
      }
    }
  }

  func testCaretRevealsSyntaxInRenderedText() throws {
    let markdown = "# Title\n\nSome **bold** text.\n"
    let caret = Array(markdown.utf8).firstIndex(of: UInt8(ascii: "b"))!  // inside **bold**
    let edit = PreparedDocument(markdown: markdown, editing: EditingOptions(caret: caret))
    XCTAssertTrue((edit.text as String).contains("Some **bold** text."))
    XCTAssertTrue((edit.text as String).hasPrefix("Title"))
    let heading = PreparedDocument(markdown: markdown, editing: EditingOptions(caret: 3))
    XCTAssertTrue((heading.text as String).hasPrefix("# Title"))
    XCTAssertTrue((heading.text as String).contains("Some bold text."))
  }

  func testRenderedAndSourceOffsetsRoundTrip() throws {
    let markdown = "Para with *it* and [link](https://x.y).\n\n- item **b**\n"
    let edit = PreparedDocument(markdown: markdown, editing: EditingOptions())
    // Rendered -> source -> rendered is the identity for every offset inside editable text.
    var checked = 0
    for region in edit.editRegions {
      for rendered in region.range.lowerBound...(region.range.lowerBound + region.projection.length) {
        let source = try XCTUnwrap(edit.sourceOffset(forRendered: rendered))
        XCTAssertEqual(edit.renderedOffset(forSource: source), rendered)
        checked += 1
      }
    }
    XCTAssertEqual(checked, 30)  // "Para with it and link." and "item b": 23 + 7 boundaries
  }

  /// Over a corpus: editing with no caret prepares exactly the view-mode text.
  func testEditingMatchesViewModeOverCorpus() throws {
    guard let root = ProcessInfo.processInfo.environment["MDV_CORPUS"] else { throw XCTSkip("MDV_CORPUS not set") }
    var checked = 0
    var differing: [String] = []
    let enumerator = FileManager.default.enumerator(atPath: root)
    while let path = enumerator?.nextObject() as? String, checked < 600 {
      guard path.hasSuffix(".md"), let markdown = try? String(contentsOfFile: root + "/" + path, encoding: .utf8),
        markdown.utf8.count < 200_000
      else { continue }
      checked += 1
      let view = PreparedDocument(markdown: markdown)
      let edit = PreparedDocument(markdown: markdown, editing: EditingOptions())
      if edit.text as String != view.text as String { differing.append(path) }
    }
    print("editing corpus: \(checked) files, \(differing.count) differ: \(differing.prefix(5))")
    XCTAssertEqual(differing, [])
  }
}
