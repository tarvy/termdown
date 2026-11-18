import Foundation

/// Inline styling a span of editable text carries.
public struct InlineMarks: OptionSet, Hashable, Sendable {
  public let rawValue: UInt8
  public init(rawValue: UInt8) { self.rawValue = rawValue }
  public static let italic = InlineMarks(rawValue: 1 << 0)
  public static let bold = InlineMarks(rawValue: 1 << 1)
  public static let strikethrough = InlineMarks(rawValue: 1 << 2)
  public static let code = InlineMarks(rawValue: 1 << 3)
}

/// One piece of an editable block. Spans tile the block's source bytes with no gaps or overlaps.
public struct EditSpan: Hashable, Sendable {
  public enum Kind: Hashable, Sendable {
    /// `display` is the source bytes verbatim, so rendered and source characters correspond one to one.
    case text
    /// An entity or a soft line break: `display` stands for the whole source range and the caret skips over it.
    case replaced
    /// A hard line break; `display` is "\n".
    case hardBreak
    /// Syntax that is hidden unless the caret is inside `owner`. When revealed, it shows verbatim.
    case markup
    /// A line prefix (quote markers, indentation, trailing spaces) that is never shown.
    case hidden
    /// A footnote reference or image: `display` (possibly empty) stands in for the source until revealed.
    case atom
  }

  /// UTF-8 byte offsets into the whole file.
  public var source: Range<Int>
  public var display: String
  public var kind: Kind
  public var marks: InlineMarks
  public var link: String?
  /// For markup and atoms: the syntax node whose source range reveals this span when the caret is inside it.
  public var owner: Range<Int>?
  /// The image an atom (or the markup of an HTML <img>) stands for.
  public var image: Image? = nil

  public func isRevealed(caret: Int?) -> Bool {
    guard let caret, let owner, kind == .markup || kind == .atom else { return false }
    return caret >= owner.lowerBound && caret <= owner.upperBound
  }

  /// What this span shows for a given caret.
  public func shown(caret: Int?, source bytes: [UInt8]) -> String {
    if isRevealed(caret: caret) { return String(decoding: bytes[source], as: UTF8.self) }
    switch kind {
    case .markup, .hidden: return ""
    default: return display
    }
  }
}

public struct EditableBlock: Hashable, Sendable {
  public enum Kind: Hashable, Sendable {
    case paragraph
    case heading(level: Int)
    /// A block without a live-preview map (code, table, HTML, alert, or a paragraph that failed its check):
    /// edited as verbatim source, shown raw only while the caret is inside it.
    case raw
  }

  public var isRaw: Bool { kind == .raw }

  public var kind: Kind
  /// The block's bytes in the file, from the first content byte to the last.
  public var source: Range<Int>
  public var spans: [EditSpan]

  /// The block's text as view mode shows it: every span's display, nothing revealed.
  public var hiddenText: String { spans.map { $0.kind == .markup || $0.kind == .hidden ? "" : $0.display }.joined() }
}

/// Builds exact source maps for the blocks a person can edit in place: paragraphs and headings in the main
/// flow, block quotes, lists and footnotes. Every other block (code, tables, HTML, alerts) is edited as raw
/// source, and so is any block whose map fails its own check.
public final class EditableText: @unchecked Sendable {
  public let source: [UInt8]
  /// The last block that failed its check: (built hidden text, view text). For diagnostics.
  public internal(set) var lastMismatch: (String, String)?
  let lineStarts: [Int]

  /// Lines the front matter takes, if any (they are never a gap for the caret).
  public let frontMatterLines: Int

  public init(source: String) {
    frontMatterLines = FrontMatter.split(source).bodyLineOffset
    self.source = Array(source.utf8)
    var starts = [0]
    for (index, byte) in self.source.enumerated() where byte == UInt8(ascii: "\n") { starts.append(index + 1) }
    lineStarts = starts
  }

  /// Byte offset of a 1-based line and 1-based byte column.
  public func offset(_ position: SourcePosition) -> Int? {
    guard position.line >= 1, position.line <= lineStarts.count else { return nil }
    return min(lineStarts[position.line - 1] + max(position.column - 1, 0), source.count)
  }

  /// 1-based line and byte column of a byte offset.
  public func position(ofByte offset: Int) -> SourcePosition {
    var low = 0
    var high = lineStarts.count - 1
    while low < high {
      let middle = (low + high + 1) / 2
      if lineStarts[middle] <= offset { low = middle } else { high = middle - 1 }
    }
    return SourcePosition(line: low + 1, column: offset - lineStarts[low] + 1)
  }

  /// An inclusive cmark-style source range for a byte range.
  public func sourceRange(_ range: Range<Int>) -> SourceRange {
    SourceRange(start: position(ofByte: range.lowerBound), end: position(ofByte: max(range.upperBound - 1, range.lowerBound)))
  }

  /// Byte range of an inclusive cmark source range.
  public func byteRange(_ range: SourceRange) -> Range<Int>? {
    guard range.start.line >= 1, let start = offset(range.start), let last = offset(range.end) else { return nil }
    let end = min(last + 1, source.count)
    return start <= end ? start..<end : nil
  }

  public func blocks(_ document: Document) -> [EditableBlock] {
    var result: [EditableBlock] = []
    collect(document.blocks, quoteDepth: 0, into: &result)
    return result
  }

