import Foundation
import TermDownCore

/// Rex gives a new pane a placeholder size and its window client sizes it a moment later. A pane created while its
/// window is hidden is never sized, so the viewer would paint a 640x384 page stretched over the whole pane. Rex applies
/// a resize to a block no client owns at once, so the viewer asks for the size a sized sibling implies.
public enum PaneNudge {
  public struct Request: Equatable, Sendable {
    public var columns: Int
    public var rows: Int
    public var cellWidth: Int
    public var cellHeight: Int

    public var json: String {
      "{\"columns\":\(columns),\"rows\":\(rows),\"cell_width_px\":\(cellWidth),\"cell_height_px\":\(cellHeight)}"
    }
  }

  public static let placeholder = PaneSize(columns: 80, rows: 24, pixelWidth: 640, pixelHeight: 384)

  struct Placement {
    var block: String
    var window: String
    var rect: [Double]
  }

  static func placements(view: Data) -> [Placement] {
    guard let root = try? JSONSerialization.jsonObject(with: view) as? [String: Any],
      let windows = root["windows"] as? [[String: Any]]
    else { return [] }
    var found: [Placement] = []
    func walk(_ node: [String: Any], window: String) {
      if let block = node["block_id"] as? String, let rect = node["rect"] as? [Double], rect.count == 4 {
        found.append(Placement(block: block, window: window, rect: rect))
      }
      if let split = node["split"] as? [String: Any] {
        for side in ["before", "after"] {
          if let child = split[side] as? [String: Any] { walk(child, window: window) }
        }
      }
    }
    for window in windows {
      let id = window["window_id"] as? String ?? ""
      for layer in window["layers"] as? [[String: Any]] ?? [] {
        if let layout = layer["layout"] as? [String: Any] { walk(layout, window: id) }
      }
    }
    return found
  }

  /// The other blocks in the session, those in this block's window first.
  public static func siblings(view: Data, block: String) -> [String] {
    let all = placements(view: view)
    guard let mine = all.first(where: { $0.block == block }) else { return [] }
    let others = all.filter { $0.block != block }
    return (others.filter { $0.window == mine.window } + others.filter { $0.window != mine.window }).map(\.block)
  }

  /// True when no client owns the block or has asked for a size, the state a pane in a hidden window is left in.
  public static func unsized(_ size: Data) -> Bool {
    guard let object = try? JSONSerialization.jsonObject(with: size) as? [String: Any] else { return false }
    let owner = object["owner"] as? String
    let desired = object["desired"] as? [Any] ?? []
    return (owner?.isEmpty ?? true) && desired.isEmpty
  }

  struct Implied {
    var width: Double
    var height: Double
    var cellWidth: Int
    var cellHeight: Int
    var sameWindow: Bool
    var area: Double
    var updatedAt: String

    func agrees(with other: Implied) -> Bool {
      abs(width - other.width) <= 0.05 * max(width, other.width)
        && abs(height - other.height) <= 0.05 * max(height, other.height)
    }
  }

  /// A client can leave a stale desired size on a pane whose layout changed since, and other windows may sit on another
  /// display. So a pane in this window wins, the one most sized panes agree on and then the largest; failing that, the
  /// pane in another window a client sized most recently.
  public static func request(view: Data, block: String, sizes: [String: Data]) -> Request? {
    let all = placements(view: view)
    guard let mine = all.first(where: { $0.block == block }), mine.rect[2] > 0, mine.rect[3] > 0 else { return nil }
    let implied: [Implied] = siblings(view: view, block: block).compactMap { sibling in
      guard let data = sizes[sibling], let placement = all.first(where: { $0.block == sibling }),
        placement.rect[2] > 0, placement.rect[3] > 0,
        let size = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let desired = size["desired"] as? [[String: Any]], !desired.isEmpty,
        let columns = size["columns"] as? Int, let rows = size["rows"] as? Int,
        let cellWidth = size["cell_width_px"] as? Int, let cellHeight = size["cell_height_px"] as? Int,
        cellWidth > 0, cellHeight > 0
      else { return nil }
      return Implied(
        width: Double(columns * cellWidth) / placement.rect[2], height: Double(rows * cellHeight) / placement.rect[3],
        cellWidth: cellWidth, cellHeight: cellHeight, sameWindow: placement.window == mine.window,
        area: placement.rect[2] * placement.rect[3],
        updatedAt: desired.compactMap { $0["updated_at"] as? String }.max() ?? "")
    }
    let local = implied.filter(\.sameWindow)
    let best =
      local.max { (implied.filter($0.agrees).count, $0.area) < (implied.filter($1.agrees).count, $1.area) }
      ?? implied.max { $0.updatedAt < $1.updatedAt }
    guard let best else { return nil }
    return Request(
      columns: max(1, Int(best.width * mine.rect[2] / Double(best.cellWidth))),
      rows: max(1, Int(best.height * mine.rect[3] / Double(best.cellHeight))), cellWidth: best.cellWidth,
      cellHeight: best.cellHeight)
  }

  /// Runs the rex calls and asks for the derived size. Blocking; call it off the main thread.
  public static func run(
    rexPath: String, session: String, block: String, runner: ProcessRunning, log: @Sendable (String) -> Void
  ) {
    func rex(_ arguments: [String]) -> Data? {
      guard let result = try? runner.run(rexPath, arguments, timeout: EditorCoordinator.rexTimeout),
        result.status == 0
      else { return nil }
      return result.stdout
    }
    guard let own = rex(["block", "call", "-b", block, "size"]), unsized(own) else { return }
    guard let view = rex(["api", "call", "-s", session, "session.view"]) else {
      log("pane size: could not read the session view")
      return
    }
    var sizes: [String: Data] = [:]
    for sibling in siblings(view: view, block: block) {
      sizes[sibling] = rex(["block", "call", "-b", sibling, "size"])
    }
    guard let wanted = request(view: view, block: block, sizes: sizes) else {
      log("pane size: Rex never sized this pane and no sized pane to derive a size from")
      return
    }
    let asked = rex(["block", "call", "-b", block, "resize", wanted.json]) != nil
    log("pane size: Rex left this pane at 80x24; \(asked ? "asked for" : "could not ask for") \(wanted.json)")
  }
}
