import XCTest

@testable import TermDownCore

final class AppliedChangesTests: XCTestCase {
  var base: URL!

  override func setUpWithError() throws {
    base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: base)
  }

  /// The bundled hotkey set, whatever delivery plugin the machine running the tests has installed.
  var hotkeys: [ReviewHotkey] { ReviewHotkeys.load() }

  func fixture(_ name: String, _ ext: String) throws -> URL {
    try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures/applied-diff"))
  }

  func log(_ name: String) throws -> URL { try fixture(name, "review.jsonl") }

  func text(_ name: String) throws -> String { try String(contentsOf: fixture(name, "current.md"), encoding: .utf8) }

  /// A log holding one submitted pass, shaped like the records TermDown writes.
  func submitted(_ snapshot: String, asks: [[String: Any]] = [], pass: Int = 1) throws -> URL {
    let record: [String: Any] = [
      "pass": pass, "ts": "2026-09-09T10:00:00", "format": "viewer", "action": "go", "draft_snapshot": snapshot,
      "annotations": asks,
    ]
    let url = base.appendingPathComponent(UUID().uuidString + ".review.jsonl")
    try (String(decoding: JSONSerialization.data(withJSONObject: record), as: UTF8.self) + "\n")
      .write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  func ask(
    _ type: String, _ text: String, line: Int, end: Int? = nil, note: String? = nil, seq: Int = 1
  ) -> [String: Any] {
    var record: [String: Any] = [
      "type": type, "label": type, "text": text, "context": text, "line": line, "col_from": 0,
      "end_line": end ?? line, "col_to": text.count, "occurrence": 1, "seq": seq,
    ]
    record["note"] = note ?? NSNull()
    return record
  }

  // MARK: features/applied-diff.feature

  func testTheFirstPassHasNothingToCompareAgainst() throws {
    XCTAssertNil(AppliedChanges.compute(log: try log("never-submitted"), current: "Alpha line.\n"))
    XCTAssertNil(
      AppliedChanges.compute(log: base.appendingPathComponent("missing.review.jsonl"), current: "Alpha line.\n"),
      "a draft with no log at all has never been submitted either")
  }

  func testTheBaselineIsTheLastSubmitAndNotTheLastLaunch() throws {
    let changes = try XCTUnwrap(AppliedChanges.compute(log: try log("submit-then-launches"), current: "Beta line.\n"))
    XCTAssertEqual(changes.fromPass, 1)
    XCTAssertEqual(changes.hunks.count, 1, "diffed against a launch snapshot instead of the submit")
    XCTAssertEqual(changes.hunks[0].removed, "Alpha")
    XCTAssertEqual(changes.hunks[0].added, "Beta")
  }

  func testTheBaselineIsTheNewestSubmitWhenThereAreSeveral() throws {
    let store = ReviewStore(
      draft: base.appendingPathComponent("draft.md"),
      environment: ["TERMDOWN_REVIEW_HOME": base.appendingPathComponent("store").path], home: base)
    try store.logLaunch(snapshot: "One.\n", about: nil)
    try store.submit(action: .go, annotations: [], launchText: "One.\n", finalText: "Two.\n", about: nil)
    try store.logLaunch(snapshot: "Three.\n", about: nil)
    try store.submit(action: .go, annotations: [], launchText: "Three.\n", finalText: "Four.\n", about: nil)
    try store.logLaunch(snapshot: "Five.\n", about: nil)
    let changes = try XCTUnwrap(AppliedChanges.compute(log: store.logFile, current: "Five.\n"))
    XCTAssertEqual(changes.fromPass, 2, "the log TermDown writes names the pass the text was submitted on")
    XCTAssertEqual(changes.hunks.map(\.removed), ["Four."])
  }

  func testADraftUnchangedSinceTheLastGoReportsZeroChangesRatherThanNothing() throws {
    let draft = "# Draft\n\nUntouched.\n"
    let changes = try XCTUnwrap(AppliedChanges.compute(log: try submitted(draft), current: draft))
    XCTAssertEqual(changes.hunks, [])
    XCTAssertEqual(changes.fromPass, 1)
    XCTAssertTrue(changes.markdown(hotkeys: hotkeys).contains("No changes since pass 1"))
  }

  func testChangesAreReportedAsLineRangesInTheCurrentDraft() throws {
    let old = "# Draft\n\nShipped \u{1F680} fast.\n\nThe old second paragraph.\n"
    let new = "# Draft\n\nShipped \u{1F680} fast.\n\nA rewritten second paragraph.\n"
    let changes = try XCTUnwrap(AppliedChanges.compute(log: try submitted(old), current: new))
    XCTAssertEqual(changes.hunks.count, 1)
    XCTAssertEqual(changes.hunks[0].lines, 5...5, "a line number, so the emoji above it shifts nothing")
    XCTAssertTrue(changes.markdown(hotkeys: hotkeys).contains("L5 "))
  }

  func testAOneLineRewriteReportsOnlyTheWordsThatChanged() throws {
    let old = "So we were able to deliver it in two sessions.\n"
    let new = "So we delivered it in two sessions.\n"
    let hunk = try XCTUnwrap(AppliedChanges.compute(log: try submitted(old), current: new)?.hunks.first)
    XCTAssertEqual(hunk.removed, "were able to deliver")
    XCTAssertEqual(hunk.added, "delivered")
    XCTAssertTrue(old.contains(hunk.removed) && new.contains(hunk.added))
  }

  func testAHunkNamesTheHotkeyThatAskedForIt() throws {
    let old = "# Draft\n\nWe were able to deliver it.\n"
    let new = "# Draft\n\nWe delivered it.\n"
    let log = try submitted(old, asks: [ask("shorten", "were able to deliver", line: 3)])
    let changes = try XCTUnwrap(AppliedChanges.compute(log: log, current: new))
    XCTAssertEqual(changes.hunks[0].asks.map(\.type), ["shorten"])
    XCTAssertEqual(changes.unanswered, [])
  }

  func testAHunkAnsweringSeveralAnnotationsCarriesEachOnesOwnPassage() throws {
    let changes = try XCTUnwrap(
      AppliedChanges.compute(log: try log("three-asks-one-hunk"), current: try text("three-asks-one-hunk")))
    let merged = changes.hunks.filter { $0.asks.count > 1 }
    XCTAssertEqual(merged.count, 1, "\(changes.hunks.map(\.asks.count))")
    XCTAssertEqual(merged[0].asks.map(\.type), ["note", "cringe", "delete"])
    XCTAssertEqual(
      merged[0].asks.map(\.text),
      [
        "- **First bullet.** Worded oddly", "the biggest risk of all",
        "- **Third bullet.** Onboarding takes roughly six weeks, which is too long.",
      ])
    XCTAssertEqual(changes.unanswered, [])
    let markdown = changes.markdown(hotkeys: hotkeys)
    XCTAssertTrue(markdown.contains("the biggest risk of all"), "each ask quotes the passage it was made on")
    XCTAssertTrue(markdown.contains("Worded oddly"))
    XCTAssertTrue(markdown.contains("this is worded strangely"), "the typed note comes through")
    XCTAssertTrue(markdown.contains("9 Note..."))
    XCTAssertTrue(markdown.contains("3 Cringe"))
  }

  func testAnAnnotationThatProducedNoChangeIsReportedAsUnanswered() throws {
    let old = "# Draft\n\nFirst paragraph.\n\nSecond paragraph.\n"
    let new = "# Draft\n\nFirst paragraph.\n\nSecond paragraph, rewritten.\n"
    let ignored = ask("source", "First paragraph.", line: 3, note: "where is this from?")
    let changes = try XCTUnwrap(AppliedChanges.compute(log: try submitted(old, asks: [ignored]), current: new))
    XCTAssertEqual(changes.hunks[0].asks, [], "an untouched line's ask was credited")
    XCTAssertEqual(changes.unanswered.map(\.type), ["source"])
    XCTAssertEqual(changes.unanswered[0].text, "First paragraph.")
    XCTAssertEqual(changes.unanswered[0].note, "where is this from?")
  }

  func testADeletedPassageHasNoLineToMarkButIsStillListed() throws {
    let old = "# Draft\n\nKeep this.\n\nCut this whole paragraph.\n\nAnd keep this.\n"
    let new = "# Draft\n\nKeep this.\n\nAnd keep this.\n"
    let changes = try XCTUnwrap(AppliedChanges.compute(log: try submitted(old), current: new))
    let cuts = changes.hunks.filter { $0.lines == nil }
    XCTAssertEqual(cuts.count, 1, "\(changes.hunks)")
    XCTAssertTrue(cuts[0].removed.contains("Cut this whole paragraph."))
    XCTAssertEqual(cuts[0].added, "")
    XCTAssertTrue((1...ReviewStore.pythonLines(new).count).contains(cuts[0].anchor))
    let markdown = changes.markdown(hotkeys: hotkeys)
    XCTAssertTrue(markdown.contains("~~Cut this whole paragraph.~~"))
    XCTAssertFalse(markdown.contains("→"), "a deletion is listed with no new text")
  }

  func testAChangeThatStartsOnABlankLineMarksTheProseAndNotTheGap() throws {
    let old = "# Draft\n\nFirst paragraph.\n"
    let new = "# Draft\n\nFirst paragraph.\n\nA new closing paragraph.\n"
    let hunk = try XCTUnwrap(AppliedChanges.compute(log: try submitted(old), current: new)?.hunks.first)
    XCTAssertEqual(hunk.lines, 5...5, "not 4...5, which includes the blank")
    XCTAssertEqual(hunk.added, "A new closing paragraph.")
  }

  func testAWholesaleRewriteIsCappedRatherThanShippingTheWholeDraftTwice() throws {
    var old: [String] = []
    var new: [String] = []
    for i in 0..<200 {
      old.append("old \(i) " + String(repeating: "x", count: 900))
      new.append(i % 2 == 1 ? "new \(i) " + String(repeating: "y", count: 900) : old[i])
    }
    let changes = try XCTUnwrap(
      AppliedChanges.compute(log: try submitted(old.joined(separator: "\n")), current: new.joined(separator: "\n")))
    XCTAssertEqual(changes.hunks.count, AppliedChanges.maxHunks)
    XCTAssertGreaterThan(changes.more, 0)
    for hunk in changes.hunks {
      XCTAssertLessThanOrEqual(hunk.removed.unicodeScalars.count, AppliedChanges.maxQuote + 2)
      XCTAssertLessThanOrEqual(hunk.added.unicodeScalars.count, AppliedChanges.maxQuote + 2)
    }
    XCTAssertTrue(changes.markdown(hotkeys: hotkeys).contains("more change"))
  }

  func testAReloadRederivesTheDiffAgainstTheSameBaseline() throws {
    let log = try log("submit-then-launches")
    let first = AppliedChanges.compute(log: log, current: "Beta line.\n")
    let second = AppliedChanges.compute(log: log, current: "Gamma line.\n")
    XCTAssertEqual(first?.fromPass, 1)
    XCTAssertEqual(second?.fromPass, 1)
    XCTAssertEqual(second?.hunks.first?.removed, "Alpha")
    XCTAssertEqual(second?.hunks.first?.added, "Gamma")
    XCTAssertEqual(AppliedChanges.compute(log: log, current: "Beta line.\n"), first)
  }

  // MARK: markdown()

  func testTheMarkdownNamesThePassTheHotkeyTheChangeAndWhatGotNoAnswer() throws {
    let changes = try XCTUnwrap(
      AppliedChanges.compute(log: try log("cringe-and-unanswered"), current: try text("cringe-and-unanswered")))
    XCTAssertEqual(
      changes.markdown(hotkeys: hotkeys),
      """
      ## Since pass 1

      ### 3 Cringe

      L3 ~~truly transformative~~ → great

      ## Asked for, no change found

      - L5 7 Source?: First paragraph. (note: where is this from?)

      """)
  }

  func testTheMarkdownOmitsTheUnansweredSectionWhenEveryAskGotAChange() throws {
    let changes = try XCTUnwrap(
      AppliedChanges.compute(log: try log("cringe-and-unanswered"), current: try text("cringe-and-unanswered")))
    var answered = changes
    answered.unanswered = []
    XCTAssertFalse(answered.markdown(hotkeys: hotkeys).contains("Asked for, no change found"))
  }

  func testAChangeWithNoAskIsListedAsChangedAndMultiLineSidesStayReadable() throws {
    let old = "# Draft\n\nKeep.\n\nOld one.\nOld two.\n"
    let new = "# Draft\n\nKeep.\n\nNew one.\nNew two.\n"
    let markdown = try XCTUnwrap(AppliedChanges.compute(log: try submitted(old), current: new)).markdown(
      hotkeys: hotkeys)
    XCTAssertEqual(
      markdown,
      """
      ## Since pass 1

      ### Changed

      L5-6

      ~~Old one.~~\\
      ~~Old two.~~

      → New one.\\
      New two.

      """)
  }

  func testMarkdownShownAsTextEscapesWhatMarkdownWouldAct() {
    XCTAssertEqual(AppliedChanges.literal("**bold** a_b <x> #1"), "\\*\\*bold\\*\\* a\\_b \\<x\\> \\#1")
    XCTAssertEqual(AppliedChanges.literal("- item"), "\\- item")
    XCTAssertEqual(AppliedChanges.literal("2. item"), "2\\. item")
  }

  func testAKeyThatTheHotkeySetDoesNotKnowFallsBackToTheLoggedLabel() throws {
    let log = try submitted("Old.\n", asks: [ask("mystery", "Old.", line: 1)])
    let markdown = try XCTUnwrap(AppliedChanges.compute(log: log, current: "New.\n")).markdown(hotkeys: hotkeys)
    XCTAssertTrue(markdown.contains("### mystery"))
  }
}
