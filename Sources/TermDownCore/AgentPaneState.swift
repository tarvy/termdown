import Foundation

/// Whether a Claude Code pane can take a review pass and Enter, read from `rex capture --format vt --trim`.
///
/// Pressing Enter in the wrong state answers a dialog or sends text the user typed, so `ready` is narrow: the last
/// prompt box (a line starting with `❯` alone between two rules) holds nothing but faint (SGR 2) placeholder text or nothing at
/// all, and no dialog shows under it. Mid-turn with an empty prompt is ready, because Claude Code queues the message.
/// Anything this cannot read for certain is busy.
public enum AgentPaneState: Equatable, Sendable {
  case ready, busy

  static let prompt: Character = "❯"
  static let rule: Character = "─"
  static let ideChipMark: Character = "⧉"
  static let minimumRule = 10
  static let maximumMove = 1000
  /// Words Claude Code shows in a menu or dialog drawn under the prompt box.
  static let dialogMarkers = ["Enter to confirm", "Esc to cancel", "Do you want to"]

  /// One screen cell: its character and whether it is drawn faint.
  struct Cell {
    var character: Character
    var faint: Bool
  }

  public static func classify(vt: String) -> AgentPaneState {
    // Exactly one line in the box: a second line is a typed newline.
    guard let box = parse(vt).flatMap(lastPromptBox), box.count == 1, let line = box.first,
      promptText(line).allSatisfy({ isBlank($0.character) || $0.faint })
    else { return .busy }
    return .ready
  }

  /// Whether the last prompt box holds text that is not faint placeholder, with no dialog on screen: how a paste shows
  /// it landed. A dialog or an unreadable screen is false, so Enter never goes to it.
  public static func promptHoldsText(vt: String) -> Bool {
    guard let box = parse(vt).flatMap(lastPromptBox) else { return false }
    let cells = promptText(box[box.startIndex]) + box.dropFirst().joined()
    return cells.contains { !isBlank($0.character) && !$0.faint }
  }

  /// Whether a dialog or menu shows under the last rule (anywhere, with no rule), or the screen cannot be read: after a
  /// paste that did not land, this says why. Words above the prompt box are history, not a dialog.
  public static func showsDialog(vt: String) -> Bool {
    guard let lines = parse(vt) else { return true }
    let below = lines.indices.last { isRule(lines[$0]) }.map { lines[($0 + 1)...] } ?? lines[...]
    return below.map(text).contains { line in dialogMarkers.contains { line.contains($0) } }
  }

  /// The lines between the last two rules when the first starts with `❯` in its first cell and no dialog shows under
  /// the box. A dialog's selected option (` ❯ 1. Yes`) is indented, so it is never taken for the prompt.
  static func lastPromptBox(_ lines: [[Cell]]) -> ArraySlice<[Cell]>? {
    let rules = lines.indices.filter { isRule(lines[$0]) }
    guard rules.count >= 2 else { return nil }
    let top = rules[rules.count - 2]
    let bottom = rules[rules.count - 1]
    guard bottom - top >= 2, lines[top + 1].first?.character == prompt else { return nil }
    let below = lines[(bottom + 1)...].map(text)
    if below.contains(where: { line in dialogMarkers.contains { line.contains($0) } }) { return nil }
    return lines[(top + 1)..<bottom]
  }

