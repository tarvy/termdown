import Foundation

/// What changed in a draft since the last review pass was sent, and which of that pass's asks got no change. A port
/// of review.py's `applied_changes`: the baseline is the newest submit record in the review log (never a launch,
/// whose snapshot is taken after the agent applied the pass), and positions are line numbers in the current draft.
public struct AppliedChanges: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case replace, insert, delete
  }

  /// One run of changed lines. `lines` is nil for a deletion, which has no line in the current text to mark;
  /// `anchor` is then the line now sitting where the deletion was.
  public struct Hunk: Equatable, Sendable {
    public var kind: Kind
    public var lines: ClosedRange<Int>?
    public var anchor: Int
    public var removed: String
    public var added: String
    /// The asks from the last pass that land on this hunk's lines; adjacent edits share one hunk.
    public var asks: [ReviewAnnotation]
  }

  public static let maxHunks = 40
  public static let maxQuote = 400

  public var fromPass: Int
  /// At most `maxHunks`; `more` counts the rest.
  public var hunks: [Hunk]
  public var more: Int
  /// Asks whose lines came back byte-identical: either a judgment call that should have been named, or a dropped edit.
  public var unanswered: [ReviewAnnotation]

  /// The changes since the draft's last submitted pass, or nil when there is no pass to compare to. An empty `hunks`
  /// means it was compared and nothing moved, which says the last pass did not land.
  public static func compute(log: URL, current: String) -> AppliedChanges? {
    guard let baseline = lastSubmit(in: log), let snapshot = baseline["draft_snapshot"] as? String else { return nil }
    let asks = (baseline["annotations"] as? [Any] ?? []).compactMap { ($0 as? [String: Any]).map(annotation) }
    return compare(
      old: snapshot, new: current, asks: asks, pass: number(baseline["pass"]) ?? 0)
  }

  /// The newest record with a nonzero `pass` and a snapshot; launch records carry pass 0.
  static func lastSubmit(in log: URL) -> [String: Any]? {
    guard let text = try? String(contentsOf: log, encoding: .utf8) else { return nil }
    for line in text.split(separator: "\n").reversed() where !line.trimmingCharacters(in: .whitespaces).isEmpty {
      guard let record = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
      if (number(record["pass"]) ?? 0) != 0, record["draft_snapshot"] is String { return record }
    }
    return nil
  }

  static func compare(old: String, new: String, asks: [ReviewAnnotation], pass: Int) -> AppliedChanges {
    let oldLines = ReviewStore.pythonLines(old)
    let newLines = ReviewStore.pythonLines(new)
    var hunks: [Hunk] = []
    var matched = Set<Int>()
    for op in UnifiedDiff.opcodes(oldLines, newLines) where !op.equal {
      var removed = quote(Array(oldLines[op.i1..<op.i2]))
      var added = quote(Array(newLines[op.j1..<op.j2]))
      let kind: Kind = op.i2 == op.i1 ? .insert : op.j2 == op.j1 ? .delete : .replace
      if kind == .replace, op.i2 - op.i1 == 1, op.j2 - op.j1 == 1 { (removed, added) = trimToWords(removed, added) }
      // An insertion sits between two baseline lines and covers neither, so widen it by one each way or an ask on the
      // line above a new sentence never matches.
      let (low, high) = op.i2 > op.i1 ? (op.i1 + 1, op.i2) : (op.i1, op.i1 + 1)
      var hunkAsks: [ReviewAnnotation] = []
      for (index, ask) in asks.enumerated() where ask.line <= high && (ask.endLine == 0 ? ask.line : ask.endLine) >= low
      {
        matched.insert(index)
        hunkAsks.append(ask)
      }
      hunks.append(
        Hunk(
          kind: kind, lines: op.j2 > op.j1 ? dropBlankEdges(newLines, op.j1 + 1, op.j2) : nil,
          anchor: min(op.j1 + 1, max(newLines.count, 1)), removed: clip(removed), added: clip(added), asks: hunkAsks))
    }
    return AppliedChanges(
      fromPass: pass, hunks: Array(hunks.prefix(maxHunks)), more: max(hunks.count - maxHunks, 0),
      unanswered: asks.enumerated().filter { !matched.contains($0.offset) }.map(\.element))
  }

  // MARK: Helpers

  private static func number(_ value: Any?) -> Int? {
    if let int = value as? Int { return int }
    return (value as? Double).map { Int($0) }
  }

  private static func annotation(_ record: [String: Any]) -> ReviewAnnotation {
    let line = number(record["line"]) ?? 0
    return ReviewAnnotation(
      type: record["type"] as? String ?? "", label: record["label"] as? String ?? "",
      text: record["text"] as? String ?? "", note: record["note"] as? String,
      context: record["context"] as? String ?? "", line: line, colFrom: number(record["col_from"]) ?? 0,
      endLine: number(record["end_line"]).flatMap { $0 == 0 ? nil : $0 } ?? line,
      colTo: number(record["col_to"]) ?? 0, occurrence: number(record["occurrence"]) ?? 1,
      seq: number(record["seq"]) ?? 0)
  }

  private static func isBlank(_ line: String) -> Bool {
    line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// Joined text without the blank lines that bracket a block.
  private static func quote(_ lines: [String]) -> String {
    var body = lines[...]
    while let first = body.first, isBlank(first) { body.removeFirst() }
    while let last = body.last, isBlank(last) { body.removeLast() }
    return body.joined(separator: "\n")
  }

  /// Shrinks a 1-based inclusive line range off the blank lines at either end, so a new paragraph (an inserted blank
  /// line plus its prose) points at the prose. A range blank all through keeps its edges: a whitespace-only change is
  /// still a change.
  private static func dropBlankEdges(_ lines: [String], _ low: Int, _ high: Int) -> ClosedRange<Int> {
    var start = low
    var end = high
    while start < end, isBlank(lines[start - 1]) { start += 1 }
    while end > start, isBlank(lines[end - 1]) { end -= 1 }
    return isBlank(lines[start - 1]) ? low...high : start...end
  }

  static func clip(_ text: String) -> String {
    let scalars = Array(text.unicodeScalars)
    guard scalars.count > maxQuote else { return text }
    var head = String(String.UnicodeScalarView(scalars[..<maxQuote]))
    while let last = head.last, last.isWhitespace { head.removeLast() }
    return head + " …"
  }

  /// The differing middles of two one-line versions, cut on word boundaries, so "we were able to deliver it" against
  /// "we delivered it" reads `were able to deliver` -> `delivered` instead of quoting the whole line.
  static func trimToWords(_ first: String, _ second: String) -> (String, String) {
    let a = Array(first.unicodeScalars)
    let b = Array(second.unicodeScalars)
    let common = min(a.count, b.count)
    var prefix = 0
    while prefix < common, a[prefix] == b[prefix] { prefix += 1 }
    while prefix > 0, !a[prefix - 1].properties.isWhitespace { prefix -= 1 }
    var suffix = 0
    while suffix < common - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
    while suffix > 0, !a[a.count - suffix].properties.isWhitespace { suffix -= 1 }
    let left = String(String.UnicodeScalarView(a[prefix..<(a.count - suffix)]))
    let right = String(String.UnicodeScalarView(b[prefix..<(b.count - suffix)]))
    // A trim that leaves both sides empty means the boundary walk ate the difference: quote the lines.
    return left.isEmpty && right.isEmpty ? (first, second) : (left, right)
  }

  // MARK: Markdown

  public var isEmpty: Bool { hunks.isEmpty && unanswered.isEmpty }

  /// The changes as a Markdown page for a preview pane. Hotkey keys and labels come from `hotkeys`, falling back to
  /// the label the log recorded for a type the set does not know.
  public func markdown(hotkeys: [ReviewHotkey] = ReviewHotkeys.load()) -> String {
    var out = ["## Since pass \(fromPass)", ""]
    if isEmpty {
      out += ["No changes since pass \(fromPass)", ""]
      return out.joined(separator: "\n")
    }
    for hunk in hunks {
      if hunk.asks.count > 1 {
        out += ["### " + hunk.asks.map { Self.title($0, hotkeys) }.joined(separator: " / "), ""]
        for ask in hunk.asks {
          let note = ask.note.flatMap { $0.isEmpty ? nil : " (note: \(Self.literal($0)))" } ?? ""
          out.append("- \(Self.literal(Self.title(ask, hotkeys))): \(Self.literal(Self.clip(ask.text)))\(note)")
        }
        out.append("")
      } else if let ask = hunk.asks.first {
        out += ["### " + Self.title(ask, hotkeys), ""]
        if let note = ask.note, !note.isEmpty { out += ["Note: \(Self.literal(note))", ""] }
      } else {
        out += ["### Changed", ""]
      }
      out += Self.change(hunk) + [""]
    }
    if more > 0 { out += ["And \(more) more change\(more == 1 ? "" : "s") not shown.", ""] }
    if !unanswered.isEmpty {
      out += ["## Asked for, no change found", ""]
      for ask in unanswered {
        let note = ask.note.flatMap { $0.isEmpty ? nil : " (note: \(Self.literal($0)))" } ?? ""
        out.append(
          "- L\(ask.line) \(Self.literal(Self.title(ask, hotkeys))): \(Self.literal(Self.clip(ask.text)))\(note)")
      }
      out.append("")
    }
    return out.joined(separator: "\n")
  }

  /// `3 Cringe`: the hotkey's key and label, which the set owns.
  static func title(_ ask: ReviewAnnotation, _ hotkeys: [ReviewHotkey]) -> String {
    if let hotkey = hotkeys.first(where: { $0.type == ask.type }) { return "\(hotkey.key) \(hotkey.label)" }
    return ask.label.isEmpty ? ask.type : ask.label
  }

  /// `L3 ~~old~~ → new` when both sides are a line; otherwise the line label, then the old lines struck through, then
  /// the new text after the arrow. A deletion has no new text.
  static func change(_ hunk: Hunk) -> [String] {
    let at =
      hunk.lines.map { $0.lowerBound == $0.upperBound ? "L\($0.lowerBound)" : "L\($0.lowerBound)-\($0.upperBound)" }
      ?? "L\(hunk.anchor)"
    let old = hunk.removed.split(separator: "\n", omittingEmptySubsequences: false).map { "~~\(literal(String($0)))~~" }
    let new = hunk.added.split(separator: "\n", omittingEmptySubsequences: false).map { literal(String($0)) }
    let oldText = hunk.removed.isEmpty ? [] : old
    let newText = hunk.added.isEmpty ? [] : new
    if oldText.count <= 1, newText.count <= 1 {
      return [([at] + oldText + (newText.isEmpty ? [] : ["→ " + newText[0]])).joined(separator: " ")]
    }
    var out = [at, ""]
    if !oldText.isEmpty { out += [oldText.joined(separator: "\\\n"), ""] }
    if !newText.isEmpty { out.append("→ " + newText.joined(separator: "\\\n")) }
    return out
  }

  /// One line of text shown as it is: the characters Markdown would act on are escaped, and a line is kept from
  /// opening a list.
  static func literal(_ text: String) -> String {
    var out = ""
    for character in text {
      if "\\`*_~[]<>#|".contains(character) { out.append("\\") }
      out.append(character)
    }
    let digits = out.prefix { $0.isASCII && $0.isNumber }
    if out.hasPrefix("-") || out.hasPrefix("+") { return "\\" + out }
    if !digits.isEmpty, let mark = out.dropFirst(digits.count).first, ".)".contains(mark) {
      return digits + "\\" + out.dropFirst(digits.count)
    }
    return out
  }
}
