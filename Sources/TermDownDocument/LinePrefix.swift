import Foundation

/// The structural prefix of one source line: indentation, quote markers, and a list marker with its task box.
public struct LinePrefix: Sendable {
  public var quotes: [Range<Int>] = []
  public var markerRange: Range<Int>?
  public var markerText = ""
  public var number: Int?
  public var delimiter: UInt8 = UInt8(ascii: ".")
  public var task = false
  /// Bytes the prefix covers.
  public var length = 0

  public init<C: Collection>(_ line: C) where C.Element == UInt8 {
    let bytes = Array(line)
    var index = 0
    func skipSpaces() { while index < bytes.count, bytes[index] == UInt8(ascii: " ") || bytes[index] == UInt8(ascii: "\t") { index += 1 } }
    while true {
      let start = index
      skipSpaces()
      guard index < bytes.count, bytes[index] == UInt8(ascii: ">") else {
        index = start
        break
      }
      index += 1
      if index < bytes.count, bytes[index] == UInt8(ascii: " ") { index += 1 }
      quotes.append(start..<index)
    }
    let markerStart = index
    skipSpaces()
    let bulletAt = index
    if index < bytes.count, [UInt8(ascii: "-"), UInt8(ascii: "*"), UInt8(ascii: "+")].contains(bytes[index]),
      index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: " ")
    {
      markerText = String(UnicodeScalar(bytes[index]))
      index += 2
    } else {
      var digits = index
      while digits < bytes.count, digits - index < 9, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[digits]) {
        digits += 1
      }
      if digits > index, digits + 1 < bytes.count, bytes[digits] == UInt8(ascii: ".") || bytes[digits] == UInt8(ascii: ")"),
        bytes[digits + 1] == UInt8(ascii: " ")
      {
        number = Int(String(decoding: bytes[index..<digits], as: UTF8.self))
        delimiter = bytes[digits]
        index = digits + 2
      } else {
        index = markerStart
        length = index
        return
      }
    }
    _ = bulletAt
    while index < bytes.count, bytes[index] == UInt8(ascii: " ") { index += 1 }
    if index + 3 <= bytes.count, bytes[index] == UInt8(ascii: "["),
      [UInt8(ascii: " "), UInt8(ascii: "x"), UInt8(ascii: "X")].contains(bytes[index + 1]), bytes[index + 2] == UInt8(ascii: "]")
    {
      task = true
      index += 3
      while index < bytes.count, bytes[index] == UInt8(ascii: " ") { index += 1 }
    }
    markerRange = markerStart..<index
    length = index
  }

  /// Quote markers of the line, as written.
  public func quotePrefix(in bytes: [UInt8], line: Range<Int>) -> String {
    guard let last = quotes.last else { return "" }
    return String(decoding: bytes[line.lowerBound..<(line.lowerBound + last.upperBound)], as: UTF8.self)
  }

  /// The prefix of the next list item: same quotes and indentation, the next number, an open task box.
  public func continuation(in bytes: [UInt8], line: Range<Int>) -> String {
    guard let marker = markerRange else { return quotePrefix(in: bytes, line: line) }
    let lead = String(decoding: bytes[line.lowerBound..<(line.lowerBound + marker.lowerBound)], as: UTF8.self)
    let markerBytes = bytes[(line.lowerBound + marker.lowerBound)..<(line.lowerBound + marker.upperBound)]
    let indent = String(String(decoding: markerBytes, as: UTF8.self).prefix { $0 == " " || $0 == "\t" })
    let item: String
    if let number {
      item = "\(number + 1)\(Character(UnicodeScalar(delimiter))) "
    } else {
      item = markerText + " "
    }
    return lead + indent + item + (task ? "[ ] " : "")
  }

  /// Quote markers plus spaces lining up with the content, for a soft break inside the block.
  public func indentation(in bytes: [UInt8], line: Range<Int>) -> String {
    let quote = quotePrefix(in: bytes, line: line)
    guard let marker = markerRange else { return quote }
    return quote + String(repeating: " ", count: max(marker.upperBound - (quotes.last?.upperBound ?? 0), 0))
  }
}


extension EditableText {
  /// Byte ranges of every leaf block (paragraphs, headings, code, tables, HTML, rules), in document order.
  public func leafRanges(_ document: Document) -> [Range<Int>] {
    var result: [Range<Int>] = []
    func walk(_ blocks: [Block]) {
      for block in blocks {
        switch block.kind {
        case .blockQuote(let children): walk(children)
        case .alert(let alert): walk(alert.blocks)
        case .list(let list): for item in list.items { walk(item.blocks) }
        case .footnoteDefinition(let footnote): walk(footnote.blocks)
        default:
          if let range = byteRange(block.range) { result.append(range) }
        }
      }
    }
    walk(document.blocks)
    return result.sorted { $0.lowerBound < $1.lowerBound }
  }

  /// The single caret stop on a blank line (or an empty list item, or an empty quote line) containing `offset`:
  /// the end of the line's structural prefix. Nil when the line has content or lies inside a leaf block.
  public func blankLineStop(at offset: Int, leaves: [Range<Int>]) -> Int? {
    guard offset >= 0, offset <= source.count else { return nil }
    var start = offset
    while start > 0, source[start - 1] != UInt8(ascii: "\n") { start -= 1 }
    var end = offset
    while end < source.count, source[end] != UInt8(ascii: "\n") { end += 1 }
    var contentEnd = end
    if contentEnd > start, source[contentEnd - 1] == UInt8(ascii: "\r") { contentEnd -= 1 }
    let prefix = LinePrefix(source[start..<contentEnd])
    let rest = source[(start + min(prefix.length, contentEnd - start))..<contentEnd]
    guard rest.allSatisfy({ $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") }) else { return nil }
    // A blank line inside a code block or HTML block is content, not a gap.
    let stop = min(start + prefix.length, contentEnd)
    // An ordinary blank line separating two blocks is not a stop: only an empty list item, or a blank line with
    // blank lines (or the file's edges) on both sides, where typing starts a new block.
    if prefix.markerRange == nil {
      guard isBlankLine(before: start), isBlankLine(after: end) else { return nil }
    }
    if leaves.contains(where: { $0.lowerBound <= start && stop < $0.upperBound }) { return nil }
    // Front matter is not a gap either.
    if frontMatterLines > 0, position(ofByte: start).line <= frontMatterLines { return nil }
    return stop
  }

  /// Whether the line before the one starting at `start` is blank (or there is none).
  func isBlankLine(before start: Int) -> Bool {
    guard start > 0 else { return true }
    var lineStart = start - 1
    while lineStart > 0, source[lineStart - 1] != UInt8(ascii: "\n") { lineStart -= 1 }
    return isBlank(lineStart..<(start - 1))
  }

  /// Whether the line after the one ending at `end` (a newline or the file's end) is blank (or there is none).
  func isBlankLine(after end: Int) -> Bool {
    guard end < source.count else { return true }
    var lineEnd = end + 1
    while lineEnd < source.count, source[lineEnd] != UInt8(ascii: "\n") { lineEnd += 1 }
    return isBlank((end + 1)..<lineEnd)
  }

  private func isBlank(_ range: Range<Int>) -> Bool {
    let prefix = LinePrefix(source[range])
    guard prefix.markerRange == nil else { return false }
    return source[(range.lowerBound + min(prefix.length, range.count))..<range.upperBound].allSatisfy {
      $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") || $0 == UInt8(ascii: "\r")
    }
  }
}
