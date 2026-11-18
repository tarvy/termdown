import XCTest

@testable import TermDownCore

final class UsageTests: XCTestCase {
  func testViewIsDescribedAsAFullPreviewInThisPane() {
    XCTAssertTrue(commandUsage.contains("view <file>   Render a Markdown preview in this pane"))
    XCTAssertFalse(commandUsage.contains("in the terminal"))
  }

  func testOpenDescribesBothFlags() {
    XCTAssertTrue(commandUsage.contains("open [--new | --replace] <file>"))
    XCTAssertTrue(commandUsage.contains("--new always opens a\n"))
    XCTAssertTrue(commandUsage.contains("--replace updates the preview this pane opened last."))
  }

  func testEditAndConfigAreDescribed() {
    XCTAssertTrue(commandUsage.contains("edit [--here] [--line N] <file>"))
    XCTAssertTrue(commandUsage.contains("config [get|set|unset <name> [value]]"))
  }

  func testReviewIsDescribed() {
    XCTAssertTrue(commandUsage.contains("review [--check] <file>"))
    XCTAssertTrue(commandUsage.contains("agent-guide [review]"))
  }
}