  /// Every leaf block: mapped paragraphs and headings, and raw blocks for the rest, in source order.
  public func allBlocks(_ document: Document) -> [EditableBlock] {
    var result: [EditableBlock] = []
    func walk(_ blocks: [Block], quoteDepth: Int) {
      for block in blocks {
        switch block.kind {
        case .paragraph(let inlines):
          if let mapped = build(block, inlines: inlines, kind: .paragraph, quoteDepth: quoteDepth) {
            result.append(mapped)
          } else if let raw = rawBlock(block) {
            result.append(raw)
          }
        case .heading(let heading):
          if let mapped = build(block, inlines: heading.content, kind: .heading(level: heading.level), quoteDepth: quoteDepth) {
            result.append(mapped)
          } else if let raw = rawBlock(block) {
            result.append(raw)
          }
        case .blockQuote(let children) where isMarkdownQuote(block):
          walk(children, quoteDepth: quoteDepth + 1)
        case .list(let list):
          for item in list.items { walk(item.blocks, quoteDepth: quoteDepth) }
        case .footnoteDefinition(let footnote):
          walk(footnote.blocks, quoteDepth: quoteDepth)
        default:
          if let raw = rawBlock(block) { result.append(raw) }
        }
      }
    }
    walk(document.blocks, quoteDepth: 0)
    result += uncoveredLines(result)
    // Ranges from HTML lowering can overlap; keep the first block at each position.
    var seen = 0
    return result.sorted { $0.source.lowerBound < $1.source.lowerBound }.filter { block in
      defer { seen = max(seen, block.source.upperBound) }
      return block.source.lowerBound >= seen
    }
  }

  /// Lines with content that no block covers (link reference definitions, stray syntax): each is a raw block,
  /// so the caret can reach it and no edit deletes it unseen.
  func uncoveredLines(_ blocks: [EditableBlock]) -> [EditableBlock] {
    let ranges = blocks.map(\.source).sorted { $0.lowerBound < $1.lowerBound }
    var result: [EditableBlock] = []
    var lineStart = 0
    var lineNumber = 1
    var next = 0
    while lineStart <= source.count {
      var lineEnd = lineStart
      while lineEnd < source.count, source[lineEnd] != UInt8(ascii: "\n") { lineEnd += 1 }
      var contentEnd = lineEnd
      if contentEnd > lineStart, source[contentEnd - 1] == UInt8(ascii: "\r") { contentEnd -= 1 }
      while next < ranges.count, ranges[next].upperBound < lineStart { next += 1 }
      let covered = ranges[next...].prefix { $0.lowerBound <= lineEnd }.contains { $0.upperBound >= lineStart }
      if !covered, lineNumber > frontMatterLines {
        let prefix = LinePrefix(source[lineStart..<contentEnd])
        let restStart = lineStart + min(prefix.length, contentEnd - lineStart)
        let hasContent = source[restStart..<contentEnd].contains { $0 != UInt8(ascii: " ") && $0 != UInt8(ascii: "\t") }
        if hasContent, prefix.markerRange == nil || restStart < contentEnd {
          let start = lineStart + (source[lineStart..<contentEnd].firstIndex { $0 != UInt8(ascii: " ") && $0 != UInt8(ascii: "\t") }.map { $0 - lineStart } ?? 0)
          let span = EditSpan(
            source: start..<contentEnd, display: String(decoding: source[start..<contentEnd], as: UTF8.self), kind: .text,
            marks: [], link: nil, owner: nil)
          result.append(EditableBlock(kind: .raw, source: start..<contentEnd, spans: [span]))
        }
      }
      guard lineEnd < source.count else { break }
      lineStart = lineEnd + 1
      lineNumber += 1
    }
    return result
  }

  /// A raw block: its bytes verbatim, with each line ending as a hard break.
  public func rawBlock(_ block: Block) -> EditableBlock? {
    guard let range = byteRange(block.range), !range.isEmpty else { return nil }
    var spans: [EditSpan] = []
    var index = range.lowerBound
    var runStart = index
    func flush(_ end: Int) {
      guard end > runStart else { return }
      spans.append(
        EditSpan(
          source: runStart..<end, display: String(decoding: source[runStart..<end], as: UTF8.self), kind: .text,
          marks: [], link: nil, owner: nil))
    }
    while index < range.upperBound {
      if source[index] == UInt8(ascii: "\n") {
        let lineEnd = index > runStart && source[index - 1] == UInt8(ascii: "\r") ? index - 1 : index
        flush(lineEnd)
        spans.append(EditSpan(source: lineEnd..<(index + 1), display: "\n", kind: .hardBreak, marks: [], link: nil, owner: nil))
        runStart = index + 1
      }
      index += 1
    }
    flush(range.upperBound)
    return EditableBlock(kind: .raw, source: range, spans: spans)
  }

  private func collect(_ blocks: [Block], quoteDepth: Int, into result: inout [EditableBlock]) {
    for block in blocks {
      switch block.kind {
      case .paragraph(let inlines):
        if let editable = build(block, inlines: inlines, kind: .paragraph, quoteDepth: quoteDepth) {
          result.append(editable)
        }
      case .heading(let heading):
        if let editable = build(block, inlines: heading.content, kind: .heading(level: heading.level), quoteDepth: quoteDepth) {
          result.append(editable)
        }
      case .blockQuote(let children):
        guard isMarkdownQuote(block) else { continue }
        collect(children, quoteDepth: quoteDepth + 1, into: &result)
      case .list(let list):
        for item in list.items { collect(item.blocks, quoteDepth: quoteDepth, into: &result) }
      case .footnoteDefinition(let footnote):
        collect(footnote.blocks, quoteDepth: quoteDepth, into: &result)
      default:
        continue
      }
    }
  }

  private func isMarkdownQuote(_ block: Block) -> Bool {
    guard let range = byteRange(block.range), range.lowerBound < source.count else { return false }
    return source[range.lowerBound] == UInt8(ascii: ">")
  }

  // MARK: - Building one block

