import CoreGraphics
import Foundation
import TermDownDocument
import TermDownLayout

/// The markdown being edited in place: source bytes, a caret and selection anchor as source byte offsets, and
/// undo history. Pure value type; layout-dependent movement (up, down, line ends) lives in ViewerInteraction.
public struct EditSession: Sendable {
  struct Snapshot: Sendable {
    var source: String
    var caret: Int
    var anchor: Int?
  }

  enum Coalesce: Equatable, Sendable {
    case none, typing, deleting
  }

  public private(set) var source: String
  public private(set) var bytes: [UInt8]
  public private(set) var document: Document
  public private(set) var caret: Int
  public private(set) var anchor: Int?
  /// Increments on every source change.
  public private(set) var revision = 0
  public private(set) var savedRevision = 0
  /// The file's bytes as last read from or written to disk; a change on disk is any difference from these.
  public private(set) var base: [UInt8]
  /// Remembered x for successive vertical moves.
  public var goalX: CGFloat?
  public private(set) var blocks: [EditableBlock]
  var text: EditableText
  var leaves: [Range<Int>]
  /// This revision's parse and map, for the layout worker.
  public var inputs: EditInputs {
    EditInputs(source: source, document: document, text: text, blocks: blocks, leaves: leaves)
  }
  var undoStack: [Snapshot] = []
  var redoStack: [Snapshot] = []
  var coalesce = Coalesce.none

  public init(source: String, caret: Int? = nil) {
    self.source = source
    bytes = Array(source.utf8)
    base = bytes
    document = Document.parse(source)
    text = EditableText(source: source)
    blocks = text.allBlocks(document)
    leaves = text.leafRanges(document)
    self.caret = 0
    self.caret = stop(near: caret ?? firstStop)
  }

  public var isDirty: Bool { revision != savedRevision }

  public mutating func markSaved() {
    savedRevision = revision
    base = bytes
  }

  /// Records that the text of `revision` is now on disk.
  public mutating func markSaved(revision saved: Int, text: String) {
    base = Array(text.utf8)
    if saved == revision { savedRevision = revision }
  }

  public var selection: Range<Int>? {
    guard let anchor, anchor != caret else { return nil }
    return min(anchor, caret)..<max(anchor, caret)
  }

  public var selectedSource: String? {
    selection.map { String(decoding: bytes[$0], as: UTF8.self) }
  }

  // MARK: Blocks and stops

  /// The editable block whose source contains an offset (its end included).
  public func block(containing offset: Int) -> EditableBlock? {
    var low = 0
    var high = blocks.count - 1
    guard high >= 0 else { return nil }
    while low < high {
      let middle = (low + high + 1) / 2
      if blocks[middle].source.lowerBound <= offset { low = middle } else { high = middle - 1 }
    }
    let candidate = blocks[low]
    return candidate.source.lowerBound <= offset && offset <= candidate.source.upperBound ? candidate : nil
  }

  func blockIndex(containing offset: Int) -> Int? {
    blocks.firstIndex { $0.source.lowerBound <= offset && offset <= $0.source.upperBound }
  }

  public func projection(of block: EditableBlock, caret: Int?) -> EditProjection {
    EditProjection(block: block, caret: caret, source: bytes)
  }

  /// The owner ranges revealed at a caret: two carets with the same key render the same text.
  public func revealKey(at offset: Int) -> [Range<Int>] {
    guard let block = block(containing: offset) else { return [] }
    if block.isRaw { return [block.source] }
    var owners: [Range<Int>] = []
    for span in block.spans where span.isRevealed(caret: offset) {
      if let owner = span.owner, owners.last != owner { owners.append(owner) }
    }
    return owners
  }

  /// Whether a caret may rest at an offset: it is a boundary of the projection it reveals, on a grapheme edge.
  public func isStop(_ offset: Int) -> Bool {
    guard let block = block(containing: offset) else { return blankStop(at: offset) == offset }
    let projection = projection(of: block, caret: offset)
    let rendered = projection.rendered(atSource: offset)
    guard projection.boundaries[rendered] == offset else { return false }
    let text = projection.text as NSString
    guard rendered > 0, rendered < text.length else { return true }
    return text.rangeOfComposedCharacterSequence(at: rendered).location == rendered
  }

