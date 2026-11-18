import CoreGraphics
import Foundation
import TermDownCore
import TermDownDocument
import TermDownLayout
import TermDownRender

/// A review mark as the painter draws it: the rendered text it covers and its hotkey's hex color.
public struct RenderedReviewMark: Equatable, Sendable {
  public var rendered: Range<Int>
  public var color: String

  public init(rendered: Range<Int>, color: String) {
    self.rendered = rendered
    self.color = color
  }
}

extension ViewerInteraction {
  /// The marks over the current layout, in press order, for the render overlay.
  public var renderedReviewMarks: [RenderedReviewMark] {
    guard let layout, !review.marks.isEmpty else { return [] }
    let text = EditableText(source: source)
    return review.marks.marks.compactMap { mark in
      guard let rendered = renderedRange(of: mark.range, in: layout, text: text), !rendered.isEmpty else { return nil }
      let color = reviewHotkeys.first { $0.type == mark.type }?.color ?? "#9ca3af"
      return RenderedReviewMark(rendered: rendered, color: color)
    }
  }

  /// The source bytes the person typed this pass: where the text now differs from `review.snapshot`, which the agent's
  /// own writes are rebased into, so only hand edits show. Empty while review is off.
  public var typedRanges: [Range<Int>] {
    guard review.isOn, let snapshot = review.snapshot else { return [] }
    let current = edit?.source ?? source
    guard current != snapshot else { return [] }
    return TypedEdits.ranges(from: Array(snapshot.utf8), to: Array(current.utf8))
  }

  /// The typed edits over the current layout, for the render overlay's underline.
  public var renderedTypedEdits: [Range<Int>] {
    guard let layout else { return [] }
    let ranges = typedRanges
    guard !ranges.isEmpty else { return [] }
    let text = edit?.text ?? EditableText(source: source)
    return ranges.compactMap { renderedRange(of: $0, in: layout, text: text) }.filter { !$0.isEmpty }
  }

  func renderedRange(of range: Range<Int>, in layout: PageLayout, text: EditableText) -> Range<Int>? {
    let prepared = layout.prepared
    if let start = prepared.renderedOffset(forSource: range.lowerBound),
      let end = prepared.renderedOffset(forSource: range.upperBound), start < end
    {
      return start..<end
    }
    return layout.renderedRange(forSource: range, in: text)
  }

  /// The selection as source bytes: the edit session's own, or the view selection mapped to the source.
  var reviewSelection: Range<Int>? {
    if let session = edit { return session.selection.flatMap { $0.isEmpty ? nil : $0 } }
    guard let layout, let selection = overlay.selection, !selection.isEmpty else { return nil }
    return layout.sourceBytes(forRendered: selection, in: EditableText(source: source))
  }

  /// A selection that is only figures and punctuation is retyped, not annotated (the skill's `looksNumeric`).
  static func looksNumeric(_ text: String) -> Bool {
    let allowed = Set(".,:;%$€£+-/()")
    return !text.isEmpty && text.utf16.count <= 24
      && text.allSatisfy { ("0"..."9").contains($0) || $0.isWhitespace || allowed.contains($0) }
  }

  /// The hotkey a digit annotates with over the current selection, or nil when the digit keeps its usual job.
  func reviewHotkey(for digit: Character) -> (ReviewHotkey, Range<Int>)? {
    guard review.isOn, let hotkey = reviewHotkeys.first(where: { $0.key == String(digit) }),
      let range = reviewSelection
    else { return nil }
    let text = String(decoding: Array(source.utf8)[range], as: UTF8.self)
    return Self.looksNumeric(text) ? nil : (hotkey, range)
  }

  public static let noAgentMessage =
    "No agent connected: run /ide in a Claude session and pick this preview, or press A to start one beside it."
  static let chooseAgentMessage = "Choose one agent for the review: press A"
  public static let outsideRexMessage = "The connected agent is outside Rex: reviews need an agent in a Rex pane"

  /// `m`: off asks before discarding marks. On needs one connected agent in a Rex pane to send to, and asks which
  /// when there are several and none is chosen.
  mutating func toggleReview(at now: UInt64) -> [InteractionEffect] {
    if review.isOn {
      guard !review.marks.isEmpty else { return stopReview(at: now) }
      return confirmDiscard(.discardAndStop)
    }
    if reviewAgent.connected == 0 { return show(Self.noAgentMessage, kind: .info, at: now) }
    if reviewAgent.outsideRex { return show(Self.outsideRexMessage, kind: .info, at: now) }
    if !reviewAgent.chosen { return [.chooseReviewAgent] }
    return startReview(at: now)
  }