  func build(_ block: Block, inlines: [Inline], kind: EditableBlock.Kind, quoteDepth: Int) -> EditableBlock? {
    lastMismatch = nil
    guard var range = byteRange(block.range), !range.isEmpty else { return nil }
    let view = Self.viewText(inlines)
    var attempt = range.lowerBound
    var skipped = 0
    while true {
      let replay = Replay(text: self, start: attempt, limit: range.upperBound, quoteDepth: quoteDepth)
      if attempt > range.lowerBound {
        // Link reference definitions cmark folded into the paragraph: shown only under the caret.
        replay.markup(range.lowerBound..<attempt, owner: range.lowerBound..<attempt)
      }
      if let end = replay.block(inlines, kind: kind, blockRange: range) {
        range = range.lowerBound..<end
        let editable = EditableBlock(kind: kind, source: range, spans: replay.spans)
        if editable.hiddenText == view { return editable }
        lastMismatch = (editable.hiddenText, view)
      } else if lastMismatch == nil {
        lastMismatch = (replay.failure, view)
      }
      // Retry past one more leading line, for paragraphs that start with reference definitions.
      guard case .paragraph = kind, skipped < 8, attempt < range.upperBound, source[attempt] == UInt8(ascii: "[")
        || (skipped > 0 && attempt < range.upperBound)
      else { return nil }
      guard let newline = source[attempt..<range.upperBound].firstIndex(of: UInt8(ascii: "\n")) else { return nil }
      attempt = continuationStart(newline + 1, limit: range.upperBound, quoteDepth: quoteDepth)
      skipped += 1
      lastMismatch = nil
    }
  }

  /// The text view mode renders for these inlines, matching the preparer's collect().
  public static func viewText(_ inlines: [Inline]) -> String {
    var text = ""
    for inline in inlines {
      switch inline.kind {
      case .text(let value), .code(let value): text += value
      case .softBreak: text += " "
      case .hardBreak: text += "\n"
      case .emphasis(let children), .strong(let children), .strikethrough(let children), .keyboard(let children),
        .subscript(let children), .superscript(let children), .inserted(let children), .marked(let children),
        .small(let children), .abbreviation(_, let children):
        text += viewText(children)
      case .link(let link): text += viewText(link.content)
      case .image: break
      case .footnoteReference(_, let number): text += "\(number)"
      case .anchor: break
      }
    }
    return text
  }

  /// The first content byte of a continuation line: quote markers it may carry, then all leading whitespace.
  func continuationStart(_ start: Int, limit: Int, quoteDepth: Int) -> Int {
    var index = start
    var markers = 0
    while markers < quoteDepth {
      // Quotes nested in list items carry the item's indentation before their marker.
      var probe = index
      while probe < limit, isSpace(source[probe]) { probe += 1 }
      guard probe < limit, source[probe] == UInt8(ascii: ">") else { break }
      index = probe + 1
      markers += 1
      if index < limit, source[index] == UInt8(ascii: " ") || source[index] == UInt8(ascii: "\t") { index += 1 }
    }
    while index < limit, isSpace(source[index]) { index += 1 }
    return index
  }

  /// Walks cmark's inline tree in source order, consuming the block's bytes. Delimiters must sit where the tree
  /// says; text must match byte for byte under cmark's own escape and entity rules. Any mismatch fails the block.
  final class Replay {
    let text: EditableText
    let source: [UInt8]
    var cursor: Int
    let limit: Int
    let quoteDepth: Int
    var spans: [EditSpan] = []
    var failure = ""

    init(text: EditableText, start: Int, limit: Int, quoteDepth: Int) {
      self.text = text
      source = text.source
      cursor = start
      self.limit = limit
      self.quoteDepth = quoteDepth
    }

    private func fail(_ reason: String) -> Bool {
      if failure.isEmpty {
        let context = String(decoding: source[cursor..<min(cursor + 24, limit)], as: UTF8.self)
        failure = "\(reason) at \(context.debugDescription)"
      }
      return false
    }

    // MARK: Emitting

    private func append(_ span: EditSpan) {
      guard !span.source.isEmpty else { return }
      if let last = spans.last, last.kind == span.kind, span.kind == .text || span.kind == .hidden,
        last.marks == span.marks, last.link == span.link, last.owner == span.owner,
        last.source.upperBound == span.source.lowerBound
      {
        let merged = last.source.lowerBound..<span.source.upperBound
        spans[spans.count - 1].source = merged
        spans[spans.count - 1].display =
          span.kind == .text ? String(decoding: source[merged], as: UTF8.self) : ""
      } else {
        spans.append(span)
      }
    }

    func markup(_ range: Range<Int>, owner: Range<Int>?, marks: InlineMarks = [], link: String? = nil) {
      append(EditSpan(source: range, display: "", kind: .markup, marks: marks, link: link, owner: owner))
    }

    private func hidden(_ range: Range<Int>) {
      append(EditSpan(source: range, display: "", kind: .hidden, marks: [], link: nil, owner: nil))
    }

    private func verbatim(_ range: Range<Int>, marks: InlineMarks, link: String?) {
      append(
        EditSpan(
          source: range, display: String(decoding: source[range], as: UTF8.self), kind: .text, marks: marks,
          link: link, owner: nil))
    }

    /// Sets the owner of spans emitted since `first` that were opened without one (delimiters of a node).
    private func own(from first: Int, _ owner: Range<Int>) {
      for index in first..<spans.count where spans[index].kind == .markup && spans[index].owner == nil {
        spans[index].owner = owner
      }
    }

    // MARK: Blocks

