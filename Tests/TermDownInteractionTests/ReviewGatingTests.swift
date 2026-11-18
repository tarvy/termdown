import Foundation
import XCTest

@testable import TermDownInteraction

final class ReviewGatingTests: XCTestCase {
  private func select(_ needle: String, in h: inout Harness) {
    h.run(h.model.setSelection(h.range(of: needle)))
  }

  private func startAndMark(_ h: inout Harness) {
    h.connectAgent()
    h.key(.char("m"))
    select("text", in: &h)
    h.key(.char("1"))
  }

  func testMWithNoAgentStaysOffAndSaysHowToConnect() {
    var h = Harness("Some text here.\n")
    let effects = h.key(.char("m"))
    XCTAssertFalse(h.model.review.isOn)
    XCTAssertFalse(effects.contains(.reviewLaunched))
    XCTAssertEqual(
      h.model.status.message?.text,
      "No agent connected: run /ide in a Claude session and pick this preview, or press A to start one beside it.")
  }

  func testMWithOneAgentStartsReview() {
    var h = Harness("Some text here.\n")
    h.connectAgent(title: "review-lab")
    XCTAssertEqual(h.model.reviewAgent, ReviewAgentStatus(connected: 1, title: "review-lab", chosen: true))
    let effects = h.key(.char("m"))
    XCTAssertTrue(h.model.review.isOn)
    XCTAssertTrue(effects.contains(.reviewLaunched))
  }

  func testMWithTwoAgentsAndNoChoiceAsksFirst() {
    var h = Harness("Some text here.\n")
    h.run(h.model.setReviewAgent(ReviewAgentStatus(connected: 2, title: nil, chosen: false), at: h.now))
    XCTAssertEqual(h.key(.char("m")), [.chooseReviewAgent])
    XCTAssertFalse(h.model.review.isOn)
  }

  /// An agent connected from outside Rex shows the plug but has no pane to paste into: `m`, a review request and a
  /// send all say so, and none of them asks which agent.
  func testAnAgentOutsideRexIsConnectedButCannotTakeAReview() {
    let outside = "The connected agent is outside Rex: reviews need an agent in a Rex pane"
    var h = Harness("Some text here.\n")
    let status = ReviewAgentStatus(connected: 1, title: nil, chosen: false, outsideRex: true)
    h.run(h.model.setReviewAgent(status, at: h.now))
    XCTAssertEqual(h.model.status.agent, "", "the plug shows")
    let effects = h.key(.char("m"))
    XCTAssertFalse(h.model.review.isOn)
    XCTAssertFalse(effects.contains(.chooseReviewAgent))
    XCTAssertFalse(effects.contains(.reviewLaunched))
    XCTAssertEqual(h.model.status.message?.text, outside)

    h.run(h.model.requestReview(at: h.now))
    XCTAssertFalse(h.model.review.isOn)
    XCTAssertFalse(h.effects.contains(.chooseReviewAgent))
    XCTAssertEqual(h.model.status.message?.text, outside)

    startAndMark(&h)
    h.run(h.model.setReviewAgent(status, at: h.now))
    XCTAssertFalse(h.key(.char("s")).contains { if case .submitReview = $0 { true } else { false } })
    XCTAssertEqual(h.model.status.message?.text, outside)
    XCTAssertEqual(h.model.review.marks.count, 1)
  }

  func testStartReviewTurnsReviewOnAfterTheChoice() {
    var h = Harness("Some text here.\n")
    h.run(h.model.setReviewAgent(ReviewAgentStatus(connected: 2, title: "b", chosen: true), at: h.now))
    h.run(h.model.startReview(at: h.now))
    XCTAssertTrue(h.model.review.isOn)
    XCTAssertEqual(h.model.review.snapshot, "Some text here.\n")
    XCTAssertTrue(h.effects.contains(.reviewLaunched))
  }

  func testSendWithNoAgentKeepsTheMarksAndSaysHowToConnect() {
    var h = Harness("Some text here.\n")
    startAndMark(&h)
    h.run(h.model.setReviewAgent(ReviewAgentStatus(connected: 0, title: nil, chosen: false), at: h.now))
    for key in ["s", "F"] {
      XCTAssertFalse(h.key(.char(Character(key))).contains { if case .submitReview = $0 { true } else { false } })
      XCTAssertEqual(
        h.model.status.message?.text,
        "No agent connected: run /ide in a Claude session and pick this preview, or press A to start one beside it.")
    }
    XCTAssertTrue(h.model.review.isOn)
    XCTAssertEqual(h.model.review.marks.count, 1)
  }

