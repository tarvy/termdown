import AppKit
import CoreGraphics
import CoreText
import TermDownCore

/// One row of the marks list: a review mark as the person reads it back.
public struct MarksListRow: Equatable, Sendable {
  /// A quote longer than this many characters is cut to it, ending with an ellipsis.
  public static let quoteLimit = 60

  public var seq: Int
  /// The hotkey digit of the mark's type, or `?` when no hotkey has that type.
  public var key: String
  public var label: String
  /// The hotkey's hex color.
  public var color: String
  /// The marked text on one line, cut on whole characters.
  public var quote: String
  public var note: String?
  /// The 1-based source line the mark starts on.
  public var line: Int

  public init(seq: Int, key: String, label: String, color: String, quote: String, note: String? = nil, line: Int) {
    self.seq = seq
    self.key = key
    self.label = label
    self.color = color
    self.quote = quote
    self.note = note
    self.line = line
  }

  /// `text` on one line: runs of whitespace become one space, and a longer text is cut on grapheme boundaries so a
  /// family emoji or an accent is never split.
  public static func quote(of text: String) -> String {
    let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard flat.count > quoteLimit else { return flat }
    return String(flat.prefix(quoteLimit - 1)) + "\u{2026}"
  }
}

public struct MarksListContent: Equatable, Sendable {
  public var rows: [MarksListRow]
  public var selected: Int
  /// The pass the marks are for.
  public var pass: Int

  public init(rows: [MarksListRow], selected: Int = 0, pass: Int) {
    self.rows = rows
    self.pass = pass
    self.selected = min(max(selected, 0), max(rows.count - 1, 0))
  }
}

/// The marks list: a pop-up over the page's top right with one row per mark.
public struct MarksList {
  public static let footer =
    "\u{2191}\u{2193} move \u{00B7} Enter jump \u{00B7} x delete \u{00B7} 1-9 retype \u{00B7} n note \u{00B7} Esc close"

  public static func header(_ content: MarksListContent) -> String {
    "Marks \u{00B7} \(content.rows.count) \u{00B7} pass \(content.pass)"
  }

  public let content: MarksListContent
  public let backingScale: CGFloat

  public init(content: MarksListContent, backingScale: CGFloat) {
    self.content = content
    self.backingScale = min(max(backingScale.isFinite ? backingScale : 2, 1), 4)
  }

  private func points(_ value: CGFloat) -> CGFloat { value * backingScale }

  var rowHeight: CGFloat { points(22) }
  var inset: CGFloat { points(16) }
  var margin: CGFloat { points(8) }
  var textFont: CTFont { NSFont.systemFont(ofSize: points(12), weight: .regular) as CTFont }

  func panelWidth(in area: CGRect) -> CGFloat { max(min(points(560), area.width - margin * 2), 0) }

  func footerLines(width: CGFloat) -> [String] {
    wrapped(Self.footer, font: textFont, width: width - inset * 2, maximumLines: 2)
  }

  /// How many rows fit under the header and above the footer.
  func capacity(in area: CGRect) -> Int {
    let footer = CGFloat(footerLines(width: panelWidth(in: area)).count)
    let fixed = inset * 2 + rowHeight * (1.5 + 0.5 + footer)
    return max(Int((area.height - margin * 2 - fixed) / rowHeight), 1)
  }

  /// The first row shown: the window follows the selection when the list is longer than the panel.
  func firstVisible(in area: CGRect) -> Int {
    let room = capacity(in: area)
    guard content.rows.count > room else { return 0 }
    return min(max(content.selected - room / 2, 0), content.rows.count - room)
  }

  func visibleRows(in area: CGRect) -> Range<Int> {
    let first = firstVisible(in: area)
    return first..<min(first + capacity(in: area), content.rows.count)
  }

  public func panel(in area: CGRect) -> CGRect {
    let width = panelWidth(in: area)
    let footer = CGFloat(footerLines(width: width).count)
    let rows = CGFloat(visibleRows(in: area).count)
    let height = max(min(rowHeight * (1.5 + rows + 0.5 + footer) + inset * 2, area.height - margin * 2), 0)
    return CGRect(
      x: (area.maxX - width - margin).rounded(), y: (area.minY + margin).rounded(), width: width, height: height)
  }

  /// A row's band, which is off the panel for a row the window has scrolled past.
  public func rowRect(_ index: Int, in area: CGRect) -> CGRect {
    let panel = panel(in: area)
    let top = panel.minY + inset + rowHeight * 1.5 + CGFloat(index - firstVisible(in: area)) * rowHeight
    return CGRect(x: panel.minX + inset / 2, y: top, width: max(panel.width - inset, 0), height: rowHeight)
  }