    /// Replays a whole block and returns the end of its bytes, or nil.
    func block(_ inlines: [Inline], kind: EditableBlock.Kind, blockRange: Range<Int>) -> Int? {
      let start = cursor
      if case .heading = kind, cursorByte == UInt8(ascii: "#") || isLeadingHashes() {
        // ATX opener: up to three spaces, the hashes, and the spaces after them.
        var end = cursor
        while end < limit, source[end] == UInt8(ascii: " ") { end += 1 }
        while end < limit, source[end] == UInt8(ascii: "#") { end += 1 }
        while end < limit, isSpace(source[end]) { end += 1 }
        markup(cursor..<end, owner: blockRange)
        cursor = end
        guard inlineList(inlines, marks: [], link: nil) else { return nil }
        // Closing sequence and trailing spaces.
        // cmark's range stops before the closing sequence, so scan to the end of the line.
        let tail = cursor
        while cursor < source.count, isSpace(source[cursor]) || source[cursor] == UInt8(ascii: "#") {
          cursor += 1
        }
        guard cursor == source.count || source[cursor] == UInt8(ascii: "\n") || source[cursor] == UInt8(ascii: "\r")
        else { return fail("heading tail") ? nil : nil }
        // cmark's range stops before trailing spaces, so widen the owner: the caret that has just typed a space at
        // the end of the line is still inside the heading.
        let owner = blockRange.lowerBound..<max(blockRange.upperBound, cursor)
        for index in spans.indices where spans[index].owner == blockRange { spans[index].owner = owner }
        markup(tail..<cursor, owner: owner)
        return cursor
      }
      guard inlineList(inlines, marks: [], link: nil) else { return nil }
      if case .heading = kind {
        // Setext underline: the line after the content, made only of = or -.
        let tail = cursor
        while cursor < limit, isSpace(source[cursor]) || source[cursor] == UInt8(ascii: "\r") { cursor += 1 }
        guard cursor < limit, source[cursor] == UInt8(ascii: "\n") else { return fail("setext newline") ? nil : nil }
        cursor = text.continuationStart(cursor + 1, limit: limit, quoteDepth: quoteDepth)
        guard cursor < limit, source[cursor] == UInt8(ascii: "=") || source[cursor] == UInt8(ascii: "-") else {
          return fail("setext underline") ? nil : nil
        }
        let underline = source[cursor]
        while cursor < limit, source[cursor] == underline { cursor += 1 }
        while cursor < limit, isSpace(source[cursor]) || source[cursor] == UInt8(ascii: "\r") { cursor += 1 }
        markup(tail..<cursor, owner: start..<cursor)
        own(from: 0, start..<cursor)
        return cursor
      }
      // Trailing whitespace, then nothing else may remain.
      let tail = cursor
      while cursor < limit, isWhitespace(source[cursor]) { cursor += 1 }
      guard cursor == limit else { return fail("leftover") ? nil : nil }
      // Spaces and tabs typed at the end of the last line are shown while the caret is in them, so the caret can
      // rest after a typed space; a line ending stays hidden.
      var spaces = tail
      while spaces < cursor, source[spaces] == UInt8(ascii: " ") || source[spaces] == UInt8(ascii: "\t") { spaces += 1 }
      if spaces > tail { markup(tail..<spaces, owner: tail..<spaces) }
      hidden(spaces..<cursor)
      return cursor
    }

    private var cursorByte: UInt8? { cursor < limit ? source[cursor] : nil }

    private func isLeadingHashes() -> Bool {
      var probe = cursor
      while probe < limit, source[probe] == UInt8(ascii: " ") { probe += 1 }
      return probe < limit && source[probe] == UInt8(ascii: "#")
    }

    // MARK: Inlines

    private func inlineList(_ inlines: [Inline], marks: InlineMarks, link: String?) -> Bool {
      for (index, inline) in inlines.enumerated() {
        skipTags(before: inline, marks: marks, link: link)
        guard self.inline(inline, marks: marks, link: link, next: inlines.dropFirst(index + 1).first) else {
          return false
        }
      }
      skipTags(before: nil, marks: marks, link: link)
      return true
    }

    /// Raw HTML tags between nodes (the tags of kbd, sup, a, and comments) are markup owned by the tag.
    private func skipTags(before next: Inline?, marks: InlineMarks, link: String?) {
      while cursor < limit, source[cursor] == UInt8(ascii: "<"), let end = text.htmlTag(at: cursor, limit: limit) {
        if case .text(let value)? = next?.kind, Array(value.utf8).starts(with: source[cursor..<end]) { return }
        if case .hardBreak? = next?.kind, isBreakTag(cursor..<end) { return }
        if case .link(let link)? = next?.kind, link.isAutolink { return }
        markup(cursor..<end, owner: cursor..<end, marks: marks, link: link)
        cursor = end
      }
    }

    private func isBreakTag(_ range: Range<Int>) -> Bool {
      let tag = String(decoding: source[range], as: UTF8.self).lowercased()
      return tag.hasPrefix("<br") && (tag.count == 4 || !isAlphanumeric(UInt8(tag.utf8[tag.utf8.index(tag.utf8.startIndex, offsetBy: 3)])))
    }

