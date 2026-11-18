import XCTest

@testable import TermDownCore

final class ReviewCheckTests: XCTestCase {
  func check(exists: Bool = true, rex: String? = "session:1", live: Bool = false) -> ReviewCheck {
    ReviewCheck(file: "/d/draft.md", fileExists: exists, rexSession: rex, reviewIsLive: live)
  }

  func testReadyWhenTheFileExistsInRexAndNoReviewIsOpen() {
    let result = check()
    XCTAssertEqual(result.verdict, .ready)
    XCTAssertEqual(result.status, 0)
    XCTAssertEqual(
      result.text,
      "REVIEW: READY\nFILE: /d/draft.md\nDETAIL: no review is open for this draft\n"
        + "NEXT: run `termdown review /d/draft.md`, then end your turn\n")
  }

  func testALiveReviewLocksTheDraft() {
    XCTAssertEqual(check(live: true).verdict, .locked)
    XCTAssertEqual(check(live: true).status, 1)
  }

  func testOutsideRexThereIsNoPaneToReviewIn() {
    XCTAssertEqual(check(rex: nil).verdict, .noRex)
    XCTAssertEqual(check(rex: "").verdict, .noRex)
  }

  func testAMissingFileOutranksEverythingElse() {
    XCTAssertEqual(check(exists: false, rex: nil, live: true).verdict, .noFile)
  }

  func testRexOutranksALock() {
    XCTAssertEqual(check(rex: nil, live: true).verdict, .noRex)
  }

  func testReviewArgumentsTakeTheCheckFlag() throws {
    XCTAssertEqual(try ReviewArguments.parse(["--check", "a.md"]).get(), ReviewArguments(file: "a.md", check: true))
    XCTAssertEqual(try ReviewArguments.parse(["a.md", "--check"]).get(), ReviewArguments(file: "a.md", check: true))
    XCTAssertEqual(try ReviewArguments.parse(["a.md"]).get(), ReviewArguments(file: "a.md", check: false))
    XCTAssertThrowsError(try ReviewArguments.parse(["--check"]).get())
  }

  func testTheGuideTopicsListReview() {
    XCTAssertEqual(agentGuideTopics, ["review"])
  }
}
