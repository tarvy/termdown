import AppKit
import CoreGraphics
import CoreText
import TermDownCore

public struct ScrollProgress: Hashable, Sendable {
  public var start: CGFloat
  public var fraction: CGFloat

  public init(start: CGFloat, fraction: CGFloat) {
    self.start = min(max(start, 0), 1)
    self.fraction = min(max(fraction, 0), 1 - self.start)
  }

  public init(offset: CGFloat, viewport: CGFloat, content: CGFloat) {
    guard content > 0, viewport > 0 else {
      self.init(start: 0, fraction: 1)
      return
    }
    self.init(start: offset / content, fraction: viewport / content)
  }
}

public struct StatusMessage: Hashable, Sendable {
  public enum Kind: Hashable, Sendable {
    case info, find, success, error
  }

  public var text: String
  public var kind: Kind

  public init(_ text: String, kind: Kind = .info) {
    self.text = text
    self.kind = kind
  }
}

/// One key of the review legend: the digit, its label, a short form for narrow bars and its hex color.
public struct LegendEntry: Hashable, Sendable {
  public var key: String
  public var label: String
  public var short: String?
  public var color: String

  public init(key: String, label: String, short: String? = nil, color: String) {
    self.key = key
    self.label = label
    self.short = short
    self.color = color
  }
}

/// What the status bar shows on the right while a review is on, in place of the key hints.
public struct ReviewBarContent: Hashable, Sendable {
  public var legend: [LegendEntry]
  public var marks: Int

  public init(legend: [LegendEntry], marks: Int) {
    self.legend = legend
    self.marks = marks
  }
}

public struct StatusBarContent: Hashable, Sendable {
  public var fileName: String
  public var folder: String?
  public var progress: ScrollProgress
  public var message: StatusMessage?
  public var hint: String?
  public var findField: String?
  public var editor: String?
  /// The connected agent's pane title, or nil when none is connected. Only the plug is drawn for it.
  public var agent: String?
  /// Who the draft is for, drawn before the folder.
  public var client: String?
  public var review: ReviewBarContent?

  public init(
    fileName: String, folder: String? = nil, progress: ScrollProgress, message: StatusMessage? = nil,
    hint: String? = nil, findField: String? = nil, editor: String? = nil, agent: String? = nil,
    client: String? = nil, review: ReviewBarContent? = nil
  ) {
    self.fileName = fileName
    self.folder = folder
    self.progress = progress
    self.message = message
    self.hint = hint
    self.findField = findField
    self.editor = editor
    self.agent = agent
    self.client = client
    self.review = review
  }
}

public struct StatusBar {
  public static let preferredPointHeight: CGFloat = 22
  public static let minimumPointHeight: CGFloat = 16

  public let palette: RenderPalette
  public let backingScale: CGFloat

  public init(palette: RenderPalette, backingScale: CGFloat) {
    self.palette = palette
    self.backingScale = min(max(backingScale.isFinite ? backingScale : 2, 1), 4)
  }

  public static func height(cellPixelHeight: CGFloat, backingScale: CGFloat) -> CGFloat {
    let scale = min(max(backingScale.isFinite ? backingScale : 2, 1), 4)
    let preferred = preferredPointHeight * scale
    guard cellPixelHeight.isFinite, cellPixelHeight > 0 else { return preferred.rounded() }
    let rows = max(
      (preferred / cellPixelHeight).rounded(), (minimumPointHeight * scale / cellPixelHeight).rounded(.up), 1)
    return rows * cellPixelHeight
  }

  public static let keyHintTiers = ["/ find   e edit   r refresh   q quit   ? help", "e edit   ? help"]
  public static var keyHints: String { keyHintTiers[0] }

  private func points(_ value: CGFloat) -> CGFloat { value * backingScale }

  struct Metrics {
    var body: CGRect
    var fontSize: CGFloat
    var padding: CGFloat
    var gap: CGFloat
    var hintFont: CTFont
    var hints: TextLine
    var hintsX: CGFloat
    var showsHints: Bool
  }

  func metrics(in rect: CGRect) -> Metrics { metrics(in: rect, reserving: 0) }