    private func inline(_ inline: Inline, marks: InlineMarks, link: String?, next: Inline?) -> Bool {
      switch inline.kind {
      case .text(let value):
        return matchText(Array(value.utf8), marks: marks, link: link)
      case .softBreak:
        return lineBreak(hard: false)
      case .hardBreak:
        return lineBreak(hard: true)
      case .code(let value):
        return code(value, marks: marks.union(.code), link: link)
      case .emphasis(let children):
        return delimited(children, width: 1, chars: [UInt8(ascii: "*"), UInt8(ascii: "_")], mark: .italic, marks: marks, link: link)
      case .strong(let children):
        return delimited(children, width: 2, chars: [UInt8(ascii: "*"), UInt8(ascii: "_")], mark: .bold, marks: marks, link: link)
      case .strikethrough(let children):
        var width = 0
        while cursor + width < limit, source[cursor + width] == UInt8(ascii: "~"), width < 2 { width += 1 }
        if width == 0 { return inlineList(children, marks: marks.union(.strikethrough), link: link) }
        return delimited(children, width: width, chars: [UInt8(ascii: "~")], mark: .strikethrough, marks: marks, link: link)
      case .keyboard(let children), .subscript(let children), .superscript(let children), .inserted(let children),
        .marked(let children), .small(let children), .abbreviation(_, let children):
        return inlineList(children, marks: marks, link: link)
      case .link(let target):
        return self.link(target, marks: marks)
      case .image(let picture):
        return image(picture)
      case .footnoteReference(_, let number):
        let start = cursor
        guard source[cursor..<limit].starts(with: Array("[^".utf8)),
          let close = source[cursor..<limit].firstIndex(of: UInt8(ascii: "]"))
        else { return fail("footnote") }
        cursor = close + 1
        append(
          EditSpan(source: start..<cursor, display: "\(number)", kind: .atom, marks: marks, link: link, owner: start..<cursor))
        return true
      case .anchor:
        return true
      }
    }

    private func matchText(_ value: [UInt8], marks: InlineMarks, link: String?) -> Bool {
      var index = 0
      var runStart = cursor
      func flush() {
        if cursor > runStart { verbatim(runStart..<cursor, marks: marks, link: link) }
      }
      while index < value.count {
        guard cursor < limit else { return fail("text ran past block") }
        let byte = source[cursor]
        if byte == UInt8(ascii: "\\"), cursor + 1 < limit, isASCIIPunctuation(source[cursor + 1]),
          source[cursor + 1] == value[index]
        {
          flush()
          markup(cursor..<(cursor + 1), owner: cursor..<(cursor + 2), marks: marks, link: link)
          cursor += 1
          runStart = cursor
          cursor += 1
          index += 1
          continue
        }
        if byte == UInt8(ascii: "&"), let (end, decoded) = text.entity(at: cursor, limit: limit),
          value[index...].starts(with: Array(decoded.utf8))
        {
          flush()
          append(
            EditSpan(source: cursor..<end, display: decoded, kind: .replaced, marks: marks, link: link, owner: nil))
          cursor = end
          runStart = cursor
          index += decoded.utf8.count
          continue
        }
        if byte == value[index] {
          cursor += 1
          index += 1
          continue
        }
        if byte == UInt8(ascii: "<"), let end = text.htmlTag(at: cursor, limit: limit) {
          flush()
          markup(cursor..<end, owner: cursor..<end, marks: marks, link: link)
          cursor = end
          runStart = cursor
          continue
        }
        flush()
        return fail("text mismatch (wanted \(String(decoding: value[index...].prefix(12), as: UTF8.self).debugDescription))")
      }
      flush()
      return true
    }

    private func lineBreak(hard: Bool) -> Bool {
      let start = cursor
      if hard, cursor < limit, source[cursor] == UInt8(ascii: "<"), let end = text.htmlTag(at: cursor, limit: limit),
        isBreakTag(cursor..<end)
      {
        append(EditSpan(source: cursor..<end, display: "\n", kind: .hardBreak, marks: [], link: nil, owner: nil))
        cursor = end
        return true
      }
      var backslash = false
      if hard, cursor < limit, source[cursor] == UInt8(ascii: "\\") {
        backslash = true
        cursor += 1
      }
      while cursor < limit, isSpace(source[cursor]) { cursor += 1 }
      let breakStart = cursor
      if cursor < limit, source[cursor] == UInt8(ascii: "\r") { cursor += 1 }
      guard cursor < limit, source[cursor] == UInt8(ascii: "\n") else { return fail("line break") }
      cursor += 1
      if hard {
        markup(start..<breakStart, owner: start..<cursor)
        _ = backslash
        append(EditSpan(source: breakStart..<cursor, display: "\n", kind: .hardBreak, marks: [], link: nil, owner: nil))
      } else {
        hidden(start..<breakStart)
        append(EditSpan(source: breakStart..<cursor, display: " ", kind: .replaced, marks: [], link: nil, owner: nil))
      }
      hidden(cursor..<text.continuationStart(cursor, limit: limit, quoteDepth: quoteDepth))
      cursor = text.continuationStart(cursor, limit: limit, quoteDepth: quoteDepth)
      return true
    }