  /// Marks that would be lost by leaving: review is on and something is marked.
  var hasUnsentMarks: Bool { review.isOn && !review.marks.isEmpty }

  /// Asks, in the status bar, before the marks are discarded for `action`.
  mutating func confirmDiscard(_ action: ConfirmAction) -> [InteractionEffect] {
    confirm = ReviewConfirm(prompt: "Discard \(marksCount)? y / n", action: action)
    return [.redrawStatusBar]
  }

  /// `termdown review` for the file already shown: start review the way `m` does. With no agent connected the request
  /// waits and starts when one is chosen; with several and no choice it asks which.
  public mutating func requestReview(at now: UInt64) -> [InteractionEffect] {
    if review.isOn {
      reviewPending = false
      return show("Review is already on", kind: .info, at: now)
    }
    if reviewAgent.connected == 0 {
      reviewPending = true
      return show(Self.noAgentMessage, kind: .info, at: now)
    }
    if reviewAgent.outsideRex { return show(Self.outsideRexMessage, kind: .info, at: now) }
    if !reviewAgent.chosen { return [.chooseReviewAgent] }
    return startReview(at: now)
  }

  /// A request that waits for the agent the person is about to start from the review picker.
  public mutating func awaitReviewAgent() {
    if !review.isOn { reviewPending = true }
  }

  /// `termdown review` for `url`: the file already shown is a plain request. Another file loads first (after the
  /// discard question when marks are unsent) and review is requested once it has loaded.
  public mutating func openForReview(_ url: URL, at now: UInt64) -> [InteractionEffect] {
    if let file, url.standardizedFileURL.path == file.standardizedFileURL.path { return requestReview(at: now) }
    reviewAfterOpen = url
    return open(url)
  }

  /// Turns review on, after a review agent is chosen.
  public mutating func startReview(at now: UInt64) -> [InteractionEffect] {
    reviewPending = false
    review.isOn = true
    review.snapshot = source
    if let file, reviewClient?.file != file {
      reviewClient = (file, ReviewStore(draft: file).about(pass: nil).client)
    }
    return [.reviewLaunched] + show("Review on: select text, then 1-9 to mark, s to send", kind: .info, at: now)
  }

  /// Marks kept from an earlier viewer run, already moved onto the text now shown. Only a review with no marks of its
  /// own takes them.
  public mutating func restoreMarks(_ marks: ReviewMarks, at now: UInt64) -> [InteractionEffect] {
    guard review.isOn, review.marks.isEmpty, !marks.isEmpty else { return [] }
    review.marks = marks
    return markRedraws(marks.marks.map(\.range)) + show("Restored \(marksCount) from your last review", kind: .info, at: now)
  }

  /// Turns review off without a "Review off" message and shows `message` instead: the host could not take the review
  /// lock after `startReview`, so no marks can exist yet.
  public mutating func cancelReview(message: String, at now: UInt64) -> [InteractionEffect] {
    let redraws = endReview()
    return redraws + show(message, kind: .info, at: now)
  }

  mutating func stopReview(at now: UInt64) -> [InteractionEffect] {
    endReview() + show("Review off", kind: .info, at: now)
  }

  /// Review off with every mark dropped; the redraws clear the bands, and the whole view when the marks list was open
  /// (turning review off closes it, so whether it was open is read first).
  mutating func endReview() -> [InteractionEffect] {
    let redraws = markRedraws(review.marks.marks.map(\.range)) + (marksList == nil ? [] : [.redrawAll])
    review.isOn = false
    review.marks.removeAll()
    confirm = nil
    return redraws
  }

  /// The host's report of which agent a review goes to. A disconnect mid-review keeps the marks: the review stays on
  /// until the person ends it.
  public mutating func setReviewAgent(_ status: ReviewAgentStatus, at now: UInt64) -> [InteractionEffect] {
    guard status != reviewAgent else { return [] }
    reviewAgent = status
    guard reviewPending, status.chosen else { return [.redrawStatusBar] }
    if review.isOn {
      reviewPending = false
      return [.redrawStatusBar]
    }
    return [.redrawStatusBar] + startReview(at: now)
  }

