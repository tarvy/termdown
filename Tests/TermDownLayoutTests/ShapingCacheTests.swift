import CoreGraphics
import Foundation
import TermDownDocument
import XCTest

@testable import TermDownLayout

final class ShapingCacheTests: XCTestCase {
  private func snapshot(_ page: PageLayout) -> [String] {
    var lines = page.fragments.map { "f \($0.range) \($0.origin) \($0.minX) \($0.maxX) \($0.lineTop) \($0.region.map { "\($0)" } ?? "-")" }
    lines += page.decorations.map { "d \($0.kind) \($0.rect)" }
    // Box groups are labels: compare them by first appearance.
    var groups: [Int: Int] = [:]
    lines += page.prepared.segments.map { segment in
      let group = segment.boxGroup.map { group -> String in
        if groups[group] == nil { groups[group] = groups.count }
        return String(groups[group]!)
      }
      return "s \(segment.range) \(segment.width) \(group ?? "-")"
    }
    lines.append("h \(page.height) t \(page.prepared.text as String)")
    return lines
  }

  private func cold(_ markdown: String, editing: EditingOptions? = nil) -> [String] {
    ShapingCache.shared.clear()
    return snapshot(PreparedDocument(markdown: markdown, editing: editing).layout(width: 900))
  }

  func testWarmLayoutEqualsColdLayout() throws {
    for name in ["sample", "readme"] {
      let markdown = try fixture(name)
      let fresh = cold(markdown)
      let warm = snapshot(PreparedDocument(markdown: markdown).layout(width: 900))
      XCTAssertEqual(warm, fresh, name)
    }
  }

  func testEditedDocumentReusesRunsAtNewOffsets() throws {
    let markdown = try fixture("sample")
    ShapingCache.shared.clear()
    _ = PreparedDocument(markdown: markdown, editing: EditingOptions()).layout(width: 900)
    // Insert text early, so every later run moves.
    let edited = markdown.replacingOccurrences(of: "\n\n", with: "\n\nInserted `code` and **words**.\n\n", options: [], range: markdown.range(of: "\n\n"))
    let warm = snapshot(PreparedDocument(markdown: edited, editing: EditingOptions(caret: 40)).layout(width: 900))
    let fresh = cold(edited, editing: EditingOptions(caret: 40))
    XCTAssertEqual(warm.count, fresh.count)
    if let index = warm.indices.first(where: { $0 < fresh.count && warm[$0] != fresh[$0] }) {
      XCTFail("first difference at \(index):\nwarm: \(warm[index].prefix(300))\ncold: \(fresh[index].prefix(300))")
    }
  }
}