    private func code(_ value: String, marks: InlineMarks, link: String?) -> Bool {
      guard cursor < limit, source[cursor] == UInt8(ascii: "`") else {
        // An HTML <code> element: its tags were taken as markup, the text is verbatim.
        return matchText(Array(value.utf8), marks: marks, link: link)
      }
      let start = cursor
      var ticks = 0
      while cursor < limit, source[cursor] == UInt8(ascii: "`") {
        ticks += 1
        cursor += 1
      }
      // Find the closing run of exactly `ticks` backticks.
      var probe = cursor
      var closeStart: Int?
      while probe < limit {
        if source[probe] == UInt8(ascii: "`") {
          var run = 0
          while probe + run < limit, source[probe + run] == UInt8(ascii: "`") { run += 1 }
          if run == ticks {
            closeStart = probe
            break
          }
          probe += run
        } else {
          probe += 1
        }
      }
      guard let closeStart else { return fail("code close") }
      let end = closeStart + ticks
      let owner = start..<end
      // Interior units: source range and the character it contributes (line endings become one space).
      struct Unit {
        var range: Range<Int>
        var isLineEnding: Bool
        var prefix: Range<Int>
        var char: UInt8
      }
      var units: [Unit] = []
      var index = cursor
      while index < closeStart {
        let byte = source[index]
        if byte == UInt8(ascii: "\n") || (byte == UInt8(ascii: "\r") && index + 1 < closeStart && source[index + 1] == UInt8(ascii: "\n")) {
          let lineEnd = byte == UInt8(ascii: "\r") ? index + 2 : index + 1
          let contentStart = text.continuationStart(lineEnd, limit: closeStart, quoteDepth: quoteDepth)
          units.append(Unit(range: index..<lineEnd, isLineEnding: true, prefix: lineEnd..<contentStart, char: UInt8(ascii: " ")))
          index = contentStart
        } else {
          units.append(Unit(range: index..<(index + 1), isLineEnding: false, prefix: index..<index, char: byte))
          index += 1
        }
      }
      var strip = false
      if units.count >= 2, units.first?.char == UInt8(ascii: " "), units.last?.char == UInt8(ascii: " "),
        units.contains(where: { $0.char != UInt8(ascii: " ") })
      {
        strip = true
      }
      let shown = (strip ? Array(units.dropFirst().dropLast()) : units).map(\.char)
      guard shown == Array(value.utf8) else { return fail("code content") }
      markup(start..<cursor, owner: owner, marks: marks, link: link)
      for (position, unit) in units.enumerated() {
        let stripped = strip && (position == 0 || position == units.count - 1)
        if stripped {
          markup(unit.range, owner: owner, marks: marks, link: link)
          hidden(unit.prefix)
        } else if unit.isLineEnding {
          append(EditSpan(source: unit.range, display: " ", kind: .replaced, marks: marks, link: link, owner: nil))
          hidden(unit.prefix)
        } else {
          verbatim(unit.range, marks: marks, link: link)
        }
      }
      cursor = closeStart
      markup(closeStart..<end, owner: owner, marks: marks, link: link)
      cursor = end
      return true
    }

    private func delimited(
      _ children: [Inline], width: Int, chars: [UInt8], mark: InlineMarks, marks: InlineMarks, link: String?
    ) -> Bool {
      let inner = marks.union(mark)
      guard cursor + width <= limit, let char = chars.first(where: { $0 == source[cursor] }),
        source[cursor..<(cursor + width)].allSatisfy({ $0 == char })
      else {
        // HTML form (<em>, <strong>, <del>): the tags are markup taken around the children.
        return inlineList(children, marks: inner, link: link)
      }
      let start = cursor
      let first = spans.count
      markup(cursor..<(cursor + width), owner: nil, marks: inner, link: link)
      cursor += width
      guard inlineList(children, marks: inner, link: link) else { return false }
      guard cursor + width <= limit, source[cursor..<(cursor + width)].allSatisfy({ $0 == char }) else {
        return fail("closing delimiter")
      }
      markup(cursor..<(cursor + width), owner: nil, marks: inner, link: link)
      cursor += width
      own(from: first, start..<cursor)
      return true
    }

    private func link(_ target: Link, marks: InlineMarks) -> Bool {
      let start = cursor
      let first = spans.count
      let href = target.destination
      if target.isAutolink {
        if cursor < limit, source[cursor] == UInt8(ascii: "<") {
          markup(cursor..<(cursor + 1), owner: nil, marks: marks, link: href)
          cursor += 1
          guard inlineList(target.content, marks: marks, link: href) else { return false }
          guard cursor < limit, source[cursor] == UInt8(ascii: ">") else { return fail("autolink close") }
          markup(cursor..<(cursor + 1), owner: nil, marks: marks, link: href)
          cursor += 1
          own(from: first, start..<cursor)
          return true
        }
        return inlineList(target.content, marks: marks, link: href)
      }
      guard cursor < limit, source[cursor] == UInt8(ascii: "[") else {
        // An HTML <a href>: its tags are markup around the children.
        return inlineList(target.content, marks: marks, link: href)
      }
      markup(cursor..<(cursor + 1), owner: nil, marks: marks, link: href)
      cursor += 1
      guard inlineList(target.content, marks: marks, link: href) else { return false }
      guard cursor < limit, source[cursor] == UInt8(ascii: "]") else { return fail("link close") }
      let closeStart = cursor
      cursor += 1
      guard linkSuffix() else { return fail("link destination") }
      markup(closeStart..<cursor, owner: nil, marks: marks, link: href)
      own(from: first, start..<cursor)
      return true
    }

    private func image(_ picture: Image) -> Bool {
      let start = cursor
      guard source[cursor..<limit].starts(with: Array("![".utf8)) else {
        // An HTML <img>: its tag was already taken as markup; that span stands for the image.
        if let last = spans.indices.last, spans[last].kind == .markup, spans[last].image == nil {
          spans[last].image = picture
        }
        return true
      }
      cursor += 2
      var depth = 0
      while cursor < limit {
        let byte = source[cursor]
        if byte == UInt8(ascii: "\\") {
          cursor += 2
          continue
        }
        if byte == UInt8(ascii: "`") {
          // Skip a code span inside the alt text.
          var ticks = 0
          while cursor < limit, source[cursor] == UInt8(ascii: "`") {
            ticks += 1
            cursor += 1
          }
          var probe = cursor
          while probe < limit {
            if source[probe] == UInt8(ascii: "`") {
              var run = 0
              while probe + run < limit, source[probe + run] == UInt8(ascii: "`") { run += 1 }
              if run == ticks {
                cursor = probe + run
                break
              }
              probe += run
            } else {
              probe += 1
            }
          }
          continue
        }
        if byte == UInt8(ascii: "[") { depth += 1 }
        if byte == UInt8(ascii: "]") {
          if depth == 0 { break }
          depth -= 1
        }
        cursor += 1
      }
      guard cursor < limit else { return fail("image close") }
      cursor += 1
      guard linkSuffix() else { return fail("image destination") }
      append(
        EditSpan(
          source: start..<cursor, display: "", kind: .atom, marks: [], link: nil, owner: start..<cursor, image: picture))
      return true
    }

