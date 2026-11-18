import Foundation
import TermDownCore

/// One review mark: a source byte range tagged with a hotkey's type and label, in press order.
public struct ReviewMark: Equatable, Sendable {
  public var range: Range<Int>
  public var type: String
  public var label: String
  public var note: String?
  public var seq: Int

  public init(range: Range<Int>, type: String, label: String, note: String? = nil, seq: Int) {
    self.range = range
    self.type = type
    self.label = label
    self.note = note
    self.seq = seq
  }
}

/// The span one source change replaced, found by common prefix and suffix: `old[prefix..<oldEnd]` became
/// `new[prefix..<newEnd]`.
struct ByteChange: Equatable {
  var prefix: Int
  var oldEnd: Int
  var newEnd: Int

  init?(old: [UInt8], new: [UInt8]) {
    guard old != new else { return nil }
    var prefix = 0
    while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
    var suffix = 0
    while suffix < old.count - prefix, suffix < new.count - prefix, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] {
      suffix += 1
    }
    self.prefix = prefix
    oldEnd = old.count - suffix
    newEnd = new.count - suffix
  }
}

/// The marks of one review pass, kept in press order.
public struct ReviewMarks: Equatable, Sendable {
  public private(set) var marks: [ReviewMark] = []
  var nextSeq = 1

  public init() {}

  /// Marks read back from disk, in press order. Ranges that do not fit in `length` bytes (the text they were saved
  /// against) are dropped.
  public init(restoring saved: [SavedMark], within length: Int) {
    marks = saved.compactMap { mark in
      guard 0 <= mark.start, mark.start < mark.end, mark.end <= length else { return nil }
      return ReviewMark(range: mark.start..<mark.end, type: mark.type, label: mark.label, note: mark.note, seq: mark.seq)
    }
    nextSeq = (marks.map(\.seq).max() ?? 0) + 1
  }

  /// The marks as they are written between viewer runs.
  public var saved: [SavedMark] {
    marks.map {
      SavedMark(
        start: $0.range.lowerBound, end: $0.range.upperBound, type: $0.type, label: $0.label, note: $0.note,
        seq: $0.seq)
    }
  }

  public var isEmpty: Bool { marks.isEmpty }
  public var count: Int { marks.count }

  /// Adds a mark, or updates the one already on this exact range and type (which keeps its press order).
  @discardableResult
  public mutating func add(_ range: Range<Int>, type: String, label: String, note: String? = nil) -> ReviewMark? {
    guard !range.isEmpty else { return nil }
    if let index = marks.firstIndex(where: { $0.range == range && $0.type == type }) {
      marks[index].label = label
      marks[index].note = note
      return marks[index]
    }
    let mark = ReviewMark(range: range, type: type, label: label, note: note, seq: nextSeq)
    nextSeq += 1
    marks.append(mark)
    return mark
  }

  public mutating func removeLast() {
    _ = marks.popLast()
  }

  public mutating func remove(overlapping range: Range<Int>) {
    marks.removeAll { $0.range.overlaps(range) }
  }

  public mutating func removeAll() {
    marks = []
  }

  /// Drops the mark with this press order, if it is still there.
  public mutating func remove(seq: Int) {
    marks.removeAll { $0.seq == seq }
  }

  /// Gives a mark another hotkey's type and label, keeping its range and press order. The note goes with the old type
  /// unless the new type takes one (`keepNote`). A mark already on this range with the new type is replaced by it, so
  /// two marks never share a range and type.
  @discardableResult
  public mutating func retype(seq: Int, type: String, label: String, keepNote: Bool = false) -> ReviewMark? {
    guard let index = marks.firstIndex(where: { $0.seq == seq }) else { return nil }
    let range = marks[index].range
    marks[index].type = type
    marks[index].label = label
    if !keepNote { marks[index].note = nil }
    let kept = marks[index]
    marks.removeAll { $0.seq != seq && $0.range == range && $0.type == type }
    return kept
  }

  /// Sets or clears a mark's note.
  public mutating func setNote(seq: Int, _ note: String?) {
    guard let index = marks.firstIndex(where: { $0.seq == seq }) else { return }
    marks[index].note = note
  }

  /// Moves every mark across a change from `old` to `new`. An end before the changed span stays, an end after it
  /// shifts by the length change, an end inside it clamps to the span's edge, and a mark left empty is dropped.
  public mutating func remap(from old: [UInt8], to new: [UInt8]) {
    guard let change = ByteChange(old: old, new: new) else { return }
    let delta = change.newEnd - change.oldEnd
    marks = marks.compactMap { mark in
      let start = mark.range.lowerBound
      let end = mark.range.upperBound
      let lower = start < change.prefix ? start : (start >= change.oldEnd ? start + delta : change.newEnd)
      let upper = end <= change.prefix ? end : (end >= change.oldEnd ? end + delta : change.prefix)
      guard lower < upper else { return nil }
      var moved = mark
      moved.range = lower..<upper
      return moved
    }
  }

  /// The marks as contract annotations against `source`, in press order.
  public func annotations(in source: [UInt8]) -> [ReviewAnnotation] {
    marks.compactMap { annotation(for: $0, in: source) }
  }

  func annotation(for mark: ReviewMark, in source: [UInt8]) -> ReviewAnnotation? {
    guard mark.range.upperBound <= source.count else { return nil }
    let start = mark.range.lowerBound
    let end = mark.range.upperBound
    let startLine = lineStart(before: start, in: source)
    let endLine = lineStart(before: end, in: source)
    var contextEnd = end
    while contextEnd < source.count, source[contextEnd] != UInt8(ascii: "\n") { contextEnd += 1 }
    let text = Self.text(source[start..<end])
    let before = Self.text(source[startLine..<start])
    return ReviewAnnotation(
      type: mark.type, label: mark.label, text: text, note: mark.note,
      context: Self.text(source[startLine..<contextEnd]).replacingOccurrences(of: "\r", with: ""),
      line: source[..<start].lazy.filter { $0 == UInt8(ascii: "\n") }.count + 1,
      colFrom: before.utf16.count,
      endLine: source[..<end].lazy.filter { $0 == UInt8(ascii: "\n") }.count + 1,
      colTo: Self.text(source[endLine..<end]).utf16.count,
      occurrence: text.isEmpty ? 1 : before.components(separatedBy: text).count,
      seq: mark.seq)
  }

  private func lineStart(before offset: Int, in source: [UInt8]) -> Int {
    var start = offset
    while start > 0, source[start - 1] != UInt8(ascii: "\n") { start -= 1 }
    return start
  }

  private static func text(_ bytes: ArraySlice<UInt8>) -> String {
    String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
  }
}
