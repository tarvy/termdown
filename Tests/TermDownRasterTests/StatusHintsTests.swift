import CoreGraphics
import TermDownCore
import XCTest

@testable import TermDownRender

final class StatusHintsTests: XCTestCase {
  private let palette = RenderPalette.fallback(dark: true)

  private func inkedPixels(_ bitmap: RasterBitmap, in rect: CGRect) -> Int {
    let background = palette.statusBarBackground.pixel
    var count = 0
    for y in Int(rect.minY.rounded(.up))..<Int(rect.maxY.rounded(.down)) {
      for x in Int(rect.minX.rounded(.up))..<Int(rect.maxX.rounded(.down)) {
        if let pixel = bitmap.pixel(x: x, y: y), pixel.distance(to: background) > 40 { count += 1 }
      }
    }
    return count
  }

  func testHintsAlwaysFitAndThePathYields() throws {
    XCTAssertEqual(StatusBar.keyHints, "/ find   e edit   r refresh   q quit   ? help")
    let content = StatusBarContent(
      fileName: "a-very-long-file-name-that-would-never-fit-in-a-narrow-pane.md",
      folder: "~/Documents/projects/team-notes/drafts/screenshots/visual-check",
      progress: ScrollProgress(start: 0, fraction: 0.5), message: StatusMessage("3/14", kind: .find))
    for width in [640, 900, 1600] {
      let bar = StatusBar(palette: palette, backingScale: 2)
      let rect = CGRect(x: 0, y: 0, width: width, height: 44)
      let bitmap = try XCTUnwrap(RasterBitmap(width: width, height: 44))
      bar.draw(content, in: rect, bitmap: bitmap)
      let hints = bar.keyHintsRect(in: rect)
      XCTAssertGreaterThanOrEqual(hints.minX, 0, "the hints fit at \(width) px")
      XCTAssertLessThanOrEqual(hints.maxX, rect.maxX)
      XCTAssertGreaterThan(inkedPixels(bitmap, in: hints), 40, "the hints are drawn at \(width) px")
      let right = CGRect(x: hints.maxX + 1, y: 4, width: rect.maxX - hints.maxX - 1, height: 36)
      XCTAssertEqual(inkedPixels(bitmap, in: right), 0, "no refresh control right of the hints at \(width) px")
    }
  }

  /// The abbreviated path gives way to the file's own folder before the folder goes altogether.
  func testTheAbbreviatedPathFallsBackToItsLastFolder() throws {
    func draw(_ folder: String?, width: Int) throws -> Data {
      let bar = StatusBar(palette: palette, backingScale: 2)
      let bitmap = try XCTUnwrap(RasterBitmap(width: width, height: 44))
      bar.draw(
        StatusBarContent(fileName: "notes.md", folder: folder, progress: ScrollProgress(start: 0, fraction: 1)),
        in: CGRect(x: 0, y: 0, width: width, height: 44), bitmap: bitmap)
      return Data(bitmap.bytes)
    }
    let full = "~/D/d/4/q/c/p/m/working-sessions"
    XCTAssertNotEqual(try draw(full, width: 1600), try draw("working-sessions", width: 1600), "wide: the whole path")
    let fallback = try (500...1100).first { width in
      try draw(full, width: width) == draw("working-sessions", width: width)
        && draw(full, width: width) != draw(nil, width: width)
    }
    XCTAssertNotNil(fallback, "some width shows only the last folder")
  }

  func testHintsPickTheWidestTierThatFits() throws {
    XCTAssertEqual(StatusBar.keyHintTiers, ["/ find   e edit   r refresh   q quit   ? help", "e edit   ? help"])
    let bar = StatusBar(palette: palette, backingScale: 2)
    let wide = bar.keyHintsRect(in: CGRect(x: 0, y: 0, width: 1600, height: 44))
    let narrow = bar.keyHintsRect(in: CGRect(x: 0, y: 0, width: 300, height: 44))
    XCTAssertFalse(wide.isNull)
    XCTAssertFalse(narrow.isNull, "the narrow tier fits where the full one does not")
    XCTAssertLessThan(narrow.width, wide.width / 2)
    XCTAssertGreaterThan(wide.width, 300 - 40, "the full tier would not fit at 300 px")
    XCTAssertGreaterThanOrEqual(narrow.minX, 0)
  }