    /// The part after a link's closing bracket: an inline destination, a reference label, or nothing.
    private func linkSuffix() -> Bool {
      guard cursor < limit else { return true }
      if source[cursor] == UInt8(ascii: "[") {
        var probe = cursor + 1
        while probe < limit, source[probe] != UInt8(ascii: "]") {
          probe += source[probe] == UInt8(ascii: "\\") ? 2 : 1
        }
        guard probe < limit else { return true }
        cursor = probe + 1
        return true
      }
      guard source[cursor] == UInt8(ascii: "(") else { return true }
      let save = cursor
      cursor += 1
      skipLinkWhitespace()
      if cursor < limit, source[cursor] == UInt8(ascii: "<") {
        while cursor < limit, source[cursor] != UInt8(ascii: ">"), source[cursor] != UInt8(ascii: "\n") {
          cursor += source[cursor] == UInt8(ascii: "\\") ? 2 : 1
        }
        guard cursor < limit, source[cursor] == UInt8(ascii: ">") else {
          cursor = save
          return false
        }
        cursor += 1
      } else {
        var depth = 0
        while cursor < limit, !isWhitespace(source[cursor]) {
          let byte = source[cursor]
          if byte == UInt8(ascii: "\\") {
            cursor += 2
            continue
          }
          if byte == UInt8(ascii: "(") { depth += 1 }
          if byte == UInt8(ascii: ")") {
            if depth == 0 { break }
            depth -= 1
          }
          cursor += 1
        }
      }
      skipLinkWhitespace()
      if cursor < limit, let close = [UInt8(ascii: "\""): UInt8(ascii: "\""), UInt8(ascii: "'"): UInt8(ascii: "'"),
        UInt8(ascii: "("): UInt8(ascii: ")")][source[cursor]]
      {
        cursor += 1
        while cursor < limit, source[cursor] != close { cursor += source[cursor] == UInt8(ascii: "\\") ? 2 : 1 }
        guard cursor < limit else {
          cursor = save
          return false
        }
        cursor += 1
        skipLinkWhitespace()
      }
      guard cursor < limit, source[cursor] == UInt8(ascii: ")") else {
        cursor = save
        return false
      }
      cursor += 1
      return true
    }

    private func skipLinkWhitespace() {
      while cursor < limit, isWhitespace(source[cursor]) {
        if source[cursor] == UInt8(ascii: "\n") {
          cursor = text.continuationStart(cursor + 1, limit: limit, quoteDepth: quoteDepth)
        } else {
          cursor += 1
        }
      }
    }
  }

  // MARK: Entities and raw HTML

  func entity(at start: Int, limit: Int) -> (Int, String)? {
    var index = start + 1
    guard index < limit else { return nil }
    if source[index] == UInt8(ascii: "#") {
      index += 1
      var hex = false
      if index < limit, source[index] == UInt8(ascii: "x") || source[index] == UInt8(ascii: "X") {
        hex = true
        index += 1
      }
      let digitsStart = index
      var value: UInt32 = 0
      while index < limit, index - digitsStart < (hex ? 6 : 7) {
        let byte = source[index]
        let digit: UInt32?
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(byte - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "f") where hex: digit = UInt32(byte - UInt8(ascii: "a") + 10)
        case UInt8(ascii: "A")...UInt8(ascii: "F") where hex: digit = UInt32(byte - UInt8(ascii: "A") + 10)
        default: digit = nil
        }
        guard let digit else { break }
        value = value * (hex ? 16 : 10) + digit
        index += 1
      }
      guard index > digitsStart, index < limit, source[index] == UInt8(ascii: ";") else { return nil }
      let scalar = value == 0 ? nil : Unicode.Scalar(value)
      return (index + 1, String(Character(scalar ?? "\u{FFFD}")))
    }
    let nameStart = index
    while index < limit, index - nameStart <= 32, isAlphanumeric(source[index]) { index += 1 }
    guard index > nameStart, index < limit, source[index] == UInt8(ascii: ";") else { return nil }
    let name = String(decoding: source[nameStart..<index], as: UTF8.self)
    guard let decoded = EntityTable.names[name] else { return nil }
    return (index + 1, decoded)
  }

  /// End of a CommonMark raw HTML inline starting at `start` (open tag, closing tag, or comment), if any.
  func htmlTag(at start: Int, limit: Int) -> Int? {
    var index = start + 1
    guard index < limit else { return nil }
    if source[index] == UInt8(ascii: "!") {
      guard index + 2 < limit, source[index + 1] == UInt8(ascii: "-"), source[index + 2] == UInt8(ascii: "-") else {
        return nil
      }
      var probe = index + 3
      while probe + 2 < limit {
        if source[probe] == UInt8(ascii: "-"), source[probe + 1] == UInt8(ascii: "-"), source[probe + 2] == UInt8(ascii: ">") {
          return probe + 3
        }
        probe += 1
      }
      return nil
    }
    let closing = source[index] == UInt8(ascii: "/")
    if closing { index += 1 }
    guard index < limit, isLetter(source[index]) else { return nil }
    while index < limit, isAlphanumeric(source[index]) || source[index] == UInt8(ascii: "-") { index += 1 }
    if closing {
      while index < limit, isWhitespace(source[index]) { index += 1 }
      return index < limit && source[index] == UInt8(ascii: ">") ? index + 1 : nil
    }
    // Attributes: whitespace, name, optional = value.
    while true {
      let beforeSpace = index
      while index < limit, isWhitespace(source[index]) { index += 1 }
      guard index < limit else { return nil }
      if source[index] == UInt8(ascii: ">") { return index + 1 }
      if source[index] == UInt8(ascii: "/") {
        return index + 1 < limit && source[index + 1] == UInt8(ascii: ">") ? index + 2 : nil
      }
      guard index > beforeSpace else { return nil }
      let nameByte = source[index]
      guard isLetter(nameByte) || nameByte == UInt8(ascii: "_") || nameByte == UInt8(ascii: ":") else { return nil }
      while index < limit,
        isAlphanumeric(source[index]) || [UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: ":"), UInt8(ascii: "-")].contains(source[index])
      {
        index += 1
      }
      var probe = index
      while probe < limit, isWhitespace(source[probe]) { probe += 1 }
      if probe < limit, source[probe] == UInt8(ascii: "=") {
        probe += 1
        while probe < limit, isWhitespace(source[probe]) { probe += 1 }
        guard probe < limit else { return nil }
        let quote = source[probe]
        if quote == UInt8(ascii: "\"") || quote == UInt8(ascii: "'") {
          guard let close = source[(probe + 1)..<limit].firstIndex(of: quote) else { return nil }
          index = close + 1
        } else {
          let valueStart = probe
          while probe < limit, !isWhitespace(source[probe]),
            !"\"'=<>`".utf8.contains(source[probe])
          {
            probe += 1
          }
          guard probe > valueStart else { return nil }
          index = probe
        }
      }
    }
  }

}

