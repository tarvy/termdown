import CoreGraphics
import Foundation
import TermDownCore
import TermDownLayout
import TermDownMermaid
import XCTest

@testable import TermDownRender

final class ReviewImageTests: XCTestCase {
  private var outputDirectory: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("../../.build/review-images/task4-images").standardizedFileURL
  }

  @MainActor
  func testWriteReviewImages() async throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["TERMDOWN_REVIEW_IMAGES"] == "1", "set TERMDOWN_REVIEW_IMAGES=1 to write")
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    let palettes = themePalettes()
    let themes = ["charcoal-atelier", "merino-light", "midnight-tundra"]
    let sample = prepare(try fixture("sample"))
    let elements = prepare(try fixture("elements"))
    let sampleHighlights = highlightAll(sample)
    let elementHighlights = highlightAll(elements)
    let width: CGFloat = 760 * 2
    let statusHeight = StatusBar.height(cellPixelHeight: 34, backingScale: 2)
    let mermaid = MermaidRenderer()
    for theme in themes {
      let palette = try XCTUnwrap(palettes[theme] ?? (theme == "midnight-tundra" ? palettes["merino-dark"] : nil))
      let diagrams = try await renderDiagrams(sample, width: width, palette: palette, mermaid: mermaid)
      let page = sample.layout(
        LayoutInput(
          width: width, expandedDetails: sample.initiallyExpandedDetails, prefersDark: palette.dark,
          diagramSize: diagrams.size))
      let rasterizer = Rasterizer(
        layout: page, palette: palette, assets: RenderAssets(diagram: diagrams.image), highlights: sampleHighlights)
      let full = try XCTUnwrap(rasterizer.render(CGRect(x: 0, y: 0, width: width, height: page.height)))
      try write(full, "sample-\(theme).png")

      let viewport = CGSize(width: width, height: 1100)
      let scrollable = max(page.height - (viewport.height - statusHeight), 0)
      let scrollY = (scrollable * 0.4).rounded()
      let matches = page.find("index")
      let status = StatusBarContent(
        fileName: "sample.md", folder: "termdown/docs",
        progress: ScrollProgress(offset: scrollY, viewport: viewport.height - statusHeight, content: page.height),
        message: StatusMessage("3/\(matches.count)", kind: .find), hint: "/ find   y copy   q quit")
      let frame = try XCTUnwrap(
        rasterizer.renderViewport(
          scrollY: scrollY, size: viewport, overlay: RenderOverlay(findMatches: matches, currentMatch: 2),
          status: status, statusBarHeight: statusHeight))
      try write(frame, "status-40-\(theme).png")

      let elementPage = elements.layout(width: width)
      let elementRaster = Rasterizer(layout: elementPage, palette: palette, highlights: elementHighlights)
      let codeID = try XCTUnwrap(elements.codeBlocks.first { $0.value.language == "python" }?.key)
      let selection = try XCTUnwrap(elementPage.range(of: "Plain text with"))
      let task = try XCTUnwrap(
        elementPage.targets.first {
          if case .task = $0.target { return true } else { return false }
        }
      ).target
      let overlay = RenderOverlay(
        selection: selection.lowerBound..<(selection.upperBound + 20), findMatches: elementPage.find("details"),
        currentMatch: 0, focus: .target(task), copyButton: CopyButtonOverlay(block: codeID))
      let elementImage = try XCTUnwrap(
        elementRaster.render(CGRect(x: 0, y: 0, width: width, height: elementPage.height), overlay: overlay))
      try write(elementImage, "elements-\(theme).png")
    }
  }

  func testMarksListDrawsColoredDigits() throws {
    let palette = RenderPalette.fallback(dark: true)
    let rows = [
      MarksListRow(seq: 1, key: "1", label: "Delete", color: "#ef4444", quote: "the old sentence", note: nil, line: 3),
      MarksListRow(
        seq: 2, key: "9", label: "Note...", color: "#9ca3af", quote: "a passage", note: "say it plainly", line: 12),
    ]
    let list = MarksList(content: MarksListContent(rows: rows, selected: 1, pass: 2), backingScale: 2)
    let area = CGRect(x: 0, y: 0, width: 2400, height: 800)
    let bitmap = try XCTUnwrap(RasterBitmap(width: 2400, height: 800))
    bitmap.context.setFillColor(palette.pageBackground.cgColor)
    bitmap.context.fill(area)
    list.draw(palette: palette, in: area, clip: area, bitmap: bitmap)

    let panel = list.panel(in: area)
    XCTAssertLessThan(panel.width, area.width * 0.6, "a pop-up, not full width")
    XCTAssertEqual(panel.maxX, area.maxX - 16, accuracy: 40, "it sits at the right")
    XCTAssertLessThan(panel.minY, 80, "and at the top")
    assertColor(
      bitmap.pixel(x: 20, y: 400), palette.pageBackground, tolerance: 2, "the page outside the panel is untouched")

    var inked = 0
    for y in Int(panel.minY)..<Int(panel.maxY) {
      for x in Int(panel.minX)..<Int(panel.maxX) {
        if let pixel = bitmap.pixel(x: x, y: y), pixel.distance(to: palette.statusBarBackground.pixel) > 40 {
          inked += 1
        }
      }
    }
    XCTAssertGreaterThan(inked, 200, "the panel has text drawn on it")

    func nearest(_ rect: CGRect, to color: RGB) -> Int {
      var best = Int.max
      for y in Int(rect.minY)..<Int(rect.maxY) {
        for x in Int(rect.minX)..<Int(rect.maxX) {
          if let pixel = bitmap.pixel(x: x, y: y) { best = min(best, pixel.distance(to: color.pixel)) }
        }
      }
      return best
    }
    let first = nearest(list.digitRect(0, in: area), to: RGB(hex: 0xef4444))
    XCTAssertLessThanOrEqual(first, 24, "row 1's digit is its color")
    let second = nearest(list.digitRect(1, in: area), to: RGB(hex: 0x9ca3af))
    XCTAssertLessThanOrEqual(second, 24, "row 2's digit is its color")
    XCTAssertGreaterThan(nearest(list.digitRect(0, in: area), to: RGB(hex: 0x16a34a)), 60)
  }

  @MainActor
  private func renderDiagrams(
    _ prepared: PreparedDocument, width: CGFloat, palette: RenderPalette, mermaid: MermaidRenderer
  ) async throws -> (size: @Sendable (String) -> CGSize?, image: @Sendable (String) -> CGImage?) {
    let scale = prepared.typography.scale
    let placeholder = try XCTUnwrap(
      prepared.layout(width: width).images.first {
        if case .diagram = $0.content { return true } else { return false }
      })
    let theme = MermaidTheme(palette: palette)
    let columnWidth = placeholder.rect.width / scale
    for block in prepared.codeBlocks.values where block.isDiagram {
      let diagram = await withCheckedContinuation { continuation in
        mermaid.render(MermaidRequest(code: block.code, theme: theme, width: columnWidth, scale: scale)) {
          continuation.resume(returning: $0)
        }
      }
      XCTAssertNil(diagram.failure)
    }
    return (
      mermaid.sizeProvider(theme: theme, width: columnWidth, scale: scale),
      mermaid.imageProvider(theme: theme, width: columnWidth, scale: scale)
    )
  }

  private func write(_ bitmap: RasterBitmap, _ name: String) throws {
    let data = try XCTUnwrap(bitmap.pngData())
    try data.write(to: outputDirectory.appendingPathComponent(name))
  }
}
