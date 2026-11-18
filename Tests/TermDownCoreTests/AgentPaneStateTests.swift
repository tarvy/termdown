import XCTest

@testable import TermDownCore

/// The fixtures are `rex capture --format vt --trim` of a live Claude Code pane in each state.
final class AgentPaneStateTests: XCTestCase {
  static let rule = String(repeating: "─", count: 40)

  private func fixture(_ name: String) throws -> String {
    let url = try XCTUnwrap(
      Bundle.module.url(forResource: name, withExtension: "vt", subdirectory: "Fixtures/agent-pane"))
    return String(decoding: try Data(contentsOf: url), as: UTF8.self)
  }

  /// A bottom-of-screen prompt box as Claude Code draws it, with `prompt` after the `❯`.
  private func screen(_ prompt: String, below: String = "  ~/project  main") -> String {
    "\r\nsome output\r\n\r\n\u{1b}[0m\u{1b}[38;2;136;136;136m\(Self.rule)\u{1b}[0m\r\n❯\u{a0}\(prompt)\r\n"
      + "\u{1b}[0m\u{1b}[38;2;136;136;136m\(Self.rule)\u{1b}[0m\r\n\(below)"
  }

  func testAFreshSessionWithItsFaintPlaceholderIsReady() throws {
    XCTAssertEqual(AgentPaneState.classify(vt: try fixture("idle-placeholder")), .ready)
  }

  func testAnEmptyPromptAfterATurnIsReady() throws {
    XCTAssertEqual(AgentPaneState.classify(vt: try fixture("idle-after-turn")), .ready)
  }

  func testMidTurnWithAnEmptyPromptIsReadyBecauseClaudeCodeQueuesTheMessage() throws {
    XCTAssertEqual(AgentPaneState.classify(vt: try fixture("mid-turn")), .ready)
    XCTAssertEqual(AgentPaneState.classify(vt: try fixture("mid-turn-hooks")), .ready)
  }

  /// A named session puts its name in the top rule of the prompt box.
  func testANamedSessionsRuleStillBoundsThePromptBox() {
    let named = "\r\nsome output\r\n\r\n\u{1b}[0m\u{1b}[38;2;136;136;136m\(Self.rule) applied followup ─\u{1b}[0m\r\n"
      + "❯\u{a0}\r\n\u{1b}[0m\u{1b}[38;2;136;136;136m\(Self.rule)\u{1b}[0m\r\n  ~/project  main"
    XCTAssertEqual(AgentPaneState.classify(vt: named), .ready)
    XCTAssertEqual(AgentPaneState.classify(vt: named.replacingOccurrences(of: "❯\u{a0}", with: "❯\u{a0}hi")), .busy)
    XCTAssertFalse(AgentPaneState.isRule(AgentPaneState.parse("── not a rule ──")!.first!), "too short a run")
  }

  func testUnsentTypedTextIsBusy() throws {
    XCTAssertEqual(AgentPaneState.classify(vt: try fixture("typed")), .busy)
  }

  func testADialogIsBusy() throws {
    XCTAssertEqual(AgentPaneState.classify(vt: try fixture("dialog")), .busy)
  }

  func testNothingIsBusy() {
    XCTAssertEqual(AgentPaneState.classify(vt: ""), .busy)
  }

  func testTheBuiltScreenIsReadyOnlyWhenThePromptHoldsNothingButFaintText() {
    XCTAssertEqual(AgentPaneState.classify(vt: screen("")), .ready)
    XCTAssertEqual(AgentPaneState.classify(vt: screen("\u{1b}[2mTry something\u{1b}[0m")), .ready)
    XCTAssertEqual(AgentPaneState.classify(vt: screen("x")), .busy)
    XCTAssertEqual(AgentPaneState.classify(vt: screen("\u{1b}[2mTry\u{1b}[22m typed")), .busy, "faint switched off")
    XCTAssertEqual(AgentPaneState.classify(vt: screen("\u{1b}[2mTry\u{1b}[0m\u{1b}[1Cx")), .busy, "reset ends faint")
  }

