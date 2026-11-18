import CoreGraphics
import Foundation
import TermDownDocument
import XCTest

@testable import TermDownLayout

/// Keystroke cost in edit mode: parse, prepare with the caret, and lay out the whole page.
final class EditingLatencyTests: XCTestCase {
  func testKeystrokeLatency() throws {
    let unit = "## Section\n\nA paragraph with **bold**, *italic*, `code`, and a [link](https://x.y/z) in it, long enough to wrap across the line at least once more.\n\n- item one with ~~strike~~\n- item two\n\n> quoted line\n\n"
    for size in [10_000, 50_000, 200_000] {
      var markdown = "# Doc\n\n"
      while markdown.utf8.count < size { markdown += unit }
      let caret = markdown.utf8.count / 2
      var samples: [Double] = []
      for round in 0..<7 {
        let edited = markdown + String(repeating: "x", count: round)
        let start = Date()
        let prepared = PreparedDocument(markdown: edited, typography: Typography(), editing: EditingOptions(caret: caret))
        _ = prepared.layout(width: 1200)
        samples.append(Date().timeIntervalSince(start) * 1000)
      }
      let t0 = Date()
      let document = Document.parse(markdown)
      let t1 = Date()
      let prepared = PreparedDocument(document: document, source: markdown, typography: Typography(), editing: EditingOptions(caret: caret))
      let t2 = Date()
      _ = prepared.layout(width: 1200)
      let t3 = Date()
      let view = PreparedDocument(document: document, source: markdown, typography: Typography())
      let t4 = Date()
      _ = view
      print(String(format: "split %dKB: parse %.1f, prepare(edit) %.1f, layout %.1f, prepare(view) %.1f ms", size / 1000,
        t1.timeIntervalSince(t0) * 1000, t2.timeIntervalSince(t1) * 1000, t3.timeIntervalSince(t2) * 1000, t4.timeIntervalSince(t3) * 1000))
      samples.sort()
      print(String(format: "keystroke %dKB: median %.1f ms, max %.1f ms", size / 1000, samples[3], samples[6]))
    }
  }
}