private func isSpace(_ byte: UInt8) -> Bool { byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") }
private func isWhitespace(_ byte: UInt8) -> Bool {
  byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") || byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r")
}
private func isLetter(_ byte: UInt8) -> Bool {
  (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
}
private func isAlphanumeric(_ byte: UInt8) -> Bool {
  isLetter(byte) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
}
private func isASCIIPunctuation(_ byte: UInt8) -> Bool {
  (0x21...0x2F).contains(byte) || (0x3A...0x40).contains(byte) || (0x5B...0x60).contains(byte)
    || (0x7B...0x7E).contains(byte)
}

/// What an editable block shows for one caret position, and the exact map between rendered UTF-16 offsets and
/// source UTF-8 byte offsets.
public struct EditProjection: Hashable, Sendable {
  /// The rendered text, with markup revealed only where the caret is.
  public let text: String
  /// `boundaries[i]` is the source byte offset of rendered UTF-16 boundary `i`; `count == text.utf16.count + 1`.
  /// Between two visible characters separated by hidden bytes, a boundary maps to the end of the left character,
  /// except at the block start, where it maps to the first visible character.
  public let boundaries: [Int]
  /// Which span produced each rendered UTF-16 unit.
  public let unitSpans: [Int]

  public init(block: EditableBlock, caret: Int?, source: [UInt8]) {
    var text = ""
    var boundaries: [Int] = []
    var unitSpans: [Int] = []
    var afterLineEnding = false
    for (index, span) in block.spans.enumerated() {
      let shown = span.shown(caret: caret, source: source)
      if shown.isEmpty {
        // A continuation prefix right after a line ending: the boundary moves past it, so typing at the start of
        // a continuation line never lands inside quote markers or indentation.
        if span.kind == .hidden, afterLineEnding, !boundaries.isEmpty {
          boundaries[boundaries.count - 1] = span.source.upperBound
        }
        continue
      }
      afterLineEnding =
        (span.kind == .hardBreak || (span.kind == .replaced && source[span.source].contains(UInt8(ascii: "\n"))))
        && !span.isRevealed(caret: caret)
      let verbatim = span.kind == .text || span.isRevealed(caret: caret)
      if verbatim {
        var offset = span.source.lowerBound
        for scalar in shown.unicodeScalars {
          if boundaries.isEmpty { boundaries.append(offset) }
          let width = String(scalar).utf8.count
          for _ in 0..<(scalar.utf16.count - 1) { boundaries.append(offset) }
          offset += width
          boundaries.append(offset)
          for _ in 0..<scalar.utf16.count { unitSpans.append(index) }
        }
      } else {
        // Atomic: the caret lands before or after the whole replacement.
        if boundaries.isEmpty { boundaries.append(span.source.lowerBound) }
        let units = shown.utf16.count
        for _ in 0..<(units - 1) { boundaries.append(span.source.lowerBound) }
        boundaries.append(span.source.upperBound)
        for _ in 0..<units { unitSpans.append(index) }
      }
      text += shown
    }
    if boundaries.isEmpty {
      let visibleStart = block.spans.first { $0.kind != .markup && $0.kind != .hidden }?.source.lowerBound
      boundaries = [visibleStart ?? block.source.upperBound]
    }
    self.text = text
    self.boundaries = boundaries
    self.unitSpans = unitSpans
  }

  /// A zero-width placeholder for a caret on a blank line: one rendered unit that maps to `offset` on both sides.
  public init(placeholderAt offset: Int) {
    text = "\u{200B}"
    boundaries = [offset, offset]
    unitSpans = [-1]
  }

  public var isPlaceholder: Bool { unitSpans == [-1] }

  public var length: Int { boundaries.count - 1 }

  /// Source byte offset for a rendered UTF-16 offset (clamped).
  public func source(atRendered offset: Int) -> Int { boundaries[min(max(offset, 0), length)] }

  /// Rendered UTF-16 offset for a source byte offset: the last boundary at or before it.
  public func rendered(atSource offset: Int) -> Int {
    var low = 0
    var high = boundaries.count - 1
    guard offset >= boundaries[0] else { return 0 }
    while low < high {
      let middle = (low + high + 1) / 2
      if boundaries[middle] <= offset { low = middle } else { high = middle - 1 }
    }
    return low
  }
}