  /// Metrics for what is shown: a client label never drops, so the key hints narrow or go first to leave it, and a
  /// sliver of the file name, its room.
  func metrics(in rect: CGRect, for content: StatusBarContent) -> Metrics {
    guard let client = content.client, !client.isEmpty else { return metrics(in: rect) }
    let fontSize = metrics(in: rect).fontSize
    let label = TextLine(
      client + Self.clientSeparator, font: NSFont.systemFont(ofSize: fontSize, weight: .regular) as CTFont)
    let name = TextLine(content.fileName, font: NSFont.systemFont(ofSize: fontSize, weight: .semibold) as CTFont)
    return metrics(in: rect, reserving: label.width + min(name.width, points(48)))
  }

  private func metrics(in rect: CGRect, reserving reserve: CGFloat) -> Metrics {
    let trackHeight = max(points(2).rounded(), 1)
    let body = CGRect(x: rect.minX, y: rect.minY + trackHeight, width: rect.width, height: rect.height - trackHeight)
    let fontSize = min(max(body.height * 0.5, points(11)), points(13))
    let padding = points(10)
    let hintFont = NSFont.systemFont(ofSize: fontSize * 0.92, weight: .regular) as CTFont
    let tiers = Self.keyHintTiers.map { TextLine($0, font: hintFont) }
    let fitting = tiers.first { $0.width <= rect.width - padding * 2 - (reserve > 0 ? points(12) + reserve : 0) }
    let hints = fitting ?? tiers[tiers.count - 1]
    return Metrics(
      body: body, fontSize: fontSize, padding: padding, gap: points(12), hintFont: hintFont, hints: hints,
      hintsX: rect.maxX - padding - hints.width, showsHints: fitting != nil)
  }

  public func keyHintsRect(in rect: CGRect) -> CGRect {
    let metrics = metrics(in: rect)
    guard metrics.showsHints else { return .null }
    return CGRect(x: metrics.hintsX, y: metrics.body.minY, width: metrics.hints.width, height: metrics.body.height)
  }

  /// The key hints' rect for this content: none while a review shows its legend there.
  public func keyHintsRect(_ content: StatusBarContent, in rect: CGRect) -> CGRect {
    guard content.review == nil else { return .null }
    let metrics = metrics(in: rect, for: content)
    guard metrics.showsHints else { return .null }
    return CGRect(x: metrics.hintsX, y: metrics.body.minY, width: metrics.hints.width, height: metrics.body.height)
  }

  /// The legend keys' rects in bar coordinates, left to right, for hit testing. Empty without a review or when even
  /// the digits do not fit.
  public func legendRects(_ content: StatusBarContent, in rect: CGRect) -> [(key: String, rect: CGRect)] {
    legendLayout(content, in: rect, metrics: metrics(in: rect))?.items.map { ($0.key, $0.rect) } ?? []
  }

  struct LegendLayout {
    struct Item {
      var key: String
      var rect: CGRect
      var digit: TextLine
      var label: TextLine?
      var labelX: CGFloat
      var color: RGB
    }

    var x: CGFloat
    var items: [Item]
    var trailer: TextLine
    var trailerX: CGFloat
  }

  static let legendFallbackColor = RGB(hex: 0x9ca3af)

  /// The first word of each label, so `Note...` and `Source?` become `Note` and `Source`. A label whose short form
  /// an earlier one already took gets a `+`, so `Shorten` and `Shorten a lot` read `Shorten` and `Shorten+`.
  static func shortLabels(_ labels: [String]) -> [String] {
    var taken = Set<String>()
    return labels.map { full in
      let word = full.split(separator: " ").first.map { String($0).trimmingCharacters(in: .punctuationCharacters) }
      var short = word.flatMap { $0.isEmpty ? nil : $0 } ?? full
      while !taken.insert(short).inserted { short += "+" }
      return short
    }
  }

  private func plugIconSize(_ fontSize: CGFloat) -> CGFloat { fontSize * 0.9 }

  /// The pill at the left of the bar that says review is on.
  static let reviewBadgeText = "IR"

