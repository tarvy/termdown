import Foundation
import XCTest

@testable import TermDownDocument

/// Checks every editable block's map: spans tile the block exactly, and the hidden text equals view mode.
private func check(_ markdown: String, file: StaticString = #filePath, line: UInt = #line) -> [EditableBlock] {
  let document = Document.parse(markdown)
  let editable = EditableText(source: markdown)
  let blocks = editable.blocks(document)
  for block in blocks {
    var cursor = block.source.lowerBound
    for span in block.spans {
      XCTAssertEqual(span.source.lowerBound, cursor, "gap or overlap in \(markdown.debugDescription)", file: file, line: line)
      cursor = span.source.upperBound
      if span.kind == .text {
        XCTAssertEqual(
          Array(span.display.utf8), Array(editable.source[span.source]), "text span not verbatim", file: file, line: line)
      }
    }
    XCTAssertEqual(cursor, block.source.upperBound, "spans stop short", file: file, line: line)
  }
  return blocks
}

private func spans(_ block: EditableBlock, _ source: String) -> [String] {
  let bytes = Array(source.utf8)
  return block.spans.map { span in
    let raw = String(decoding: bytes[span.source], as: UTF8.self)
    switch span.kind {
    case .text: return raw
    case .markup: return "{\(raw)}"
    case .hidden: return "_"
    case .replaced: return "[\(span.display)]"
    case .hardBreak: return "⏎"
    case .atom: return "<\(span.display)>"
    }
  }
}

final class EditableTextTests: XCTestCase {
  func testInlineMarksAreMarkup() throws {
    let markdown = "Some **bold** and *it* and `code` and ~~gone~~.\n"
    let block = try XCTUnwrap(check(markdown).first)
    XCTAssertEqual(
      spans(block, markdown),
      ["Some ", "{**}", "bold", "{**}", " and ", "{*}", "it", "{*}", " and ", "{`}", "code", "{`}", " and ", "{~~}", "gone",
       "{~~}", "."])
    XCTAssertEqual(block.hiddenText, "Some bold and it and code and gone.")
  }

  func testHeadingMarkersAreMarkupOwnedByTheHeading() throws {
    let markdown = "## Title here ##\n\nSetext\n===\n"
    let blocks = check(markdown)
    XCTAssertEqual(blocks.count, 2)
    XCTAssertEqual(spans(blocks[0], markdown), ["{## }", "Title here", "{ ##}"])
    XCTAssertEqual(blocks[0].hiddenText, "Title here")
    XCTAssertEqual(blocks[1].hiddenText, "Setext")
  }

  func testEscapesEntitiesAndBreaks() throws {
    let markdown = "a \\* b &amp; c&#x41;\nnext  \nhard\\\nlast\n"
    let block = try XCTUnwrap(check(markdown).first)
    XCTAssertEqual(block.hiddenText, "a * b & cA next\nhard\nlast")
    XCTAssertTrue(spans(block, markdown).contains("[&]"))
    XCTAssertTrue(spans(block, markdown).contains("{\\}"))
  }

  func testLinksHideTheirDestination() throws {
    let markdown = "See [the guide](https://example.com \"T\") and <https://a.b> and https://c.d now.\n"
    let block = try XCTUnwrap(check(markdown).first)
    XCTAssertEqual(block.hiddenText, "See the guide and https://a.b and https://c.d now.")
    XCTAssertTrue(spans(block, markdown).contains("{](https://example.com \"T\")}"))
    XCTAssertEqual(block.spans.first { $0.display == "the guide" }?.link, "https://example.com")
  }

  func testQuotesAndListsStripContinuationPrefixes() throws {
    let markdown = "> quoted line\n> continues here\n\n- item one\n  wraps on\n- item two\n"
    let blocks = check(markdown)
    XCTAssertEqual(blocks.map(\.hiddenText), ["quoted line continues here", "item one wraps on", "item two"])
  }

