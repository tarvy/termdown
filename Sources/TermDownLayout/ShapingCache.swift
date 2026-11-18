import CoreGraphics
import Foundation

/// Shaped runs keyed by their content and styles, so preparing a document again (after a keystroke) only shapes
/// the runs that changed. Positions are stored relative to the run and rebased when reused.
final class ShapingCache: @unchecked Sendable {
  struct Entry {
    /// Segments with run-local ranges and run-local box groups.
    var segments: [ShapedSegment]
    var atoms: [CachedAtom]
    var words: [Word]
    var run: Run
  }

  enum CachedAtom {
    case segment(Int)
    case hardBreak
    case image(Int)
    case anchor(String)
  }

  static let shared = ShapingCache()
  static let capacity = 50_000

  private let lock = NSLock()
  private var typography: Typography?
  private var entries: [AnyHashable: Entry] = [:]

  func clear() {
    lock.lock()
    entries = [:]
    lock.unlock()
  }

  func entry(_ key: AnyHashable, typography: Typography) -> Entry? {
    lock.lock()
    defer { lock.unlock() }
    guard self.typography == typography else { return nil }
    return entries[key]
  }

  func store(_ entry: Entry, for key: AnyHashable, typography: Typography) {
    lock.lock()
    defer { lock.unlock() }
    if self.typography != typography {
      self.typography = typography
      entries = [:]
    }
    if entries.count >= Self.capacity { entries = [:] }
    entries[key] = entry
  }
}

extension ShapedSegment {
  /// A copy moved by `delta` in the document text, with its box group renumbered.
  func rebased(by delta: Int, group: Int?) -> ShapedSegment {
    ShapedSegment(
      range: (range.lowerBound + delta)..<(range.upperBound + delta), line: line, lineStart: lineStart, style: style,
      width: width, trailingWhitespace: trailingWhitespace, ascent: ascent, descent: descent, fontSize: fontSize,
      baselineShift: baselineShift, above: above, below: below, leadingPad: leadingPad, trailingPad: trailingPad,
      boxVerticalPad: boxVerticalPad, breakAfter: breakAfter, boxGroup: group, affectsLineHeight: affectsLineHeight,
      bidiLevel: bidiLevel, drawOffset: drawOffset)
  }
}