  mutating func handleConfirm(_ key: Key, at now: UInt64) -> [InteractionEffect] {
    guard let pending = confirm else { return [] }
    switch key {
    case .char("y"):
      confirm = nil
      switch pending.action {
      case .discardAndStop: return stopReview(at: now)
      case .discardAndQuit: return endReview() + [.quit]
      case .discardAndOpen(let url):
        pendingNavigation = deferredNavigation
        deferredNavigation = nil
        return endReview() + [.loadDocument(url)]
      }
    case .char("n"), .escape:
      confirm = nil
      reviewAfterOpen = nil
      if let held = deferredNavigation {
        revertHistory(for: held)
        deferredNavigation = nil
      }
      return [.redrawStatusBar]
    case .ctrl("c"), .ctrl("q"):
      return [.quit]
    default:
      return []
    }
  }

  mutating func annotate(_ hotkey: ReviewHotkey, range: Range<Int>, at now: UInt64) -> [InteractionEffect] {
    if hotkey.prompt != nil {
      pendingNote = (range, hotkey)
      noteField = ""
      helpVisible = false
      overlay.hoverLink = nil
      return setPointerShape(.default) + [.redrawAll]
    }
    return addMark(range, hotkey: hotkey, note: nil, at: now)
  }

  mutating func addMark(_ range: Range<Int>, hotkey: ReviewHotkey, note: String?, at now: UInt64) -> [InteractionEffect] {
    guard review.marks.add(range, type: hotkey.type, label: hotkey.label, note: note) != nil else { return [] }
    // The mark is made, so the selection is spent; a repeated digit then asks for a new one.
    let spent = edit == nil ? setSelection(nil) : []
    return markRedraws([range]) + spent + show("\(hotkey.label): \(marksCount)", kind: .info, at: now)
  }

  var marksCount: String { review.marks.count == 1 ? "1 mark" : "\(review.marks.count) marks" }