  func testTooNarrowForTheHintsDropsThem() throws {
    let bar = StatusBar(palette: palette, backingScale: 2)
    let rect = CGRect(x: 0, y: 0, width: 150, height: 44)
    let bitmap = try XCTUnwrap(RasterBitmap(width: 150, height: 44))
    bar.draw(
      StatusBarContent(fileName: "x.md", folder: "~/a", progress: ScrollProgress(start: 0, fraction: 1)), in: rect,
      bitmap: bitmap)
    XCTAssertTrue(bar.keyHintsRect(in: rect).isNull)
    XCTAssertGreaterThan(inkedPixels(bitmap, in: CGRect(x: 0, y: 6, width: 120, height: 34)), 20, "the path draws")
  }

  func testTheEditorBadgeIsDrawnAfterTheFileName() throws {
    let bar = StatusBar(palette: palette, backingScale: 2)
    let rect = CGRect(x: 0, y: 0, width: 1600, height: 44)
    let content = StatusBarContent(fileName: "a.md", folder: "~/a", progress: ScrollProgress(start: 0, fraction: 1))
    let plain = try XCTUnwrap(RasterBitmap(width: 1600, height: 44))
    bar.draw(content, in: rect, bitmap: plain)
    var badged = content
    badged.editor = "Neovim: live"
    let withBadge = try XCTUnwrap(RasterBitmap(width: 1600, height: 44))
    bar.draw(badged, in: rect, bitmap: withBadge)
    let middle = CGRect(x: 200, y: 4, width: 400, height: 36)
    XCTAssertEqual(inkedPixels(plain, in: middle), 0)
    XCTAssertGreaterThan(inkedPixels(withBadge, in: middle), 40)
    let path = CGRect(x: 0, y: 4, width: 100, height: 36)
    XCTAssertEqual(inkedPixels(withBadge, in: path), inkedPixels(plain, in: path), "the path is unchanged")
  }

  func testTheEditorBadgeYieldsToTheFileName() throws {
    let bar = StatusBar(palette: palette, backingScale: 2)
    let rect = CGRect(x: 0, y: 0, width: 260, height: 44)
    let content = StatusBarContent(fileName: "a.md", progress: ScrollProgress(start: 0, fraction: 1))
    let plain = try XCTUnwrap(RasterBitmap(width: 260, height: 44))
    bar.draw(content, in: rect, bitmap: plain)
    var badged = content
    badged.editor = "Sublime Text: on save, with a very long name"
    let withBadge = try XCTUnwrap(RasterBitmap(width: 260, height: 44))
    bar.draw(badged, in: rect, bitmap: withBadge)
    XCTAssertEqual(
      inkedPixels(withBadge, in: CGRect(x: 0, y: 4, width: 260, height: 36)),
      inkedPixels(plain, in: CGRect(x: 0, y: 4, width: 260, height: 36)), "a badge that does not fit is left out")
  }

  func testHelpOverlayDrawsAPanelOverTheContent() throws {
    let overlay = HelpOverlay(palette: palette, backingScale: 2)
    let area = CGRect(x: 0, y: 0, width: 1400, height: 1200)
    let bitmap = try XCTUnwrap(RasterBitmap(width: 1400, height: 1200))
    bitmap.context.setFillColor(palette.pageBackground.cgColor)
    bitmap.context.fill(CGRect(x: 0, y: 0, width: 1400, height: 1200))
    overlay.draw(in: area, clip: area, bitmap: bitmap)
    let panel = overlay.panel(in: area)
    XCTAssertTrue(area.contains(panel))
    let inside = try XCTUnwrap(bitmap.pixel(x: Int(panel.maxX) - 12, y: Int(panel.maxY) - 12))
    XCTAssertLessThanOrEqual(inside.distance(to: palette.statusBarBackground.pixel), 3)
    XCTAssertGreaterThan(HelpOverlay.entries(editMode: .split).count, 15)
    XCTAssertTrue(HelpOverlay.entries(editMode: .split).contains { $0.keys.contains("?") })
  }

