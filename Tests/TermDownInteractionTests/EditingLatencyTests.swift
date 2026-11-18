import CryptoKit
import Foundation
import TermDownDocument
import TermDownLayout
import XCTest

@testable import TermDownInteraction

/// Whole keystroke in edit mode: the session's edit (parse + map), then prepare with its inputs and lay out.
final class KeystrokeLatencyTests: XCTestCase {
  func testWholeKeystroke() throws {
    let unit = "## Section\n\nA paragraph with **bold**, *italic*, `code`, and a [link](https://x.y/z) in it, long enough to wrap across the line at least once more.\n\n- item one with ~~strike~~\n- item two\n\n> quoted line\n\n"
    var report: [String] = []
    for size in [5_000, 40_000, 140_000] {
      var markdown = "# Doc\n\n"
      while markdown.utf8.count < size { markdown += unit }
      var session = EditSession(source: markdown, caret: markdown.utf8.count / 2)
      _ = PreparedDocument(inputs: session.inputs, typography: Typography(), editing: EditingOptions(caret: session.caret))
        .layout(width: 1200)
      var samples: [Double] = []
      for _ in 0..<9 {
        let start = Date()
        session.insert("x")
        let prepared = PreparedDocument(
          inputs: session.inputs, typography: Typography(), editing: EditingOptions(caret: session.caret))
        _ = prepared.layout(width: 1200)
        samples.append(Date().timeIntervalSince(start) * 1000)
      }
      samples.sort()
      // The byte length and hash let another implementation prove it benched the identical document.
      let digest = SHA256.hash(data: Data(markdown.utf8)).map { String(format: "%02x", $0) }.joined()
      report.append(
        String(
          format: "keystroke %dKB: median %.1f ms, max %.1f ms (bytes %d, sha256 %@)", size / 1000, samples[4], samples[8],
          markdown.utf8.count, digest))
    }
    print(report.joined(separator: "\n"))
  }
}
