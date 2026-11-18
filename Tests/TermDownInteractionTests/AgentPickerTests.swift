import CoreGraphics
import Foundation
import TermDownRender
import XCTest

@testable import TermDownCore
@testable import TermDownInteraction

final class AgentPickerTests: XCTestCase {
  let agents = [
    ConnectedAgent(id: 1, pid: 10, block: "block:a", title: "Visit Group final report"),
    ConnectedAgent(id: 2, pid: 20, block: "block:b", title: "IDE connectivity"),
    ConnectedAgent(id: 3, pid: 30),
  ]

  func testRowsListAgentsThenAllThenStartNew() {
    let content = AgentPickerContent.make(
      agents: agents, recipients: [2], agentCommand: "claude", windows: ["block:a": "w1", "block:b": "w2"],
      viewerWindow: "w1")
    XCTAssertEqual(content.rows.map(\.action), [.agent(1), .agent(2), .agent(3), .all, .startNew])
    XCTAssertEqual(content.rows.map(\.label).prefix(3), ["Visit Group final report", "IDE connectivity", "Agent 3"])
    XCTAssertEqual(content.rows[0].detail, "this tab, pid 10")
    XCTAssertEqual(content.rows[2].detail, "outside Rex, pid 30")
    XCTAssertEqual(content.rows.map(\.current), [false, true, false, false, false])
    XCTAssertEqual(content.selected, 1, "the picker starts on the current recipient")
    XCTAssertEqual(content.rows.last?.detail, "claude")
  }

  func testReviewPickerHasNoAllRow() {
    let content = AgentPickerContent.make(
      agents: Array(agents.prefix(2)), recipients: [1, 2], agentCommand: "claude", forReview: true)
    XCTAssertEqual(content.rows.map(\.action), [.agent(1), .agent(2), .startNew])
    XCTAssertEqual(content.title, "Send the review to")
    XCTAssertEqual(content.rows.map(\.current), [false, false, false], "all connected agents is not a review target")
  }

  func testAllIsCurrentWhenEveryAgentGetsTheSelection() {
    let content = AgentPickerContent.make(agents: agents, recipients: [1, 2, 3], agentCommand: "claude")
    XCTAssertEqual(content.rows.map(\.current), [false, false, false, true, false])
  }

  func testOneAgentHasNoAllRow() {
    let content = AgentPickerContent.make(agents: [agents[0]], recipients: [1], agentCommand: "claude")
    XCTAssertEqual(content.rows.map(\.action), [.agent(1), .startNew])
    XCTAssertTrue(content.rows[0].current)
  }

  func testShiftAOpensThePickerAndKeysChooseARow() {
    var h = Harness("Some text.\n")
    XCTAssertEqual(h.key(.char("A")), [.openAgentPicker])
    h.run(h.model.showAgentPicker(AgentPickerContent.make(agents: agents, recipients: [1], agentCommand: "claude")))
    XCTAssertEqual(h.model.agentPicker?.selected, 0)
    XCTAssertEqual(h.key(.down), [.redrawAll])
    XCTAssertEqual(h.key(.enter), [.redrawAll, .chooseAgent(.agent(2))])
    XCTAssertNil(h.model.agentPicker)

    h.run(h.model.showAgentPicker(AgentPickerContent.make(agents: agents, recipients: [1], agentCommand: "claude")))
    XCTAssertEqual(h.key(.char("5")), [.redrawAll, .chooseAgent(.startNew)])
    h.run(h.model.showAgentPicker(AgentPickerContent.make(agents: agents, recipients: [1], agentCommand: "claude")))
    XCTAssertEqual(h.key(.escape), [.redrawAll])
    XCTAssertNil(h.model.agentPicker)
  }

  func testClickingARowChoosesItAndClickingOutsideCloses() {
    var h = Harness("Some text.\n")
    let content = AgentPickerContent.make(agents: agents, recipients: [1], agentCommand: "claude")
    h.run(h.model.showAgentPicker(content))
    let view = AgentPicker(content: content, backingScale: h.model.typography.backingScale)
    let area = CGRect(x: 0, y: 0, width: h.model.geometry.width, height: h.model.geometry.contentHeight)
    let row = view.rowRect(3, in: area)
    XCTAssertEqual(h.model.agentPickerPressed(at: CGPoint(x: row.midX, y: row.midY)), [.redrawAll, .chooseAgent(.all)])
    h.run(h.model.showAgentPicker(content))
    XCTAssertEqual(h.model.agentPickerPressed(at: CGPoint(x: 1, y: 1)), [.redrawAll])
    XCTAssertNil(h.model.agentPicker)
  }
}