  func testHelpListsTheChangesSinceTheLastPass() {
    XCTAssertEqual(
      HelpOverlay.entries(editMode: .split).first { $0.keys == "D" }?.action,
      "Show what changed since the last pass sent, beside the preview")
  }

  /// `m` no longer simply clears the marks: it needs a connected session, and asks before discarding marks.
  func testHelpSaysWhatMNeedsAndThatItAsksBeforeDiscarding() {
    XCTAssertEqual(
      HelpOverlay.entries(editMode: .split).first { $0.keys == "m" }?.action,
      "Review mode on (needs a connected session) or off (asks before discarding marks)")
  }

  func testHelpEntriesFollowTheEditMode() {
    func action(_ keys: String, _ mode: EditMode) -> String? {
      HelpOverlay.entries(editMode: mode).first { $0.keys == keys }?.action
    }
    XCTAssertEqual(action("e", .split), "Edit beside the preview")
    XCTAssertEqual(action("E", .split), "Edit in this pane")
    XCTAssertEqual(action("e", .here), "Edit in this pane")
    XCTAssertEqual(action("E", .here), "Edit beside the preview")
    XCTAssertEqual(action(",", .split), "Choose the editor")
    XCTAssertEqual(
      action("Click", .here),
      "Follow links, toggle details, press Copy, open videos; with Neovim beside, jump the editor")
    XCTAssertEqual(
      HelpOverlay(palette: palette, backingScale: 2, editMode: .here).entries.map(\.action),
      HelpOverlay.entries(editMode: .here).map(\.action))
  }

  func testLongHelpActionsWrapInsteadOfTruncating() {
    let overlay = HelpOverlay(palette: palette, backingScale: 2)
    let width = overlay.panel(in: CGRect(x: 0, y: 0, width: 1400, height: 3000)).width
    let rows = overlay.rows(width: width)
    let click = rows.first { $0.keys == "Click" }
    XCTAssertEqual(click?.lines.count, 2)
    XCTAssertEqual(
      click?.lines.joined(separator: " "),
      "Follow links, toggle details, press Copy, open videos; with Neovim beside, jump the editor")
    XCTAssertEqual(rows.first { $0.keys == "e" }?.lines, ["Edit beside the preview"])
  }

  private func footerPixels(_ bitmap: RasterBitmap, in panel: CGRect) -> Int {
    var count = 0
    for y in Int(panel.minY)..<Int(panel.maxY) {
      for x in Int(panel.minX)..<Int(panel.maxX) {
        if let pixel = bitmap.pixel(x: x, y: y), pixel.distance(to: palette.statusMutedText.pixel) <= 2 { count += 1 }
      }
    }
    return count
  }

  func testHelpOverlayKeepsOneColumnWhenItFits() throws {
    let overlay = HelpOverlay(palette: palette, backingScale: 2)
    let area = CGRect(x: 0, y: 0, width: 1400, height: 2400)
    let layout = overlay.layout(in: area)
    XCTAssertEqual(layout.columns.count, 1)
    XCTAssertEqual(layout.columns[0].map(\.keys), overlay.entries.map(\.keys))
    let panel = overlay.panel(in: area)
    XCTAssertEqual(panel.height, overlay.contentHeight(layout.columns))
    XCTAssertTrue(area.contains(panel))
    let bitmap = try XCTUnwrap(RasterBitmap(width: 1400, height: 2400))
    overlay.draw(in: area, clip: area, bitmap: bitmap)
    XCTAssertGreaterThan(footerPixels(bitmap, in: panel), 0)
  }

