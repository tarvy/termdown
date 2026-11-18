/// Markdown to email-safe HTML for pasting into mail clients: semantic tags, no classes, no scripts, no raw HTML
/// passthrough, every piece of text escaped. Mirrors the browser reviewer's rich-text copy so a paste from either
/// looks the same. Front matter is dropped.
public enum MarkdownHTML {
  public static func html(from markdown: String) -> String {
    blocks(Document.parse(markdown).blocks)
  }

  /// A bare domain typed by hand is meant as a web link; existing schemes, site-absolute paths and anchors are kept.
  public static func normalizeURL(_ href: String) -> String {
    let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty || trimmed.hasPrefix("/") || trimmed.hasPrefix("#") || hasScheme(trimmed) { return trimmed }
    return "https://" + trimmed
  }

  /// The address a link in the draft keeps once pasted elsewhere, or nil when it only works beside the draft: a
  /// relative file, a site-absolute path or an in-page anchor points nowhere in an email, so its text is kept unlinked.
  static func pasteURL(_ href: String) -> String? {
    let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
    if hasScheme(trimmed) { return trimmed }
    if trimmed.hasPrefix("//") { return "https:" + trimmed }
    if trimmed.lowercased().hasPrefix("www.") { return "https://" + trimmed }
    return nil
  }

  private static func hasScheme(_ text: String) -> Bool {
    guard let colon = text.firstIndex(of: ":"), let first = text.first, first.isASCII, first.isLetter else {
      return false
    }
    return text[..<colon].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "+.-".contains($0)) }
  }

  private static let unsafeSchemes = ["javascript:", "vbscript:", "data:"]

  private static func isSafe(_ url: String) -> Bool {
    let compact = url.filter { !$0.isWhitespace && !$0.isNewline }.lowercased()
    return !unsafeSchemes.contains { compact.hasPrefix($0) }
  }

  private static func escape(_ text: String) -> String {
    var out = ""
    out.reserveCapacity(text.count)
    for character in text {
      switch character {
      case "&": out += "&amp;"
      case "<": out += "&lt;"
      case ">": out += "&gt;"
      default: out.append(character)
      }
    }
    return out
  }

  private static func attribute(_ text: String) -> String {
    escape(text).replacingOccurrences(of: "\"", with: "&quot;")
  }

  // MARK: Blocks

  private static func blocks(_ blocks: [Block]) -> String {
    blocks.map(block).joined()
  }

  private static func block(_ block: Block) -> String {
    switch block.kind {
    case .heading(let heading):
      let level = min(max(heading.level, 1), 6)
      return "<h\(level)>\(inlines(heading.content))</h\(level)>"
    case .paragraph(let content), .plain(let content):
      let text = inlines(content)
      return text.isEmpty ? "" : "<p>\(text)</p>"
    case .blockQuote(let children):
      return "<blockquote>\(blocks(children))</blockquote>"
    case .alert(let alert):
      return "<blockquote><p><strong>\(alert.kind.title)</strong></p>\(blocks(alert.blocks))</blockquote>"
    case .list(let list):
      return self.list(list)
    case .codeBlock(let code):
      return "<pre><code>\(escape(code.code))</code></pre>"
    case .table(let table):
      return self.table(table)
    case .footnoteDefinition(let footnote):
      return "<p>[\(footnote.number)]</p>" + blocks(footnote.blocks)
    case .details(let details):
      return "<p><strong>\(inlines(details.summary))</strong></p>" + blocks(details.blocks)
    case .division(let division):
      return blocks(division.blocks)
    case .thematicBreak:
      return "<hr>"
    }
  }

  private static func list(_ list: List) -> String {
    let items = list.items.map { "<li>\(item($0))</li>" }.joined()
    switch list.kind {
    case .bullet: return "<ul>\(items)</ul>"
    case .ordered(let start): return "<ol\(start == 1 ? "" : " start=\"\(start)\"")>\(items)</ol>"
    }
  }

  /// A paragraph inside an item is written without its `<p>`, which mail clients space badly.
  private static func item(_ item: ListItem) -> String {
    let marker =
      switch item.task {
      case .checked: "\u{2611} "
      case .unchecked: "\u{2610} "
      case nil: ""
      }
    return marker + item.blocks.map(tight).joined()
  }

  private static func tight(_ block: Block) -> String {
    switch block.kind {
    case .paragraph(let content), .plain(let content): inlines(content)
    default: self.block(block)
    }
  }

  private static func table(_ table: Table) -> String {
    let border = "border:1px solid #ccc;padding:5px 8px;"
    func row(_ row: TableRow) -> String {
      let cells = row.cells.map { cell -> String in
        let tag = cell.isHeader ? "th" : "td"
        let align =
          switch cell.alignment {
          case .left: "text-align:left;"
          case .center: "text-align:center;"
          case .right: "text-align:right;"
          case .none: cell.isHeader ? "text-align:left;" : ""
          }
        return "<\(tag) style=\"\(border)\(align)\">\(cell.content.map(tight).joined())</\(tag)>"
      }
      return "<tr>\(cells.joined())</tr>"
    }
    let rows = (table.header.map { [$0] } ?? []) + table.rows
    return "<table style=\"border-collapse:collapse;\">\(rows.map(row).joined())</table>"
  }

  // MARK: Inlines

  private static func inlines(_ inlines: [Inline]) -> String {
    inlines.map(inline).joined()
  }

  private static func wrap(_ tag: String, _ children: [Inline]) -> String {
    "<\(tag)>\(inlines(children))</\(tag)>"
  }

  private static func inline(_ inline: Inline) -> String {
    switch inline.kind {
    case .text(let text): escape(text)
    case .softBreak: "\n"
    case .hardBreak: "<br>"
    case .code(let text): "<code>\(escape(text))</code>"
    case .emphasis(let children): wrap("em", children)
    case .strong(let children): wrap("strong", children)
    case .strikethrough(let children): wrap("s", children)
    case .keyboard(let children): wrap("kbd", children)
    case .subscript(let children): wrap("sub", children)
    case .superscript(let children): wrap("sup", children)
    case .inserted(let children): wrap("u", children)
    case .marked(let children): wrap("mark", children)
    case .small(let children): wrap("small", children)
    case .abbreviation(_, let children): inlines(children)
    case .link(let link): self.link(link)
    case .image(let image): escape(image.alt)
    case .footnoteReference(_, let number): "[\(number)]"
    case .anchor: ""
    }
  }

  private static func link(_ link: Link) -> String {
    let content = inlines(link.content)
    guard let url = pasteURL(link.destination), isSafe(url) else { return content }
    return "<a href=\"\(attribute(url))\">\(content)</a>"
  }
}