  func testSendToAllAgentsAsksForOne() {
    var h = Harness("Some text here.\n")
    startAndMark(&h)
    h.run(h.model.setReviewAgent(ReviewAgentStatus(connected: 2, title: nil, chosen: false), at: h.now))
    for key in ["s", "F"] {
      XCTAssertFalse(h.key(.char(Character(key))).contains { if case .submitReview = $0 { true } else { false } })
      XCTAssertEqual(h.model.status.message?.text, "Choose one agent for the review: press A")
    }
    XCTAssertTrue(h.model.review.isOn)
    XCTAssertEqual(h.model.review.marks.count, 1)
  }

  func testMOffWithMarksAsksBeforeDiscarding() {
    var h = Harness("Some text here.\n")
    startAndMark(&h)
    XCTAssertEqual(h.model.review.marks.count, 1)
    h.key(.char("m"))
    XCTAssertEqual(h.model.confirm?.prompt, "Discard 1 mark? y / n")
    XCTAssertEqual(h.model.confirm?.action, .discardAndStop)
    XCTAssertEqual(h.model.status.message?.text, "Discard 1 mark? y / n")
    XCTAssertTrue(h.model.review.isOn)
    XCTAssertEqual(h.model.review.marks.count, 1)

    h.key(.char("n"))
    XCTAssertNil(h.model.confirm)
    XCTAssertTrue(h.model.review.isOn)
    XCTAssertEqual(h.model.review.marks.count, 1)

    h.key(.char("m"))
    XCTAssertNotNil(h.model.confirm)
    h.key(.escape)
    XCTAssertNil(h.model.confirm, "Esc also keeps the marks")
    XCTAssertEqual(h.model.review.marks.count, 1)

    h.key(.char("m"))
    h.key(.char("y"))
    XCTAssertNil(h.model.confirm)
    XCTAssertFalse(h.model.review.isOn)
    XCTAssertTrue(h.model.review.marks.isEmpty)
  }

  func testThePromptCountsMarks() {
    var h = Harness("Some text here and more text.\n")
    h.connectAgent()
    h.key(.char("m"))
    select("Some", in: &h)
    h.key(.char("1"))
    select("more", in: &h)
    h.key(.char("2"))
    h.key(.char("m"))
    XCTAssertEqual(h.model.confirm?.prompt, "Discard 2 marks? y / n")
  }

  func testOtherKeysDoNothingWhileTheDiscardPromptIsUp() {
    var h = Harness("Some text here.\n")
    startAndMark(&h)
    h.key(.char("m"))
    XCTAssertEqual(h.key(.char("j")), [])
    XCTAssertNotNil(h.model.confirm)
    XCTAssertEqual(h.key(.ctrl("c")), [.quit])
  }

  func testMOffWithoutMarksStopsAtOnce() {
    var h = Harness("Some text here.\n")
    h.connectAgent()
    h.key(.char("m"))
    h.key(.char("m"))
    XCTAssertNil(h.model.confirm)
    XCTAssertFalse(h.model.review.isOn)
  }

  func testDisconnectMidReviewKeepsMarks() {
    var h = Harness("Some text here.\n")
    startAndMark(&h)
    h.run(h.model.setReviewAgent(ReviewAgentStatus(connected: 0, title: nil, chosen: false), at: h.now))
    XCTAssertTrue(h.model.review.isOn)
    XCTAssertEqual(h.model.review.marks.count, 1)
  }

  func testCancelReviewTurnsItOffAndShowsTheMessage() {
    var h = Harness("Some text here.\n")
    h.connectAgent()
    h.key(.char("m"))
    h.run(h.model.cancelReview(message: "Review is open in another viewer", at: h.now))
    XCTAssertFalse(h.model.review.isOn)
    XCTAssertTrue(h.model.review.marks.isEmpty)
    XCTAssertEqual(h.model.status.message?.text, "Review is open in another viewer")
    XCTAssertEqual(h.model.status.message?.kind, .info)
  }