  func testHelpOverlaySplitsIntoColumnsWhenOneWouldBeClipped() throws {
    let overlay = HelpOverlay(palette: palette, backingScale: 2)
    let area = CGRect(x: 0, y: 0, width: 1800, height: 1000)
    let layout = overlay.layout(in: area)
    XCTAssertGreaterThan(layout.columns.count, 1)
    XCTAssertEqual(layout.columns.flatMap { $0.map(\.keys) }, overlay.entries.map(\.keys))
    let sizes = layout.columns.map(\.count)
    XCTAssertLessThan(sizes.max()! - sizes.min()!, layout.columns.count)
    let panel = overlay.panel(in: area)
    XCTAssertLessThanOrEqual(overlay.contentHeight(layout.columns), area.height - 32)
    XCTAssertEqual(panel.height, overlay.contentHeight(layout.columns))
    XCTAssertTrue(area.contains(panel))
    let bitmap = try XCTUnwrap(RasterBitmap(width: 1800, height: 1000))
    overlay.draw(in: area, clip: area, bitmap: bitmap)
    XCTAssertGreaterThan(footerPixels(bitmap, in: panel), 0)
    XCTAssertEqual(layout.columns.last?.last?.keys, "q  Ctrl-C")
  }

  func testWriteHelpOverlayImage() throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["TERMDOWN_REVIEW_IMAGES"] == "1", "set TERMDOWN_REVIEW_IMAGES=1 to write")
    let overlay = HelpOverlay(palette: palette, backingScale: 2)
    let area = CGRect(x: 0, y: 0, width: 1800, height: 1000)
    let bitmap = try XCTUnwrap(RasterBitmap(width: 1800, height: 1000))
    bitmap.context.setFillColor(palette.pageBackground.cgColor)
    bitmap.context.fill(area)
    overlay.draw(in: area, clip: area, bitmap: bitmap)
    let out = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("../../.build/review-images").standardizedFileURL
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    try XCTUnwrap(bitmap.pngData()).write(to: out.appendingPathComponent("help-short.png"))
  }

  func testHelpOverlayPatchMatchesTheFullDraw() throws {
    let overlay = HelpOverlay(palette: palette, backingScale: 2)
    let area = CGRect(x: 0, y: 0, width: 1000, height: 900)
    let full = try XCTUnwrap(RasterBitmap(width: 1000, height: 900))
    overlay.draw(in: area, clip: area, bitmap: full)
    let patchRect = CGRect(x: 300, y: 200, width: 240, height: 160)
    let patch = try XCTUnwrap(RasterBitmap(width: 240, height: 160))
    overlay.draw(in: area, clip: patchRect, origin: patchRect.origin, bitmap: patch)
    for (x, y) in [(10, 10), (120, 80), (230, 150)] {
      XCTAssertEqual(patch.pixel(x: x, y: y), full.pixel(x: 300 + x, y: 200 + y))
    }
  }

  private func fieldFillPixels(_ bitmap: RasterBitmap) -> Int {
    var count = 0
    for y in 6..<bitmap.height {
      for x in 0..<bitmap.width {
        if let pixel = bitmap.pixel(x: x, y: y), pixel.distance(to: palette.pageBackground.pixel) <= 1 { count += 1 }
      }
    }
    return count
  }

  func testTheFindFieldIsDrawnOnlyWhileSearching() throws {
    let bar = StatusBar(palette: palette, backingScale: 2)
    let rect = CGRect(x: 0, y: 0, width: 900, height: 44)
    let progress = ScrollProgress(start: 0, fraction: 1)
    let idle = try XCTUnwrap(RasterBitmap(width: 900, height: 44))
    bar.draw(StatusBarContent(fileName: "a.md", progress: progress), in: rect, bitmap: idle)
    XCTAssertEqual(fieldFillPixels(idle), 0, "no field by default")
    let counting = try XCTUnwrap(RasterBitmap(width: 900, height: 44))
    bar.draw(
      StatusBarContent(fileName: "a.md", progress: progress, message: StatusMessage("2/14", kind: .find)), in: rect,
      bitmap: counting)
    XCTAssertEqual(fieldFillPixels(counting), 0, "no field while only the matches are active")
    let searching = try XCTUnwrap(RasterBitmap(width: 900, height: 44))
    bar.draw(StatusBarContent(fileName: "a.md", progress: progress, findField: "abc"), in: rect, bitmap: searching)
    XCTAssertGreaterThan(fieldFillPixels(searching), 50)
  }

  func testTheCaretStaysInsideTheFieldAtTheTextHeight() throws {
    let bar = StatusBar(palette: palette, backingScale: 2)
    let rect = CGRect(x: 0, y: 0, width: 900, height: 44)
    let metrics = bar.metrics(in: rect)
    for query in ["", "abc", "Typography"] {
      let bitmap = try XCTUnwrap(RasterBitmap(width: 900, height: 44))
      bar.draw(
        StatusBarContent(fileName: "a.md", progress: ScrollProgress(start: 0, fraction: 1), findField: query),
        in: rect, bitmap: bitmap)
      let geometry = bar.findField(query, right: metrics.hintsX - metrics.gap, in: rect)
      let inside = geometry.field.insetBy(dx: 0, dy: geometry.border)
      XCTAssertGreaterThanOrEqual(geometry.caret.minY, inside.minY + 1, query.debugDescription)
      XCTAssertLessThanOrEqual(geometry.caret.maxY, inside.maxY - 1, query.debugDescription)
      XCTAssertGreaterThan(geometry.caret.height, metrics.fontSize * 0.8, "as tall as a line of text")
      let x = Int(geometry.caret.midX)
      assertColor(bitmap.pixel(x: x, y: Int(geometry.caret.midY)), palette.statusBarText, tolerance: 8, "caret")
      assertColor(
        bitmap.pixel(x: x, y: Int(inside.minY.rounded(.up))), palette.pageBackground, tolerance: 8,
        "the row inside the top border is clear")
      assertColor(
        bitmap.pixel(x: x, y: Int(inside.maxY.rounded(.down)) - 1), palette.pageBackground, tolerance: 8,
        "the row inside the bottom border is clear")
    }
  }

  // MARK: Review legend, agent plug and client

  private func legend(_ count: Int = 9) throws -> [LegendEntry] {
    try ReviewHotkeys.parse(Data(ReviewHotkeys.bundled.utf8)).prefix(count).map {
      LegendEntry(key: $0.key, label: $0.label, color: $0.color)
    }
  }

  private func reviewContent(
    legend entries: [LegendEntry], marks: Int = 3, fileName: String = "a.md", folder: String? = nil,
    client: String? = nil, agent: String? = nil
  ) -> StatusBarContent {
    StatusBarContent(
      fileName: fileName, folder: folder, progress: ScrollProgress(start: 0, fraction: 1), agent: agent,
      client: client, review: ReviewBarContent(legend: entries, marks: marks))
  }

  func testReviewLegendReplacesKeyHints() throws {
    let bar = StatusBar(palette: palette, backingScale: 2)
    let rect = CGRect(x: 0, y: 0, width: 1600, height: 44)
    let content = reviewContent(legend: try legend())
    let bitmap = try XCTUnwrap(RasterBitmap(width: 1600, height: 44))
    bar.draw(content, in: rect, bitmap: bitmap)
    XCTAssertTrue(bar.keyHintsRect(content, in: rect).isNull, "no key hints while reviewing")
    XCTAssertFalse(bar.keyHintsRect(StatusBarContent(fileName: "a.md", progress: content.progress), in: rect).isNull)
    let rects = bar.legendRects(content, in: rect)
    XCTAssertEqual(rects.map(\.key), (1...9).map(String.init))
    for entry in rects {
      XCTAssertGreaterThan(inkedPixels(bitmap, in: entry.rect), 20, "key \(entry.key) is drawn at 1600 px")
    }
  }

  func testLegendTiersFitAt640And380() throws {
    let bar = StatusBar(palette: palette, backingScale: 2)
    var totals: [CGFloat] = []
    for width in [1600, 640, 380] {
      let rect = CGRect(x: 0, y: 0, width: width, height: 44)
      let content = reviewContent(legend: try legend(), client: "parnell", agent: "review-lab")
      let rects = bar.legendRects(content, in: rect)
      XCTAssertEqual(rects.count, 9, "every key is listed at \(width) px")
      for entry in rects {
        XCTAssertTrue(rect.contains(entry.rect), "key \(entry.key) is inside the bar at \(width) px: \(entry.rect)")
      }
      let fontSize = bar.metrics(in: rect).fontSize
      let widest = rects.map(\.rect.width).max() ?? 0
      if width == 1600 { XCTAssertGreaterThan(widest, fontSize * 3, "labels are shown when there is room") }
      if width == 380 { XCTAssertLessThan(widest, fontSize * 3, "digits only at 380 px") }
      totals.append((rects.last?.rect.maxX ?? 0) - (rects.first?.rect.minX ?? 0))
    }
    XCTAssertGreaterThan(totals[0], totals[1])
    XCTAssertLessThanOrEqual(totals[2], totals[1] + 0.001, "the legend gives way as the bar narrows")
  }

  func testLegendDigitIsDrawnInItsColor() throws {
    let bar = StatusBar(palette: palette, backingScale: 2)
    let rect = CGRect(x: 0, y: 0, width: 1600, height: 44)
    let content = reviewContent(legend: try legend())
    let bitmap = try XCTUnwrap(RasterBitmap(width: 1600, height: 44))
    bar.draw(content, in: rect, bitmap: bitmap)
    let entry = try XCTUnwrap(bar.legendRects(content, in: rect).first { $0.key == "1" })
    let digit = CGRect(
      x: entry.rect.minX, y: entry.rect.minY, width: bar.metrics(in: rect).fontSize * 0.6, height: entry.rect.height)
    var counts: [PixelColor: Int] = [:]
    let background = palette.statusBarBackground.pixel
    for y in Int(digit.minY)..<Int(digit.maxY) {
      for x in Int(digit.minX)..<Int(digit.maxX) {
        if let pixel = bitmap.pixel(x: x, y: y), pixel != background { counts[pixel, default: 0] += 1 }
      }
    }
    let common = try XCTUnwrap(counts.max { $0.value < $1.value }?.key)
    XCTAssertLessThanOrEqual(common.distance(to: RGB(hex: 0xef4444).pixel), 40, "\(common)")
  }

  func testLegendDrawsOnlyTheKeysGiven() throws {
    let bar = StatusBar(palette: palette, backingScale: 2)
    let rect = CGRect(x: 0, y: 0, width: 1600, height: 44)
    let rects = bar.legendRects(reviewContent(legend: try legend(3)), in: rect)
    XCTAssertEqual(rects.map(\.key), ["1", "2", "3"])
    let plain = StatusBarContent(fileName: "a.md", progress: ScrollProgress(start: 0, fraction: 1))
    XCTAssertTrue(bar.legendRects(plain, in: rect).isEmpty)
  }

  func testAMissingLegendColorFallsBackToGray() throws {
    let bar = StatusBar(palette: palette, backingScale: 2)
    let rect = CGRect(x: 0, y: 0, width: 1600, height: 44)
    let content = reviewContent(legend: [LegendEntry(key: "1", label: "Delete", color: "")])
    let bitmap = try XCTUnwrap(RasterBitmap(width: 1600, height: 44))
    bar.draw(content, in: rect, bitmap: bitmap)
    let entry = try XCTUnwrap(bar.legendRects(content, in: rect).first)
    var near = 0
    for y in Int(entry.rect.minY)..<Int(entry.rect.maxY) {
      for x in Int(entry.rect.minX)..<Int(entry.rect.minX + bar.metrics(in: rect).fontSize * 0.6) {
        if let pixel = bitmap.pixel(x: x, y: y), pixel.distance(to: RGB(hex: 0x9ca3af).pixel) <= 8 { near += 1 }
      }
    }
    XCTAssertGreaterThan(near, 10)
  }

  private func greenPixels(_ bitmap: RasterBitmap) -> Int {
    var count = 0
    for y in 0..<bitmap.height {
      for x in 0..<bitmap.width {
        if let pixel = bitmap.pixel(x: x, y: y), pixel.distance(to: palette.alerts.tip.pixel) <= 24 { count += 1 }
      }
    }
    return count
  }

  func testPlugOnlyWhenConnected() throws {
    let bar = StatusBar(palette: palette, backingScale: 2)
    let rect = CGRect(x: 0, y: 0, width: 900, height: 44)
    let progress = ScrollProgress(start: 0, fraction: 1)
    let none = try XCTUnwrap(RasterBitmap(width: 900, height: 44))
    bar.draw(StatusBarContent(fileName: "a.md", progress: progress), in: rect, bitmap: none)
    XCTAssertEqual(greenPixels(none), 0, "no plug with no agent connected")
    let connected = try XCTUnwrap(RasterBitmap(width: 900, height: 44))
    bar.draw(StatusBarContent(fileName: "a.md", progress: progress, agent: "review-lab"), in: rect, bitmap: connected)
    XCTAssertGreaterThan(greenPixels(connected), 20, "the plug is green")
    let untitled = try XCTUnwrap(RasterBitmap(width: 900, height: 44))
    bar.draw(StatusBarContent(fileName: "a.md", progress: progress, agent: ""), in: rect, bitmap: untitled)
    XCTAssertGreaterThan(greenPixels(untitled), 20, "a plug with no title is still a plug")
    XCTAssertEqual(Data(connected.bytes), Data(untitled.bytes), "the agent's title is never drawn, only the plug")
  }

  func testThePlugStaysWhenTheAgentTitleYields() throws {
    let bar = StatusBar(palette: palette, backingScale: 2)
    // The narrowest bar that holds the review badge, the plug and the digits-only legend.
    let rect = CGRect(x: 0, y: 0, width: 520, height: 44)
    let name = "a-very-long-file-name-that-would-never-fit-in-a-narrow-pane.md"
    func draw(agent: String) throws -> RasterBitmap {
      let bitmap = try XCTUnwrap(RasterBitmap(width: 520, height: 44))
      bar.draw(reviewContent(legend: try legend(), fileName: name, agent: agent), in: rect, bitmap: bitmap)
      return bitmap
    }
    let titled = try draw(agent: "review-lab")
    let untitled = try draw(agent: "")
    XCTAssertGreaterThan(greenPixels(titled), 20, "the plug stays")
    XCTAssertEqual(Data(titled.bytes), Data(untitled.bytes), "the title is dropped before the file name truncates")
  }

  func testReviewDrawsNoAgentTitleAndShowsTheBadge() throws {
    let bar = StatusBar(palette: palette, backingScale: 2)
    let rect = CGRect(x: 0, y: 0, width: 2900, height: 44)
    func draw(agent: String) throws -> RasterBitmap {
      let bitmap = try XCTUnwrap(RasterBitmap(width: 2900, height: 44))
      bar.draw(reviewContent(legend: try legend(), agent: agent), in: rect, bitmap: bitmap)
      return bitmap
    }
    // Each bitmap is held while its bytes are read: they belong to it.
    let titled = try draw(agent: "Term Down interactive review UX")
    let untitled = try draw(agent: "")
    XCTAssertEqual(Data(titled.bytes), Data(untitled.bytes), "with room to spare, the agent's title is not drawn")
    let plain = try XCTUnwrap(RasterBitmap(width: 2900, height: 44))
    bar.draw(StatusBarContent(fileName: "a.md", progress: ScrollProgress(start: 0, fraction: 1)), in: rect, bitmap: plain)
    let badge = CGRect(x: 20, y: 8, width: 40, height: 28)
    XCTAssertGreaterThan(
      inkedPixels(untitled, in: badge), inkedPixels(plain, in: badge) + 100, "the IR badge leads the bar")
  }

  func testReviewTiersGiveWayFromLabelsToKeysToDigits() throws {
    let bar = StatusBar(palette: palette, backingScale: 2)
    var short = try legend()
    let abbreviations = ["Del", "Awk", "Cringe", "Trim", "Halve", "Detail", "Src?", "Over", "Note"]
    for index in short.indices { short[index].short = abbreviations[index] }
    func layout(_ width: CGFloat) -> StatusBar.LegendLayout? {
      let rect = CGRect(x: 0, y: 0, width: width, height: 44)
      return bar.legendLayout(
        reviewContent(legend: short, marks: 2, fileName: "example.md", folder: "example"), in: rect,
        metrics: bar.metrics(in: rect))
    }
    let wide = try XCTUnwrap(layout(2900))
    XCTAssertEqual(wide.items.first?.label?.string, "Delete")
    XCTAssertEqual(wide.trailer.string, "2 marks   M list   U undo   x clear   D changes   s send")
    let middle = try XCTUnwrap(layout(1200))
    XCTAssertEqual(middle.items.map { $0.label?.string }, abbreviations)
    let narrow = try XCTUnwrap(layout(640))
    XCTAssertTrue(narrow.items.allSatisfy { $0.label == nil }, "digits only")
    XCTAssertTrue(narrow.trailer.string.hasSuffix("s send") || narrow.trailer.string.hasSuffix("s"))
  }

  func testClientLabelSurvivesNarrowPane() throws {
    var marked = palette
    marked.statusMutedText = RGB(hex: 0xff00ff)
    let bar = StatusBar(palette: marked, backingScale: 2)
    let rect = CGRect(x: 0, y: 0, width: 380, height: 44)
    let name = "a-very-long-file-name-that-would-never-fit-in-a-narrow-pane.md"
    func draw(client: String?, folder: String?) throws -> RasterBitmap {
      let bitmap = try XCTUnwrap(RasterBitmap(width: 380, height: 44))
      bar.draw(
        StatusBarContent(
          fileName: name, folder: folder, progress: ScrollProgress(start: 0, fraction: 1), client: client), in: rect,
        bitmap: bitmap)
      return bitmap
    }
    func mutedPixels(_ bitmap: RasterBitmap) -> Int {
      var count = 0
      for y in 0..<bitmap.height {
        for x in 0..<200 {
          if let pixel = bitmap.pixel(x: x, y: y), pixel.distance(to: marked.statusMutedText.pixel) <= 24 { count += 1 }
        }
      }
      return count
    }
    let withClient = try draw(client: "parnell", folder: "~/Documents/projects")
    let without = try draw(client: nil, folder: "~/Documents/projects")
    XCTAssertGreaterThan(mutedPixels(withClient), 30, "the client text has ink")
    XCTAssertEqual(mutedPixels(without), 0, "the folder is dropped when the file name needs the room")
    let noFolder = try draw(client: "parnell", folder: nil)
    XCTAssertEqual(Data(withClient.bytes), Data(noFolder.bytes), "the folder is dropped before the client")
  }

  func testTheClientIsDrawnBeforeTheFolder() throws {
    let bar = StatusBar(palette: palette, backingScale: 2)
    let rect = CGRect(x: 0, y: 0, width: 1600, height: 44)
    let progress = ScrollProgress(start: 0, fraction: 1)
    let plain = try XCTUnwrap(RasterBitmap(width: 1600, height: 44))
    bar.draw(StatusBarContent(fileName: "a.md", folder: "~/a", progress: progress), in: rect, bitmap: plain)
    let labelled = try XCTUnwrap(RasterBitmap(width: 1600, height: 44))
    bar.draw(
      StatusBarContent(fileName: "a.md", folder: "~/a", progress: progress, client: "parnell"), in: rect,
      bitmap: labelled)
    XCTAssertEqual(inkedPixels(plain, in: CGRect(x: 0, y: 4, width: 20, height: 36)), 0)
    XCTAssertGreaterThan(inkedPixels(labelled, in: CGRect(x: 20, y: 4, width: 60, height: 36)), 40)
  }

  func testTheReviewTrailerCountsMarks() throws {
    let bar = StatusBar(palette: palette, backingScale: 2)
    let rect = CGRect(x: 0, y: 0, width: 1600, height: 44)
    let none = reviewContent(legend: try legend(), marks: 0)
    let some = reviewContent(legend: try legend(), marks: 12)
    let zero = try XCTUnwrap(RasterBitmap(width: 1600, height: 44))
    let twelve = try XCTUnwrap(RasterBitmap(width: 1600, height: 44))
    bar.draw(none, in: rect, bitmap: zero)
    bar.draw(some, in: rect, bitmap: twelve)
    let trailer = CGRect(x: 1300, y: 4, width: 300, height: 36)
    XCTAssertGreaterThan(inkedPixels(zero, in: trailer), 40, "the count and send key are drawn")
    XCTAssertNotEqual(Data(zero.bytes), Data(twelve.bytes), "the count follows the marks")
  }
}