  func testAColorWhoseComponentIsTwoIsNotFaint() {
    XCTAssertEqual(AgentPaneState.classify(vt: screen("\u{1b}[38;2;2;2;2mtyped\u{1b}[0m")), .busy)
    XCTAssertEqual(AgentPaneState.classify(vt: screen("\u{1b}[38;5;2mtyped\u{1b}[0m")), .busy)
  }

  func testAPromptThatSpansLinesIsBusy() {
    XCTAssertEqual(AgentPaneState.classify(vt: screen("\r\n")), .busy, "a typed newline is unsent text")
    XCTAssertEqual(AgentPaneState.classify(vt: screen("\u{1b}[2mfaint\u{1b}[0m\r\n  \u{1b}[2mmore\u{1b}[0m")), .busy)
  }

  func testOnlyTheLastPromptBoxCounts() {
    let earlier = screen("")
    XCTAssertEqual(AgentPaneState.classify(vt: earlier + "\r\n" + screen("typed")), .busy)
  }

  func testAMenuUnderThePromptIsBusy() {
    XCTAssertEqual(AgentPaneState.classify(vt: screen("", below: "  Enter to confirm · Esc to cancel")), .busy)
  }

  func testAnUnknownEscapeSequenceIsBusy() {
    XCTAssertEqual(AgentPaneState.classify(vt: screen("\u{1b}[K")), .busy)
    XCTAssertEqual(AgentPaneState.classify(vt: screen("\u{1b}]0;title\u{07}")), .busy)
  }

  func testNoPromptLineBetweenTheRulesIsBusy() {
    let vt = "\(Self.rule)\r\n  just text\r\n\(Self.rule)\r\n"
    XCTAssertEqual(AgentPaneState.classify(vt: vt), .busy)
  }

  /// After the paste, Enter goes only to a prompt box that now holds text, never to a dialog.
  func testThePasteLandedOnlyWhenThePromptBoxHoldsText() throws {
    XCTAssertTrue(AgentPaneState.promptHoldsText(vt: try fixture("typed")))
    XCTAssertTrue(AgentPaneState.promptHoldsText(vt: screen("[Pasted text #1 +3 lines]")))
    XCTAssertTrue(
      AgentPaneState.promptHoldsText(vt: screen("Review pass 1\r\n  Apply the edits")), "a paste over lines")
    XCTAssertFalse(AgentPaneState.promptHoldsText(vt: try fixture("idle-placeholder")))
    XCTAssertFalse(AgentPaneState.promptHoldsText(vt: try fixture("idle-after-turn")))
    XCTAssertFalse(AgentPaneState.promptHoldsText(vt: try fixture("dialog")))
    XCTAssertFalse(AgentPaneState.promptHoldsText(vt: ""))
    XCTAssertFalse(AgentPaneState.promptHoldsText(vt: screen("text", below: "  Enter to confirm · Esc to cancel")))
    XCTAssertFalse(AgentPaneState.promptHoldsText(vt: screen("text\u{1b}[K")))
  }

  /// The real handoff pasted into a live pane wraps over several lines of the prompt box, with blank lines before the
  /// closing rule. Enter on this state submitted it.
  func testTheRealPastedHandoffLandedButIsNotReady() throws {
    let vt = try fixture("pasted-multiline")
    XCTAssertTrue(AgentPaneState.promptHoldsText(vt: vt))
    XCTAssertEqual(AgentPaneState.classify(vt: vt), .busy)
  }

  /// With the preview connected over /ide, Claude Code starts the prompt box with a context chip such as
  /// `[⧉ In live.md]`. The chip is not prompt text.
  func testTheIDEContextChipIsNotPromptText() throws {
    XCTAssertEqual(AgentPaneState.classify(vt: try fixture("idle-ide-chip")), .ready)
    XCTAssertEqual(AgentPaneState.classify(vt: try fixture("typed-ide-chip")), .busy)
    XCTAssertFalse(AgentPaneState.promptHoldsText(vt: try fixture("idle-ide-chip")), "a chip alone is not a paste")
    XCTAssertTrue(AgentPaneState.promptHoldsText(vt: try fixture("typed-ide-chip")))
  }