  func testStatusCarriesLegendOnlyWhileReviewing() {
    var h = Harness("Some text here.\n")
    h.connectAgent()
    XCTAssertNil(h.model.status.review)
    h.key(.char("m"))
    XCTAssertEqual(h.model.status.review?.legend.map(\.key), (1...9).map(String.init))
    XCTAssertEqual(h.model.status.review?.marks, 0)
    XCTAssertEqual(h.model.status.review?.legend.first?.label, "Delete")
    XCTAssertEqual(h.model.status.review?.legend.first?.color, "#ef4444")
    select("text", in: &h)
    h.key(.char("1"))
    XCTAssertEqual(h.model.status.review?.marks, 1)
  }

  func testStatusLegendFollowsTheHotkeysGiven() {
    var h = Harness("Some text here.\n")
    h.model.reviewHotkeys = Array(h.model.reviewHotkeys.prefix(3))
    h.connectAgent()
    h.key(.char("m"))
    XCTAssertEqual(h.model.status.review?.legend.map(\.key), ["1", "2", "3"])
  }

  func testStatusAgentFollowsTheConnection() {
    var h = Harness("Some text here.\n")
    XCTAssertNil(h.model.status.agent)
    h.connectAgent(title: "review-lab")
    XCTAssertEqual(h.model.status.agent, "review-lab")
    h.run(h.model.setReviewAgent(ReviewAgentStatus(connected: 2, title: nil, chosen: false), at: h.now))
    XCTAssertEqual(h.model.status.agent, "", "connected with no title is a plug with no title")
    h.run(h.model.setReviewAgent(ReviewAgentStatus(connected: 0, title: nil, chosen: false), at: h.now))
    XCTAssertNil(h.model.status.agent)
  }

  func testStatusClientComesFromTheDraftOnlyWhileReviewing() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("termdown-client-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("draft.md")
    let text = "---\nclient: Parnell\n---\n\nSome text here.\n"
    try text.write(to: file, atomically: true, encoding: .utf8)
    var h = Harness(text, path: file.path)
    h.connectAgent()
    XCTAssertNil(h.model.status.client)
    h.key(.char("m"))
    XCTAssertEqual(h.model.status.client, "Parnell")
    h.key(.char("m"))
    XCTAssertNil(h.model.status.client)
  }

  // MARK: Leaving with unsent marks

  static let guide = "Some text here with a [Link](other.md) and a [Self](guide.md#top).\n\n# Top\n"
  static let other = "# Other\n\nMore text on this page.\n"
  static var otherURL: URL { URL(fileURLWithPath: "/docs/other.md") }

  func testQWithNoMarksQuitsAtOnce() {
    var h = Harness(Self.guide)
    XCTAssertEqual(h.key(.char("q")), [.quit])
    h.connectAgent()
    h.key(.char("m"))
    XCTAssertEqual(h.key(.char("q")), [.quit], "review with no marks has nothing to lose")
  }

  func testQWithMarksAsks() {
    var h = Harness(Self.guide)
    startAndMark(&h)
    XCTAssertFalse(h.key(.char("q")).contains(.quit))
    XCTAssertEqual(h.model.confirm, ReviewConfirm(prompt: "Discard 1 mark? y / n", action: .discardAndQuit))
    XCTAssertEqual(h.model.status.message?.text, "Discard 1 mark? y / n")

    h.key(.char("n"))
    XCTAssertNil(h.model.confirm)
    XCTAssertEqual(h.model.review.marks.count, 1)

    h.key(.char("q"))
    XCTAssertTrue(h.key(.char("y")).contains(.quit))
    XCTAssertTrue(h.model.review.marks.isEmpty, "a discarded mark is not kept for the host to save")
  }

  func testControlCQuitsAtOnceAndLeavesTheMarksForTheHostToKeep() {
    var h = Harness(Self.guide)
    startAndMark(&h)
    XCTAssertEqual(h.key(.ctrl("c")), [.quit])
    XCTAssertEqual(h.model.review.marks.count, 1)
  }

  func testALinkToAnotherFileWithMarksAsks() {
    var h = Harness(Self.guide, files: ["/docs/other.md": Self.other])
    startAndMark(&h)
    h.click(h.point(of: "Link"))
    XCTAssertTrue(h.loads.isEmpty)
    XCTAssertEqual(h.model.file?.lastPathComponent, "guide.md")
    XCTAssertEqual(h.model.confirm, ReviewConfirm(prompt: "Discard 1 mark? y / n", action: .discardAndOpen(Self.otherURL)))

    h.key(.char("n"))
    XCTAssertNil(h.model.confirm)
    XCTAssertTrue(h.loads.isEmpty)
    XCTAssertEqual(h.model.review.marks.count, 1)

    h.click(h.point(of: "Link"))
    h.key(.char("y"))
    XCTAssertEqual(h.loads.map(\.lastPathComponent), ["other.md"])
    XCTAssertEqual(h.model.file?.lastPathComponent, "other.md")
    XCTAssertFalse(h.model.review.isOn)
    XCTAssertTrue(h.model.review.marks.isEmpty)
    h.key(.backspace)
    XCTAssertEqual(h.model.file?.lastPathComponent, "guide.md", "the link still counts as a step in the history")
  }

