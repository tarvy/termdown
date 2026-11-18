import Foundation
import TermDownCore
import XCTest

@testable import TermDownHost

final class PaneNudgeTests: XCTestCase {
  let view = Data(
    """
    {"windows": [
      {"window_id": "window:shown", "layers": [{"kind": "tiled", "layout": {"rect": [0, 0, 1, 1],
        "block_id": "block:other-window"}}]},
      {"window_id": "window:elsewhere", "layers": [{"kind": "tiled", "layout": {"rect": [0, 0, 1, 1],
        "block_id": "block:older"}}]},
      {"window_id": "window:hidden", "layers": [{"kind": "tiled", "layout": {"rect": [0, 0, 1, 1], "split": {
        "before": {"rect": [0, 0, 0.5, 1], "block_id": "block:left"},
        "after": {"rect": [0.5, 0, 0.5, 1], "split": {
          "before": {"rect": [0.5, 0, 0.5, 0.25], "block_id": "block:viewer"},
          "after": {"rect": [0.5, 0.25, 0.5, 0.75], "block_id": "block:below"}}}}}}]}
    ]}
    """.utf8)

  func size(
    columns: Int, rows: Int, cell: (Int, Int) = (7, 14), owned: Bool, at time: String = "2026-11-04T19:41:00-06:00"
  ) -> Data {
    let owner = owned ? "\"client:1\"" : "null"
    let entry = "{\"client_id\": \"client:1\", \"columns\": \(columns), \"rows\": \(rows), \"updated_at\": \"\(time)\"}"
    let desired = owned ? "[\(entry)]" : "[]"
    return Data(
      """
      {"columns": \(columns), "rows": \(rows), "cell_width_px": \(cell.0), "cell_height_px": \(cell.1),
       "owner": \(owner), "desired": \(desired)}
      """.utf8)
  }

  func testSiblingInTheSameWindowSetsTheSize() {
    let sizes = ["block:left": size(columns: 100, rows: 60, owned: true)]
    XCTAssertEqual(
      PaneNudge.request(view: view, block: "block:viewer", sizes: sizes),
      PaneNudge.Request(columns: 100, rows: 15, cellWidth: 7, cellHeight: 14))
  }

  func testSameWindowSiblingsComeFirst() {
    XCTAssertEqual(
      PaneNudge.siblings(view: view, block: "block:viewer"),
      ["block:left", "block:below", "block:other-window", "block:older"])
  }

  func testSiblingInAnotherWindowSetsTheSize() {
    let sizes = [
      "block:left": size(columns: 80, rows: 24, owned: false),
      "block:other-window": size(columns: 241, rows: 65, cell: (8, 16), owned: true),
    ]
    XCTAssertEqual(
      PaneNudge.request(view: view, block: "block:viewer", sizes: sizes),
      PaneNudge.Request(columns: 120, rows: 16, cellWidth: 8, cellHeight: 16))
  }

  func testNewestSizedWindowWinsWhenThisWindowHasNone() {
    let sizes = [
      "block:other-window": size(columns: 241, rows: 65, cell: (8, 16), owned: true, at: "2026-11-04T19:43:00-06:00"),
      "block:older": size(columns: 330, rows: 93, cell: (14, 28), owned: true, at: "2026-11-04T16:00:00-06:00"),
    ]
    XCTAssertEqual(
      PaneNudge.request(view: view, block: "block:viewer", sizes: sizes),
      PaneNudge.Request(columns: 120, rows: 16, cellWidth: 8, cellHeight: 16))
  }

  func testLargerPaneInThisWindowBreaksATie() {
    let sizes = [
      "block:left": size(columns: 100, rows: 60, owned: true),
      "block:below": size(columns: 100, rows: 60, owned: true),
    ]
    XCTAssertEqual(
      PaneNudge.request(view: view, block: "block:viewer", sizes: sizes),
      PaneNudge.Request(columns: 100, rows: 15, cellWidth: 7, cellHeight: 14))
  }

  func testNoSizedSiblingAsksForNothing() {
    let sizes = [
      "block:left": size(columns: 80, rows: 24, owned: false),
      "block:other-window": size(columns: 80, rows: 24, owned: false),
    ]
    XCTAssertNil(PaneNudge.request(view: view, block: "block:viewer", sizes: sizes))
    XCTAssertNil(PaneNudge.request(view: view, block: "block:missing", sizes: sizes))
  }

  func testStaleSiblingIsOutvoted() {
    let sizes = [
      "block:left": size(columns: 200, rows: 120, owned: true),
      "block:below": size(columns: 100, rows: 45, owned: true),
      "block:other-window": size(columns: 200, rows: 60, owned: true),
    ]
    XCTAssertEqual(
      PaneNudge.request(view: view, block: "block:viewer", sizes: sizes),
      PaneNudge.Request(columns: 100, rows: 15, cellWidth: 7, cellHeight: 14))
  }

  func testTinyPaneRoundsDownToAtLeastOneCell() {
    let sizes = ["block:left": size(columns: 1, rows: 1, owned: true)]
    XCTAssertEqual(
      PaneNudge.request(view: view, block: "block:viewer", sizes: sizes),
      PaneNudge.Request(columns: 1, rows: 1, cellWidth: 7, cellHeight: 14))
  }

  func testUnsizedMeansNoOwnerAndNoDesiredSize() {
    XCTAssertTrue(PaneNudge.unsized(size(columns: 80, rows: 24, owned: false)))
    XCTAssertFalse(PaneNudge.unsized(size(columns: 80, rows: 24, owned: true)))
    XCTAssertFalse(PaneNudge.unsized(Data("not json".utf8)))
  }

  func testRunAsksRexForTheDerivedSize() {
    let runner = ScriptedRex([
      ["block", "call", "-b", "block:viewer", "size"]: size(columns: 80, rows: 24, owned: false),
      ["api", "call", "-s", "session:1", "session.view"]: view,
      ["block", "call", "-b", "block:left", "size"]: size(columns: 100, rows: 60, owned: true),
    ])
    let lines = LogLines()
    PaneNudge.run(rexPath: "/rex", session: "session:1", block: "block:viewer", runner: runner, log: lines.add)
    XCTAssertEqual(
      runner.calls.last,
      [
        "block", "call", "-b", "block:viewer", "resize",
        "{\"columns\":100,\"rows\":15,\"cell_width_px\":7,\"cell_height_px\":14}",
      ])
    XCTAssertEqual(lines.lines.count, 1)
  }

  func testRunLeavesAnOwnedPaneAlone() {
    let runner = ScriptedRex([
      ["block", "call", "-b", "block:viewer", "size"]: size(columns: 80, rows: 24, owned: true)
    ])
    PaneNudge.run(rexPath: "/rex", session: "session:1", block: "block:viewer", runner: runner, log: { _ in })
    XCTAssertEqual(runner.calls, [["block", "call", "-b", "block:viewer", "size"]])
  }
}

final class ScriptedRex: ProcessRunning, @unchecked Sendable {
  let replies: [[String]: Data]
  private(set) var calls: [[String]] = []

  init(_ replies: [[String]: Data]) {
    self.replies = replies
  }

  func run(_ executable: String, _ arguments: [String], timeout: TimeInterval?) throws -> (
    status: Int32, stdout: Data, stderr: Data
  ) {
    calls.append(arguments)
    if arguments.contains("resize") { return (0, Data(), Data()) }
    guard let reply = replies[arguments] else { return (1, Data(), Data()) }
    return (0, reply, Data())
  }
}

final class LogLines: @unchecked Sendable {
  private(set) var lines: [String] = []

  func add(_ line: String) {
    lines.append(line)
  }
}