  /// A live Bash permission dialog: `Do you want to proceed?` over a `❯ 1. Yes` option, with no prompt box under it.
  /// The second capture is the same dialog after a bracketed paste reached it: Claude Code ignored the paste.
  func testAToolPermissionDialogIsBusyAndHoldsNoPaste() throws {
    for name in ["permission", "permission-after-paste"] {
      let vt = try fixture(name)
      XCTAssertEqual(AgentPaneState.classify(vt: vt), .busy, name)
      XCTAssertFalse(AgentPaneState.promptHoldsText(vt: vt), name)
      XCTAssertTrue(AgentPaneState.showsDialog(vt: vt), name)
    }
  }

  /// A dialog's selected option starts with an indented `❯`. Between two rules it is still not the prompt.
  func testAnIndentedOptionBetweenRulesIsNotThePrompt() {
    let option = "\(Self.rule)\r\n\u{1b}[1C\u{1b}[38;5;12m❯\u{1b}[1C\u{1b}[0m1. Yes\r\n\(Self.rule)\r\n"
    XCTAssertEqual(AgentPaneState.classify(vt: option), .busy)
    XCTAssertFalse(AgentPaneState.promptHoldsText(vt: option))
    let blank = "\(Self.rule)\r\n\u{1b}[1C❯\u{a0}\r\n\(Self.rule)\r\n"
    XCTAssertEqual(AgentPaneState.classify(vt: blank), .busy)
  }

  /// After a paste that did not land, whether the pane shows a dialog (or cannot be read) decides what the bar says.
  func testShowsDialogOnlyForADialogUnderTheLastRuleOrAnUnreadableScreen() throws {
    XCTAssertTrue(AgentPaneState.showsDialog(vt: try fixture("dialog")))
    XCTAssertTrue(AgentPaneState.showsDialog(vt: screen("", below: "  Enter to confirm · Esc to cancel")))
    XCTAssertTrue(AgentPaneState.showsDialog(vt: screen("text\u{1b}[K")), "unreadable")
    for name in ["idle-placeholder", "idle-after-turn", "typed", "pasted-multiline", "mid-turn"] {
      XCTAssertFalse(AgentPaneState.showsDialog(vt: try fixture(name)), name)
    }
    XCTAssertFalse(AgentPaneState.showsDialog(vt: ""))
    XCTAssertFalse(
      AgentPaneState.showsDialog(vt: "Do you want to see more?\r\n" + screen("")), "the words above the prompt box")
  }

  func testOnlyALeadingChipIsStripped() {
    let chip = "\u{1b}[0m\u{1b}[38;2;71;130;200m[⧉ In a.md]\u{1b}[0m"
    XCTAssertEqual(AgentPaneState.classify(vt: screen("[not a chip] hello")), .busy)
    XCTAssertEqual(AgentPaneState.classify(vt: screen("[not a chip]")), .busy, "other bracketed text is text")
    XCTAssertEqual(AgentPaneState.classify(vt: screen(chip + "\u{1b}[1C\u{1b}[2mTry something\u{1b}[0m")), .ready)
    XCTAssertEqual(AgentPaneState.classify(vt: screen("[⧉ 1 line selected]")), .ready, "the colour is not the test")
    XCTAssertEqual(AgentPaneState.classify(vt: screen("[⧉ In a.md")), .busy, "an unclosed chip is text")
    XCTAssertEqual(AgentPaneState.classify(vt: screen(chip + " " + chip)), .busy, "only one chip is stripped")
    XCTAssertEqual(AgentPaneState.classify(vt: screen("hi " + chip)), .busy, "a chip after text is text")
    XCTAssertEqual(AgentPaneState.classify(vt: screen("[⧉ In a[1].md]")), .ready, "the matching bracket ends it")
    XCTAssertEqual(AgentPaneState.classify(vt: screen("[⧉ In a.md]x")), .busy)
    XCTAssertTrue(AgentPaneState.promptHoldsText(vt: screen(chip + " [Pasted text #1 +3 lines]")))
  }
}