  func reviewBadge(fontSize: CGFloat) -> (line: TextLine, width: CGFloat, height: CGFloat) {
    let line = TextLine(
      Self.reviewBadgeText, font: NSFont.systemFont(ofSize: fontSize * 0.78, weight: .bold) as CTFont)
    return (line, line.width + points(6) * 2, fontSize * 1.25)
  }

  /// The review keys after the legend, widest first; the count of marks leads each.
  static func reviewTrailers(marks: Int) -> [String] {
    let count = marks == 1 ? "1 mark" : "\(marks) marks"
    return [
      "\(count)   M list   U undo   x clear   D changes   s send", "\(marks)   M list   U undo   D changes   s send",
      "\(marks)   M list   s send", "\(marks)   s send", "\(marks)   s",
    ]
  }

  /// The widest legend tier that leaves the review badge, plug, client and a sliver of the file name their room: full
  /// labels with every review key, then short labels with fewer keys, then digits only. The file name and its folder
  /// fill whatever is left, truncating first. When not even the narrowest tier fits the bar, there is no legend.
  func legendLayout(_ content: StatusBarContent, in rect: CGRect, metrics: Metrics) -> LegendLayout? {
    guard let review = content.review else { return nil }
    let nameFont = NSFont.systemFont(ofSize: metrics.fontSize, weight: .semibold) as CTFont
    let folderFont = NSFont.systemFont(ofSize: metrics.fontSize, weight: .regular) as CTFont
    var essentials = min(TextLine(content.fileName, font: nameFont).width, points(48))
    essentials += reviewBadge(fontSize: metrics.fontSize).width + points(8)
    if let client = content.client, !client.isEmpty {
      essentials += TextLine(client + Self.clientSeparator, font: folderFont).width
    }
    if content.agent != nil { essentials += points(8) + plugIconSize(metrics.fontSize) }
    let digitFont = NSFont.systemFont(ofSize: metrics.fontSize * 0.92, weight: .semibold) as CTFont
    let digitGap = points(5)
    let trailers = Self.reviewTrailers(marks: review.marks)
    let labels = review.legend.map(\.label)
    let fallback = Self.shortLabels(labels)
    let short = review.legend.enumerated().map { $0.element.short ?? fallback[$0.offset] }
    let room = rect.width - metrics.padding * 2
    // (labels: 0 full, 1 short, 2 none; which trailer)
    let tiers: [(labels: Int, trailer: Int)] = [(0, 0), (1, 0), (1, 1), (1, 2), (2, 2), (2, 3), (2, 4)]

    func build(_ tier: (labels: Int, trailer: Int)) -> LegendLayout {
      let digitsOnly = tier.labels == 2
      let spacing = digitsOnly ? points(5) : points(10)
      var cursor: CGFloat = 0
      var items: [LegendLayout.Item] = []
      for (index, entry) in review.legend.enumerated() {
        let digit = TextLine(entry.key, font: digitFont)
        let label = digitsOnly ? nil : TextLine(tier.labels == 0 ? labels[index] : short[index], font: metrics.hintFont)
        let width = digit.width + (label.map { digitGap + $0.width } ?? 0)
        let color = parseHexColor(entry.color) ?? Self.legendFallbackColor
        items.append(
          LegendLayout.Item(
            key: entry.key, rect: CGRect(x: cursor, y: metrics.body.minY, width: width, height: metrics.body.height),
            digit: digit, label: label, labelX: cursor + digit.width + digitGap, color: color))
        cursor += width + spacing
      }
      let trailer = TextLine(trailers[tier.trailer], font: metrics.hintFont)
      let trailerX = review.legend.isEmpty ? 0 : cursor - spacing + (digitsOnly ? points(12) : points(16))
      let total = trailerX + trailer.width
      let origin = rect.maxX - metrics.padding - total
      for index in items.indices {
        items[index].rect.origin.x += origin
        items[index].labelX += origin
      }
      return LegendLayout(x: origin, items: items, trailer: trailer, trailerX: origin + trailerX)
    }

    let built = tiers.map(build)
    if let fitting = built.first(where: { rect.maxX - metrics.padding - $0.x + metrics.gap + essentials <= room }) {
      return fitting
    }
    let narrowest = built[built.count - 1]
    return rect.maxX - metrics.padding - narrowest.x <= room ? narrowest : nil
  }

