import Foundation
import Testing

@testable import TermDownCore

@Suite struct AgentRoutingTests {
  let opener = ConnectedAgent(id: 1, pid: 10, block: "block:opener")
  let other = ConnectedAgent(id: 2, pid: 20, block: "block:other")
  let unknown = ConnectedAgent(id: 3)

  @Test func openerSendsOnlyToTheOpenersAgent() {
    let agents = [opener, other, unknown]
    #expect(AgentRouting.recipients(agents, pairing: .opener, opener: "block:opener", choice: nil) == [1])
  }

  @Test func openerFallsBackToEveryAgentWhenNoneIsTheOpener() {
    let agents = [other, unknown]
    #expect(AgentRouting.recipients(agents, pairing: .opener, opener: "block:opener", choice: nil) == [2, 3])
    #expect(AgentRouting.recipients(agents, pairing: .opener, opener: nil, choice: nil) == [2, 3])
  }

  @Test func unknownPanesNeverMatchAMissingOpener() {
    #expect(AgentRouting.recipients([unknown, other], pairing: .opener, opener: nil, choice: nil) == [3, 2])
  }

  @Test func allSendsToEveryAgent() {
    #expect(AgentRouting.recipients([opener, other], pairing: .all, opener: "block:opener", choice: nil) == [1, 2])
  }

  @Test func askSendsToTheOnlyAgentAndWaitsWhenThereAreSeveral() {
    #expect(AgentRouting.recipients([other], pairing: .ask, opener: nil, choice: nil) == [2])
    #expect(AgentRouting.recipients([opener, other], pairing: .ask, opener: nil, choice: nil) == [])
    #expect(AgentRouting.needsChoice([opener, other], pairing: .ask, choice: nil))
    #expect(!AgentRouting.needsChoice([other], pairing: .ask, choice: nil))
    #expect(!AgentRouting.needsChoice([opener, other], pairing: .opener, choice: nil))
  }

  @Test func aChoiceOverridesThePairingWhileItsAgentIsConnected() {
    let agents = [opener, other]
    #expect(AgentRouting.recipients(agents, pairing: .opener, opener: "block:opener", choice: .agent(2)) == [2])
    #expect(AgentRouting.recipients(agents, pairing: .ask, opener: nil, choice: .agent(2)) == [2])
    #expect(AgentRouting.recipients(agents, pairing: .opener, opener: "block:opener", choice: .all) == [1, 2])
    #expect(!AgentRouting.needsChoice(agents, pairing: .ask, choice: .agent(2)))
  }

  @Test func aChoiceWhoseAgentLeftFallsBackToThePairing() {
    let agents = [opener, other]
    #expect(AgentRouting.recipients(agents, pairing: .opener, opener: "block:opener", choice: .agent(9)) == [1])
    #expect(AgentRouting.needsChoice(agents, pairing: .ask, choice: .agent(9)))
  }

  @Test func askTargetIsTheOnlyRecipientsPaneElseTheOpener() {
    let agents = [opener, other]
    #expect(AgentRouting.askTarget(agents, pairing: .opener, opener: "block:opener", choice: .agent(2)) == "block:other")
    #expect(AgentRouting.askTarget(agents, pairing: .all, opener: "block:opener", choice: nil) == "block:opener")
    #expect(AgentRouting.askTarget([], pairing: .opener, opener: "block:opener", choice: nil) == "block:opener")
  }

  /// A review goes only to the single recipient's own Rex pane: never to the opener, and never to an agent outside Rex.
  @Test func reviewTargetIsTheOnlyRecipientsPaneAndNeverTheOpener() {
    let agents = [opener, other]
    #expect(
      AgentRouting.reviewTarget(agents, pairing: .opener, opener: "block:opener", choice: .agent(2)) == "block:other")
    #expect(AgentRouting.reviewTarget(agents, pairing: .all, opener: "block:opener", choice: nil) == nil)
    #expect(AgentRouting.reviewTarget([], pairing: .opener, opener: "block:opener", choice: nil) == nil)
    #expect(AgentRouting.reviewTarget([unknown], pairing: .opener, opener: "block:opener", choice: nil) == nil)
    #expect(AgentRouting.reviewTarget([unknown], pairing: .ask, opener: "block:opener", choice: .agent(3)) == nil)
    #expect(AgentRouting.askTarget([unknown], pairing: .opener, opener: "block:opener", choice: nil) == "block:opener")
  }

  @Test func parsesProcessArguments() {
    var bytes: [UInt8] = []
    var argc = Int32(2)
    withUnsafeBytes(of: &argc) { bytes += $0 }
    for part in ["/usr/bin/claude", "", "", "claude", "--ide", "REX_BLOCK=block:abc", "A=b=c", "NOEQUALS", ""] {
      bytes += Array(part.utf8) + [0]
    }
    let environment = ProcessEnvironment.parse(bytes)
    #expect(environment?["REX_BLOCK"] == "block:abc")
    #expect(environment?["A"] == "b=c")
    #expect(environment?["claude"] == nil)
  }

  @Test func readsThisProcesssEnvironment() {
    let environment = ProcessEnvironment.read(getpid())
    #expect(environment?["PATH"] == ProcessInfo.processInfo.environment["PATH"])
  }
}