  func testALinkWithReviewOnAndNoMarksOpensAtOnce() {
    var h = Harness(Self.guide, files: ["/docs/other.md": Self.other])
    h.connectAgent()
    h.key(.char("m"))
    h.click(h.point(of: "Link"))
    XCTAssertNil(h.model.confirm)
    XCTAssertEqual(h.model.file?.lastPathComponent, "other.md")
  }

  func testBackAndForwardWithMarksAskAndNoLeavesTheHistoryAlone() {
    var h = Harness(Self.guide, files: ["/docs/other.md": Self.other])
    h.click(h.point(of: "Link"))
    XCTAssertEqual(h.model.file?.lastPathComponent, "other.md")
    h.connectAgent()
    h.key(.char("m"))
    h.run(h.model.setSelection(h.range(of: "text")))
    h.key(.char("1"))

    h.key(.backspace)
    XCTAssertEqual(h.model.confirm?.action, .discardAndOpen(URL(fileURLWithPath: "/docs/guide.md")))
    XCTAssertEqual(h.model.file?.lastPathComponent, "other.md")
    h.key(.char("n"))
    XCTAssertEqual(h.model.review.marks.count, 1)

    h.key(.char("h"))
    h.key(.char("n"))
    XCTAssertEqual(h.model.file?.lastPathComponent, "other.md")

    h.key(.char("y"))  // nothing pending: ignored
    h.key(.char("m"))
    h.key(.char("y"))
    XCTAssertFalse(h.model.review.isOn)
    h.key(.backspace)
    XCTAssertEqual(h.model.file?.lastPathComponent, "guide.md", "the refused back left the history where it was")

    h.connectAgent()
    h.key(.char("m"))
    h.run(h.model.setSelection(h.range(of: "text")))
    h.key(.char("1"))
    h.key(.char("L"))
    XCTAssertEqual(h.model.confirm?.action, .discardAndOpen(Self.otherURL))
    h.key(.char("y"))
    XCTAssertEqual(h.model.file?.lastPathComponent, "other.md")
    XCTAssertFalse(h.model.review.isOn)
  }

  /// A click while the discard prompt is up would load its link and replace the held Back, which then could not be
  /// reverted. The prompt swallows clicks; the wheel still scrolls.
  func testAClickWhileTheDiscardPromptIsUpDoesNothingAndTheWheelStillScrolls() {
    let other = "# Other\n\nA [Third](third.md) link.\n\n" + longDocument()
    var h = Harness(Self.guide, files: ["/docs/other.md": other, "/docs/third.md": "# Third\n"])
    h.click(h.point(of: "Link"))
    XCTAssertEqual(h.model.file?.lastPathComponent, "other.md")
    h.connectAgent()
    h.key(.char("m"))
    h.run(h.model.setSelection(h.range(of: "link")))
    h.key(.char("1"))
    h.key(.backspace)
    let asked = h.model.confirm
    XCTAssertEqual(asked?.action, .discardAndOpen(URL(fileURLWithPath: "/docs/guide.md")))
    let loads = h.loads

    XCTAssertEqual(h.click(h.point(of: "Third")), [])
    XCTAssertEqual(h.model.confirm, asked, "the click does not replace the Back prompt")
    XCTAssertEqual(h.loads, loads)
    let top = h.model.offset
    h.mouse(.wheelDown, at: h.point(of: "Third"))
    XCTAssertGreaterThan(h.model.offset, top, "the wheel still scrolls")

    h.key(.char("n"))
    XCTAssertNil(h.model.confirm)
    XCTAssertEqual(h.model.review.marks.count, 1)
    h.key(.char("m"))
    h.key(.char("y"))
    h.key(.backspace)
    XCTAssertEqual(h.model.file?.lastPathComponent, "guide.md", "the refused Back left the history where it was")
  }