  func testRevealShowsOnlyTheMarkupUnderTheCaret() throws {
    let markdown = "x **bold** y *it*\n"
    let block = try XCTUnwrap(check(markdown).first)
    let bytes = Array(markdown.utf8)
    let caret = 4  // inside **bold**
    XCTAssertEqual(block.spans.map { $0.shown(caret: caret, source: bytes) }.joined(), "x **bold** y it")
    XCTAssertEqual(block.spans.map { $0.shown(caret: 16, source: bytes) }.joined(), "x bold y *it*")
  }

  func testFrontMatterShiftsLines() throws {
    let markdown = "---\ntitle: x\n---\n\nBody *text*.\n"
    let block = try XCTUnwrap(check(markdown).first)
    XCTAssertEqual(block.hiddenText, "Body text.")
  }

  func testMultibyteText() throws {
    let markdown = "Café 日本語 👩🏽‍💻 **bø**\n"
    let block = try XCTUnwrap(check(markdown).first)
    XCTAssertEqual(block.hiddenText, "Café 日本語 👩🏽‍💻 bø")
  }

  // MARK: Corpora

  /// Every CommonMark spec example: report how many eligible blocks map exactly. The bar is in the assert.
  func testCommonMarkSpecCorpus() throws {
    let spec = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent(".build/checkouts/swift-cmark/test/spec.txt")
    guard let text = try? String(contentsOf: spec, encoding: .utf8) else { throw XCTSkip("spec.txt not checked out") }
    let report = corpus(examples(in: text))
    print("spec corpus: \(report.summary)")
    try? report.failures.joined(separator: "\n\n").write(
      toFile: NSTemporaryDirectory() + "termdown-spec-failures.txt", atomically: true, encoding: .utf8)
    XCTAssertGreaterThanOrEqual(report.rate, 0.985, report.summary)
  }

  /// Markdown files under MDV_CORPUS (for example a notes vault).
  func testDirectoryCorpus() throws {
    guard let root = ProcessInfo.processInfo.environment["MDV_CORPUS"] else { throw XCTSkip("MDV_CORPUS not set") }
    var files: [String] = []
    let enumerator = FileManager.default.enumerator(atPath: root)
    while let path = enumerator?.nextObject() as? String {
      if path.hasSuffix(".md"), !path.contains("node_modules"), !path.hasPrefix(".") {
        if let text = try? String(contentsOfFile: root + "/" + path, encoding: .utf8) { files.append(text) }
      }
    }
    let report = corpus(files)
    print("directory corpus (\(files.count) files): \(report.summary)")
    try? report.failures.joined(separator: "\n\n").write(
      toFile: NSTemporaryDirectory() + "termdown-corpus-failures.txt", atomically: true, encoding: .utf8)
    XCTAssertGreaterThanOrEqual(report.rate, 0.9999, report.summary)
  }

  private struct Report {
    var eligible = 0
    var mapped = 0
    var failures: [String] = []
    var rate: Double { eligible == 0 ? 1 : Double(mapped) / Double(eligible) }
    var summary: String { "\(mapped)/\(eligible) eligible blocks mapped (\(String(format: "%.2f", rate * 100))%)" }
  }

  private func corpus(_ documents: [String]) -> Report {
    var report = Report()
    for markdown in documents {
      let document = Document.parse(markdown)
      let editable = EditableText(source: markdown)
      var pending: [(Block, Int)] = document.blocks.map { ($0, 0) }
      while !pending.isEmpty {
        let (block, depth) = pending.removeFirst()
        let built: EditableBlock?
        switch block.kind {
        case .paragraph(let inlines):
          built = editable.build(block, inlines: inlines, kind: .paragraph, quoteDepth: depth)
        case .heading(let heading):
          built = editable.build(block, inlines: heading.content, kind: .heading(level: heading.level), quoteDepth: depth)
        case .blockQuote(let children):
          if let range = editable.byteRange(block.range), range.lowerBound < editable.source.count,
            editable.source[range.lowerBound] == UInt8(ascii: ">")
          {
            pending += children.map { ($0, depth + 1) }
          }
          continue
        case .list(let list):
          pending += list.items.flatMap(\.blocks).map { ($0, depth) }
          continue
        case .footnoteDefinition(let footnote):
          pending += footnote.blocks.map { ($0, depth) }
          continue
        default:
          continue
        }
        report.eligible += 1
        if let built {
          var cursor = built.source.lowerBound
          var tiles = true
          for span in built.spans {
            if span.source.lowerBound != cursor { tiles = false }
            cursor = span.source.upperBound
          }
          if tiles && cursor == built.source.upperBound {
            report.mapped += 1
          } else {
            report.failures.append("TILING\n\(markdown)")
          }
        } else {
          let raw = editable.byteRange(block.range).map { String(decoding: editable.source[$0], as: UTF8.self) } ?? "?"
          let mismatch = editable.lastMismatch.map { "built: \($0.0.debugDescription)\nview:  \($0.1.debugDescription)" }
          report.failures.append("BLOCK \(raw.debugDescription)\n\(mismatch ?? "no range")")
        }
      }
    }
    return report
  }