  mutating func handleNoteField(_ key: Key, at now: UInt64) -> [InteractionEffect] {
    if pendingLink != nil { return handleLinkField(key, at: now) }
    switch key {
    case .char(let character):
      noteField?.append(character)
    case .backspace:
      if noteField?.isEmpty == false { noteField?.removeLast() }
    case .enter:
      let note = (noteField ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      let pending = pendingNote
      let target = noteTargetSeq
      noteField = nil
      pendingNote = nil
      noteTargetSeq = nil
      guard !note.isEmpty, let pending else { return [.redrawAll] }
      if let target { return [.redrawAll] + setListedNote(seq: target, hotkey: pending.hotkey, note: note, at: now) }
      return [.redrawAll] + addMark(pending.range, hotkey: pending.hotkey, note: note, at: now)
    case .escape:
      noteField = nil
      pendingNote = nil
      noteTargetSeq = nil
    case .ctrl("c"), .ctrl("q"):
      return [.quit]
    default:
      return []
    }
    return [.redrawAll]
  }

  mutating func removeLastMark(at now: UInt64) -> [InteractionEffect] {
    guard review.isOn else { return [] }
    guard let last = review.marks.marks.last else { return show("No marks", kind: .info, at: now) }
    let redraws = markRedraws([last.range])
    review.marks.removeLast()
    return redraws + show("Removed \(last.label): \(marksCount)", kind: .info, at: now)
  }

  mutating func removeSelectedMarks(at now: UInt64) -> [InteractionEffect] {
    guard review.isOn else { return [] }
    guard let range = reviewSelection else { return show("Select text to clear its marks", kind: .info, at: now) }
    let removed = review.marks.marks.filter { $0.range.overlaps(range) }
    guard !removed.isEmpty else { return show("No marks in the selection", kind: .info, at: now) }
    let redraws = markRedraws(removed.map(\.range))
    review.marks.remove(overlapping: range)
    return redraws + show("Cleared \(removed.count): \(marksCount)", kind: .info, at: now)
  }

  /// `s`: send this pass, which ends review. Each pass stands alone; `m` starts the next one.
  mutating func submitReview(at now: UInt64) -> [InteractionEffect] {
    guard review.isOn else { return show("Review is off: m starts it", kind: .info, at: now) }
    // A pass with no marks and no typed edits would send the agent nothing.
    if review.marks.isEmpty, (edit?.source ?? source) == review.snapshot {
      return show("Nothing to send: mark text or edit the draft first", kind: .info, at: now)
    }
    // A pass goes to exactly one agent and never to the clipboard; the marks wait for one.
    if reviewAgent.connected == 0 { return show(Self.noAgentMessage, kind: .info, at: now) }
    if reviewAgent.outsideRex { return show(Self.outsideRexMessage, kind: .info, at: now) }
    if !reviewAgent.chosen { return show(Self.chooseAgentMessage, kind: .info, at: now) }
    let leaving = edit == nil ? [] : endEditing(at: now)
    return leaving + [.submitReview]
  }

  /// `D`: the host shows what changed since the last pass sent for this file, with review on or off.
  mutating func showChanges(at now: UInt64) -> [InteractionEffect] {
    file == nil ? [] : [.showChanges]
  }

  /// After the host wrote a pass: the pass is complete on its own, so review ends with its marks cleared.
  public mutating func reviewSubmitted(pass: Int) -> [InteractionEffect] {
    review.pass = pass
    return endReview()
  }

  /// The passes already sent for this draft, read from its review log when review starts, so numbering carries on.
  public mutating func setReviewPass(_ pass: Int) {
    review.pass = pass
  }

  /// Another writer, such as the agent applying a pass, changed the file: that change is not a hand edit, so it joins
  /// the snapshot the next manual-edits diff is taken against.
  mutating func rebaseReviewSnapshot(from old: [UInt8], to new: [UInt8]) {
    guard review.isOn, let snapshot = review.snapshot, old != new else { return }
    let merged = LineMerge.merge(base: old, disk: new, mine: Array(snapshot.utf8))
    review.snapshot = String(decoding: merged.text, as: UTF8.self)
  }

  /// Redraws the bands under marks over source ranges, the way selection changes are redrawn.
  func markRedraws(_ ranges: [Range<Int>]) -> [InteractionEffect] {
    guard let layout else { return [] }
    let text = EditableText(source: source)
    let rects = ranges.compactMap { renderedRange(of: $0, in: layout, text: text) }.flatMap {
      layout.rects(for: $0).map(\.rect)
    }
    return bands(rects).map { .redraw($0) }
  }
}

// MARK: Marks list

extension ViewerInteraction {
  static let noMarksMessage = "No marks yet: select text, then 1-9"

  /// The list's rows: every mark in document order, with its hotkey's digit and color.
  func markRows() -> [MarksListRow] {
    let bytes = Array(source.utf8)
    let ordered = review.marks.marks.sorted { ($0.range.lowerBound, $0.seq) < ($1.range.lowerBound, $1.seq) }
    return ordered.compactMap { mark in
      guard mark.range.upperBound <= bytes.count else { return nil }
      let hotkey = reviewHotkeys.first { $0.type == mark.type }
      return MarksListRow(
        seq: mark.seq, key: hotkey?.key ?? "?", label: mark.label,
        color: hotkey.map { $0.color.isEmpty ? "#9ca3af" : $0.color } ?? "#9ca3af",
        quote: MarksListRow.quote(of: String(decoding: bytes[mark.range], as: UTF8.self)), note: mark.note,
        line: bytes[..<mark.range.lowerBound].lazy.filter { $0 == UInt8(ascii: "\n") }.count + 1)
    }
  }

  /// Rebuilds an open list after the marks changed or moved. The selected mark stays selected while it exists; when it
  /// is gone the row now at its index is, clamped to the end. With no rows left the list closes.
  mutating func refreshMarksList() {
    guard let current = marksList else { return }
    let rows = review.isOn ? markRows() : []
    guard !rows.isEmpty else {
      marksList = nil
      return
    }
    let seq = current.rows.indices.contains(current.selected) ? current.rows[current.selected].seq : nil
    let kept = seq.flatMap { seq in rows.firstIndex { $0.seq == seq } }
    marksList = MarksListContent(rows: rows, selected: kept ?? current.selected, pass: review.pass + 1)
  }

