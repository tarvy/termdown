import AppKit
import CoreGraphics
import CoreText
import TermDownCore

/// One row of the agent picker.
public struct AgentPickerRow: Equatable, Sendable {
  public enum Action: Equatable, Sendable {
    case agent(Int)
    case all
    case startNew
  }

  public var action: Action
  public var label: String
  public var detail: String
  /// The selection goes here now.
  public var current: Bool

  public init(action: Action, label: String, detail: String = "", current: Bool = false) {
    self.action = action
    self.label = label
    self.detail = detail
    self.current = current
  }
}

public struct AgentPickerContent: Equatable, Sendable {
  public var rows: [AgentPickerRow]
  public var selected: Int
  public var title: String

  public init(rows: [AgentPickerRow], selected: Int? = nil, title: String = AgentPicker.title) {
    self.rows = rows
    self.title = title
    let initial = selected ?? rows.firstIndex(where: \.current) ?? 0
    self.selected = min(max(initial, 0), max(rows.count - 1, 0))
  }

  /// The picker's rows: each connected agent, then "All connected agents" when there are several, then "Start a new
  /// agent". `viewerWindow` marks agents in the viewer's own tab. A review goes to one session, so `forReview` drops
  /// the "All connected agents" row.
  public static func make(
    agents: [ConnectedAgent], recipients: [Int], agentCommand: String, windows: [String: String] = [:],
    viewerWindow: String? = nil, forReview: Bool = false
  ) -> AgentPickerContent {
    var rows = agents.map { agent -> AgentPickerRow in
      var notes: [String] = []
      if let block = agent.block, viewerWindow != nil, windows[block] == viewerWindow { notes.append("this tab") }
      if agent.block == nil { notes.append(agent.pid == nil ? "not identified yet" : "outside Rex") }
      if let pid = agent.pid { notes.append("pid \(pid)") }
      let title = agent.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Agent \(agent.id)"
      return AgentPickerRow(
        action: .agent(agent.id), label: title, detail: notes.joined(separator: ", "),
        current: recipients == [agent.id])
    }
    if agents.count > 1, !forReview {
      rows.append(AgentPickerRow(action: .all, label: "All connected agents", current: recipients.count == agents.count))
    }
    rows.append(AgentPickerRow(action: .startNew, label: "Start a new agent beside this viewer", detail: agentCommand))
    return AgentPickerContent(rows: rows, title: forReview ? AgentPicker.reviewTitle : AgentPicker.title)
  }
}

public struct AgentPicker {
  public static let title = "Send highlights to"
  public static let reviewTitle = "Send the review to"
  public static let footer = "1-9 or arrows and Enter to choose, Esc cancels. Lasts while this viewer is open."

  public let content: AgentPickerContent
  public let backingScale: CGFloat

  public init(content: AgentPickerContent, backingScale: CGFloat) {
    self.content = content
    self.backingScale = min(max(backingScale.isFinite ? backingScale : 2, 1), 4)
  }

  public static func label(_ index: Int, _ row: AgentPickerRow) -> String {
    "\(index + 1)  \(row.current ? "●" : "○")  \(row.label)"
  }

  private func points(_ value: CGFloat) -> CGFloat { value * backingScale }

  var rowHeight: CGFloat { points(22) }
  var inset: CGFloat { points(16) }
  var textFont: CTFont { NSFont.systemFont(ofSize: points(12), weight: .regular) as CTFont }

  func footerLines(width: CGFloat) -> [String] {
    wrapped(Self.footer, font: textFont, width: width - inset * 2, maximumLines: 2)
  }

  public func panel(in area: CGRect) -> CGRect {
    let width = max(min(points(620), area.width - points(16)), 0)
    let lines = 1.5 + CGFloat(max(content.rows.count, 1)) + 0.5 + CGFloat(footerLines(width: width).count)
    let height = max(min(rowHeight * lines + inset * 2, area.height - points(16)), 0)
    return CGRect(
      x: (area.midX - width / 2).rounded(), y: (area.midY - height / 2).rounded(), width: width, height: height)
  }

  public func rowRect(_ index: Int, in area: CGRect) -> CGRect {
    let panel = panel(in: area)
    let top = panel.minY + inset + rowHeight * 1.5 + CGFloat(index) * rowHeight
    return CGRect(x: panel.minX + inset / 2, y: top, width: max(panel.width - inset, 0), height: rowHeight)
  }

  public func row(at point: CGPoint, in area: CGRect) -> Int? {
    let panel = panel(in: area)
    return content.rows.indices.first { index in
      let rect = rowRect(index, in: area)
      return rect.contains(point) && rect.maxY <= panel.maxY
    }
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
    let room = panel.width - inset * 2
    func baseline(_ line: TextLine, in band: CGRect) -> CGFloat {
      (band.midY + (line.ascent - line.descent) / 2).rounded()
    }

    let title = TextLine(content.title, font: titleFont, truncateTo: room)
    context.setFillColor(palette.statusBarText.cgColor)
    title.draw(
      in: context,
      at: CGPoint(
        x: panel.minX + inset,
        y: baseline(title, in: CGRect(x: 0, y: panel.minY + inset, width: 0, height: rowHeight))))

    var y = rowRect(0, in: area).minY
    for (index, row) in content.rows.enumerated() {
      let band = rowRect(index, in: area)
      if index == content.selected {
        context.setFillColor(palette.selectionFill.cgColor)
        context.addPath(CGPath(roundedRect: band, cornerWidth: points(4), cornerHeight: points(4), transform: nil))
        context.fillPath()
      }
      let labelWidth = row.detail.isEmpty ? room : room * 0.66
      let label = TextLine(Self.label(index, row), font: labelFont, truncateTo: labelWidth)
      context.setFillColor(row.current ? palette.link.cgColor : palette.statusBarText.cgColor)
      label.draw(in: context, at: CGPoint(x: panel.minX + inset, y: baseline(label, in: band)))
      if !row.detail.isEmpty {
        let detailRoom = max(room - label.width - points(16), 0)
        let detail = TextLine(row.detail, font: textFont, truncateTo: detailRoom, truncation: .middle)
        context.setFillColor(palette.statusMutedText.cgColor)
        detail.draw(in: context, at: CGPoint(x: panel.maxX - inset - detail.width, y: baseline(detail, in: band)))
      }
      y = band.maxY
    }
    y += rowHeight * 0.5
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
