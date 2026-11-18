import Foundation
import TermDownCore
import XCTest

@testable import TermDownHost
@testable import TermDownInteraction

@MainActor
final class ReviewHostTests: XCTestCase {
  static let draft = "# Draft\n\nThe quick brown fox jumps.\n\nA second line — with a dash.\n"
  var store: TestDirectory!

  override func setUp() async throws {
    store = try TestDirectory()
    setenv("TERMDOWN_REVIEW_HOME", store.url.path, 1)
  }

  override func tearDown() async throws {
    unsetenv("TERMDOWN_REVIEW_HOME")
    store = nil
  }

  func type(_ text: String, into host: ViewerHost) {
    host.receive(Array(text.utf8))
  }

  func mark(_ needle: String, key: String, in host: ViewerHost) throws {
    let text = try XCTUnwrap(host.interaction.layout?.prepared.text)
    let found = text.range(of: needle)
    XCTAssertNotEqual(found.location, NSNotFound)
    host.perform(host.interaction.setSelection(found.location..<(found.location + found.length)))
    type(key, into: host)
  }

  /// A review needs a connected agent session in a Rex pane; this stands one in for the host, in `block:claude`, and
  /// tells the interaction it is the review target.
  func connectAgent(_ host: ViewerHost, title: String = "claude") {
    let ide = host.ide ?? IDEBridge(workspaceFolders: [], file: host.interaction.file)
    ide.standIns = [ConnectedAgent(id: 1, block: "block:claude", title: title)]
    host.ide = ide
    reportChosenAgent(host, title: title)
  }

  /// Only tells the interaction an agent is chosen; the host itself has no review target.
  func reportChosenAgent(_ host: ViewerHost, title: String = "claude") {
    host.perform(host.interaction.setReviewAgent(ReviewAgentStatus(connected: 1, title: title, chosen: true), at: 0))
  }

  func titleReply(_ block: String, _ title: String, fixture: EditorFixture) {
    fixture.runner.reply(
      to: "do com.superlogical.terminal.title -s \(EditorFixture.session) -b \(block) --json",
      (0, Data(#"{"title":"\#(title)"}"#.utf8), Data()))
  }

  /// What `rex capture` shows of the agent's pane: one of the captured Claude Code states.
  func paneShows(_ state: String, fixture: EditorFixture) throws {
    fixture.runner.reply(to: "capture", (0, try rexFixture("agent-pane/\(state).vt"), Data()))
  }

  /// The agent's pane before the paste, then after it (by default the real handoff as Claude Code shows it, wrapped
  /// over several lines), and back to `state` once Enter submits it.
  func agentPane(_ state: String, thenAfterPaste pasted: String? = "pasted-multiline", fixture: EditorFixture) throws {
    try paneShows(state, fixture: fixture)
    let runner = fixture.runner
    let before = try rexFixture("agent-pane/\(state).vt")
    let after = try pasted.map { try rexFixture("agent-pane/\($0).vt") }
    let earlier = runner.onCall
    runner.onCall = { arguments in
      earlier?(arguments)
      if arguments.first == "send", let after { runner.reply(to: "capture", (0, after, Data())) }
      if arguments.first == "send-key" { runner.reply(to: "capture", (0, before, Data())) }
    }
  }

  /// The Rex calls that touch the agent's pane, in order, without the arguments that follow the block.
  func paneCalls(_ fixture: EditorFixture) -> [String] {
    fixture.runner.rexCalls.filter { ["capture", "send", "send-key", "focus"].contains($0.first) }.map {
      $0.first == "send-key" ? "send-key \($0.last ?? "")" : $0[0]
    }
  }

  func logRecords(_ store: ReviewStore) throws -> [[String: Any]] {
    try String(contentsOf: store.logFile, encoding: .utf8).split(separator: "\n").map {
      try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
    }
  }

  func testGoWritesBothSidecarsThenPastesOnceAndClearsTheMarks() throws {
    let fixture = try EditorFixture(Self.draft, opener: "block:claude")
    let host = fixture.host
    let review = ReviewStore(draft: fixture.file)
    let seen = Recorder<String>()
    fixture.runner.onCall = { arguments in
      guard ["capture", "send"].contains(arguments.first) else { return }
      let files = [review.passEditsFile(1), review.editsFile, review.logFile]
      let written = files.filter { FileManager.default.fileExists(atPath: $0.path) }.count
      let log = (try? String(contentsOf: review.logFile, encoding: .utf8)) ?? ""
      let submitted = log.split(separator: "\n").count > 1
      seen.add("\(arguments[0]) with \(written == files.count && submitted ? "the pass written" : "no pass written")")
    }
    try agentPane("idle-placeholder", fixture: fixture)

    connectAgent(host)
    type("m", into: host)
    XCTAssertTrue(host.interaction.review.isOn)
    XCTAssertEqual(try logRecords(review).map { $0["event"] as? String }, ["launch"])
    try mark("quick", key: "1", in: host)
    try mark("second", key: "3", in: host)
    XCTAssertEqual(host.source.overlay.annotations.count, 2, "the marks are painted")
    type("s", into: host)

    let sends = fixture.runner.rexCalls.filter { $0.first == "send" }
    XCTAssertEqual(sends.count, 1)
    XCTAssertEqual(
      seen.values, ["capture with no pass written", "send with the pass written", "capture with the pass written"])
    XCTAssertEqual(
      paneCalls(fixture), ["capture", "send", "capture", "send-key Enter"],
      "Enter only once the paste shows, and not focused")
    let captures = fixture.runner.rexCalls.filter { $0.first == "capture" }
    let capture = ["capture", "-b", "block:claude", "-s", EditorFixture.session, "--format", "vt", "--trim"]
    XCTAssertEqual(captures, [capture, capture])
    let enter = try XCTUnwrap(fixture.runner.rexCalls.first { $0.first == "send-key" })
    XCTAssertEqual(enter, ["send-key", "-b", "block:claude", "-s", EditorFixture.session, "Enter"])
    XCTAssertEqual(sends.first?[2], "block:claude")
    XCTAssertTrue(sends.first?.last?.contains("Review pass 1 on @\(review.draft.path): apply") == true)
    XCTAssertTrue(
      sends.first?.last?.contains("apply \(review.passEditsFile(1).path). Run `termdown agent-guide review` for how.")
        == true)
    XCTAssertFalse(sends.first?.last?.hasSuffix("\r") == true, "Enter is its own key, not part of the paste")

    XCTAssertEqual(try Data(contentsOf: review.editsFile), try Data(contentsOf: review.passEditsFile(1)))
    let edits = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: review.passEditsFile(1))) as? [String: Any])
    XCTAssertEqual(edits["action"] as? String, "finish", "every pass stands alone")
    XCTAssertEqual(edits["draft"] as? String, review.draft.path)
    let annotations = try XCTUnwrap(edits["annotations"] as? [[String: Any]])
    XCTAssertEqual(annotations.map { $0["type"] as? String }, ["delete", "cringe"])
    XCTAssertEqual(annotations.map { $0["text"] as? String }, ["quick", "second"])
    XCTAssertEqual(annotations.first?["line"] as? Int, 3)
    XCTAssertEqual(annotations.first?["col_from"] as? Int, 4)
    XCTAssertTrue(edits["manual_edits"] is NSNull)

    let records = try logRecords(review)
    XCTAssertEqual(records.count, 2)
    XCTAssertEqual(records[1]["pass"] as? Int, 1)
    XCTAssertEqual(records[1]["action"] as? String, "finish")
    XCTAssertEqual((records[1]["about"] as? [String: Any])?["pass"] as? Int, 1)

    XCTAssertTrue(host.interaction.review.marks.isEmpty)
    XCTAssertFalse(host.interaction.review.isOn, "a sent pass ends review")
    XCTAssertFalse(FileManager.default.fileExists(atPath: review.lockFile.path), "and lets go of the lock")
    XCTAssertEqual(host.interaction.review.snapshot, Self.draft)
    XCTAssertTrue(host.source.overlay.annotations.isEmpty)
    XCTAssertEqual(fixture.status, "Pass 1 sent to claude")
  }