  /// `M`: the marks in a pop-up, in document order.
  mutating func openMarksList(at now: UInt64) -> [InteractionEffect] {
    guard review.isOn else { return show("Review is off: m starts it", kind: .info, at: now) }
    let rows = markRows()
    guard !rows.isEmpty else { return show(Self.noMarksMessage, kind: .info, at: now) }
    marksList = MarksListContent(rows: rows, selected: 0, pass: review.pass + 1)
    helpVisible = false
    overlay.hoverLink = nil
    return setPointerShape(.default) + [.redrawAll]
  }

  mutating func closeMarksList() -> [InteractionEffect] {
    marksList = nil
    return [.redrawAll]
  }

  var listedMark: ReviewMark? {
    guard let list = marksList, list.rows.indices.contains(list.selected) else { return nil }
    return review.marks.marks.first { $0.seq == list.rows[list.selected].seq }
  }

  mutating func handleMarksList(_ key: Key, at now: UInt64) -> [InteractionEffect] {
    guard var list = marksList else { return [] }
    switch key {
    case .ctrl("c"), .ctrl("q"):
      return [.quit]
    case .char("j"), .down, .char("k"), .up:
      let forward = key == .char("j") || key == .down
      list.selected = cycle(from: list.selected, count: list.rows.count, forward: forward) ?? 0
      marksList = list
      return [.redrawAll]
    case .enter:
      return jumpToListedMark(list.selected, at: now)
    case .escape, .char("M"):
      return closeMarksList()
    case .char("x"):
      return deleteListedMark(at: now)
    case .char("n"):
      return editListedNote(at: now)
    case .char(let digit) where ("1"..."9").contains(digit):
      return retypeListedMark(to: digit, at: now)
    default:
      return []
    }
  }

  mutating func marksListPressed(at point: CGPoint, at now: UInt64) -> [InteractionEffect] {
    guard let list = marksList else { return [] }
    let view = MarksList(content: list, backingScale: typography.backingScale)
    let area = CGRect(x: 0, y: 0, width: geometry.width, height: geometry.contentHeight)
    if let row = view.row(at: point, in: area) { return jumpToListedMark(row, at: now) }
    return view.panel(in: area).contains(point) ? [] : closeMarksList()
  }

  /// Enter: close the list, select the mark's passage and scroll it into view.
  mutating func jumpToListedMark(_ index: Int, at now: UInt64) -> [InteractionEffect] {
    guard let list = marksList, list.rows.indices.contains(index),
      let mark = review.marks.marks.first(where: { $0.seq == list.rows[index].seq })
    else { return [] }
    marksList = nil
    let closed: [InteractionEffect] = [.redrawAll]
    guard let layout, let rendered = renderedRange(of: mark.range, in: layout, text: EditableText(source: source)),
      !rendered.isEmpty
    else { return closed + show("That passage is not on the page", kind: .info, at: now) }
    var effects = closed + setSelection(rendered)
    if let rect = layout.rects(for: rendered, scrolled: false).first?.rect { effects += reveal(rect, centered: true) }
    return effects
  }

  mutating func deleteListedMark(at now: UInt64) -> [InteractionEffect] {
    guard let mark = listedMark else { return [] }
    let redraws = markRedraws([mark.range])
    review.marks.remove(seq: mark.seq)
    return redraws + [.redrawAll] + show("Removed \(mark.label): \(marksCount)", kind: .info, at: now)
  }

  /// A digit gives the listed mark that hotkey's type. A hotkey that takes a note asks for it first; any other drops
  /// the mark's note.
  mutating func retypeListedMark(to digit: Character, at now: UInt64) -> [InteractionEffect] {
    guard let mark = listedMark, let hotkey = reviewHotkeys.first(where: { $0.key == String(digit) }) else { return [] }
    if hotkey.prompt != nil { return askListedNote(for: mark, hotkey: hotkey) }
    let hadNote = mark.note != nil
    let redraws = markRedraws([mark.range])
    review.marks.retype(seq: mark.seq, type: hotkey.type, label: hotkey.label)
    return redraws + [.redrawAll]
      + show(hadNote ? "Note dropped" : "\(hotkey.label): \(marksCount)", kind: .info, at: now)
  }

  /// `n`: edit a note mark's text, starting from what it says.
  mutating func editListedNote(at now: UInt64) -> [InteractionEffect] {
    guard let mark = listedMark else { return [] }
    guard let hotkey = reviewHotkeys.first(where: { $0.type == mark.type }), hotkey.prompt != nil else {
      let key = reviewHotkeys.first { $0.prompt != nil }?.key ?? "9"
      return show("Notes are for \(key) marks: press \(key) to make this a note", kind: .info, at: now)
    }
    return askListedNote(for: mark, hotkey: hotkey)
  }