  /// The caret stop of a blank line or empty item containing an offset, outside every block.
  public func blankStop(at offset: Int) -> Int? {
    guard block(containing: offset) == nil else { return nil }
    return text.blankLineStop(at: offset, leaves: leaves)
  }

  var firstStop: Int {
    guard let block = blocks.first else { return 0 }
    return projection(of: block, caret: nil).boundaries[0]
  }

  /// The nearest stop to an offset, preferring the left.
  public func stop(near offset: Int) -> Int {
    guard !blocks.isEmpty else { return min(max(offset, 0), bytes.count) }
    if isStop(offset) { return offset }
    if let block = block(containing: offset) {
      let hidden = projection(of: block, caret: nil)
      let candidate = hidden.source(atRendered: hidden.rendered(atSource: offset))
      if isStop(candidate) { return candidate }
      return hidden.boundaries[0]
    }
    if let blank = blankStop(at: offset) { return blank }
    // Between blocks: the start of the next editable block, or the end of the last one.
    if let next = blocks.first(where: { $0.source.lowerBound > offset }) {
      return projection(of: next, caret: nil).boundaries[0]
    }
    let last = blocks[blocks.count - 1]
    return projection(of: last, caret: nil).boundaries.last ?? last.source.upperBound
  }

  /// The next stop after (or before) an offset. Inside a block it steps by source scalars; past a block's edge
  /// it moves to the nearest blank-line stop or the edge of the neighbouring editable block, whichever is closer.
  func adjacentStop(from offset: Int, forward: Bool) -> Int? {
    if let index = blockIndex(containing: offset) {
      let block = blocks[index]
      var candidate = offset
      while true {
        candidate = forward ? nextScalar(after: candidate) : previousScalar(before: candidate)
        if candidate < block.source.lowerBound || candidate > block.source.upperBound { break }
        if candidate != offset, isStop(candidate) { return candidate }
        if candidate <= 0 || candidate >= bytes.count { break }
      }
      return gapStop(from: forward ? block.source.upperBound : block.source.lowerBound, forward: forward)
    }
    return gapStop(from: offset, forward: forward)
  }

  /// Scans line by line from a position outside blocks to the next blank-line stop or editable block edge.
  private func gapStop(from offset: Int, forward: Bool) -> Int? {
    var line = lineRange(containing: offset)
    while true {
      if forward {
        guard line.upperBound < bytes.count else { return nil }
        var next = line.upperBound
        while next < bytes.count, bytes[next] != UInt8(ascii: "\n") { next += 1 }
        line = lineRange(containing: min(next + 1, bytes.count))
        if next + 1 > bytes.count { return nil }
      } else {
        guard line.lowerBound > 0 else { return nil }
        line = lineRange(containing: line.lowerBound - 1)
      }
      if let blank = blankStop(at: line.lowerBound), blank != offset { return blank }
      if let block = blocks.first(where: { $0.source.overlaps(line) || $0.source.lowerBound == line.lowerBound }) {
        let projection = projection(of: block, caret: nil)
        let edge = forward ? projection.boundaries[0] : (projection.boundaries.last ?? block.source.upperBound)
        if edge != offset { return stop(near: edge) }
      }
    }
  }

  private func nextScalar(after offset: Int) -> Int {
    var next = offset + 1
    while next < bytes.count, bytes[next] & 0xC0 == 0x80 { next += 1 }
    return min(next, bytes.count)
  }

  private func previousScalar(before offset: Int) -> Int {
    var previous = offset - 1
    while previous > 0, bytes[previous] & 0xC0 == 0x80 { previous -= 1 }
    return max(previous, 0)
  }

  /// The stop at the next (or previous) word edge in the rendered text.
  func wordStop(from offset: Int, forward: Bool) -> Int? {
    guard let block = block(containing: offset) else { return nil }
    let projection = projection(of: block, caret: offset)
    let text = Array(projection.text.utf16)
    var position = projection.rendered(atSource: offset)
    func isWord(_ unit: UInt16) -> Bool {
      guard let scalar = Unicode.Scalar(unit) else { return true }
      return scalar.properties.isAlphabetic || scalar.properties.numericType != nil || scalar == "_"
    }
    if forward {
      guard position < text.count else { return adjacentStop(from: offset, forward: true) }
      while position < text.count, !isWord(text[position]) { position += 1 }
      while position < text.count, isWord(text[position]) { position += 1 }
    } else {
      guard position > 0 else { return adjacentStop(from: offset, forward: false) }
      while position > 0, !isWord(text[position - 1]) { position -= 1 }
      while position > 0, isWord(text[position - 1]) { position -= 1 }
    }
    return stop(near: projection.source(atRendered: position))
  }