  static let clientSeparator = " \u{00B7} "

  public func draw(_ content: StatusBarContent, in rect: CGRect, bitmap: RasterBitmap) {
    let context = bitmap.context
    context.saveGState()
    defer { context.restoreGState() }
    context.translateBy(x: 0, y: CGFloat(bitmap.height))
    context.scaleBy(x: 1, y: -1)
    context.clip(to: rect)
    context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    draw(content, in: rect, context: context)
  }

  func draw(_ content: StatusBarContent, in rect: CGRect, context: CGContext) {
    context.setFillColor(palette.statusBarBackground.cgColor)
    context.fill(rect)

    let trackHeight = max(points(2).rounded(), 1)
    context.setFillColor(palette.progressTrack.cgColor)
    context.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: trackHeight))
    let minimumThumb = min(points(14), rect.width)
    let thumbWidth = max(rect.width * content.progress.fraction, minimumThumb)
    let thumbX = rect.minX + min(rect.width * content.progress.start, rect.width - thumbWidth)
    let thumb = CGRect(x: thumbX, y: rect.minY, width: thumbWidth, height: trackHeight)
    context.setFillColor(palette.progressFill.cgColor)
    context.addPath(
      CGPath(roundedRect: thumb, cornerWidth: trackHeight / 2, cornerHeight: trackHeight / 2, transform: nil))
    context.fillPath()

    let metrics = metrics(in: rect, for: content)
    let body = metrics.body
    let fontSize = metrics.fontSize
    let padding = metrics.padding
    let gap = metrics.gap
    let textColor = palette.statusBarText
    func baseline(_ line: TextLine) -> CGFloat { (body.midY + (line.ascent - line.descent) / 2).rounded() }

    var right = rect.maxX - padding
    if content.review != nil {
      if let legend = legendLayout(content, in: rect, metrics: metrics) {
        for item in legend.items {
          context.setFillColor(item.color.cgColor)
          item.digit.draw(in: context, at: CGPoint(x: item.rect.minX, y: baseline(item.digit)))
          if let label = item.label {
            context.setFillColor(palette.statusHintText.cgColor)
            label.draw(in: context, at: CGPoint(x: item.labelX, y: baseline(label)))
          }
        }
        context.setFillColor(palette.statusHintText.cgColor)
        legend.trailer.draw(in: context, at: CGPoint(x: legend.trailerX, y: baseline(legend.trailer)))
        right = legend.x - gap
      }
    } else if metrics.showsHints {
      context.setFillColor(palette.statusHintText.cgColor)
      metrics.hints.draw(in: context, at: CGPoint(x: metrics.hintsX, y: baseline(metrics.hints)))
      right = metrics.hintsX - gap
    }
    if let message = content.message {
      let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium) as CTFont
      let line = TextLine(
        message.text, font: font, truncateTo: max(min(rect.width * 0.4, right - rect.minX - padding - points(40)), 0))
      let color: RGB =
        switch message.kind {
        case .info, .find: textColor
        case .success: palette.alerts.tip
        case .error: palette.alerts.caution
        }
      let glyphs = Glyphs(context: context, hairline: max(1, backingScale.rounded()))
      let iconSize = fontSize * 0.8
      let hasIcon = message.kind != .info
      let pillWidth = line.width + points(8) * 2 + (hasIcon ? iconSize + points(5) : 0)
      let pillHeight = min(body.height - points(4), fontSize * 1.6)
      let pill = CGRect(
        x: right - pillWidth, y: (body.midY - pillHeight / 2).rounded(), width: pillWidth, height: pillHeight)
      context.setFillColor(palette.progressTrack.cgColor(alpha: 0.6))
      context.addPath(
        CGPath(roundedRect: pill, cornerWidth: pillHeight / 2, cornerHeight: pillHeight / 2, transform: nil))
      context.fillPath()
      var x = pill.minX + points(8)
      if hasIcon {
        let icon = CGRect(x: x, y: body.midY - iconSize / 2, width: iconSize, height: iconSize)
        switch message.kind {
        case .find: glyphs.magnifier(in: icon, color: color.cgColor)
        case .success: glyphs.check(in: icon, color: color.cgColor)
        case .error: glyphs.alertIcon(.caution, in: icon, color: color.cgColor)
        case .info: break
        }
        x = icon.maxX + points(5)
      }
      context.setFillColor(color.cgColor)
      line.draw(in: context, at: CGPoint(x: x, y: baseline(line)))
      right = pill.minX - gap
    }

    if let query = content.findField {
      let geometry = findField(query, right: right, in: rect)
      let field = geometry.field
      context.setFillColor(palette.pageBackground.cgColor)
      context.addPath(CGPath(roundedRect: field, cornerWidth: points(4), cornerHeight: points(4), transform: nil))
      context.fillPath()
      context.setStrokeColor(palette.focusOutline.cgColor)
      context.setLineWidth(geometry.border)
      context.addPath(
        CGPath(
          roundedRect: field.insetBy(dx: geometry.border / 2, dy: geometry.border / 2), cornerWidth: points(4),
          cornerHeight: points(4), transform: nil))
      context.strokePath()
      Glyphs(context: context, hairline: max(1, backingScale.rounded())).magnifier(
        in: geometry.icon, color: palette.statusMutedText.cgColor)
      context.setFillColor(textColor.cgColor)
      geometry.line.draw(in: context, at: CGPoint(x: geometry.textX, y: geometry.baseline))
      context.fill(geometry.caret)
      right = field.minX - gap
    }

    let nameFont = NSFont.systemFont(ofSize: fontSize, weight: .semibold) as CTFont
    let folderFont = NSFont.systemFont(ofSize: fontSize, weight: .regular) as CTFont
    var available = max(right - (rect.minX + padding), 0)
    let fullName = TextLine(content.fileName, font: nameFont)
    // Review on: a badge at the far left says so; it is reserved before anything else on the left.
    var badgePill: (line: TextLine, width: CGFloat, height: CGFloat)?
    if content.review != nil {
      let pill = reviewBadge(fontSize: fontSize)
      if available >= pill.width + points(8) {
        badgePill = pill
        available -= pill.width + points(8)
      }
    }
    // The plug and the client never drop: the plug is reserved first, then the client, which gives up room down to a
    // sliver of the file name.
    let plugGap = points(8)
    let plugSize = plugIconSize(fontSize)
    let showsPlug = content.agent != nil && available >= plugGap + plugSize
    if showsPlug { available -= plugGap + plugSize }
    var clientLine: TextLine?
    if let client = content.client, !client.isEmpty {
      let nameRoom = min(fullName.width, points(48))
      let line = TextLine(
        client + Self.clientSeparator, font: folderFont,
        truncateTo: max(available - nameRoom, min(available, points(40))))
      clientLine = line
      available = max(available - line.width, 0)
    }
    var badge: TextLine?
    if let editor = content.editor, !editor.isEmpty {
      let line = TextLine(editor, font: folderFont)
      if available - line.width - gap >= points(40) {
        badge = line
        available -= line.width + gap
      }
    }
    let name = TextLine(content.fileName, font: nameFont, truncateTo: available, truncation: .middle)
    // A name squeezed to less than an ellipsis is left out rather than drawn over its neighbours.
    let showsName = available >= points(8)
    // Spare room goes to the folder. The agent's title is never drawn: the plug says one is connected, and `A` names it.
    let spare = available - name.width
    var x = rect.minX + padding
    if let badgePill {
      let pill = CGRect(
        x: x, y: (body.midY - badgePill.height / 2).rounded(), width: badgePill.width, height: badgePill.height)
      context.setFillColor(palette.focusOutline.cgColor)
      context.addPath(CGPath(roundedRect: pill, cornerWidth: points(4), cornerHeight: points(4), transform: nil))
      context.fillPath()
      context.setFillColor(palette.statusBarBackground.cgColor)
      badgePill.line.draw(in: context, at: CGPoint(x: pill.minX + points(6), y: baseline(badgePill.line)))
      x = pill.maxX + points(8)
    }
    if let clientLine {
      context.setFillColor(palette.statusMutedText.cgColor)
      clientLine.draw(in: context, at: CGPoint(x: x, y: baseline(clientLine)))
      x += clientLine.width
    }
    if let folder = content.folder, !folder.isEmpty {
      let separator = TextLine(" \u{203A} ", font: folderFont)
      // The folder shows whole when the room is spare, never cut to an ellipsis: the abbreviated path, else the
      // file's own folder alone, else nothing.
      let candidates = [folder, folder.split(separator: "/").last.map(String.init)].compactMap { $0 }
      if let folderLine = candidates.lazy.map({ TextLine($0, font: folderFont) })
        .first(where: { $0.width <= spare - separator.width })
      {
        context.setFillColor(palette.statusMutedText.cgColor)
        folderLine.draw(in: context, at: CGPoint(x: x, y: baseline(folderLine)))
        x += folderLine.width
        context.setFillColor(palette.statusHintText.cgColor)
        separator.draw(in: context, at: CGPoint(x: x, y: baseline(separator)))
        x += separator.width
      }
    }
    if showsName {
      context.setFillColor(textColor.cgColor)
      name.draw(in: context, at: CGPoint(x: x, y: baseline(name)))
      x += name.width
    }
    if showsPlug {
      x += plugGap
      let icon = CGRect(x: x, y: (body.midY - plugSize / 2).rounded(), width: plugSize, height: plugSize)
      Glyphs(context: context, hairline: max(1, backingScale.rounded())).plug(
        in: icon, color: palette.alerts.tip.cgColor)
      x += plugSize
    }
    if let badge {
      x += gap
      context.setFillColor(palette.statusMutedText.cgColor)
      badge.draw(in: context, at: CGPoint(x: x, y: baseline(badge)))
      x += badge.width
    }

    if let hint = content.hint, !hint.isEmpty {
      let line = TextLine(hint, font: metrics.hintFont)
      if line.width <= right - x - gap {
        context.setFillColor(palette.statusHintText.cgColor)
        line.draw(in: context, at: CGPoint(x: right - line.width, y: baseline(line)))
      }
    }
  }

  struct FindFieldGeometry {
    var field: CGRect
    var icon: CGRect
    var line: TextLine
    var textX: CGFloat
    var baseline: CGFloat
    var caret: CGRect
    var border: CGFloat
  }

  func findField(_ query: String, right: CGFloat, in rect: CGRect) -> FindFieldGeometry {
    let metrics = metrics(in: rect)
    let body = metrics.body
    let fontSize = metrics.fontSize
    let font = NSFont.systemFont(ofSize: fontSize, weight: .regular) as CTFont
    let iconSize = fontSize * 0.8
    let inner = points(6)
    let caretWidth = max(points(1), 1)
    let border = max(points(1), 1)
    let maximumWidth = max(rect.width * 0.45, points(80))
    let textRoom = maximumWidth - inner * 3 - iconSize - caretWidth
    let line = TextLine(query, font: font, truncateTo: max(textRoom, 0), truncation: .start)
    let fieldWidth = min(max(inner * 3 + iconSize + line.width + caretWidth, rect.width * 0.25), maximumWidth)
    let fieldHeight = min(body.height - points(4), fontSize * 1.6)
    let field = CGRect(
      x: max(right - fieldWidth, rect.minX + metrics.padding), y: (body.midY - fieldHeight / 2).rounded(),
      width: fieldWidth, height: fieldHeight)
    let icon = CGRect(x: field.minX + inner, y: body.midY - iconSize / 2, width: iconSize, height: iconSize)
    let textX = icon.maxX + inner
    let ascent = CTFontGetAscent(font)
    let descent = CTFontGetDescent(font)
    let baseline = (body.midY + (ascent - descent) / 2).rounded()
    let inside = field.insetBy(dx: 0, dy: border + max(points(2), 1))
    let top = max(baseline - ascent, inside.minY)
    let bottom = min(baseline + descent, inside.maxY)
    let caret = CGRect(
      x: textX + line.width + points(1), y: top, width: caretWidth, height: max(bottom - top, 1))
    return FindFieldGeometry(
      field: field, icon: icon, line: line, textX: textX, baseline: baseline, caret: caret, border: border)
  }
}
