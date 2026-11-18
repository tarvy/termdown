import AppKit
import CoreGraphics
import CoreText
import TermDownCore

/// What the note dialog shows: the passage being annotated and the note typed so far.
public struct NoteDialogContent: Equatable, Sendable {
  public var title: String
  public var prompt: String
  public var excerpt: String
  public var text: String
  /// The hotkey's colour, as `#rrggbb`.
  public var color: String

  public init(title: String, prompt: String, excerpt: String, text: String, color: String) {
    self.title = title
    self.prompt = prompt
    self.excerpt = excerpt
    self.text = text
    self.color = color
  }
}

/// A floating panel over the page for typing a review note (the prompting hotkey, 9 by default).
public struct NoteDialog {
  public static let footer = "Enter adds the note  \u{00B7}  Esc cancels"
  static let excerptLines = 2
  static let minimumFieldLines = 3
  static let maximumFieldLines = 8

  public let content: NoteDialogContent
  public let backingScale: CGFloat

  public init(content: NoteDialogContent, backingScale: CGFloat) {
    self.content = content
    self.backingScale = min(max(backingScale.isFinite ? backingScale : 2, 1), 4)
  }

  private func points(_ value: CGFloat) -> CGFloat { value * backingScale }

  var inset: CGFloat { points(20) }
  var headerHeight: CGFloat { points(24) }
  var excerptLineHeight: CGFloat { points(18) }
  var fieldLineHeight: CGFloat { points(21) }
  var fieldPadding: CGFloat { points(10) }
  var footerHeight: CGFloat { points(18) }
  var gap: CGFloat { points(12) }
  var titleFont: CTFont { NSFont.systemFont(ofSize: points(14), weight: .semibold) as CTFont }
  var excerptFont: CTFont {
    let base = NSFont.systemFont(ofSize: points(12), weight: .regular)
    return NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask) as CTFont
  }
  var fieldFont: CTFont { NSFont.systemFont(ofSize: points(14), weight: .regular) as CTFont }
  var footerFont: CTFont { NSFont.systemFont(ofSize: points(12), weight: .regular) as CTFont }

  func panelWidth(in area: CGRect) -> CGFloat { max(min(points(600), area.width - points(32)), 0) }

  func excerptLines(width: CGFloat) -> [String] {
    // The last line holds the rest of the passage; drawing truncates it with an ellipsis.
    guard !content.excerpt.isEmpty else { return [] }
    return wrapped(content.excerpt, font: excerptFont, width: width - inset * 2 - points(12), maximumLines: Self.excerptLines)
  }

  /// The note wrapped to the field, newlines shown as spaces.
  func fieldLines(width: CGFloat) -> [String] {
    let text = content.text.replacingOccurrences(of: "\n", with: " ")
    guard !text.isEmpty else { return [""] }
    var lines = wrapped(text, font: fieldFont, width: fieldTextWidth(width), maximumLines: .max)
    // `wrapped` trims; keep the trailing spaces on the last line so the caret moves when one is typed.
    let trailing = text.reversed().prefix { $0 == " " }
    if !trailing.isEmpty { lines[lines.count - 1] += String(trailing) }
    return lines
  }

  func fieldTextWidth(_ panelWidth: CGFloat) -> CGFloat { max(panelWidth - inset * 2 - fieldPadding * 2, 0) }

  func visibleFieldLines(width: CGFloat) -> Int {
    min(max(fieldLines(width: width).count, Self.minimumFieldLines), Self.maximumFieldLines)
  }

  public func panel(in area: CGRect) -> CGRect {
    let width = panelWidth(in: area)
    let excerpt = excerptLines(width: width).count
    var height = inset + headerHeight + gap
    if excerpt > 0 { height += CGFloat(excerpt) * excerptLineHeight + gap }
    height += CGFloat(visibleFieldLines(width: width)) * fieldLineHeight + fieldPadding * 2
    height += gap + footerHeight + inset
    height = max(min(height, area.height - points(16)), 0)
    return CGRect(
      x: (area.midX - width / 2).rounded(), y: (area.midY - height / 2).rounded(), width: width, height: height)
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
    context.setFillColor(palette.pageBackground.cgColor(alpha: 0.55))
    context.fill(area)
    let panel = panel(in: area)
    guard panel.width > 0, panel.height > 0 else { return }

    let radius = points(10)
    context.saveGState()
    context.setShadow(
      offset: CGSize(width: 0, height: points(6)), blur: points(24), color: CGColor(gray: 0, alpha: 0.25))
    context.setFillColor(palette.statusBarBackground.cgColor)
    context.addPath(CGPath(roundedRect: panel, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.fillPath()
    context.restoreGState()
    context.setStrokeColor(palette.border.cgColor)
    context.setLineWidth(max(points(1), 1))
    context.addPath(
      CGPath(roundedRect: panel.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.strokePath()
    context.clip(to: panel)

    let accent = (parseHexColor(content.color) ?? palette.link).cgColor
    let glyphs = Glyphs(context: context, hairline: max(1, backingScale.rounded()))
    let room = panel.width - inset * 2
    func baseline(_ line: TextLine, in band: CGRect) -> CGFloat {
      (band.midY + (line.ascent - line.descent) / 2).rounded()
    }

    // Header: pencil and title.
    var y = panel.minY + inset
    let header = CGRect(x: panel.minX + inset, y: y, width: room, height: headerHeight)
    let iconSize = points(16)
    glyphs.pencil(
      in: CGRect(x: header.minX, y: header.midY - iconSize / 2, width: iconSize, height: iconSize), color: accent)
    let title = TextLine(content.title, font: titleFont, truncateTo: room - iconSize - points(8))
    context.setFillColor(palette.statusBarText.cgColor)
    title.draw(in: context, at: CGPoint(x: header.minX + iconSize + points(8), y: baseline(title, in: header)))
    y = header.maxY + gap

    // The passage, quoted with a bar in the hotkey's colour.
    let excerpt = excerptLines(width: panel.width)
    if !excerpt.isEmpty {
      let block = CGRect(
        x: panel.minX + inset, y: y, width: room, height: CGFloat(excerpt.count) * excerptLineHeight)
      context.setFillColor(accent)
      context.fill(CGRect(x: block.minX, y: block.minY, width: points(3), height: block.height))
      context.setFillColor(palette.statusMutedText.cgColor)
      for (index, text) in excerpt.enumerated() {
        let band = CGRect(
          x: block.minX, y: block.minY + CGFloat(index) * excerptLineHeight, width: room, height: excerptLineHeight)
        let line = TextLine(text, font: excerptFont, truncateTo: room - points(12))
        line.draw(in: context, at: CGPoint(x: block.minX + points(12), y: baseline(line, in: band)))
      }
      y = block.maxY + gap
    }

    // The text area: the last lines of the note, a caret after it, the prompt as a placeholder when empty.
    let visible = visibleFieldLines(width: panel.width)
    let field = CGRect(
      x: panel.minX + inset, y: y, width: room, height: CGFloat(visible) * fieldLineHeight + fieldPadding * 2)
    let border = max(points(1), 1)
    context.setFillColor(palette.pageBackground.cgColor)
    context.addPath(CGPath(roundedRect: field, cornerWidth: points(6), cornerHeight: points(6), transform: nil))
    context.fillPath()
    context.setStrokeColor(palette.focusOutline.cgColor)
    context.setLineWidth(border * 1.5)
    context.addPath(
      CGPath(
        roundedRect: field.insetBy(dx: border * 0.75, dy: border * 0.75), cornerWidth: points(6),
        cornerHeight: points(6), transform: nil))
    context.strokePath()

    let lines = fieldLines(width: panel.width)
    let shown = Array(lines.suffix(Self.maximumFieldLines))
    let textX = field.minX + fieldPadding
    let textRoom = fieldTextWidth(panel.width)
    var caretX = textX
    var caretBand = CGRect(x: textX, y: field.minY + fieldPadding, width: textRoom, height: fieldLineHeight)
    if content.text.isEmpty {
      let placeholder = TextLine(content.prompt, font: fieldFont, truncateTo: textRoom)
      context.setFillColor(palette.statusHintText.cgColor)
      placeholder.draw(in: context, at: CGPoint(x: textX, y: baseline(placeholder, in: caretBand)))
    } else {
      context.setFillColor(palette.statusBarText.cgColor)
      for (index, text) in shown.enumerated() {
        let band = CGRect(
          x: textX, y: field.minY + fieldPadding + CGFloat(index) * fieldLineHeight, width: textRoom,
          height: fieldLineHeight)
        let line = TextLine(text, font: fieldFont)
        line.draw(in: context, at: CGPoint(x: textX, y: baseline(line, in: band)))
        caretBand = band
        caretX = min(textX + line.width + points(1), textX + textRoom)
      }
    }
    let ascent = CTFontGetAscent(fieldFont)
    let descent = CTFontGetDescent(fieldFont)
    let caretHeight = ascent + descent
    context.setFillColor(palette.statusBarText.cgColor)
    context.fill(
      CGRect(
        x: caretX, y: (caretBand.midY - caretHeight / 2).rounded(), width: max(points(1.5), 1), height: caretHeight))
    y = field.maxY + gap

    let footer = TextLine(Self.footer, font: footerFont, truncateTo: room)
    context.setFillColor(palette.statusMutedText.cgColor)
    footer.draw(
      in: context,
      at: CGPoint(
        x: panel.minX + inset, y: baseline(footer, in: CGRect(x: 0, y: y, width: 0, height: footerHeight))))
  }
}
