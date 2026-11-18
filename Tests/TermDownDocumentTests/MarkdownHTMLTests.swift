import TermDownDocument
import XCTest

final class MarkdownHTMLTests: XCTestCase {
  func html(_ markdown: String) -> String { MarkdownHTML.html(from: markdown) }

  func testParagraphBoldLinkAndList() {
    XCTAssertEqual(
      html("**a** and [x](https://e.com)\n\n- one\n- two"),
      "<p><strong>a</strong> and <a href=\"https://e.com\">x</a></p><ul><li>one</li><li>two</li></ul>")
  }

  func testLinksWithAnAddressAreKept() {
    XCTAssertEqual(html("[x](mailto:a@b.co)"), "<p><a href=\"mailto:a@b.co\">x</a></p>")
    XCTAssertEqual(html("[x](www.example.com/a)"), "<p><a href=\"https://www.example.com/a\">x</a></p>")
    XCTAssertEqual(html("[x](//example.com/a)"), "<p><a href=\"https://example.com/a\">x</a></p>")
  }

  func testLinksThatOnlyWorkBesideTheDraftKeepTheirTextUnlinked() {
    for destination in ["other.md", "./notes/other.md#part", "../a/b.pdf", "docs/a", "/docs/a", "#top", "example.com"] {
      XCTAssertEqual(html("see [the notes](\(destination)) here"), "<p>see the notes here</p>", destination)
    }
    XCTAssertEqual(html("[**bold** text](other.md)"), "<p><strong>bold</strong> text</p>")
  }

  func testTypedLinkPromptStillCompletesABareDomain() {
    XCTAssertEqual(MarkdownHTML.normalizeURL("example.com"), "https://example.com")
    XCTAssertEqual(MarkdownHTML.normalizeURL("https://e.com"), "https://e.com")
  }

  func testScriptSchemesLoseTheirLink() {
    XCTAssertEqual(html("[x](javascript:alert(1))"), "<p>x</p>")
  }

  func testHeadingsItalicStrikeAndCode() {
    XCTAssertEqual(
      html("# Title\n\n### Three\n\n*it* ~~gone~~ `c<d>`"),
      "<h1>Title</h1><h3>Three</h3><p><em>it</em> <s>gone</s> <code>c&lt;d&gt;</code></p>")
  }

  func testTextIsEscaped() {
    XCTAssertEqual(html("a < b & c > d"), "<p>a &lt; b &amp; c &gt; d</p>")
    XCTAssertEqual(
      html("[x](https://e.com/?a=1&b=\"2\")"), "<p><a href=\"https://e.com/?a=1&amp;b=&quot;2&quot;\">x</a></p>")
  }

  func testOrderedAndNestedListsHaveNoParagraphsInsideItems() {
    XCTAssertEqual(
      html("3. one\n4. two\n   - inner\n\n"),
      "<ol start=\"3\"><li>one</li><li>two<ul><li>inner</li></ul></li></ol>")
  }

  func testTaskItemsKeepTheirState() {
    XCTAssertEqual(html("- [x] done\n- [ ] todo"), "<ul><li>\u{2611} done</li><li>\u{2610} todo</li></ul>")
  }

  func testQuoteRuleAndCodeBlock() {
    XCTAssertEqual(html("> quoted"), "<blockquote><p>quoted</p></blockquote>")
    XCTAssertEqual(html("text\n\n***\n\nmore"), "<p>text</p><hr><p>more</p>")
    XCTAssertEqual(html("```swift\nlet a = 1 < 2\n```"), "<pre><code>let a = 1 &lt; 2\n</code></pre>")
  }

  func testTableUsesInlineStylesOnly() {
    let out = html("| A | B |\n|---|--:|\n| 1 | **2** |")
    XCTAssertTrue(out.hasPrefix("<table style=\"border-collapse:collapse;\"><tr><th style="), out)
    XCTAssertTrue(out.contains(">A</th>"), out)
    XCTAssertTrue(out.contains("text-align:right;\"><strong>2</strong></td>"), out)
    XCTAssertTrue(out.hasSuffix("</tr></table>"), out)
  }

  func testFrontMatterIsDropped() {
    XCTAssertEqual(html("---\ntitle: x\n---\n\nBody"), "<p>Body</p>")
  }

  func testNoClassesScriptsOrRawHTML() {
    let out = html("<script>alert(1)</script>\n\n<div class=\"x\">hi</div>\n\n**ok**")
    XCTAssertFalse(out.contains("<script"), out)
    XCTAssertFalse(out.contains("class="), out)
    XCTAssertTrue(out.contains("<strong>ok</strong>"), out)
  }

  func testImagesBecomeTheirAltText() {
    XCTAssertEqual(html("![a chart](chart.png)"), "<p>a chart</p>")
  }

  func testEmptyInputGivesEmptyOutput() {
    XCTAssertEqual(html(""), "")
  }
}