  private func examples(in spec: String) -> [String] {
    let fence = String(repeating: "`", count: 32)
    var result: [String] = []
    var lines: [String] = []
    var inExample = false
    for line in spec.components(separatedBy: "\n") {
      if line.hasPrefix(fence + " example") {
        inExample = true
        lines = []
      } else if inExample && line == "." {
        result.append(lines.joined(separator: "\n").replacingOccurrences(of: "\u{2192}", with: "\t") + "\n")
        inExample = false
      } else if inExample {
        lines.append(line)
      }
    }
    return result
  }
}

final class EditableTextRegressionTests: XCTestCase {
  func testParagraphRightAfterHeading() throws {
    let markdown = "# Guide\n\n## Derive\nAn Investigation exists.\n"
    let document = Document.parse(markdown)
    XCTAssertEqual(check(markdown).map(\.hiddenText), ["Guide", "Derive", "An Investigation exists."])
  }

  func testParagraphInterruptedByTable() throws {
    let markdown = "Intro line\n| a | b |\n|---|---|\n| 1 | 2 |\n"
    XCTAssertEqual(check(markdown).map(\.hiddenText), ["Intro line"])
  }

  func testQuoteNestedInListItem() throws {
    let markdown = "- item\n\n     > quoted `x`\n     > more\n"
    XCTAssertEqual(check(markdown).map(\.hiddenText), ["item", "quoted x more"])
  }

  func testMultibyteInsideCode() throws {
    let markdown = "Path `4.1 → 4.2` and `\u{a0}b\u{a0}`\n"
    XCTAssertEqual(check(markdown).first?.hiddenText, "Path 4.1 → 4.2 and \u{a0}b\u{a0}")
  }
}

final class EditableTextFileProbe: XCTestCase {
  func testProbeFile() throws {
    guard let path = ProcessInfo.processInfo.environment["MDV_FILE"] else { throw XCTSkip("MDV_FILE not set") }
    let markdown = try String(contentsOfFile: path, encoding: .utf8)
    let document = Document.parse(markdown)
    let editable = EditableText(source: markdown)
    for block in document.blocks.prefix(6) {
      let raw = editable.byteRange(block.range).map { String(decoding: editable.source[$0], as: UTF8.self) }
      print("PROBE", block.range.start.line, block.range.start.column, block.range.end.line, block.range.end.column, (raw ?? "nil").prefix(60).debugDescription)
    }
  }
}

final class EditProjectionTests: XCTestCase {
  func testProjectionMapsEveryRenderedBoundary() throws {
    let markdown = "x **bø** &amp; 👩🏽‍💻 `c`\r\nline two\r\n"
    let editable = EditableText(source: markdown)
    let block = try XCTUnwrap(editable.blocks(Document.parse(markdown)).first)
    XCTAssertEqual(block.hiddenText, "x bø & 👩🏽‍💻 c line two")
    let projection = EditProjection(block: block, caret: nil, source: editable.source)
    XCTAssertEqual(projection.text, block.hiddenText)
    XCTAssertEqual(projection.boundaries.count, projection.text.utf16.count + 1)
    XCTAssertEqual(zip(projection.boundaries, projection.boundaries.dropFirst()).allSatisfy { $0 <= $1 }, true)
    // Left affinity: the boundary before "b" is the end of "x ", before the hidden **; source 4 (after **) maps
    // back to it.
    let b = (projection.text as NSString).range(of: "bø").location
    XCTAssertEqual(projection.source(atRendered: b), 2)
    XCTAssertEqual(projection.source(atRendered: b + 1), 5)
    XCTAssertEqual(projection.rendered(atSource: 4), b)
    // The CRLF is one rendered space; the boundary before it sits before the hidden closing backtick.
    let space = (projection.text as NSString).range(of: " line").location
    XCTAssertEqual(projection.source(atRendered: space + 1) - projection.source(atRendered: space), 3)
  }

