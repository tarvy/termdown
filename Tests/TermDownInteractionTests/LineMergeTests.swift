import XCTest

@testable import TermDownInteraction

final class LineMergeTests: XCTestCase {
  private func merge(_ base: String, _ disk: String, _ mine: String) -> (String, Int, Int) {
    let r = LineMerge.merge(base: Array(base.utf8), disk: Array(disk.utf8), mine: Array(mine.utf8))
    return (String(decoding: r.text, as: UTF8.self), r.applied, r.keptMine)
  }

  func testDisjointChangesBothApply() {
    let (text, applied, kept) = merge("a\nb\nc\nd\n", "A\nb\nc\nd\n", "a\nb\nc\nD\n")
    XCTAssertEqual(text, "A\nb\nc\nD\n")
    XCTAssertEqual(applied, 1)
    XCTAssertEqual(kept, 0)
  }

  func testInsertionsAndDeletionsFromDiskApply() {
    let (text, _, _) = merge("a\nb\nc\n", "a\nx\ny\nb\n", "a\nb\nc\nmine\n")
    XCTAssertEqual(text, "a\nx\ny\nb\nmine\n", "disk inserted x y and deleted c; mine appended a line")
  }

  func testOverlappingChangeKeepsMine() {
    let (text, applied, kept) = merge("a\nb\nc\n", "a\nB\nc\n", "a\nb2\nc\n")
    XCTAssertEqual(text, "a\nb2\nc\n")
    XCTAssertEqual(applied, 0)
    XCTAssertEqual(kept, 1)
  }

  func testNoTrailingNewlineAndCRLFSurvive() {
    let (text, _, _) = merge("a\r\nb\r\nc", "a\r\nB\r\nc", "a\r\nb\r\nc\r\nd")
    XCTAssertEqual(text, "a\r\nB\r\nc\r\nd")
  }

  func testAgentRewritesOneLineWhileThePersonTypesOnAnother() {
    let base = (1...400).map { "line \($0)" }.joined(separator: "\n") + "\n"
    let disk = base.replacingOccurrences(of: "line 369\n", with: "line 369 edited by the agent\n")
    let mine = base.replacingOccurrences(of: "line 371\n", with: "line 371 edited by me\n")
    let (text, applied, kept) = merge(base, disk, mine)
    XCTAssertTrue(text.contains("line 369 edited by the agent\n") && text.contains("line 371 edited by me\n"))
    XCTAssertEqual(applied, 1)
    XCTAssertEqual(kept, 0)
  }
}
