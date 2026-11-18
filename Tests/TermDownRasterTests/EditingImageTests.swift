import CoreGraphics
import Foundation
import TermDownCore
import TermDownLayout
import XCTest

@testable import TermDownRender

/// Writes edit-mode frames for a person to look at (TERMDOWN_REVIEW_IMAGES=1).
final class EditingImageTests: XCTestCase {
  func testWriteEditingImages() throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["TERMDOWN_REVIEW_IMAGES"] == "1", "set TERMDOWN_REVIEW_IMAGES=1")
    let out = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("../../.build/review-images/editing").standardizedFileURL
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let markdown = "# Scratch note\n\nSome **bold** words and a [link](https://example.com).\n\n- first item\n- second item\n\n```swift\nlet x = 1\n```\n\n> a quote line\n"
    let bytes = Array(markdown.utf8)
    let carets: [(String, Int?)] = [
      ("view", nil),
      ("caret-in-bold", bytes.firstRange(of: Array("old".utf8))!.lowerBound),
      ("caret-in-link", bytes.firstRange(of: Array("ink".utf8))!.lowerBound),
      ("caret-in-heading", 4),
      ("caret-in-code", bytes.firstRange(of: Array("let x".utf8))!.lowerBound + 4),
    ]
    let palette = RenderPalette.fallback(dark: true)
    for (name, caret) in carets {
      let prepared = PreparedDocument(
        markdown: markdown, typography: Typography(bodySize: 15, zoom: 1, backingScale: 2),
        editing: caret == nil ? nil : EditingOptions(caret: caret))
      let page = prepared.layout(LayoutInput(width: 1000, expandedDetails: [], prefersDark: true))
      var overlay = RenderOverlay()
      if let caret, let rendered = prepared.renderedOffset(forSource: caret) {
        overlay.caret = page.caretRect(atRendered: rendered, width: 4)
      }
      let image = try XCTUnwrap(
        Rasterizer(layout: page, palette: palette).render(CGRect(x: 0, y: 0, width: 1000, height: page.height), overlay: overlay))
      try XCTUnwrap(image.pngData()).write(to: out.appendingPathComponent("\(name).png"))
    }
  }
}