  func testTheNextReviewIsPassTwoAndDoesNotCountTheAgentsChangeAsAHandEdit() throws {
    let fixture = try EditorFixture(Self.draft, opener: "block:claude")
    let host = fixture.host
    let review = ReviewStore(draft: fixture.file)
    try agentPane("idle-after-turn", fixture: fixture)
    connectAgent(host)
    type("m", into: host)
    try mark("quick", key: "1", in: host)
    type("s", into: host)

    let applied = Self.draft.replacingOccurrences(of: "quick ", with: "")
    try Data(applied.utf8).write(to: fixture.file)
    host.fileChanged()
    type("m", into: host)
    XCTAssertEqual(host.interaction.review.pass, 1, "numbering carries on from the log")
    try mark("brown", key: "4", in: host)
    type("M", into: host)
    XCTAssertEqual(host.interaction.marksList?.pass, 2)
    type("M", into: host)
    type("s", into: host)

    let records = try logRecords(review)
    XCTAssertEqual(records.compactMap { $0["pass"] as? Int }, [0, 1, 0, 2])
    XCTAssertTrue(records[3]["manual_edit_diff"] is NSNull, "the change on disk since pass 1 is not a hand edit")
    XCTAssertEqual(records[3]["draft_snapshot"] as? String, applied)
    let second = fixture.runner.rexCalls.last { $0.first == "send" }?.last
    XCTAssertTrue(second?.contains("Review pass 2") == true)
    XCTAssertTrue(second?.contains(review.passEditsFile(2).path) == true)
    XCTAssertTrue(FileManager.default.fileExists(atPath: review.passEditsFile(1).path), "pass 1 is kept")
  }

  /// The B16 loop on a real draft: two marks and Go, then waits for the agent's change on disk, then a second Go.
  func testLiveDraftTwoPasses() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let path = environment["TERMDOWN_REVIEW_LIVE_DRAFT"], let home = environment["TERMDOWN_REVIEW_LIVE_STORE"]
    else { throw XCTSkip("set TERMDOWN_REVIEW_LIVE_DRAFT and TERMDOWN_REVIEW_LIVE_STORE to run the live loop") }
    setenv("TERMDOWN_REVIEW_HOME", home, 1)
    let draft = URL(fileURLWithPath: path)
    let fixture = try EditorFixture(opener: "block:claude")
    let host = fixture.host
    host.open(draft)
    spin(until: { host.interaction.layout?.prepared.text.range(of: "25 years").location ?? NSNotFound != NSNotFound })
    let review = ReviewStore(draft: draft)
    try agentPane("idle-after-turn", fixture: fixture)

    connectAgent(host)
    type("m", into: host)
    try mark(" in some cases", key: "1", in: host)
    try mark("for the first time in 25 years", key: "3", in: host)
    print("live: pass 1 marks \(host.interaction.review.marks.marks.map { "\($0.type) \($0.range)" })")
    type("s", into: host)
    print("live: status \(fixture.status ?? "")")
    print("live: edits \(review.editsFile.path)")
    print("live: paste \(fixture.runner.rexCalls.filter { $0.first == "send" }.last ?? [])")

    let before = host.interaction.source
    spin(until: { (try? String(contentsOf: draft, encoding: .utf8)) != before }, timeout: 120)
    host.fileChanged()
    XCTAssertNotEqual(host.interaction.source, before, "the agent's change reached the viewer")