  func testTheSameFileNeverAsks() {
    var h = Harness(Self.guide, files: ["/docs/other.md": Self.other])
    startAndMark(&h)
    XCTAssertEqual(h.model.open(URL(fileURLWithPath: "/docs/guide.md")), [.reload])
    XCTAssertEqual(h.model.open(URL(fileURLWithPath: "/docs/./guide.md")), [.reload])
    XCTAssertNil(h.model.confirm)
    h.click(h.point(of: "Self"))
    XCTAssertNil(h.model.confirm, "a link into the shown file just scrolls")
    h.reload(Self.guide + "\nMore.\n")
    XCTAssertNil(h.model.confirm)
    XCTAssertEqual(h.model.review.marks.count, 1)
    XCTAssertTrue(h.model.review.isOn)
  }

  func testOpeningAnotherFileFromOutsideAsksWhileMarksAreUnsent() {
    var h = Harness(Self.guide, files: ["/docs/other.md": Self.other])
    startAndMark(&h)
    XCTAssertEqual(h.model.open(Self.otherURL), [.redrawStatusBar])
    XCTAssertEqual(h.model.confirm?.action, .discardAndOpen(Self.otherURL))
    h.key(.char("y"))
    XCTAssertEqual(h.model.file?.lastPathComponent, "other.md")
    XCTAssertEqual(h.loads.count, 1)
    XCTAssertFalse(h.model.review.isOn)
  }

  func testOpeningAnotherFileWithNothingUnsentIsUntouched() {
    var h = Harness(Self.guide, files: ["/docs/other.md": Self.other])
    let guide = URL(fileURLWithPath: "/docs/guide.md")
    let toOther = h.model.open(Self.otherURL)
    XCTAssertEqual(toOther, [.loadDocument(Self.otherURL)])
    h.run(toOther)
    h.connectAgent()
    h.key(.char("m"))
    XCTAssertEqual(h.model.open(guide), [.loadDocument(guide)], "review on with no marks has nothing to lose")
  }

  // MARK: termdown review

  func testPendingReviewStartsOnConnect() {
    var h = Harness("Some text here.\n")
    h.run(h.model.requestReview(at: h.now))
    XCTAssertTrue(h.model.reviewPending)
    XCTAssertFalse(h.model.review.isOn)
    XCTAssertEqual(
      h.model.status.message?.text,
      "No agent connected: run /ide in a Claude session and pick this preview, or press A to start one beside it.")

    h.run(h.model.setReviewAgent(ReviewAgentStatus(connected: 1, title: "x", chosen: true), at: h.now))
    XCTAssertTrue(h.model.review.isOn)
    XCTAssertFalse(h.model.reviewPending)
    XCTAssertTrue(h.effects.contains(.reviewLaunched))
  }

  func testPendingReviewWaitsForOneChosenAgent() {
    var h = Harness("Some text here.\n")
    h.model.reviewPending = true
    h.run(h.model.setReviewAgent(ReviewAgentStatus(connected: 2, title: nil, chosen: false), at: h.now))
    XCTAssertFalse(h.model.review.isOn)
    XCTAssertTrue(h.model.reviewPending)
    h.run(h.model.setReviewAgent(ReviewAgentStatus(connected: 2, title: "b", chosen: true), at: h.now))
    XCTAssertTrue(h.model.review.isOn)
  }

  func testStartingReviewAnyOtherWayClearsAPendingRequest() {
    var h = Harness("Some text here.\n")
    h.model.reviewPending = true
    h.connectAgent()
    XCTAssertTrue(h.model.review.isOn)
    XCTAssertFalse(h.model.reviewPending)
    h.run(h.model.setReviewAgent(ReviewAgentStatus(connected: 0, title: nil, chosen: false), at: h.now))
    h.run(h.model.requestReview(at: h.now))
    XCTAssertFalse(h.model.reviewPending, "review is already on")
  }

  func testRequestWithOneAgentStartsAtOnce() {
    var h = Harness("Some text here.\n")
    h.connectAgent()
    let effects = h.model.requestReview(at: h.now)
    XCTAssertTrue(effects.contains(.reviewLaunched))
    XCTAssertTrue(h.model.review.isOn)
    XCTAssertFalse(h.model.reviewPending)
  }

  func testRequestWithSeveralAgentsAndNoChoiceOpensThePicker() {
    var h = Harness("Some text here.\n")
    h.run(h.model.setReviewAgent(ReviewAgentStatus(connected: 2, title: nil, chosen: false), at: h.now))
    XCTAssertEqual(h.model.requestReview(at: h.now), [.chooseReviewAgent])
    XCTAssertFalse(h.model.review.isOn)
  }