  /// The strip a row's colored digit is drawn in.
  public func digitRect(_ index: Int, in area: CGRect) -> CGRect {
    let band = rowRect(index, in: area)
    return CGRect(x: band.minX + inset / 2, y: band.minY, width: points(18), height: band.height)
  }

  public func row(at point: CGPoint, in area: CGRect) -> Int? {
    visibleRows(in: area).first { rowRect($0, in: area).contains(point) }
  }

  public func draw(palette: RenderPalette, in area: CGRect, clip: CGRect, origin: CGPoint = .zero, bitmap: RasterBitmap)
  {
    let context = bitmap.context
    context.saveGState()
    defer { context.restoreGState() }
    context.translateBy(x: 0, y: CGFloat(bitmap.height))
    context.scaleBy(x: 1, y: -1)
    context.translateBy(x: -origin.x, y: -origin.y)
    context.clip(to: clip)
    context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    let panel = panel(in: area)
    guard panel.width > 0, panel.height > 0 else { return }
    let radius = points(8)
    context.setFillColor(palette.statusBarBackground.cgColor)
    context.addPath(CGPath(roundedRect: panel, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.fillPath()
    context.setStrokeColor(palette.border.cgColor)
    context.setLineWidth(max(points(1), 1))
    context.addPath(
      CGPath(roundedRect: panel.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.strokePath()
    context.clip(to: panel)

    let titleFont = NSFont.systemFont(ofSize: points(14), weight: .semibold) as CTFont
    let labelFont = NSFont.systemFont(ofSize: points(12), weight: .medium) as CTFont
    let digitFont = NSFont.systemFont(ofSize: points(14), weight: .bold) as CTFont
    let room = panel.width - inset * 2
    func baseline(_ line: TextLine, in band: CGRect) -> CGFloat {
      (band.midY + (line.ascent - line.descent) / 2).rounded()
    }

    let title = TextLine(Self.header(content), font: titleFont, truncateTo: room)
    context.setFillColor(palette.statusBarText.cgColor)
    title.draw(
      in: context,
      at: CGPoint(
        x: panel.minX + inset,
        y: baseline(title, in: CGRect(x: 0, y: panel.minY + inset, width: 0, height: rowHeight))))

    let visible = visibleRows(in: area)
    let labelColumn = points(96)
    for index in visible {
      let row = content.rows[index]
      let band = rowRect(index, in: area)
      if index == content.selected {
        context.setFillColor(palette.selectionFill.cgColor)
        context.addPath(CGPath(roundedRect: band, cornerWidth: points(4), cornerHeight: points(4), transform: nil))
        context.fillPath()
      }
      let digitX = digitRect(index, in: area).minX
      let color = parseHexColor(row.color) ?? RGB(hex: 0x9ca3af)
      let digit = TextLine(row.key, font: digitFont)
      context.setFillColor(color.cgColor)
      digit.draw(in: context, at: CGPoint(x: digitX, y: baseline(digit, in: band)))

      let lineText = TextLine("L\(row.line)", font: textFont)
      let lineX = band.maxX - inset / 2 - lineText.width
      context.setFillColor(palette.statusMutedText.cgColor)
      lineText.draw(in: context, at: CGPoint(x: lineX, y: baseline(lineText, in: band)))

      let labelX = digitX + points(24)
      let label = TextLine(row.label, font: labelFont, truncateTo: labelColumn - points(8))
      context.setFillColor(palette.statusBarText.cgColor)
      label.draw(in: context, at: CGPoint(x: labelX, y: baseline(label, in: band)))

      var x = labelX + labelColumn
      let space = max(lineX - points(12) - x, 0)
      let quote = TextLine(
        "\u{201C}\(row.quote)\u{201D}", font: textFont, truncateTo: row.note == nil ? space : space * 0.55)
      context.setFillColor(palette.statusBarText.cgColor)
      quote.draw(in: context, at: CGPoint(x: x, y: baseline(quote, in: band)))
      if let note = row.note {
        x += quote.width + points(8)
        let noteText = TextLine("\u{2192} \(note)", font: textFont, truncateTo: max(lineX - points(12) - x, 0))
        context.setFillColor(palette.link.cgColor)
        noteText.draw(in: context, at: CGPoint(x: x, y: baseline(noteText, in: band)))
      }
    }

    var y = panel.minY + inset + rowHeight * 1.5 + CGFloat(visible.count) * rowHeight + rowHeight * 0.5
    context.setFillColor(palette.statusMutedText.cgColor)
    for text in footerLines(width: panel.width) {
      let line = TextLine(text, font: textFont, truncateTo: room)
      line.draw(
        in: context,
        at: CGPoint(x: panel.minX + inset, y: baseline(line, in: CGRect(x: 0, y: y, width: 0, height: rowHeight))))
      y += rowHeight
    }
  }
}
