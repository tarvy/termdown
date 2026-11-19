import XCTest

@testable import TermDownCore

final class ReviewCheckTests: XCTestCase {
  func check(
    exists: Bool = true, rex: String? = "session:1", live: Bool = false, here: Bool? = false, connected: Bool? = nil
  ) -> ReviewCheck {
    ReviewCheck(
      file: "/d/draft.md", fileExists: exists, rexSession: rex, reviewIsLive: live, previewHere: here,
      connected: connected)
  }

  func testReadyWhenTheFileExistsInRexAndNoReviewIsOpen() {
    let result = check()
    XCTAssertEqual(result.verdict, .ready)
    XCTAssertEqual(result.status, 0)
    XCTAssertEqual(
      result.text,
      "REVIEW: READY\nFILE: /d/draft.md\nPREVIEW: none\nCONNECTED: unknown\n"
        + "DETAIL: no review is open for this draft\n"
        + "NEXT: run `termdown review /d/draft.md` from your own shell, then end your turn\n")
  }

  func testALiveReviewInYourOwnTabIsOpen() {
    let result = check(live: true, here: true, connected: true)
    XCTAssertEqual(result.verdict, .open)
    XCTAssertEqual(result.status, 1)
    XCTAssertTrue(result.text.contains("PREVIEW: here\nCONNECTED: yes\n"))
    XCTAssertTrue(result.next.contains("in the preview beside them"))
  }

  func testALiveReviewOutsideYourTabIsLockedAndNeverOpenBesideYou() {
    for here in [false, nil] as [Bool?] {
      let result = check(live: true, here: here)
      XCTAssertEqual(result.verdict, .locked)
      XCTAssertEqual(result.status, 1)
      XCTAssertTrue(result.detail.contains("not in your tab"))
      XCTAssertTrue(result.next.contains("Do not say it is open beside them"))
    }
  }

  func testPreviewAndConnectedLinesSayWhatTermdownCouldTell() {
    XCTAssertTrue(check(here: nil).text.contains("PREVIEW: unknown\n"))
    XCTAssertTrue(check(here: true, connected: false).text.contains("PREVIEW: here\nCONNECTED: no\n"))
  }

  func pane(_ file: String?, agents: [String]?) -> PreviewPane {
    PreviewPane(block: "block:p", state: ViewerState(file: file, openedAt: 0, opener: nil, agents: agents))
  }

  func testOwnTabPreviewReadsOnlyThePanesInYourTab() {
    let file = "/d/draft.md"
    XCTAssertTrue(ownTabPreview(file: file, previews: nil, callerBlock: "block:me") == (nil, nil))
    XCTAssertTrue(ownTabPreview(file: file, previews: [], callerBlock: "block:me") == (false, false))
    XCTAssertTrue(
      ownTabPreview(file: file, previews: [pane("/d/other.md", agents: ["block:me"])], callerBlock: "block:me")
        == (false, false), "a preview of another file is not this draft")
    XCTAssertTrue(
      ownTabPreview(file: file, previews: [pane(file, agents: ["block:me"])], callerBlock: "block:me") == (true, true))
    XCTAssertTrue(
      ownTabPreview(file: file, previews: [pane(file, agents: ["block:other"])], callerBlock: "block:me")
        == (true, false), "another agent's connection is not yours")
    XCTAssertTrue(
      ownTabPreview(file: file, previews: [pane(file, agents: nil)], callerBlock: "block:me") == (true, nil),
      "an older viewer cannot say")
    XCTAssertTrue(ownTabPreview(file: file, previews: [pane(file, agents: [])], callerBlock: nil) == (true, nil))
  }

  func testViewerStateCarriesConnectedAgentsAndReadsOlderViewers() throws {
    let state = ViewerState(file: "/d/a.md", openedAt: 1, opener: nil, agents: ["block:me"])
    let decoded = try JSONDecoder().decode(ViewerState.self, from: JSONEncoder().encode(state))
    XCTAssertEqual(decoded.agents, ["block:me"])
    let old = try JSONDecoder().decode(ViewerState.self, from: Data(#"{"file":"/d/a.md","opened_at":1}"#.utf8))
    XCTAssertNil(old.agents)
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