  func testRequestWhileReviewIsOnOnlySaysSoAndKeepsTheMarks() {
    var h = Harness("Some text here.\n")
    startAndMark(&h)
    let effects = h.model.requestReview(at: h.now)
    XCTAssertFalse(effects.contains(.reviewLaunched))
    XCTAssertEqual(h.model.status.message?.text, "Review is already on")
    XCTAssertEqual(h.model.review.marks.count, 1)
    XCTAssertNil(h.model.confirm)
  }

  func testReviewOfTheShownFileIsARequestWithoutReloading() {
    var h = Harness("Some text here.\n")
    h.connectAgent()
    let effects = h.model.openForReview(URL(fileURLWithPath: "/docs/./guide.md"), at: h.now)
    XCTAssertFalse(effects.contains(.reload))
    XCTAssertTrue(effects.contains(.reviewLaunched))
  }

  func testReviewOfAnotherFileLoadsItThenStartsReview() {
    var h = Harness(Self.guide, files: ["/docs/other.md": Self.other])
    h.connectAgent()
    h.run(h.model.openForReview(Self.otherURL, at: h.now))
    XCTAssertEqual(h.model.file?.lastPathComponent, "other.md")
    XCTAssertTrue(h.model.review.isOn)
    XCTAssertEqual(h.model.review.snapshot, Self.other)
  }

  func testReviewOfAnotherFileWithNoAgentWaitsForOne() {
    var h = Harness(Self.guide, files: ["/docs/other.md": Self.other])
    h.run(h.model.openForReview(Self.otherURL, at: h.now))
    XCTAssertEqual(h.model.file?.lastPathComponent, "other.md")
    XCTAssertFalse(h.model.review.isOn)
    XCTAssertTrue(h.model.reviewPending)
    h.connectAgent()
    XCTAssertTrue(h.model.review.isOn)
  }

  func testReviewOfAnotherFileWithUnsentMarksAsksFirst() {
    var h = Harness(Self.guide, files: ["/docs/other.md": Self.other])
    startAndMark(&h)
    h.run(h.model.openForReview(Self.otherURL, at: h.now))
    XCTAssertEqual(h.model.confirm?.action, .discardAndOpen(Self.otherURL))
    XCTAssertEqual(h.model.file?.lastPathComponent, "guide.md")
    XCTAssertFalse(h.model.reviewPending)

    h.key(.char("n"))
    XCTAssertEqual(h.model.file?.lastPathComponent, "guide.md")
    XCTAssertEqual(h.model.review.marks.count, 1)
    h.key(.char("m"))
    h.key(.char("y"))
    h.run(h.model.openForReview(URL(fileURLWithPath: "/docs/guide.md"), at: h.now))
    XCTAssertTrue(h.model.review.isOn, "the refused switch left no request behind")
    XCTAssertEqual(h.model.file?.lastPathComponent, "guide.md")
  }

  func testYesAtTheDiscardPromptLoadsTheFileAndStartsReview() {
    var h = Harness(Self.guide, files: ["/docs/other.md": Self.other])
    startAndMark(&h)
    h.run(h.model.openForReview(Self.otherURL, at: h.now))
    h.key(.char("y"))
    XCTAssertEqual(h.model.file?.lastPathComponent, "other.md")
    XCTAssertTrue(h.model.review.isOn)
    XCTAssertTrue(h.model.review.marks.isEmpty)
  }

  func testAFileThatCannotBeReadLeavesNoReviewRequest() {
    var h = Harness(Self.guide)
    h.connectAgent()
    h.run(h.model.openForReview(Self.otherURL, at: h.now))
    XCTAssertEqual(h.model.file?.lastPathComponent, "guide.md")
    XCTAssertNil(h.model.reviewAfterOpen)
    XCTAssertFalse(h.model.reviewPending)
  }

  func testAPendingRequestDoesNotFollowTheViewerToAnotherFile() {
    var h = Harness(Self.guide, files: ["/docs/other.md": Self.other])
    h.run(h.model.requestReview(at: h.now))
    XCTAssertTrue(h.model.reviewPending)
    h.run(h.model.open(Self.otherURL))
    h.connectAgent()
    XCTAssertFalse(h.model.review.isOn)
  }
}