  func testRevealedProjectionIsVerbatimInsideTheOwner() throws {
    let markdown = "x **bold** y\n"
    let editable = EditableText(source: markdown)
    let block = try XCTUnwrap(editable.blocks(Document.parse(markdown)).first)
    let projection = EditProjection(block: block, caret: 5, source: editable.source)
    XCTAssertEqual(projection.text, "x **bold** y")
    XCTAssertEqual(projection.boundaries, Array(0...12))
  }

  /// Over a whole corpus: for each block, hidden projection text matches view mode, and every rendered boundary
  /// round-trips through its source offset.
  func testProjectionRoundTripsOverCorpus() throws {
    let root = ProcessInfo.processInfo.environment["MDV_CORPUS"]
    let spec = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent(".build/checkouts/swift-cmark/test/spec.txt")
    var documents: [String] = []
    if let root {
      let enumerator = FileManager.default.enumerator(atPath: root)
      while let path = enumerator?.nextObject() as? String, documents.count < 1500 {
        if path.hasSuffix(".md"), let text = try? String(contentsOfFile: root + "/" + path, encoding: .utf8) {
          documents.append(text)
        }
      }
    } else if let text = try? String(contentsOf: spec, encoding: .utf8) {
      documents = [text]
    }
    var blocks = 0
    var reveals = 0
    for markdown in documents {
      let editable = EditableText(source: markdown)
      for block in editable.blocks(Document.parse(markdown)) {
        blocks += 1
        let hidden = EditProjection(block: block, caret: nil, source: editable.source)
        XCTAssertEqual(hidden.text, block.hiddenText)
        for (index, offset) in hidden.boundaries.enumerated() {
          let back = hidden.rendered(atSource: offset)
          XCTAssertEqual(hidden.boundaries[back], offset)
          XCTAssertGreaterThanOrEqual(back, index == 0 ? 0 : 0)
        }
        // Reveal at every markup owner start: the projection stays monotonic and covers the owner verbatim.
        for span in block.spans where span.kind == .markup {
          guard let owner = span.owner else { continue }
          reveals += 1
          let shown = EditProjection(block: block, caret: owner.lowerBound, source: editable.source)
          XCTAssertTrue(zip(shown.boundaries, shown.boundaries.dropFirst()).allSatisfy { $0 <= $1 })
          let revealed = String(decoding: editable.source[span.source], as: UTF8.self)
          XCTAssertTrue(shown.text.contains(revealed))
        }
      }
    }
    print("projection corpus: \(blocks) blocks, \(reveals) reveals checked")
    XCTAssertGreaterThan(blocks, 0)
  }

  func testOneMegabyteBuildTime() throws {
    var markdown = "# Big\n\n"
    var paragraph = 0
    while markdown.utf8.count < 1_000_000 {
      paragraph += 1
      markdown += "Paragraph \(paragraph) with **bold**, *italic*, `code`, a [link](https://x.y/\(paragraph)) and &amp;.\n"
      markdown += "- item one with ~~strike~~\n- item two\n\n> quoted line \(paragraph)\n> continues\n\n"
    }
    let start = Date()
    let document = Document.parse(markdown)
    let parsed = Date()
    let blocks = EditableText(source: markdown).blocks(document)
    let mapped = Date()
    let parseMs = parsed.timeIntervalSince(start) * 1000
    let mapMs = mapped.timeIntervalSince(parsed) * 1000
    print(String(format: "1MB: %d blocks, parse %.1f ms, map %.1f ms", blocks.count, parseMs, mapMs))
    XCTAssertGreaterThan(blocks.count, 10_000)
  }
}