  /// Opens the note dialog for a listed mark; the list stays open underneath.
  mutating func askListedNote(for mark: ReviewMark, hotkey: ReviewHotkey) -> [InteractionEffect] {
    pendingNote = (mark.range, hotkey)
    noteTargetSeq = mark.seq
    noteField = mark.note ?? ""
    return [.redrawAll]
  }

  mutating func setListedNote(seq: Int, hotkey: ReviewHotkey, note: String, at now: UInt64) -> [InteractionEffect] {
    guard let mark = review.marks.marks.first(where: { $0.seq == seq }) else { return [.redrawStatusBar] }
    if mark.type != hotkey.type {
      review.marks.retype(seq: seq, type: hotkey.type, label: hotkey.label, keepNote: true)
    }
    review.marks.setNote(seq: seq, note)
    return markRedraws([mark.range]) + [.redrawAll] + show("\(hotkey.label): \(marksCount)", kind: .info, at: now)
  }
}

/// Where text typed by hand sits in the current source.
enum TypedEdits {
  /// A middle section larger than this (in characters, on either side) is marked whole rather than diffed again.
  static let refineLimit = 600

  /// The ranges of `new` that differ from `old`, touching ranges merged. Lines are matched first, then each changed
  /// run is narrowed to the characters that changed, so a word typed into a paragraph is just that word.
  static func ranges(from old: [UInt8], to new: [UInt8]) -> [Range<Int>] {
    let oldLines = LineMerge.lines(old)
    var oldOffsets = [0]
    for line in oldLines { oldOffsets.append(oldOffsets[oldOffsets.count - 1] + line.count) }
    var found: [Range<Int>] = []
    var delta = 0
    for hunk in LineMerge.hunks(from: oldLines, to: LineMerge.lines(new)) {
      let before = oldOffsets[hunk.base.lowerBound]
      let removed = Array(old[before..<oldOffsets[hunk.base.upperBound]])
      let added = Array(hunk.replacement.joined())
      found += narrow(removed, added).map { (before + delta + $0.lowerBound)..<(before + delta + $0.upperBound) }
      delta += added.count - removed.count
    }
    return merged(found)
  }

  /// The ranges of `added` that are not in `removed`, on character boundaries.
  static func narrow(_ removed: [UInt8], _ added: [UInt8]) -> [Range<Int>] {
    var prefix = 0
    while prefix < removed.count, prefix < added.count, removed[prefix] == added[prefix] { prefix += 1 }
    while prefix > 0, prefix < added.count, added[prefix] & 0xC0 == 0x80 { prefix -= 1 }
    var suffix = 0
    while suffix < removed.count - prefix, suffix < added.count - prefix,
      removed[removed.count - 1 - suffix] == added[added.count - 1 - suffix]
    {
      suffix += 1
    }
    var end = added.count - suffix
    while end < added.count, added[end] & 0xC0 == 0x80 { end += 1 }
    guard prefix < end else { return [] }
    let oldEnd = removed.count - (added.count - end)
    let oldMiddle = String(decoding: removed[prefix..<max(oldEnd, prefix)], as: UTF8.self)
    let newMiddle = String(decoding: added[prefix..<end], as: UTF8.self)
    let oldCharacters = Array(oldMiddle)
    let newCharacters = Array(newMiddle)
    guard !oldCharacters.isEmpty, oldCharacters.count <= refineLimit, newCharacters.count <= refineLimit else {
      return [prefix..<end]
    }
    var offsets = [prefix]
    for character in newCharacters { offsets.append(offsets[offsets.count - 1] + character.utf8.count) }
    var inserted = IndexSet()
    for case .insert(let offset, _, _) in newCharacters.difference(from: oldCharacters) { inserted.insert(offset) }
    return inserted.rangeView.map { offsets[$0.lowerBound]..<offsets[$0.upperBound] }
  }

  static func merged(_ ranges: [Range<Int>]) -> [Range<Int>] {
    var out: [Range<Int>] = []
    for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) where !range.isEmpty {
      if let last = out.last, range.lowerBound <= last.upperBound {
        out[out.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
      } else {
        out.append(range)
      }
    }
    return out
  }
}