  // MARK: Caret movement

  public mutating func move(to offset: Int, extend: Bool) {
    let target = stop(near: offset)
    if extend {
      if anchor == nil { anchor = caret }
    } else {
      anchor = nil
    }
    caret = target
    coalesce = .none
  }

  public mutating func moveHorizontally(forward: Bool, word: Bool, extend: Bool) {
    goalX = nil
    if !extend, let selection {
      move(to: forward ? selection.upperBound : selection.lowerBound, extend: false)
      return
    }
    let target = word ? wordStop(from: caret, forward: forward) : adjacentStop(from: caret, forward: forward)
    guard let target else {
      if !extend { anchor = nil }
      return
    }
    move(to: target, extend: extend)
  }

  public mutating func selectAll() {
    guard let first = blocks.first, let last = blocks.last else { return }
    anchor = projection(of: first, caret: nil).boundaries[0]
    caret = projection(of: last, caret: nil).boundaries.last ?? last.source.upperBound
    coalesce = .none
  }

  // MARK: Editing

  private mutating func replace(_ range: Range<Int>, with text: String, caretAfter: Int? = nil, kind: Coalesce) {
    if kind == .none || kind != coalesce {
      undoStack.append(Snapshot(source: source, caret: caret, anchor: anchor))
      if undoStack.count > 500 { undoStack.removeFirst() }
    }
    redoStack = []
    var next = bytes
    let inserted = Array(text.utf8)
    next.replaceSubrange(range, with: inserted)
    load(String(decoding: next, as: UTF8.self))
    anchor = nil
    caret = stop(near: caretAfter ?? (range.lowerBound + inserted.count))
    // Prefer the exact insertion point when it is a stop, even if stop(near:) would choose otherwise.
    let exact = caretAfter ?? (range.lowerBound + inserted.count)
    if isStop(exact) { caret = exact }
    coalesce = kind
    goalX = nil
  }

  private mutating func load(_ newSource: String) {
    source = newSource
    bytes = Array(newSource.utf8)
    document = Document.parse(newSource)
    text = EditableText(source: newSource)
    blocks = text.allBlocks(document)
    leaves = text.leafRanges(document)
    revision += 1
  }

  /// Replaces the whole source (a reload from disk). The caret keeps its place in the text around it: offsets
  /// before the change stay, offsets after it shift by the change's length.
  public mutating func reload(_ newSource: String) {
    let next = Array(newSource.utf8)
    base = next
    guard next != bytes else { return }
    let old = bytes
    var prefix = 0
    while prefix < old.count, prefix < next.count, old[prefix] == next[prefix] { prefix += 1 }
    var suffix = 0
    while suffix < old.count - prefix, suffix < next.count - prefix, old[old.count - 1 - suffix] == next[next.count - 1 - suffix] {
      suffix += 1
    }
    let offset = caret
    let mapped = offset <= prefix ? offset : (offset >= old.count - suffix ? offset + next.count - old.count : prefix)
    undoStack.append(Snapshot(source: source, caret: caret, anchor: anchor))
    redoStack = []
    load(newSource)
    savedRevision = revision
    anchor = nil
    caret = stop(near: min(max(mapped, 0), bytes.count))
  }

  public struct MergeOutcome: Equatable, Sendable {
    public var applied: Int
    public var keptMine: Int
  }