  /// The screen as lines of cells, or nil when it holds an escape sequence other than SGR (`m`), cursor-forward (`C`)
  /// and OSC 8, which is all a trimmed capture uses. An OSC 8 hyperlink (Claude Code draws a pasted image's
  /// `[Image #1]` as one) draws nothing itself, so it is dropped; the linked text stays as cells.
  static func parse(_ vt: String) -> [[Cell]]? {
    var lines: [[Cell]] = [[]]
    var faint = false
    var scalars = vt.unicodeScalars[...]
    while let scalar = scalars.popFirst() {
      switch scalar {
      case "\u{1b}":
        let introducer = scalars.popFirst()
        if introducer == "]" {
          guard skipOSC(&scalars) else { return nil }
          continue
        }
        guard introducer == "[" else { return nil }
        var parameters = ""
        var final: Unicode.Scalar?
        while let next = scalars.popFirst() {
          if (0x40...0x7e).contains(next.value) {
            final = next
            break
          }
          parameters.unicodeScalars.append(next)
        }
        switch final {
        case "m": faint = applySGR(parameters, faint: faint)
        case "C":
          guard let count = parameters.isEmpty ? 1 : Int(parameters), (0...maximumMove).contains(count) else {
            return nil
          }
          lines[lines.count - 1] += Array(repeating: Cell(character: " ", faint: faint), count: count)
        default: return nil
        }
      case "\n": lines.append([])
      case "\r": continue
      default:
        guard scalar.value >= 0x20 else { return nil }
        lines[lines.count - 1].append(Cell(character: Character(scalar), faint: faint))
      }
    }
    return lines
  }

  /// Drops an OSC 8 hyperlink through its terminator, BEL or ST (`ESC \`). False for any other OSC, or when the screen
  /// ends first.
  static func skipOSC(_ scalars: inout Substring.UnicodeScalarView.SubSequence) -> Bool {
    guard scalars.starts(with: "8;".unicodeScalars) else { return false }
    while let next = scalars.popFirst() {
      if next == "\u{7}" { return true }
      if next == "\u{1b}" { return scalars.popFirst() == "\\" }
    }
    return false
  }

  /// The faint flag after an SGR sequence. Extended colors (`38;5;n`, `38;2;r;g;b`) are skipped whole, so a `2` in
  /// them is not taken for faint.
  static func applySGR(_ parameters: String, faint: Bool) -> Bool {
    if parameters.isEmpty { return false }
    var faint = faint
    var codes = parameters.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) }[...]
    while let code = codes.popFirst() {
      switch code {
      // An unknown code clears faint: that can only make the pane read busy.
      case 0?, nil: faint = false
      case 2?: faint = true
      case 22?: faint = false
      case 38?, 48?, 58?:
        switch codes.popFirst() {
        case 5??: codes = codes.dropFirst(1)
        case 2??: codes = codes.dropFirst(3)
        default: break
        }
      default: break
      }
    }
    return faint
  }

  static func text(_ line: [Cell]) -> String { String(line.map(\.character)) }

  static func isBlank(_ character: Character) -> Bool { character == " " || character == "\u{a0}" }

  /// A run of at least `minimumRule` rule characters that also ends in one. Claude Code writes a named session's name
  /// into the prompt box's top rule (`──── my session ─`), so text inside the rule is allowed.
  static func isRule(_ line: [Cell]) -> Bool {
    let visible = line.map(\.character).filter { !isBlank($0) }
    return visible.prefix { $0 == rule }.count >= minimumRule && visible.last == rule
  }

  /// The cells after the `❯` of a prompt line, less a leading IDE-context chip.
  static func promptText(_ line: [Cell]) -> ArraySlice<Cell> {
    guard let start = line.firstIndex(where: { $0.character == prompt }) else { return [] }
    return withoutIDEChip(line[(start + 1)...])
  }

  /// Claude Code starts the prompt box with `[⧉ In live.md]` or `[⧉ 1 line selected]` while an IDE such as this
  /// preview is connected. Only that one leading segment, `[⧉` through its matching `]`, is dropped; any other text,
  /// bracketed or not, stays and reads as typed. The colour is not part of the test.
  static func withoutIDEChip(_ cells: ArraySlice<Cell>) -> ArraySlice<Cell> {
    guard let open = cells.firstIndex(where: { !isBlank($0.character) }), cells[open].character == "[",
      cells.index(after: open) < cells.endIndex, cells[cells.index(after: open)].character == ideChipMark
    else { return cells }
    var depth = 0
    for index in cells[open...].indices {
      switch cells[index].character {
      case "[": depth += 1
      case "]":
        depth -= 1
        if depth == 0 { return cells[cells.index(after: index)...] }
      default: break
      }
    }
    return cells
  }
}
