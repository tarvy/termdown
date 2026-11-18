import XCTest

@testable import TermDownCore

final class ReviewHotkeysTests: XCTestCase {
  func testTheBundledSetHasNineKeysInOrder() {
    let hotkeys = ReviewHotkeys.load()
    XCTAssertEqual(hotkeys.map(\.key), (1...9).map(String.init))
    XCTAssertEqual(
      hotkeys.map(\.type),
      ["delete", "awkward", "cringe", "shorten", "shorten_hard", "expand", "source", "overstated", "note"])
    XCTAssertEqual(hotkeys.last?.prompt, "Instruction for this passage:")
    XCTAssertNil(hotkeys.first?.prompt)
  }

  func testEveryHotkeyTellsTheAgentWhatToDo() {
    for hotkey in ReviewHotkeys.load() {
      XCTAssertFalse(hotkey.apply?.isEmpty ?? true, "\(hotkey.type) has no apply line")
    }
  }

  func testNothingOutsideThisRepositorySuppliesTheSet() throws {
    let source = try String(
      contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../Sources/TermDownCore/ReviewHotkeys.swift"), encoding: .utf8)
    XCTAssertFalse(source.contains("installed_plugins"))
  }

  func testParseReadsAnExplicitFile() throws {
    let json = ##"{"hotkeys": [{"key": "1", "type": "delete", "label": "Cut", "hint": "h", "color": "#000000", "apply": "x"}]}"##
    XCTAssertEqual(try ReviewHotkeys.parse(Data(json.utf8)).map(\.label), ["Cut"])
  }
}