  /// Folds a change another writer made on disk into the edited text, line by line. Lines only disk changed are
  /// taken; where both changed the same lines, this text wins. The disk text becomes the new base, so the next
  /// autosave is allowed again. Returns nil when disk still matches the base.
  public mutating func merge(disk newSource: String) -> MergeOutcome? {
    let disk = Array(newSource.utf8)
    guard disk != base else { return nil }
    if disk == bytes {
      base = disk
      savedRevision = revision
      return MergeOutcome(applied: 0, keptMine: 0)
    }
    let result = LineMerge.merge(base: base, disk: disk, mine: bytes)
    let merged = String(decoding: result.text, as: UTF8.self)
    base = disk
    guard result.text != bytes else {
      if result.text == disk { savedRevision = revision }
      return MergeOutcome(applied: result.applied, keptMine: result.keptMine)
    }
    let old = bytes
    let next = result.text
    var prefix = 0
    while prefix < old.count, prefix < next.count, old[prefix] == next[prefix] { prefix += 1 }
    var suffix = 0
    while suffix < old.count - prefix, suffix < next.count - prefix, old[old.count - 1 - suffix] == next[next.count - 1 - suffix] {
      suffix += 1
    }
    let offset = caret
    let mapped = offset <= prefix ? offset : (offset >= old.count - suffix ? offset + next.count - old.count : prefix)
    undoStack.append(Snapshot(source: source, caret: caret, anchor: anchor))
    redoStack = []
    load(merged)
    if next == disk { savedRevision = revision }
    anchor = nil
    caret = stop(near: min(max(mapped, 0), bytes.count))
    coalesce = .none
    return MergeOutcome(applied: result.applied, keptMine: result.keptMine)
  }

  /// Typed text. Coalesces into one undo step until a word ends.
  public mutating func insert(_ typed: String) {
    let range = selection ?? caret..<caret
    let boundary = typed.first.map { $0.isWhitespace || $0.isPunctuation } ?? false
    replace(range, with: typed, kind: boundary ? .none : .typing)
    if boundary { coalesce = .none }
  }

  /// Pasted text: one undo step; line endings normalised to the file's own.
  public mutating func paste(_ pasted: String) {
    var text = pasted.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    if usesCRLF { text = text.replacingOccurrences(of: "\n", with: "\r\n") }
    replace(selection ?? caret..<caret, with: text, kind: .none)
  }

  var usesCRLF: Bool {
    guard let newline = bytes.firstIndex(of: UInt8(ascii: "\n")) else { return false }
    return newline > 0 && bytes[newline - 1] == UInt8(ascii: "\r")
  }

  var newline: String { usesCRLF ? "\r\n" : "\n" }

  public mutating func deleteSelection() {
    guard let selection else { return }
    replace(selection, with: "", kind: .none)
  }

  public mutating func deleteBackward(word: Bool = false) {
    if let selection { return replace(selection, with: "", kind: .none) }
    if !word, let prefix = markerBeforeCaret() {
      return replace(prefix, with: "", kind: .none)
    }
    guard let target = word ? wordStop(from: caret, forward: false) : adjacentStop(from: caret, forward: false),
      target < caret
    else { return }
    if joinsRaw(target, caret) { return move(to: target, extend: false) }
    let range = target..<caret
    replace(range, with: "", caretAfter: target, kind: .deleting)
  }

  public mutating func deleteForward(word: Bool = false) {
    if let selection { return replace(selection, with: "", kind: .none) }
    guard let target = word ? wordStop(from: caret, forward: true) : adjacentStop(from: caret, forward: true),
      target > caret
    else { return }
    if joinsRaw(caret, target) { return move(to: target, extend: false) }
    replace(caret..<target, with: "", caretAfter: caret, kind: .deleting)
  }

  /// Deleting across a block boundary where either side is raw (a fence, a table, a reference definition) would
  /// break that block's syntax, so the caret only moves there.
  func joinsRaw(_ lower: Int, _ upper: Int) -> Bool {
    guard let first = blockIndex(containing: lower), let second = blockIndex(containing: upper), first != second else {
      // Into or out of a gap: protect raw blocks on either side.
      return [lower, upper].contains { block(containing: $0)?.isRaw == true }
    }
    return blocks[first].isRaw || blocks[second].isRaw
  }

  /// At the first stop of a list item or quote line, Backspace removes the marker before deleting text.
  func markerBeforeCaret() -> Range<Int>? {
    guard let block = block(containing: caret), !block.isRaw, projection(of: block, caret: nil).boundaries[0] == caret else {
      return nil
    }
    let line = lineRange(containing: caret)
    let prefix = LinePrefix(bytes[line.lowerBound..<caret])
    guard prefix.markerRange != nil || !prefix.quotes.isEmpty, prefix.length == caret - line.lowerBound else {
      return nil
    }
    if let marker = prefix.markerRange { return (line.lowerBound + marker.lowerBound)..<caret }
    let last = prefix.quotes.last!
    return (line.lowerBound + last.lowerBound)..<caret
  }

