import XCTest

@testable import TermDownCore

final class AgentPromptTests: XCTestCase {
  func testOneLineQuote() {
    XCTAssertEqual(
      AgentPrompt.message(file: "/a/notes.md", startLine: 3, endLine: 3, quote: "Some text"),
      "In @/a/notes.md line 3:\n> Some text\n\n")
  }

  func testLineRangeQuotesEveryLine() {
    XCTAssertEqual(
      AgentPrompt.message(file: "/a/notes.md", startLine: 3, endLine: 5, quote: "one\ntwo\n"),
      "In @/a/notes.md lines 3-5:\n> one\n> two\n\n")
  }

  func testNoSelectionNamesTheLineOnly() {
    XCTAssertEqual(AgentPrompt.message(file: "/a/notes.md", startLine: 7, endLine: 7, quote: ""), "In @/a/notes.md line 7:\n\n")
  }

  func testLongQuoteIsClipped() {
    let message = AgentPrompt.message(file: "/f.md", startLine: 1, endLine: 1, quote: String(repeating: "x", count: 700))
    XCTAssertTrue(message.contains(String(repeating: "x", count: AgentPrompt.quoteLimit) + "…"))
    XCTAssertFalse(message.contains(String(repeating: "x", count: AgentPrompt.quoteLimit + 1)))
  }

  func testEveryReviewPassStandsAloneAndNamesTheDraftEditsAndPass() {
    XCTAssertEqual(
      AgentPrompt.review(draft: "/a/draft.md", edits: "/s/draft.md.pass-2.edits.json", pass: 2),
      "Review pass 2 on @/a/draft.md: apply /s/draft.md.pass-2.edits.json. Run `termdown agent-guide review` for how."
        + " The draft is open in TermDown, so just edit the file in place; do not start another reviewer."
        + " This pass is complete on its own: do not start another one, and carry on with the conversation.\n\n")
  }

  func testTheReviewPromptNamesNothingOutsideTermdown() {
    let prompt = AgentPrompt.review(draft: "/a/d.md", edits: "/s/e.json", pass: 1)
    XCTAssertFalse(prompt.contains("skill"))
    XCTAssertFalse(prompt.contains("review.py"))
  }

  func testPasteIsBracketed() {
    XCTAssertEqual(AgentPrompt.paste("hi\nthere"), "\u{1b}[200~hi\nthere\u{1b}[201~")
  }
}