    type("m", into: host)
    try mark("We raised the floor for every engineer and tester through training", key: "4", in: host)
    type("s", into: host)
    print("live: status \(fixture.status ?? "")")
    print("live: paste \(fixture.runner.rexCalls.filter { $0.first == "send" }.last ?? [])")
    XCTAssertEqual(try logRecords(review).compactMap { $0["pass"] as? Int }, [0, 1, 0, 2])
  }

  func testAPassToAnAgentStillWorkingIsQueuedAndEndsReview() throws {
    let fixture = try EditorFixture(Self.draft, opener: "block:claude")
    let host = fixture.host
    let review = ReviewStore(draft: fixture.file)
    try agentPane("mid-turn", fixture: fixture)
    connectAgent(host)
    type("m", into: host)
    try mark("quick", key: "2", in: host)
    type("s", into: host)

    XCTAssertEqual(paneCalls(fixture), ["capture", "send", "capture", "send-key Enter"])
    let edits = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: review.passEditsFile(1))) as? [String: Any])
    XCTAssertEqual(edits["action"] as? String, "finish")
    let sent = fixture.runner.rexCalls.first { $0.first == "send" }?.last
    XCTAssertEqual(
      sent,
      AgentPrompt.paste(
        AgentPrompt.review(
          draft: review.draft.path, edits: review.passEditsFile(1).path, pass: 1)))
    XCTAssertFalse(host.interaction.review.isOn)
    XCTAssertTrue(host.interaction.review.marks.isEmpty)
    XCTAssertTrue(fixture.hostFixture.pasteboard.writes.isEmpty)
    XCTAssertEqual(fixture.status, "Pass 1 sent to claude")
  }

  /// A pane whose prompt holds text, or shows a dialog, gets nothing: no files, no log record, no paste, no Enter.
  func testBusyPaneWritesNothing() throws {
    for state in ["typed", "dialog"] {
      let fixture = try EditorFixture(Self.draft, opener: "block:claude")
      let host = fixture.host
      let review = ReviewStore(draft: fixture.file)
      try agentPane(state, fixture: fixture)
      connectAgent(host)
      type("m", into: host)
      try mark("quick", key: "1", in: host)
      type("s", into: host)

      XCTAssertEqual(paneCalls(fixture), ["capture"], state)
      XCTAssertFalse(FileManager.default.fileExists(atPath: review.editsFile.path), state)
      XCTAssertFalse(FileManager.default.fileExists(atPath: review.passEditsFile(1).path), state)
      XCTAssertEqual(try logRecords(review).map { $0["event"] as? String }, ["launch"], "no submit record: \(state)")
      XCTAssertEqual(host.interaction.review.marks.count, 1, state)
      XCTAssertTrue(host.interaction.review.isOn, state)
      XCTAssertTrue(fixture.hostFixture.pasteboard.writes.isEmpty, state)
      XCTAssertEqual(fixture.status, "Agent is busy or has unsent text: finish there, then press s again", state)
      try FileManager.default.removeItem(at: review.directory)
    }
  }

  func testAPaneRexCannotCaptureIsBusy() throws {
    let fixture = try EditorFixture(Self.draft, opener: "block:claude")
    let host = fixture.host
    let review = ReviewStore(draft: fixture.file)
    fixture.runner.reply(to: "capture", (1, Data(), Data("no such block".utf8)))
    connectAgent(host)
    type("m", into: host)
    try mark("quick", key: "1", in: host)
    type("s", into: host)

    XCTAssertEqual(paneCalls(fixture), ["capture"])
    XCTAssertFalse(FileManager.default.fileExists(atPath: review.editsFile.path))
    XCTAssertTrue(host.interaction.review.isOn, "a refused send keeps review on")
    XCTAssertEqual(host.interaction.review.marks.count, 1)
    XCTAssertEqual(fixture.status, "Agent is busy or has unsent text: finish there, then press s again")
  }

  /// Enter failed: the handoff sits in the agent's prompt. The pass was written, so it counts as submitted.
  func testEnterFailingLeavesThePassPasted() throws {
    let fixture = try EditorFixture(Self.draft, opener: "block:claude")
    let host = fixture.host
    let review = ReviewStore(draft: fixture.file)
    try agentPane("idle-placeholder", fixture: fixture)
    fixture.runner.reply(to: "send-key", (1, Data(), Data("no such key".utf8)))
    connectAgent(host)
    type("m", into: host)
    try mark("quick", key: "1", in: host)
    type("s", into: host)

    XCTAssertEqual(paneCalls(fixture), ["capture", "send", "capture", "send-key Enter"])
    XCTAssertTrue(FileManager.default.fileExists(atPath: review.passEditsFile(1).path))
    XCTAssertTrue(host.interaction.review.marks.isEmpty)
    XCTAssertEqual(host.interaction.review.pass, 1)
    XCTAssertEqual(fixture.status, "Pass 1 written but not submitted: check the agent's pane")
    XCTAssertEqual(host.interaction.status.message?.kind, .info)
  }

  /// The paste never showed in the prompt box, so Enter is not pressed: it could land on something else.
  func testAPasteThatNeverShowsIsNotEntered() throws {
    let fixture = try EditorFixture(Self.draft, opener: "block:claude")
    let host = fixture.host
    try agentPane("idle-placeholder", thenAfterPaste: nil, fixture: fixture)
    connectAgent(host)
    type("m", into: host)
    try mark("quick", key: "1", in: host)
    type("s", into: host)

    let calls = paneCalls(fixture)
    XCTAssertEqual(Array(calls.prefix(2)), ["capture", "send"])
    XCTAssertGreaterThan(calls.count, 3, "the pane is captured again a few times")
    XCTAssertEqual(Set(calls.dropFirst(2)), ["capture"], "no Enter")
    XCTAssertTrue(host.interaction.review.marks.isEmpty)
    XCTAssertEqual(fixture.status, "Pass 1 written but not submitted: check the agent's pane")
  }

  /// A paste that turns into a dialog is not the paste: Enter would answer the dialog, and the bar must not tell the
  /// person to press it either. The permission capture is a live one: Claude Code ignored the paste sent to it.
  func testADialogAfterThePasteIsNotEntered() throws {
    for dialog in ["dialog", "permission-after-paste"] {
      let fixture = try EditorFixture(Self.draft, opener: "block:claude")
      let host = fixture.host
      try agentPane("idle-placeholder", thenAfterPaste: dialog, fixture: fixture)
      connectAgent(host)
      type("m", into: host)
      try mark("quick", key: "1", in: host)
      type("s", into: host)

      XCTAssertFalse(paneCalls(fixture).contains("send-key Enter"), dialog)
      XCTAssertEqual(fixture.status, "Pass 1 written but not submitted: a dialog is open in the agent's pane", dialog)
      XCTAssertTrue(host.interaction.review.marks.isEmpty, "the pass was written: \(dialog)")
      try FileManager.default.removeItem(at: ReviewStore(draft: fixture.file).directory)
    }
  }

  /// After the paste the pane cannot be read: it may be a dialog, so it is treated as one.
  func testAnUnreadablePaneAfterThePasteIsNotEntered() throws {
    let fixture = try EditorFixture(Self.draft, opener: "block:claude")
    let host = fixture.host
    try paneShows("idle-placeholder", fixture: fixture)
    let runner = fixture.runner
    runner.onCall = { arguments in
      if arguments.first == "send" { runner.reply(to: "capture", (0, Data("\u{1b}[2J?".utf8), Data())) }
    }
    connectAgent(host)
    type("m", into: host)
    try mark("quick", key: "1", in: host)
    type("s", into: host)

    XCTAssertFalse(paneCalls(fixture).contains("send-key Enter"))
    XCTAssertEqual(fixture.status, "Pass 1 written but not submitted: a dialog is open in the agent's pane")
  }

  /// A permission dialog before the paste is busy: nothing is written and nothing is sent.
  func testAPermissionDialogRefusesThePass() throws {
    let fixture = try EditorFixture(Self.draft, opener: "block:claude")
    let host = fixture.host
    let review = ReviewStore(draft: fixture.file)
    try agentPane("permission", fixture: fixture)
    connectAgent(host)
    type("m", into: host)
    try mark("quick", key: "1", in: host)
    type("s", into: host)

    XCTAssertEqual(paneCalls(fixture), ["capture"])
    XCTAssertFalse(exists(review.passEditsFile(1)))
    XCTAssertEqual(fixture.status, "Agent is busy or has unsent text: finish there, then press s again")
  }

  /// Rex could not deliver the paste after the pass was written: say so, keep the marks, and do not blame the agent.
  func testSendFailingKeepsTheMarksAndSaysThePassIsSaved() throws {
    let fixture = try EditorFixture(Self.draft, opener: "block:claude")
    let host = fixture.host
    let review = ReviewStore(draft: fixture.file)
    try agentPane("idle-placeholder", fixture: fixture)
    fixture.runner.reply(to: "send", (1, Data(), Data("no such block".utf8)))
    connectAgent(host)
    type("m", into: host)
    try mark("quick", key: "1", in: host)
    type("s", into: host)

    XCTAssertEqual(paneCalls(fixture), ["capture", "send"])
    XCTAssertTrue(FileManager.default.fileExists(atPath: review.passEditsFile(1).path))
    XCTAssertEqual(host.interaction.review.marks.count, 1)
    XCTAssertTrue(fixture.hostFixture.pasteboard.writes.isEmpty)
    XCTAssertEqual(fixture.status, "Could not reach the agent's pane: pass 1 is saved, press s to resend")
  }

  /// Review Focus 2: the session dropped mid-review. The marks wait for a reconnect; nothing goes to the clipboard.
  func testNoAgentWhileReviewingHasNoClipboardFallback() throws {
    let fixture = try EditorFixture(Self.draft, opener: "block:claude")
    let host = fixture.host
    let review = ReviewStore(draft: fixture.file)
    try agentPane("idle-placeholder", fixture: fixture)
    connectAgent(host)
    type("m", into: host)
    try mark("quick", key: "1", in: host)
    host.perform(host.interaction.setReviewAgent(ReviewAgentStatus(connected: 0, title: nil, chosen: false), at: 0))
    type("s", into: host)

    XCTAssertTrue(paneCalls(fixture).isEmpty)
    XCTAssertTrue(fixture.hostFixture.pasteboard.writes.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: review.editsFile.path))
    XCTAssertEqual(host.interaction.review.marks.count, 1)
    XCTAssertEqual(
      fixture.status,
      "No agent connected: run /ide in a Claude session and pick this preview, or press A to start one beside it.")
  }

  /// Connected, but the host has no agent pane to send to: still no clipboard while reviewing.
  func testNoAgentPaneWhileReviewingHasNoClipboardFallback() throws {
    let fixture = try EditorFixture(Self.draft)
    let host = fixture.host
    let review = ReviewStore(draft: fixture.file)
    reportChosenAgent(host)
    type("m", into: host)
    try mark("quick", key: "1", in: host)
    type("s", into: host)

    XCTAssertTrue(paneCalls(fixture).isEmpty)
    XCTAssertTrue(fixture.hostFixture.pasteboard.writes.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: review.editsFile.path))
    XCTAssertTrue(host.interaction.review.isOn)
    XCTAssertEqual(host.interaction.review.marks.count, 1)
    XCTAssertEqual(
      fixture.status,
      "No agent connected: run /ide in a Claude session and pick this preview, or press A to start one beside it.")
  }

  /// "All connected agents" picked with `A` mid-review is no choice: the pass waits for one agent.
  func testAllAgentsMidReviewAsksForOneAgent() throws {
    let fixture = try EditorFixture(Self.draft, opener: "block:claude")
    let host = fixture.host
    let review = ReviewStore(draft: fixture.file)
    try agentPane("idle-placeholder", fixture: fixture)
    connectAgent(host)
    type("m", into: host)
    try mark("quick", key: "1", in: host)
    host.perform(host.interaction.setReviewAgent(ReviewAgentStatus(connected: 2, title: nil, chosen: false), at: 0))
    type("s", into: host)

    XCTAssertTrue(paneCalls(fixture).isEmpty)
    XCTAssertTrue(fixture.hostFixture.pasteboard.writes.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: review.editsFile.path))
    XCTAssertEqual(host.interaction.review.marks.count, 1)
    XCTAssertEqual(fixture.status, "Choose one agent for the review: press A")
  }

  func testAgentsChangedFeedsTheInteraction() throws {
    let fixture = try EditorFixture(Self.draft)
    let host = fixture.host
    let ide = IDEBridge(workspaceFolders: [], file: fixture.file)
    host.ide = ide
    titleReply("block:claude", "claude", fixture: fixture)
    XCTAssertEqual(host.interaction.reviewAgent, ReviewAgentStatus(connected: 0, title: nil, chosen: false))

    ide.standIns = [ConnectedAgent(id: 1, pid: 10, block: "block:claude")]
    host.agentsChanged()
    spin(until: { host.interaction.reviewAgent.connected == 1 })
    XCTAssertEqual(host.interaction.reviewAgent, ReviewAgentStatus(connected: 1, title: "claude", chosen: true))

    ide.standIns = []
    host.agentsChanged()
    spin(until: { host.interaction.reviewAgent.connected == 0 })
    XCTAssertEqual(host.interaction.reviewAgent, ReviewAgentStatus(connected: 0, title: nil, chosen: false))
  }

  func testMWithTwoAgentsOpensTheReviewPickerAndAChoiceStartsReview() throws {
    let fixture = try EditorFixture(Self.draft)
    let host = fixture.host
    let ide = IDEBridge(workspaceFolders: [], file: fixture.file, pairing: .ask)
    host.ide = ide
    titleReply("block:one", "one", fixture: fixture)
    titleReply("block:two", "two", fixture: fixture)
    ide.standIns = [ConnectedAgent(id: 1, block: "block:one"), ConnectedAgent(id: 2, block: "block:two")]
    host.agentsChanged()
    spin(until: { host.interaction.agentPicker != nil })
    type("\u{1b}", into: host)
    spin(0.05)
    XCTAssertNil(host.interaction.agentPicker)
    XCTAssertEqual(host.interaction.reviewAgent, ReviewAgentStatus(connected: 2, title: nil, chosen: false))

    type("m", into: host)
    spin(until: { host.interaction.agentPicker != nil })
    XCTAssertEqual(host.interaction.agentPicker?.title, "Send the review to")
    XCTAssertEqual(host.interaction.agentPicker?.rows.map(\.action), [.agent(1), .agent(2), .startNew])
    XCTAssertFalse(host.interaction.review.isOn)

    type("2", into: host)
    XCTAssertTrue(host.interaction.review.isOn)
    spin(until: { host.interaction.reviewAgent.chosen })
    XCTAssertEqual(host.interaction.reviewAgent, ReviewAgentStatus(connected: 2, title: "two", chosen: true))
    XCTAssertEqual(ide.askTarget, "block:two")
  }

  /// Choosing "Start a new agent" in the review picker is a promise of a review: it starts when that agent connects.
  func testStartingANewAgentFromTheReviewPickerStartsReviewWhenItConnects() throws {
    let config = FileManager.default.temporaryDirectory.appendingPathComponent("ide-\(UUID().uuidString)")
    setenv("CLAUDE_CONFIG_DIR", config.path, 1)
    defer {
      unsetenv("CLAUDE_CONFIG_DIR")
      try? FileManager.default.removeItem(at: config)
    }
    let fixture = try EditorFixture(Self.draft)
    let host = fixture.host
    let ide = IDEBridge(workspaceFolders: [], file: fixture.file, pairing: .ask)
    ide.start()
    defer { ide.stop() }
    spin(until: { ide.port != nil })
    XCTAssertNotNil(ide.port)
    host.ide = ide
    titleReply("block:one", "one", fixture: fixture)
    titleReply("block:two", "two", fixture: fixture)
    fixture.runner.reply(to: "split", (0, Data("block:new\n".utf8), Data()))
    ide.standIns = [ConnectedAgent(id: 1, block: "block:one"), ConnectedAgent(id: 2, block: "block:two")]
    host.agentsChanged()
    spin(until: { host.interaction.agentPicker != nil })
    type("\u{1b}", into: host)
    spin(0.05)

    type("m", into: host)
    spin(until: { host.interaction.agentPicker != nil })
    XCTAssertEqual(host.interaction.agentPicker?.rows.map(\.action), [.agent(1), .agent(2), .startNew])
    XCTAssertFalse(host.interaction.reviewPending)
    type("3", into: host)
    spin(until: { host.interaction.reviewPending })
    XCTAssertTrue(host.interaction.reviewPending)
    XCTAssertFalse(host.interaction.review.isOn)
    XCTAssertEqual(host.pendingAgentPane, "block:new")

    titleReply("block:new", "new", fixture: fixture)
    ide.standIns.append(ConnectedAgent(id: 3, block: "block:new"))
    host.agentsChanged()
    spin(until: { host.interaction.review.isOn })
    XCTAssertTrue(host.interaction.review.isOn)
    XCTAssertFalse(host.interaction.reviewPending)
    spin(until: { host.interaction.reviewAgent.chosen })
    XCTAssertEqual(host.interaction.reviewAgent, ReviewAgentStatus(connected: 3, title: "new", chosen: true))
    XCTAssertEqual(ide.askTarget, "block:new")
  }

  func testAReviewRequestShowsTheFileAndStartsReviewOnceAnAgentIsConnected() throws {
    let fixture = try EditorFixture(Self.draft, files: ["other.md": "# Other\n\nBody text.\n"])
    let host = fixture.host
    let other = fixture.hostFixture.directory.url.appendingPathComponent("other.md")
    host.review(other)
    XCTAssertEqual(host.interaction.file?.lastPathComponent, "other.md")
    XCTAssertFalse(host.interaction.review.isOn)
    XCTAssertTrue(host.interaction.reviewPending)
    XCTAssertEqual(
      fixture.status,
      "No agent connected: run /ide in a Claude session and pick this preview, or press A to start one beside it.")

    connectAgent(host)
    XCTAssertTrue(host.interaction.review.isOn)
    XCTAssertEqual(host.reviewSession?.store.draft.lastPathComponent, "other.md")
  }

  func testAReviewRequestWhileReviewIsOnChangesNothing() throws {
    let fixture = try EditorFixture(Self.draft)
    let host = fixture.host
    connectAgent(host)
    type("m", into: host)
    try mark("quick", key: "1", in: host)
    host.review(fixture.file)
    XCTAssertEqual(fixture.status, "Review is already on")
    XCTAssertEqual(host.interaction.review.marks.count, 1)
    XCTAssertTrue(host.interaction.review.isOn)
  }

  /// The picker was invisible: the host never copied it onto the frame source the painter draws.
  func testTheAgentPickerReachesTheFrameSource() throws {
    let fixture = try EditorFixture(Self.draft)
    let host = fixture.host
    let ide = IDEBridge(workspaceFolders: [], file: fixture.file, pairing: .ask)
    host.ide = ide
    titleReply("block:one", "one", fixture: fixture)
    titleReply("block:two", "two", fixture: fixture)
    ide.standIns = [ConnectedAgent(id: 1, block: "block:one"), ConnectedAgent(id: 2, block: "block:two")]
    XCTAssertNil(host.source.agentPicker)
    type("A", into: host)
    spin(until: { host.interaction.agentPicker != nil })
    XCTAssertNotNil(host.interaction.agentPicker)
    XCTAssertEqual(host.source.agentPicker, host.interaction.agentPicker)
    type("\u{1b}", into: host)
    spin(0.05)
    XCTAssertNil(host.source.agentPicker)
  }

  // MARK: Which pane a review reaches

  /// One agent connected from outside Rex, and an opener pane that is some other session: the plug shows, `m` says
  /// why review cannot start, and no pass is ever pasted or entered in the opener. `a` still pastes there.
  func testAnAgentOutsideRexNeverSendsTheReviewToTheOpener() throws {
    let fixture = try EditorFixture(Self.draft, opener: "block:claude")
    let host = fixture.host
    let ide = IDEBridge(workspaceFolders: [], file: fixture.file, rex: .init(opener: "block:claude"))
    host.ide = ide
    try agentPane("idle-placeholder", fixture: fixture)
    ide.standIns = [ConnectedAgent(id: 1, pid: 10)]
    host.agentsChanged()
    spin(until: { host.interaction.reviewAgent.connected == 1 })
    XCTAssertEqual(
      host.interaction.reviewAgent, ReviewAgentStatus(connected: 1, title: nil, chosen: false, outsideRex: true))
    XCTAssertNil(ide.reviewTarget)
    XCTAssertEqual(ide.askTarget, "block:claude", "ask keeps its opener fallback")

    type("m", into: host)
    XCTAssertFalse(host.interaction.review.isOn)
    XCTAssertNil(host.interaction.agentPicker)
    XCTAssertEqual(fixture.status, "The connected agent is outside Rex: reviews need an agent in a Rex pane")

    // Even with the interaction told otherwise, the host has no review target and sends nothing.
    reportChosenAgent(host)
    type("m", into: host)
    XCTAssertTrue(host.interaction.review.isOn)
    try mark("quick", key: "1", in: host)
    type("s", into: host)
    XCTAssertEqual(paneCalls(fixture), [])
    XCTAssertFalse(exists(ReviewStore(draft: fixture.file).passEditsFile(1)))
    XCTAssertEqual(host.interaction.review.marks.count, 1)
    XCTAssertEqual(
      fixture.status,
      "No agent connected: run /ide in a Claude session and pick this preview, or press A to start one beside it.")
  }

  /// Picking an agent outside Rex in the review picker does not start a review it could never send.
  func testPickingAnAgentOutsideRexForReviewSaysWhy() throws {
    let fixture = try EditorFixture(Self.draft)
    let host = fixture.host
    let ide = IDEBridge(workspaceFolders: [], file: fixture.file, pairing: .ask)
    host.ide = ide
    titleReply("block:one", "one", fixture: fixture)
    ide.standIns = [ConnectedAgent(id: 1, block: "block:one"), ConnectedAgent(id: 2, pid: 20)]
    host.agentsChanged()
    spin(until: { host.interaction.agentPicker != nil })
    type("\u{1b}", into: host)
    spin(0.05)

    type("m", into: host)
    spin(until: { host.interaction.agentPicker != nil })
    type("2", into: host)
    XCTAssertFalse(host.interaction.review.isOn)
    XCTAssertEqual(fixture.status, "The connected agent is outside Rex: reviews need an agent in a Rex pane")
    XCTAssertEqual(
      host.interaction.reviewAgent, ReviewAgentStatus(connected: 2, title: nil, chosen: false, outsideRex: true))
  }

  /// The send path itself: with no target it never falls back to the opener, writes nothing and touches no pane.
  func testTheReviewSendNeverTargetsTheOpener() throws {
    let fixture = try EditorFixture(Self.draft, opener: "block:claude")
    try paneShows("idle-placeholder", fixture: fixture)
    var prompted = false
    let result = fixture.coordinator.sendReview(
      prompt: {
        prompted = true
        return "pass"
      }, target: nil)
    XCTAssertEqual(result, .noAgent)
    XCTAssertFalse(prompted)
    XCTAssertEqual(paneCalls(fixture), [])
  }

  /// The last agent left while a describe for it was still out: that late answer must not bring back a connected,
  /// chosen status.
  func testALateDescribeDoesNotUndoADisconnect() throws {
    let fixture = try EditorFixture(Self.draft)
    let host = fixture.host
    let ide = IDEBridge(workspaceFolders: [], file: fixture.file)
    host.ide = ide
    let gate = DispatchSemaphore(value: 0)
    let asked = DispatchSemaphore(value: 0)
    fixture.runner.onCall = { arguments in
      guard arguments.first == "do" else { return }
      asked.signal()
      gate.wait()
    }
    ide.standIns = [ConnectedAgent(id: 1, pid: 10, block: "block:claude")]
    host.agentsChanged()
    XCTAssertEqual(asked.wait(timeout: .now() + 5), .success, "the describe is out")

    ide.standIns = []
    host.agentsChanged()
    XCTAssertEqual(host.interaction.reviewAgent, ReviewAgentStatus(connected: 0, title: nil, chosen: false))
    gate.signal()
    fixture.waitIdle()
    spin(0.1)
    XCTAssertEqual(host.interaction.reviewAgent, ReviewAgentStatus(connected: 0, title: nil, chosen: false))
  }

  /// Review started with the only agent, not picked: it is pinned, so a second agent connecting mid-review neither
  /// turns the target into no choice nor opens the picker.
  func testTheReviewTargetIsPinnedWhenReviewStarts() throws {
    let fixture = try EditorFixture(Self.draft)
    let host = fixture.host
    let ide = IDEBridge(workspaceFolders: [], file: fixture.file, pairing: .ask)
    host.ide = ide
    titleReply("block:one", "one", fixture: fixture)
    titleReply("block:two", "two", fixture: fixture)
    ide.standIns = [ConnectedAgent(id: 1, block: "block:one")]
    host.agentsChanged()
    spin(until: { host.interaction.reviewAgent.chosen })
    XCTAssertNil(ide.agentState().choice)
    type("m", into: host)
    XCTAssertTrue(host.interaction.review.isOn)

    ide.standIns.append(ConnectedAgent(id: 2, block: "block:two"))
    host.agentsChanged()
    spin(until: { host.interaction.reviewAgent.connected == 2 })
    spin(0.05)
    XCTAssertEqual(host.interaction.reviewAgent, ReviewAgentStatus(connected: 2, title: "one", chosen: true))
    XCTAssertNil(host.interaction.agentPicker)
    XCTAssertEqual(ide.reviewTarget, "block:one")
    XCTAssertEqual(ide.agentState().choice, .agent(1))
  }

  // MARK: Keeping marks safe

  /// A second viewer on the same draft, the way a restarted `termdown` would be: another host, the same file.
  func restarted(on file: URL, text: String? = nil) throws -> EditorFixture {
    let fixture = try EditorFixture(Self.draft, opener: "block:claude")
    fixture.host.open(file)
    let wanted = try XCTUnwrap(text ?? (try String(contentsOf: file, encoding: .utf8)))
    spin(until: { fixture.host.interaction.source == wanted && fixture.host.interaction.layout != nil })
    XCTAssertEqual(fixture.host.interaction.file?.lastPathComponent, file.lastPathComponent)
    return fixture
  }

  func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

  func testMarksSurviveAViewerRestart() throws {
    var first: EditorFixture? = try EditorFixture(Self.draft, opener: "block:claude")
    let file = try XCTUnwrap(first?.file)
    let directory = try XCTUnwrap(first?.hostFixture.directory)  // outlives the first viewer, as the file does
    defer { withExtendedLifetime(directory) {} }
    let review = ReviewStore(draft: file)
    let host = try XCTUnwrap(first?.host)
    connectAgent(host)
    type("m", into: host)
    try mark("quick", key: "1", in: host)
    try mark("second", key: "3", in: host)
    let marked = host.interaction.review.marks.marks
    XCTAssertEqual(marked.count, 2)
    XCTAssertTrue(exists(review.marksFile), "saved as soon as the marks change")
    first = nil

    let again = try restarted(on: file)
    connectAgent(again.host)
    XCTAssertTrue(again.host.interaction.review.marks.isEmpty, "nothing comes back until review starts")
    type("m", into: again.host)
    XCTAssertTrue(again.host.interaction.review.isOn)
    XCTAssertEqual(again.host.interaction.review.marks.marks, marked)
    XCTAssertEqual(again.host.source.overlay.annotations.count, 2, "the restored marks are painted")
    XCTAssertEqual(again.status, "Restored 2 marks from your last review")
  }

  func testRestoredMarksFollowTheTextThatMovedWhileTheViewerWasAway() throws {
    var first: EditorFixture? = try EditorFixture(Self.draft, opener: "block:claude")
    let file = try XCTUnwrap(first?.file)
    let directory = try XCTUnwrap(first?.hostFixture.directory)  // outlives the first viewer, as the file does
    defer { withExtendedLifetime(directory) {} }
    let host = try XCTUnwrap(first?.host)
    connectAgent(host)
    type("m", into: host)
    try mark("second", key: "3", in: host)
    first = nil

    let edited = "Intro added by the agent.\n\n" + Self.draft
    try Data(edited.utf8).write(to: file)
    let again = try restarted(on: file, text: edited)
    connectAgent(again.host)
    type("m", into: again.host)
    let annotations = again.host.interaction.review.marks.annotations(in: Array(edited.utf8))
    XCTAssertEqual(annotations.map(\.text), ["second"])
    XCTAssertEqual(annotations.first?.line, 7)
  }

  func testMarksWhosePassageIsGoneAreDroppedAndTheSavedFileWithThem() throws {
    var first: EditorFixture? = try EditorFixture(Self.draft, opener: "block:claude")
    let file = try XCTUnwrap(first?.file)
    let directory = try XCTUnwrap(first?.hostFixture.directory)  // outlives the first viewer, as the file does
    defer { withExtendedLifetime(directory) {} }
    let review = ReviewStore(draft: file)
    let host = try XCTUnwrap(first?.host)
    connectAgent(host)
    type("m", into: host)
    try mark("quick", key: "1", in: host)
    XCTAssertTrue(exists(review.marksFile))
    first = nil

    let edited = Self.draft.replacingOccurrences(of: "The quick brown fox jumps.", with: "Gone.")
    try Data(edited.utf8).write(to: file)
    let again = try restarted(on: file, text: edited)
    connectAgent(again.host)
    type("m", into: again.host)
    XCTAssertTrue(again.host.interaction.review.isOn)
    XCTAssertTrue(again.host.interaction.review.marks.isEmpty)
    XCTAssertFalse(exists(review.marksFile))
  }

  func testASecondViewerCannotReviewTheSameFile() throws {
    let fixture = try EditorFixture(Self.draft, opener: "block:claude")
    let host = fixture.host
    let review = ReviewStore(draft: fixture.file)
    XCTAssertTrue(review.acquireLock(pid: getppid()), "another live viewer holds the draft")
    connectAgent(host)
    type("m", into: host)

    XCTAssertFalse(host.interaction.review.isOn)
    XCTAssertEqual(fixture.status, "Review is already running for this file in another preview")
    XCTAssertFalse(exists(review.logFile), "no launch record")
    XCTAssertEqual(
      try String(contentsOf: review.lockFile, encoding: .utf8).trimmingCharacters(in: .newlines), "\(getppid())")
    type("1", into: host)
    XCTAssertTrue(host.interaction.review.marks.isEmpty)

    review.releaseLock()
    type("m", into: host)
    XCTAssertTrue(host.interaction.review.isOn)
    XCTAssertEqual(try logRecords(review).map { $0["event"] as? String }, ["launch"])
  }

  func testALockLeftByADeadViewerDoesNotBlockReview() throws {
    let fixture = try EditorFixture(Self.draft, opener: "block:claude")
    let review = ReviewStore(draft: fixture.file)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try process.run()
    process.waitUntilExit()
    XCTAssertTrue(review.acquireLock(pid: process.processIdentifier))
    connectAgent(fixture.host)
    type("m", into: fixture.host)
    XCTAssertTrue(fixture.host.interaction.review.isOn)
  }

  func testSendingClearsTheSavedMarksAndReleasesTheLock() throws {
    let fixture = try EditorFixture(Self.draft, opener: "block:claude")
    let host = fixture.host
    let review = ReviewStore(draft: fixture.file)
    try agentPane("idle-after-turn", fixture: fixture)
    connectAgent(host)
    type("m", into: host)
    XCTAssertTrue(exists(review.lockFile))
    try mark("quick", key: "1", in: host)
    XCTAssertTrue(exists(review.marksFile))
    type("s", into: host)
    XCTAssertFalse(exists(review.marksFile), "sent: nothing left to keep")
    XCTAssertFalse(exists(review.lockFile), "the pass ends review")
    XCTAssertFalse(host.interaction.review.isOn)

    type("m", into: host)
    XCTAssertTrue(exists(review.lockFile), "the next pass takes the lock again")
  }

  func testAPastedPassCountsAsSentAndARefusedOneKeepsTheSavedMarks() throws {
    let refused = try EditorFixture(Self.draft, opener: "block:claude")
    let store = ReviewStore(draft: refused.file)
    try agentPane("typed", fixture: refused)
    connectAgent(refused.host)
    type("m", into: refused.host)
    try mark("quick", key: "1", in: refused.host)
    type("s", into: refused.host)
    XCTAssertEqual(refused.host.interaction.review.marks.count, 1)
    XCTAssertTrue(exists(store.marksFile), "busy: the marks wait")
    XCTAssertTrue(exists(store.lockFile))

    let pasted = try EditorFixture(Self.draft, opener: "block:claude")
    let pastedStore = ReviewStore(draft: pasted.file)
    try agentPane("idle-placeholder", thenAfterPaste: nil, fixture: pasted)
    connectAgent(pasted.host)
    type("m", into: pasted.host)
    try mark("quick", key: "1", in: pasted.host)
    type("s", into: pasted.host)
    XCTAssertTrue(pasted.host.interaction.review.marks.isEmpty)
    XCTAssertFalse(exists(pastedStore.marksFile), "pasted counts as submitted")
    XCTAssertFalse(pasted.host.interaction.review.isOn, "and ends review like a sent pass")
  }

  func testNoAgentAndUnreachableAgentKeepTheSavedMarks() throws {
    let fixture = try EditorFixture(Self.draft, opener: "block:claude")
    let host = fixture.host
    let review = ReviewStore(draft: fixture.file)
    try agentPane("idle-placeholder", fixture: fixture)
    fixture.runner.reply(to: "send", (1, Data(), Data("no such block".utf8)))
    connectAgent(host)
    type("m", into: host)
    try mark("quick", key: "1", in: host)
    type("s", into: host)
    XCTAssertEqual(host.interaction.review.marks.count, 1)
    XCTAssertTrue(exists(review.marksFile), "unreachable keeps them")
    host.perform(host.interaction.setReviewAgent(ReviewAgentStatus(connected: 0, title: nil, chosen: false), at: 0))
    type("s", into: host)
    XCTAssertTrue(exists(review.marksFile), "no agent keeps them")
  }

  func testStoppingReviewReleasesTheLockAndDiscardedMarksAreNotKept() throws {
    let fixture = try EditorFixture(Self.draft, opener: "block:claude")
    let host = fixture.host
    let review = ReviewStore(draft: fixture.file)
    connectAgent(host)
    type("m", into: host)
    XCTAssertTrue(exists(review.lockFile))
    type("m", into: host)
    XCTAssertFalse(exists(review.lockFile), "m with nothing marked just stops")

    type("m", into: host)
    try mark("quick", key: "1", in: host)
    type("m", into: host)
    XCTAssertEqual(fixture.status, "Discard 1 mark? y / n")
    XCTAssertTrue(exists(review.marksFile))
    type("n", into: host)
    XCTAssertTrue(exists(review.marksFile))
    type("m", into: host)
    type("y", into: host)
    XCTAssertFalse(exists(review.marksFile))
    XCTAssertFalse(exists(review.lockFile))
  }

  func testLeavingTheFileReleasesTheLockAndOpeningTheSameFileAsksNothing() throws {
    let fixture = try EditorFixture(Self.draft, opener: "block:claude")
    let host = fixture.host
    let review = ReviewStore(draft: fixture.file)
    let other = try fixture.hostFixture.directory.write("other.md", "# Other\n\nElsewhere.\n")
    connectAgent(host)
    type("m", into: host)
    host.open(fixture.file)
    spin(0.05)
    XCTAssertNil(host.interaction.confirm)
    XCTAssertTrue(host.interaction.review.isOn)
    XCTAssertTrue(exists(review.lockFile))

    host.open(other)
    spin(until: { host.interaction.file?.lastPathComponent == "other.md" })
    XCTAssertFalse(host.interaction.review.isOn)
    XCTAssertFalse(exists(review.lockFile))
  }

  func testOpeningAnotherFileWithMarksAsksAndDiscardingClearsThem() throws {
    let fixture = try EditorFixture(Self.draft, opener: "block:claude")
    let host = fixture.host
    let review = ReviewStore(draft: fixture.file)
    let other = try fixture.hostFixture.directory.write("other.md", "# Other\n\nElsewhere.\n")
    connectAgent(host)
    type("m", into: host)
    try mark("quick", key: "1", in: host)
    host.open(other)
    XCTAssertEqual(host.interaction.file?.lastPathComponent, "main.md")
    XCTAssertEqual(fixture.status, "Discard 1 mark? y / n")
    type("y", into: host)
    spin(until: { host.interaction.file?.lastPathComponent == "other.md" })
    XCTAssertEqual(host.interaction.file?.lastPathComponent, "other.md")
    XCTAssertFalse(exists(review.marksFile))
    XCTAssertFalse(exists(review.lockFile))
  }

  func testQuitKeepsUnsentMarksOnDiskAndReleasesTheLock() throws {
    let fixture = try EditorFixture(Self.draft, opener: "block:claude")
    let host = fixture.host
    let review = ReviewStore(draft: fixture.file)
    var quits = 0
    host.onQuit = { quits += 1 }
    connectAgent(host)
    type("m", into: host)
    try mark("quick", key: "1", in: host)
    type("\u{3}", into: host)
    XCTAssertEqual(quits, 1)
    XCTAssertTrue(exists(review.marksFile), "Ctrl-C does not ask, so the marks are what a restart restores")
    XCTAssertFalse(exists(review.lockFile))
  }

  func testQAsksAndYesDiscardsThenQuits() throws {
    let fixture = try EditorFixture(Self.draft, opener: "block:claude")
    let host = fixture.host
    let review = ReviewStore(draft: fixture.file)
    var quits = 0
    host.onQuit = { quits += 1 }
    connectAgent(host)
    type("m", into: host)
    try mark("quick", key: "1", in: host)
    type("q", into: host)
    XCTAssertEqual(quits, 0)
    XCTAssertEqual(fixture.status, "Discard 1 mark? y / n")
    type("y", into: host)
    XCTAssertEqual(quits, 1)
    XCTAssertFalse(exists(review.marksFile))
    XCTAssertFalse(exists(review.lockFile))
  }

  func testDeletingTheLastMarkClearsTheSavedFile() throws {
    let fixture = try EditorFixture(Self.draft, opener: "block:claude")
    let host = fixture.host
    let review = ReviewStore(draft: fixture.file)
    connectAgent(host)
    type("m", into: host)
    try mark("quick", key: "1", in: host)
    XCTAssertTrue(exists(review.marksFile))
    type("U", into: host)
    XCTAssertTrue(host.interaction.review.marks.isEmpty)
    XCTAssertFalse(exists(review.marksFile))
  }

  func testAMidReviewSwitchesTheAgentForTheNextPass() throws {
    let fixture = try EditorFixture(Self.draft)
    let host = fixture.host
    let ide = IDEBridge(workspaceFolders: [], file: fixture.file)
    host.ide = ide
    titleReply("block:one", "one", fixture: fixture)
    titleReply("block:two", "two", fixture: fixture)
    ide.standIns = [ConnectedAgent(id: 1, block: "block:one"), ConnectedAgent(id: 2, block: "block:two")]
    ide.choose(.agent(1))
    host.agentsChanged()
    spin(until: { host.interaction.reviewAgent.title == "one" })
    type("m", into: host)
    XCTAssertTrue(host.interaction.review.isOn)
    XCTAssertEqual(ide.askTarget, "block:one")

    type("A", into: host)
    spin(until: { host.interaction.agentPicker != nil })
    XCTAssertEqual(host.interaction.agentPicker?.title, "Send highlights to")
    type("2", into: host)
    spin(until: { host.interaction.reviewAgent.title == "two" })
    XCTAssertEqual(host.interaction.reviewAgent.title, "two")
    XCTAssertEqual(ide.askTarget, "block:two")
    XCTAssertTrue(host.interaction.review.isOn)
  }

  // MARK: Changes since the last pass (D)

  static let applied = draft.replacingOccurrences(of: "quick ", with: "")

  /// Review on, pass 1 already sent for `draft`, and the agent's change to the file shown.
  func reviewedAfterPassOne(_ fixture: EditorFixture) throws {
    let review = ReviewStore(draft: fixture.file)
    connectAgent(fixture.host)
    type("m", into: fixture.host)
    let annotation = ReviewAnnotation(
      type: "delete", label: "Delete", text: "quick ", note: nil, context: "The quick brown fox jumps.", line: 3,
      colFrom: 4, endLine: 3, colTo: 10, occurrence: 1, seq: 1)
    try review.submit(
      action: .go, annotations: [annotation], launchText: Self.draft, finalText: Self.draft,
      about: review.about(pass: 1))
    try Data(Self.applied.utf8).write(to: fixture.file)
    fixture.host.fileChanged()
  }

  func runs(_ fixture: EditorFixture) -> [[String]] { fixture.runner.rexCalls.filter { $0.first == "run" } }

  func testDOnAFirstPassHasNothingToCompareAgainst() throws {
    let fixture = try EditorFixture(Self.draft, opener: "block:claude")
    connectAgent(fixture.host)
    type("m", into: fixture.host)
    type("D", into: fixture.host)
    XCTAssertEqual(fixture.status, "No earlier pass to compare against")
    XCTAssertEqual(runs(fixture), [])
    XCTAssertFalse(exists(ReviewStore(draft: fixture.file).changesFile))
  }

  func testDWorksWithReviewOff() throws {
    let fixture = try EditorFixture(Self.draft, opener: "block:claude")
    type("D", into: fixture.host)
    XCTAssertEqual(fixture.status, "No earlier pass to compare against")
    XCTAssertEqual(runs(fixture), [])

    let review = ReviewStore(draft: fixture.file)
    try review.submit(
      action: .finish, annotations: [], launchText: Self.draft, finalText: Self.draft, about: review.about(pass: 1))
    try Data(Self.applied.utf8).write(to: fixture.file)
    fixture.host.fileChanged()
    XCTAssertFalse(fixture.host.interaction.review.isOn)
    type("D", into: fixture.host)
    XCTAssertEqual(runs(fixture).count, 1)
    XCTAssertEqual(fixture.status, "Changes since pass 1 shown beside the preview")
    XCTAssertTrue(exists(review.changesFile))
  }

  func testDWritesTheChangesAndOpensThemInAPaneToTheRightAt40Percent() throws {
    let fixture = try EditorFixture(Self.draft, opener: "block:claude")
    let review = ReviewStore(draft: fixture.file)
    try reviewedAfterPassOne(fixture)
    type("D", into: fixture.host)

    XCTAssertEqual(
      review.changesFile.path,
      review.directory.appendingPathComponent(fixture.file.lastPathComponent + ".changes.md").path)
    let changes = try String(contentsOf: review.changesFile, encoding: .utf8)
    XCTAssertTrue(changes.contains("## Since pass 1"), changes)
    XCTAssertTrue(changes.contains("1 Delete"), changes)
    XCTAssertTrue(changes.contains("L3 ~~quick brown~~ → brown"), changes)
    let run = try XCTUnwrap(runs(fixture).first)
    XCTAssertEqual(
      run,
      [
        "run", "--json", "--session", EditorFixture.session, "--block", EditorFixture.previewBlock, "--split", "right",
        "--ratio", "40", "--focus=false", "--label", "termdown-changes", "--cwd", review.directory.path, "--",
        fixture.coordinator.context.viewer, "view", review.changesFile.path,
      ])
    XCTAssertEqual(runs(fixture).count, 1)
    XCTAssertEqual(fixture.status, "Changes since pass 1 shown beside the preview")
  }

  func testDAgainRefreshesTheFileInPlaceAndOpensNoSecondPane() throws {
    let fixture = try EditorFixture(Self.draft, opener: "block:claude")
    let review = ReviewStore(draft: fixture.file)
    try reviewedAfterPassOne(fixture)
    type("D", into: fixture.host)
    let before = try String(contentsOf: review.changesFile, encoding: .utf8)

    let again = Self.applied.replacingOccurrences(of: "second line", with: "next line")
    try Data(again.utf8).write(to: fixture.file)
    fixture.host.fileChanged()
    type("D", into: fixture.host)
    let after = try String(contentsOf: review.changesFile, encoding: .utf8)
    XCTAssertNotEqual(before, after)
    XCTAssertTrue(after.contains("L5 ~~second~~ → next"), after)
    XCTAssertEqual(runs(fixture).count, 1, "the pane watches the file, so it needs no second pane")
  }

  func testDOpensAgainWhenThePaneWasClosedByHand() throws {
    let fixture = try EditorFixture(Self.draft, opener: "block:claude")
    try reviewedAfterPassOne(fixture)
    type("D", into: fixture.host)
    let block = EditorFixture.launchedBlock
    fixture.runner.reply(
      to: "block inspect -s \(EditorFixture.session) \(block)",
      (3, Data(), Data("Error: block target \"\(block)\" not found".utf8)))
    type("D", into: fixture.host)
    XCTAssertEqual(runs(fixture).count, 2)
  }

  /// The pane outlives review: what the agent changes after a pass is what it is for.
  func testSendingAPassOrStoppingReviewKeepsThePane() throws {
    let fixture = try EditorFixture(Self.draft, opener: "block:claude")
    let review = ReviewStore(draft: fixture.file)
    try reviewedAfterPassOne(fixture)
    type("D", into: fixture.host)
    try agentPane("idle-after-turn", fixture: fixture)
    try mark("brown", key: "4", in: fixture.host)
    type("s", into: fixture.host)
    XCTAssertFalse(fixture.host.interaction.review.isOn)
    XCTAssertTrue(exists(review.changesFile))
    type("m", into: fixture.host)
    type("m", into: fixture.host)
    XCTAssertTrue(exists(review.changesFile))
    XCTAssertEqual(fixture.runner.rexCalls.filter { $0.starts(with: ["block", "close"]) }, [])
    type("D", into: fixture.host)
    XCTAssertEqual(runs(fixture).count, 1, "the same pane refreshes")
  }

  func testLeavingTheFileAndQuittingCloseThePaneToo() throws {
    for leave in ["open", "quit"] {
      let fixture = try EditorFixture(Self.draft, opener: "block:claude")
      let review = ReviewStore(draft: fixture.file)
      try reviewedAfterPassOne(fixture)
      type("D", into: fixture.host)
      if leave == "open" {
        let other = try fixture.hostFixture.directory.write("other.md", "# Other\n")
        fixture.host.open(other)
        spin(until: { fixture.host.interaction.file?.lastPathComponent == "other.md" })
      } else {
        fixture.host.perform(.quit)
      }
      XCTAssertFalse(exists(review.changesFile), leave)
      XCTAssertEqual(fixture.runner.rexCalls.filter { $0.starts(with: ["block", "close"]) }.count, 1, leave)
    }
  }

  func testAPaneThatWasNeverOpenedIsNotClosed() throws {
    let fixture = try EditorFixture(Self.draft, opener: "block:claude")
    connectAgent(fixture.host)
    type("m", into: fixture.host)
    type("D", into: fixture.host)
    type("m", into: fixture.host)
    XCTAssertEqual(fixture.runner.rexCalls.filter { $0.starts(with: ["block", "close"]) }, [])
  }

  func testDOutsideRexSaysThereIsNowhereToShowTheChanges() throws {
    let fixture = try EditorFixture(Self.draft, inRex: false)
    let review = ReviewStore(draft: fixture.file)
    try reviewedAfterPassOne(fixture)
    type("D", into: fixture.host)
    XCTAssertEqual(fixture.status, "Could not open the changes: not running in a Rex pane")
    XCTAssertEqual(runs(fixture), [])
    XCTAssertFalse(exists(review.changesFile), "nothing is left behind for a pane that never opened")
  }
}