  /// Enter: splits the block. In a list item it starts the next item (or ends the list on an empty item); in a
  /// quote it starts a new quoted paragraph; elsewhere it starts a new paragraph.
  public mutating func newParagraph() {
    if let selection { replace(selection, with: "", kind: .none) }
    let line = lineRange(containing: caret)
    if block(containing: caret)?.isRaw == true {
      // Inside code or a table: one line break, keeping the line's indentation.
      replace(caret..<caret, with: newline + leadingWhitespace(of: line), kind: .none)
      return
    }
    var prefix = LinePrefix(bytes[line.lowerBound..<line.upperBound])
    // A marker-like start ("2024. was") on a paragraph's continuation line is text, not a list item.
    if prefix.markerRange != nil, let block = block(containing: caret), block.source.lowerBound < line.lowerBound {
      prefix.markerRange = nil
      prefix.length = prefix.quotes.last?.upperBound ?? 0
    }
    let rest = bytes[(line.lowerBound + min(prefix.length, line.count))..<line.upperBound]
    let isEmpty = rest.allSatisfy { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") || $0 == UInt8(ascii: "\r") }
    if prefix.markerRange != nil {
      if isEmpty {
        replace(line.lowerBound..<line.upperBound, with: prefix.quotePrefix(in: bytes, line: line), kind: .none)
        return
      }
      let next = newline + prefix.continuation(in: bytes, line: line)
      replace(caret..<caret, with: next, kind: .none)
      return
    }
    if !prefix.quotes.isEmpty {
      let quote = prefix.quotePrefix(in: bytes, line: line)
      if isEmpty {
        replace(line.lowerBound..<line.upperBound, with: "", kind: .none)
        return
      }
      let bare = quote.trimmingCharacters(in: .whitespaces)
      replace(caret..<caret, with: newline + bare + newline + quote + indentAfterPrefix(line, prefix), kind: .none)
      return
    }
    replace(caret..<caret, with: newline + newline + indentAfterPrefix(line, prefix), kind: .none)
  }

  /// Spaces and tabs at the start of a line.
  func leadingWhitespace(of line: Range<Int>) -> String {
    let lead = bytes[line].prefix { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") }
    return String(decoding: lead, as: UTF8.self)
  }

  /// The indentation after a line's quote markers (a list item's continuation lines carry it).
  func indentAfterPrefix(_ line: Range<Int>, _ prefix: LinePrefix) -> String {
    let start = line.lowerBound + min(prefix.length, line.count)
    let lead = bytes[start..<line.upperBound].prefix { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") }
    return String(decoding: lead, as: UTF8.self)
  }

  /// Shift-Enter: a soft line break inside the block, keeping the line's continuation prefix.
  public mutating func softBreak() {
    let line = lineRange(containing: caret)
    if block(containing: caret)?.isRaw == true {
      replace(selection ?? caret..<caret, with: newline + leadingWhitespace(of: line), kind: .none)
      return
    }
    let prefix = LinePrefix(bytes[line.lowerBound..<line.upperBound])
    let indent = prefix.markerRange == nil ? indentAfterPrefix(line, prefix) : ""
    replace(selection ?? caret..<caret, with: newline + prefix.indentation(in: bytes, line: line) + indent, kind: .none)
  }

  func lineRange(containing offset: Int) -> Range<Int> {
    var start = min(offset, bytes.count)
    while start > 0, bytes[start - 1] != UInt8(ascii: "\n") { start -= 1 }
    var end = min(offset, bytes.count)
    while end < bytes.count, bytes[end] != UInt8(ascii: "\n") { end += 1 }
    if end > start, bytes[end - 1] == UInt8(ascii: "\r") { end -= 1 }
    return start..<end
  }

  // MARK: Formatting

  /// Inline emphasis a key can toggle: the markers it wraps text in.
  public enum Emphasis: Sendable {
    case italic, bold

    var markerLength: Int { self == .bold ? 2 : 1 }
    var marker: String { String(repeating: "*", count: markerLength) }
  }

  /// The text a formatting key acts on: the selection, else the word at the caret. Nil when there is neither, or when
  /// the text is code or spans blocks, where markers would corrupt the markdown.
  func formatTarget() -> Range<Int>? {
    var target = selection
    if target == nil {
      var lower = caret
      var upper = caret
      while lower > 0, isWordByte(bytes[lower - 1]) { lower -= 1 }
      while upper < bytes.count, isWordByte(bytes[upper]) { upper += 1 }
      if lower < upper { target = lower..<upper }
    }
    guard let target, let block = block(containing: target.lowerBound), !block.isRaw,
      target.upperBound <= block.source.upperBound
    else { return nil }
    return target
  }

  private func isWordByte(_ byte: UInt8) -> Bool {
    byte >= 0x80 || (byte >= 0x30 && byte <= 0x39) || (byte | 0x20 >= 0x61 && byte | 0x20 <= 0x7a)
  }

  private func starRun(from offset: Int, forward: Bool) -> Int {
    var count = 0
    var at = forward ? offset : offset - 1
    while at >= 0, at < bytes.count, bytes[at] == UInt8(ascii: "*") {
      count += 1
      at += forward ? 1 : -1
    }
    return count
  }

  /// Wraps the target in the emphasis markers, or takes them off when it is already emphasised. Bold and italic share
  /// `*`, so a run of three around the text is both. A selection that includes its own markers is unwrapped as if
  /// only the text inside were selected. One undo step. False when there is nothing to format.
  @discardableResult
  public mutating func toggle(_ emphasis: Emphasis) -> Bool {
    guard var core = formatTarget() else { return false }
    // A selection that carries its own pair of markers stands for the text inside them.
    let leading = bytes[core].prefix { $0 == UInt8(ascii: "*") }.count
    let trailing = bytes[core].reversed().prefix { $0 == UInt8(ascii: "*") }.count
    let carried = min(leading, trailing)
    if selection != nil, carried > 0, core.count > 2 * carried,
      !bytes[(core.lowerBound + carried)..<(core.upperBound - carried)].contains(UInt8(ascii: "*"))
    {
      core = (core.lowerBound + carried)..<(core.upperBound - carried)
    }
    let around = min(starRun(from: core.lowerBound, forward: false), starRun(from: core.upperBound, forward: true))
    let isOn = emphasis == .bold ? around >= 2 : around % 2 == 1
    let length = emphasis.markerLength
    let inner = String(decoding: bytes[core], as: UTF8.self)
    let hadSelection = selection != nil
    let caretInside = caret
    let shift: Int
    if isOn {
      replace((core.lowerBound - length)..<(core.upperBound + length), with: inner, kind: .none)
      shift = -length
    } else {
      replace(core, with: emphasis.marker + inner + emphasis.marker, kind: .none)
      shift = length
    }
    if hadSelection {
      move(to: core.lowerBound + shift, extend: false)
      move(to: core.upperBound + shift, extend: true)
    } else {
      move(to: caretInside + shift, extend: false)
    }
    return true
  }

  /// The text a link would wrap, and where it is: the selection, else the word at the caret.
  public func linkTarget() -> (range: Range<Int>, text: String)? {
    guard let range = formatTarget() else { return nil }
    return (range, String(decoding: bytes[range], as: UTF8.self))
  }

  /// Wraps `text` at `range` as `[text](url)`, if it is still what it was when the link was asked for. One undo step.
  @discardableResult
  public mutating func link(range: Range<Int>, text: String, url: String) -> Bool {
    guard range.upperBound <= bytes.count, String(decoding: bytes[range], as: UTF8.self) == text else { return false }
    let destination = url.contains { $0.isWhitespace || $0 == "(" || $0 == ")" } ? "<\(url)>" : url
    replace(range, with: "[\(text)](\(destination))", kind: .none)
    return true
  }

  // MARK: Undo

  public var canUndo: Bool { !undoStack.isEmpty }

  public mutating func undo() {
    guard let snapshot = undoStack.popLast() else { return }
    redoStack.append(Snapshot(source: source, caret: caret, anchor: anchor))
    restore(snapshot)
  }

  public mutating func redo() {
    guard let snapshot = redoStack.popLast() else { return }
    undoStack.append(Snapshot(source: source, caret: caret, anchor: anchor))
    restore(snapshot)
  }

  private mutating func restore(_ snapshot: Snapshot) {
    load(snapshot.source)
    caret = stop(near: snapshot.caret)
    anchor = snapshot.anchor
    coalesce = .none
    goalX = nil
  }
}

