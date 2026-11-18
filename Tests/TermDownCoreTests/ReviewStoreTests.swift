import XCTest

@testable import TermDownCore

final class ReviewStoreTests: XCTestCase {
  var base: URL!
  var store: URL!

  override func setUpWithError() throws {
    base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    store = base.appendingPathComponent("store")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: base)
  }

  func makeStore(_ draft: URL) -> ReviewStore {
    ReviewStore(draft: draft, environment: [ReviewStore.homeVariable: store.path], home: base)
  }

  func write(_ text: String, _ path: String) throws -> URL {
    let url = base.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  func logRecords(_ store: ReviewStore) throws -> [[String: Any]] {
    try String(contentsOf: store.logFile, encoding: .utf8).split(separator: "\n").map {
      try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
    }
  }

  func annotation(_ type: String, _ text: String, note: String? = nil, seq: Int) -> ReviewAnnotation {
    ReviewAnnotation(
      type: type, label: type.capitalized, text: text, note: note, context: "We shipped fast. We shipped fast.",
      line: 3, colFrom: 17, endLine: 3, colTo: 33, occurrence: 2, seq: seq)
  }

  /// Pinned: the folder name is `<stem>-<12 hex of SHA-1 over the resolved path>`, and must not drift.
  func testDirectoryNameIsPinned() {
    XCTAssertEqual(
      ReviewStore.directoryName(for: URL(fileURLWithPath: "/nonexistent/Q3 report (draft).v2.md")),
      "Q3-report--draft-.v2-71405177717f")
  }

  func testSidecarFilesKeepTheFullDraftName() {
    let store = makeStore(base.appendingPathComponent("follow-up.email.md"))
    XCTAssertEqual(store.editsFile.lastPathComponent, "follow-up.email.md.edits.json")
    XCTAssertEqual(store.logFile.lastPathComponent, "follow-up.email.md.review.jsonl")
    XCTAssertEqual(store.editsFile.deletingLastPathComponent().path, store.directory.path)
  }

  func testRootIsTermdownsOwnFolderAndHonoursTheOverride() {
    let home = URL(fileURLWithPath: "/Users/someone")
    let own = "/Users/someone/Library/Application Support/termdown/reviews"
    XCTAssertEqual(ReviewStore.root(environment: [:], home: home).path, own)
    XCTAssertEqual(ReviewStore.root(environment: [ReviewStore.homeVariable: ""], home: home).path, own)
    XCTAssertEqual(ReviewStore.root(environment: [ReviewStore.homeVariable: "/x/y"], home: home).path, "/x/y")
    XCTAssertEqual(ReviewStore.root(environment: ["INTERACTIVE_REVIEW_HOME": "/x/y"], home: home).path, own)
  }

  func testReviewIsLiveOnlyWhileTheHolderRuns() throws {
    let review = makeStore(try write("a\n", "d/draft.md"))
    XCTAssertFalse(review.reviewIsLive())
    XCTAssertTrue(review.acquireLock(pid: getpid()))
    XCTAssertTrue(review.reviewIsLive())
    review.releaseLock()
    XCTAssertFalse(review.reviewIsLive())
    try FileManager.default.createDirectory(at: review.directory, withIntermediateDirectories: true)
    try "2147483646\n".write(to: review.lockFile, atomically: true, encoding: .utf8)
    XCTAssertFalse(review.reviewIsLive())
  }

  func testStemFollowsPathlib() {
    XCTAssertEqual(ReviewStore.stemOf("a.tar.gz"), "a.tar")
    XCTAssertEqual(ReviewStore.stemOf(".bashrc"), ".bashrc")
    XCTAssertEqual(ReviewStore.stemOf("draft."), "draft.")
    XCTAssertEqual(ReviewStore.directoryName(for: URL(fileURLWithPath: "/x/.md")).prefix(4), ".md-")
  }

  func testAboutNamesTheClientAndWhatTheDraftPertainsTo() throws {
    _ = try write(
      "---\nschema_version: 1\ncompany: acme\nengagement: assessment\nstarted: YYYY-MM-DD\n---\n",
      "40-customers/acme/assessment/overview.md")
    _ = try write("---\ntype: project\nname: Side work\nclient: globex\nstatus: active\n---\n", "work/side/overview.md")
    _ = try write("# Tooling — notes on it\n", "proj/CLAUDE.md")
    let drafts = [
      try write("Hello\n", "40-customers/acme/assessment/directed-effort/session-1/follow-up.md"),
      try write("---\nclient: initech\nsubject: Kickoff recap\n---\nHi\n", "40-customers/acme/assessment/recap.md"),
      try write("Hi\n", "work/side/drafts/plan.md"),
      try write("Hi\n", "proj/notes/draft.md"),
      try write("Hi\n", "loose/draft.md"),
    ]
    // client, kind, source, pertains_to, engagement for each draft, in order.
    let expected: [[String?]] = [
      ["acme/assessment", "client", "overview.md", "directed-effort/session-1", "assessment"],
      ["initech", "client", "draft frontmatter", "Kickoff recap", "assessment"],
      ["Side work", "project", "overview.md", "drafts", nil],
      ["Tooling", "context", "CLAUDE.md", nil, nil],
      [nil, nil, nil, nil, nil],
    ]
    for (draft, want) in zip(drafts, expected) {
      let encoder = JSONEncoder()
      let about = ReviewAbout(draft: draft, pass: 2, home: URL(fileURLWithPath: "/nonexistent-home"))
      let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(about)) as? [String: Any])
      let got = ["client", "kind", "source", "pertains_to", "engagement"].map { json[$0] as? String }
      XCTAssertEqual(got, want, draft.lastPathComponent)
      XCTAssertEqual(json["pass"] as? Int, 2)
    }
  }

  func testWrittenEditsFileValidates() throws {
    let draft = try write("# Title\n\nWe shipped fast. We shipped fast.\n", "draft.md")
    let store = makeStore(draft)
    try store.submit(
      action: .go,
      annotations: [
        annotation("delete", "We shipped fast.", seq: 1), annotation("note", "fast", note: "say how", seq: 2),
      ],
      launchText: "# Title\n\nWe shipped.\n", finalText: "# Title\n\nWe shipped fast. We shipped fast.\n", about: nil)
    let edits = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.editsFile)) as? [String: Any])
    XCTAssertEqual(edits["draft"] as? String, store.draft.path)
    XCTAssertEqual((edits["annotations"] as? [[String: Any]])?.first?["note"] as? NSNull, NSNull())
    XCTAssertEqual((edits["manual_edits"] as? [String: Any])?["note"] as? String, ReviewStore.manualEditsNote)

    XCTAssertEqual(Set(edits.keys), ["draft", "action", "annotations", "manual_edits"])
    let first = try XCTUnwrap((edits["annotations"] as? [[String: Any]])?.first)
    XCTAssertEqual(
      Set(first.keys),
      ["type", "label", "text", "note", "context", "line", "col_from", "end_line", "col_to", "occurrence", "seq"])
  }

  func testLaunchAndSubmitRecordsCarryTheContractFields() throws {
    let draft = try write("one\n", "draft.md")
    let store = makeStore(draft)
    let about = store.about(pass: store.nextPass())
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    try store.logLaunch(snapshot: "one\n", about: about, now: date)
    XCTAssertEqual(store.nextPass(), 1)
    XCTAssertEqual(
      try store.submit(action: .go, annotations: [], launchText: "one\n", finalText: "two\n", about: about, now: date),
      1)
    try store.logLaunch(snapshot: "two\n", about: about, now: date)
    XCTAssertEqual(
      try store.submit(
        action: .finish, annotations: [annotation("cringe", "x", seq: 1)], launchText: "two\n", finalText: "two\n",
        about: about, now: date), 2)

    let records = try logRecords(store)
    XCTAssertEqual(records.count, 4)
    let launchKeys: Set = [
      "pass", "pre_review", "before_pass", "ts", "format", "about", "event", "draft_snapshot", "manual_edit_diff",
      "annotations",
    ]
    let submitKeys: Set = [
      "pass", "ts", "format", "about", "action", "draft_snapshot", "manual_edit_diff", "annotations",
    ]
    XCTAssertEqual(Set(records[0].keys), launchKeys)
    XCTAssertEqual(Set(records[1].keys), submitKeys)
    XCTAssertEqual(records[0]["pre_review"] as? Bool, true)
    XCTAssertEqual(records[2]["pre_review"] as? Bool, false)
    XCTAssertEqual(records.map { $0["pass"] as? Int }, [0, 1, 0, 2])
    XCTAssertEqual(records[2]["before_pass"] as? Int, 2)
    XCTAssertEqual(records[0]["event"] as? String, "launch")
    XCTAssertEqual(records[0]["format"] as? String, "viewer")
    XCTAssertEqual(records[0]["manual_edit_diff"] as? NSNull, NSNull())
    XCTAssertEqual((records[0]["about"] as? [String: Any])?["file"] as? String, "draft.md")
    XCTAssertEqual(records[1]["manual_edit_diff"] as? String, "--- at-open\n+++ submitted\n@@ -1 +1 @@\n-one\n+two")
    XCTAssertEqual(records[3]["manual_edit_diff"] as? NSNull, NSNull())
    XCTAssertEqual(records[3]["action"] as? String, "finish")
    XCTAssertEqual((records[3]["annotations"] as? [[String: Any]])?.first?["col_from"] as? Int, 17)
    let ts = try XCTUnwrap(records[0]["ts"] as? String)
    XCTAssertNotNil(ts.wholeMatch(of: #/\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d/#), ts)

    let edits = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.editsFile)) as? [String: Any])
    XCTAssertEqual(edits["action"] as? String, "finish")
    XCTAssertEqual(edits["manual_edits"] as? NSNull, NSNull())
  }

  func testSubmitWritesPassFileAndLatest() throws {
    let draft = try write("one\n", "draft.md")
    let store = makeStore(draft)
    XCTAssertEqual(store.passEditsFile(2), store.directory.appendingPathComponent("draft.md.pass-2.edits.json"))
    try store.submit(
      action: .go, annotations: [annotation("delete", "one", seq: 1)], launchText: "one\n", finalText: "one\n",
      about: nil)
    try store.submit(
      action: .finish, annotations: [annotation("cringe", "two", seq: 1)], launchText: "one\n", finalText: "one\n",
      about: nil)

    func edits(_ url: URL) throws -> [String: Any] {
      try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
    let first = try edits(store.passEditsFile(1))
    let second = try edits(store.passEditsFile(2))
    XCTAssertEqual(first["action"] as? String, "go")
    XCTAssertEqual((first["annotations"] as? [[String: Any]])?.map { $0["text"] as? String }, ["one"])
    XCTAssertEqual(second["action"] as? String, "finish")
    XCTAssertEqual((second["annotations"] as? [[String: Any]])?.map { $0["text"] as? String }, ["two"])
    XCTAssertEqual(try Data(contentsOf: store.editsFile), try Data(contentsOf: store.passEditsFile(2)))
  }

  /// Garbled lines and launch records (`pass` 0) are not passes; any other record is one.
  func testPassCountSkipsLaunchesAndGarbage() throws {
    let store = makeStore(base.appendingPathComponent("draft.md"))
    try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
    try "{\"pass\": 0}\n{\"pass\": 1, \"draft_snapshot\": \"\\\"pass\\\": 0\"}\nnot json\n\n{\"action\": \"go\"}\n"
      .write(to: store.logFile, atomically: true, encoding: .utf8)
    XCTAssertEqual(store.nextPass(), 3)
  }

  /// The diff is a unified diff with `at-open` and `submitted` headers, one line per element, no trailing newline.
  func testManualEditDiffIsAUnifiedDiff() {
    XCTAssertEqual(
      ReviewStore.manualEditDiff(from: "a\nb\nc\n", to: "a\nB\nc\n"),
      "--- at-open\n+++ submitted\n@@ -1,3 +1,3 @@\n a\n-b\n+B\n c")
    XCTAssertNil(ReviewStore.manualEditDiff(from: "same\n", to: "same\n"))
  }

  // MARK: Saved marks and the review lock

  func testMarkSidecarsSitBesideTheLogNamedForTheDraft() throws {
    let review = makeStore(try write("a\n", "d/draft.md"))
    XCTAssertEqual(review.marksFile, review.directory.appendingPathComponent("draft.md.marks.json"))
    XCTAssertEqual(review.lockFile, review.directory.appendingPathComponent("draft.md.review.lock"))
  }

  func testMarksRoundTrip() throws {
    let review = makeStore(try write("a\n", "d/draft.md"))
    XCTAssertNil(review.loadMarks())
    let marks = [
      SavedMark(start: 4, end: 9, type: "delete", label: "Delete", note: nil, seq: 1),
      SavedMark(start: 12, end: 20, type: "note", label: "Note", note: "say \"why\" — here", seq: 3),
    ]
    try review.saveMarks(marks, snapshot: "The quick — text\n")
    let loaded = try XCTUnwrap(review.loadMarks())
    XCTAssertEqual(loaded.marks, marks)
    XCTAssertEqual(loaded.snapshot, "The quick — text\n")

    review.clearMarks()
    XCTAssertFalse(FileManager.default.fileExists(atPath: review.marksFile.path))
    XCTAssertNil(review.loadMarks())
    review.clearMarks()
  }

  func testAnUnreadableMarksFileLoadsAsNothing() throws {
    let review = makeStore(try write("a\n", "d/draft.md"))
    try FileManager.default.createDirectory(at: review.directory, withIntermediateDirectories: true)
    try "not json".write(to: review.marksFile, atomically: true, encoding: .utf8)
    XCTAssertNil(review.loadMarks())
  }

  /// A pid that is certainly not running: a child that has exited and been reaped.
  func deadPID() throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try process.run()
    process.waitUntilExit()
    return process.processIdentifier
  }

  func testTheLockRecordsThePidAndKeepsOtherViewersOut() throws {
    let review = makeStore(try write("a\n", "d/draft.md"))
    let mine = getpid()
    let other = getppid()
    XCTAssertTrue(review.acquireLock(pid: mine))
    XCTAssertEqual(
      try String(contentsOf: review.lockFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
      "\(mine)")
    XCTAssertFalse(review.acquireLock(pid: other), "a live viewer holds it")
    XCTAssertTrue(review.acquireLock(pid: mine), "the holder asking again keeps it")
    review.releaseLock()
    XCTAssertFalse(FileManager.default.fileExists(atPath: review.lockFile.path))
    XCTAssertTrue(review.acquireLock(pid: other))
    review.releaseLock()
  }

  func testTheLockOfADeadViewerIsTaken() throws {
    let review = makeStore(try write("a\n", "d/draft.md"))
    XCTAssertTrue(review.acquireLock(pid: try deadPID()))
    XCTAssertTrue(review.acquireLock(pid: getpid()))
    XCTAssertEqual(
      try String(contentsOf: review.lockFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
      "\(getpid())")
  }

  func testAGarbledLockIsTakenAndReleasingWithoutOneIsFine() throws {
    let review = makeStore(try write("a\n", "d/draft.md"))
    review.releaseLock()
    try FileManager.default.createDirectory(at: review.directory, withIntermediateDirectories: true)
    try "?".write(to: review.lockFile, atomically: true, encoding: .utf8)
    XCTAssertTrue(review.acquireLock(pid: getpid()))
  }
}
