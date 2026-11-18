import XCTest

@testable import TermDownCore

final class AgentSkillTests: XCTestCase {
  var home: URL!

  override func setUpWithError() throws {
    home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: home)
  }

  func makeParent(_ name: String) throws {
    try FileManager.default.createDirectory(
      at: home.appendingPathComponent(name), withIntermediateDirectories: true)
  }

  func skillFile(_ parent: String, _ skill: String = "termdown") -> URL {
    home.appendingPathComponent("\(parent)/skills/\(skill)/SKILL.md")
  }

  func states(_ reports: [AgentSkillReport]) -> [AgentSkillState] { reports.map(\.state) }

  func writeSkill(_ parent: String, _ content: String, skill: String = "termdown") throws {
    try FileManager.default.createDirectory(
      at: skillFile(parent, skill).deletingLastPathComponent(), withIntermediateDirectories: true)
    try content.write(to: skillFile(parent, skill), atomically: true, encoding: .utf8)
  }

  var outdatedStub: String {
    agentStub.replacingOccurrences(of: "\"\(agentStubVersion)\"", with: "\"0\"")
  }

  func testStubFrontmatterAndBody() {
    XCTAssertTrue(agentStub.hasPrefix("---\nname: termdown\ndescription: "))
    XCTAssertEqual(stubVersion(of: agentStub), agentStubVersion)
    XCTAssertTrue(agentStub.contains("`termdown agent-guide`"))
    XCTAssertTrue(agentStub.contains("Installed by \"termdown agents install\""))
  }

  func testGuideContainsOpenCommandAndFallbackRule() {
    XCTAssertTrue(agentGuide.contains("termdown open /absolute/path/to/file.md"))
    XCTAssertTrue(agentGuide.contains("Do not retry, use another viewer, or install anything."))
    XCTAssertTrue(agentGuide.contains("print the file path"))
    XCTAssertTrue(agentGuide.contains("beside the pane the command runs in (your own pane)"))
    XCTAssertFalse(agentGuide.contains("focused in Rex"))
    XCTAssertFalse(agentGuide.contains("reuse that tab's preview"))
    XCTAssertTrue(agentGuide.contains("`--replace` when updating or revising the same deliverable"))
    XCTAssertTrue(agentGuide.contains("`--new` when the user should compare documents side by side"))
    XCTAssertTrue(agentGuide.contains("When unsure, use no flag."))
  }

  func testGuideRoutesReviewRequestsToTheReviewGuide() {
    XCTAssertTrue(agentGuide.contains("Pick the command by what the user asked, first match:"))
    XCTAssertTrue(agentGuide.contains("run `termdown agent-guide review` and follow it"))
    XCTAssertTrue(agentGuide.contains("`termdown open` does not start a review."))
  }

  func testTheOpenSkillHandsReviewsToTheReviewSkill() {
    XCTAssertTrue(agentStub.contains("use the termdown-review skill instead"))
    XCTAssertFalse(agentStub.contains("runs the interactive review"))
  }

  func testTheReviewSkillCarriesTheStartProcedureItself() {
    XCTAssertTrue(agentReviewStub.hasPrefix("---\nname: termdown-review\ndescription: "))
    XCTAssertEqual(stubVersion(of: agentReviewStub), agentStubVersion)
    XCTAssertTrue(agentReviewStub.contains("review, mark up or send passes"))
    XCTAssertTrue(agentReviewStub.contains("Run `termdown review --check FILE`"))
    XCTAssertTrue(agentReviewStub.contains("Do what `NEXT:` says."))
    XCTAssertTrue(agentReviewStub.contains("`termdown agent-guide review`"))
    XCTAssertTrue(agentReviewStub.contains("do not open a browser review, run review.py"))
    XCTAssertEqual(agentSkillStubs.map(\.name), ["termdown", "termdown-review"])
  }

  func testReviewGuideStartsWithThePreflightAndNamesNothingOutsideTermdown() {
    let guide = reviewGuide()
    XCTAssertTrue(guide.contains("Run `termdown review --check FILE`"))
    XCTAssertTrue(guide.contains("`REVIEW: READY`: run `termdown review FILE`, then end your turn."))
    XCTAssertTrue(guide.contains("Never run a second reviewer, a browser page or a script for the same draft."))
    XCTAssertTrue(guide.contains("`col_to` belongs to `end_line`, not to `line`"))
    XCTAssertFalse(guide.contains("review.py"))
    for hotkey in ReviewHotkeys.load() {
      XCTAssertTrue(guide.contains("- `\(hotkey.type)` (key \(hotkey.key), \(hotkey.label)): "), hotkey.type)
    }
  }

  func testGuideCoversSettingsAndEditing() {
    XCTAssertTrue(
      agentGuide.contains(
        "run `termdown config set editor <command>` (for example `nvim`, `hx`, `code`) or `termdown config set edit-mode split|here`. Run `termdown config` to show the current values. Do not edit config.json."
      ))
    XCTAssertTrue(agentGuide.contains("Do not open editor panes or run `termdown edit` unless the user asks."))
    XCTAssertTrue(
      agentGuide.contains(
        "If a write is refused because the file changed, re-read it and never overwrite the user's saved changes."))
    XCTAssertEqual(agentStubVersion, "3")
  }

  func testGuideTellsAgentsToAskForIDEWhenNotConnected() {
    XCTAssertTrue(agentGuide.contains("run `/ide` and pick the termdown preview"))
    XCTAssertTrue(agentGuide.contains("Never try to connect the session yourself"))
    XCTAssertFalse(agentGuide.contains("so a preview you open sends its highlights to you"))
  }

  func testStubVersionRejectsForeignContent() {
    XCTAssertNil(stubVersion(of: "---\nname: termdown\n---\nbody"))
    XCTAssertNil(stubVersion(of: "no frontmatter"))
  }

  func testInstallWritesBothSkillsOnlyWhereParentExists() throws {
    try makeParent(".claude")
    try makeParent(".cursor")
    let reports = try AgentSkills(home: home).install()
    XCTAssertEqual(
      reports.map(\.skill),
      ["termdown", "termdown-review", "termdown", "termdown-review", "termdown", "termdown-review"])
    XCTAssertEqual(states(reports), [.installed, .installed, .skipped, .skipped, .installed, .installed])
    XCTAssertEqual(try String(contentsOf: skillFile(".claude"), encoding: .utf8), agentStub)
    XCTAssertEqual(try String(contentsOf: skillFile(".claude", "termdown-review"), encoding: .utf8), agentReviewStub)
    XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".agents").path))
  }

  func testInstallIsIdempotent() throws {
    try makeParent(".agents")
    let skills = AgentSkills(home: home)
    _ = try skills.install()
    XCTAssertEqual(states(try skills.install()), [.skipped, .skipped, .current, .current, .skipped, .skipped])
  }

  func testInstallRefusesForeignFile() throws {
    try makeParent(".claude")
    try writeSkill(".claude", "mine", skill: "termdown-review")
    XCTAssertEqual(Array(states(try AgentSkills(home: home).install()).prefix(2)), [.installed, .foreign])
    XCTAssertEqual(try String(contentsOf: skillFile(".claude", "termdown-review"), encoding: .utf8), "mine")
  }

  func testInstallUpgradesAnOutdatedStubAndAddsTheReviewSkill() throws {
    try makeParent(".claude")
    try writeSkill(".claude", outdatedStub)
    let skills = AgentSkills(home: home)
    XCTAssertEqual(Array(states(skills.status()).prefix(2)), [.outdated, .missing])
    XCTAssertEqual(Array(states(try skills.install()).prefix(2)), [.installed, .installed])
    XCTAssertEqual(try String(contentsOf: skillFile(".claude"), encoding: .utf8), agentStub)
  }

  func testStatusStates() throws {
    try makeParent(".claude")
    try makeParent(".agents")
    try makeParent(".cursor")
    let skills = AgentSkills(home: home)
    XCTAssertEqual(Set(states(skills.status())), [.missing])
    _ = try skills.install()
    try writeSkill(".agents", "mine")
    try writeSkill(".cursor", outdatedStub, skill: "termdown-review")
    let reports = skills.status()
    XCTAssertEqual(states(reports), [.current, .current, .foreign, .current, .current, .outdated])
    XCTAssertEqual(agentStatusExitCode(reports), 1)
  }

  func testStatusSkippedWhenNoAgentsInstalled() {
    let reports = AgentSkills(home: home).status()
    XCTAssertEqual(reports.count, 6)
    XCTAssertEqual(Set(states(reports)), [.skipped])
    XCTAssertEqual(agentStatusExitCode(reports), 0)
  }

  func testRemoveDeletesMarkedOnly() throws {
    try makeParent(".claude")
    try makeParent(".agents")
    let skills = AgentSkills(home: home)
    _ = try skills.install()
    try writeSkill(".agents", "mine")
    XCTAssertEqual(states(try skills.remove()), [.missing, .missing, .foreign, .missing, .skipped, .skipped])
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: skillFile(".claude").deletingLastPathComponent().path))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: skillFile(".claude", "termdown-review").deletingLastPathComponent().path))
    XCTAssertEqual(try String(contentsOf: skillFile(".agents"), encoding: .utf8), "mine")
  }

  func testStatusLinesNameDirectoryAndAgents() throws {
    try makeParent(".cursor")
    let lines = agentStatusLines(AgentSkills(home: home).status())
    XCTAssertEqual(lines.count, 6)
    XCTAssertTrue(lines[5].hasPrefix("missing "))
    XCTAssertTrue(lines[4].hasSuffix("/.cursor/skills/termdown (cursor-agent)"))
    XCTAssertTrue(lines[5].hasSuffix("/.cursor/skills/termdown-review (cursor-agent)"))
  }

  func report(_ parent: String, _ state: AgentSkillState, skill: String = "termdown") -> AgentSkillReport {
    let target = agentSkillTargets.first { $0.parent == parent }!
    return AgentSkillReport(
      target: target, skill: skill, state: state,
      directory: home.appendingPathComponent(target.relativeDirectory(skill)))
  }

  func testNamesPickTargets() throws {
    XCTAssertEqual(try agentSkillTargets(named: []).map(\.parent), [".claude", ".agents", ".cursor"])
    XCTAssertEqual(try agentSkillTargets(named: ["cursor", "Claude"]).map(\.parent), [".claude", ".cursor"])
    XCTAssertEqual(try agentSkillTargets(named: ["codex", "pi"]).map(\.parent), [".agents"], "one shared directory")
    XCTAssertEqual(try agentSkillTargets(named: ["claude-code", "cursor-agent", "devin"]).count, 3)
  }

  func testAnUnknownNameIsRefusedAndListsTheNames() {
    XCTAssertThrowsError(try agentSkillTargets(named: ["claude", "vim"])) { error in
      XCTAssertEqual(error as? UnknownAgentName, UnknownAgentName(name: "vim"))
      XCTAssertEqual("\(error)", "unknown agent \"vim\"; use claude, codex, cursor")
    }
  }

  func testInstallingNamedTargetsLeavesTheOthersAlone() throws {
    try makeParent(".claude")
    try makeParent(".cursor")
    let reports = try AgentSkills(home: home, targets: agentSkillTargets(named: ["cursor"])).install()
    XCTAssertEqual(reports.map(\.target.parent), [".cursor", ".cursor"])
    XCTAssertEqual(states(reports), [.installed, .installed])
    XCTAssertFalse(FileManager.default.fileExists(atPath: skillFile(".claude").path))
  }

  func testOfferPendingIsFoundAgentsWithoutTheCurrentSkill() {
    let reports = [report(".claude", .current), report(".agents", .skipped), report(".cursor", .outdated)]
    XCTAssertEqual(agentOfferPending(reports).map(\.target.parent), [".cursor"])
    XCTAssertEqual(agentOfferPending([report(".claude", .missing), report(".agents", .foreign)]).count, 1)
  }

  func testOfferQuestionNamesEachAgentAndWhereItGoes() {
    let question = agentOfferQuestion([
      report(".claude", .outdated), report(".claude", .missing, skill: "termdown-review"),
      report(".cursor", .missing, skill: "termdown-review"),
    ])
    XCTAssertEqual(
      question,
      "Teach these coding agents to use termdown?\n  Claude Code  (~/.claude/skills: termdown, termdown-review)\n"
        + "  cursor-agent  (~/.cursor/skills: termdown-review)\n[Y/n] ")
  }

  func testOfferEnterOrYesInstalls() {
    for answer in ["", "y", "YES", " y "] {
      var installed = false
      let outcome = offerAgentInstall(
        pending: [report(".claude", .missing)], isInteractive: true, ask: { answer }, install: { installed = true })
      XCTAssertEqual(outcome, .installed, answer)
      XCTAssertTrue(installed, answer)
    }
  }

  func testOfferNoOrEndOfInputDeclines() {
    var installed = false
    for answer in ["n", "no", "later", nil] as [String?] {
      XCTAssertEqual(
        offerAgentInstall(
          pending: [report(".claude", .missing)], isInteractive: true, ask: { answer }, install: { installed = true }),
        .declined)
    }
    XCTAssertFalse(installed)
  }

  func testOfferAsksNothingWhenEveryFoundAgentIsCurrent() {
    var asked = false
    let outcome = offerAgentInstall(
      pending: [], isInteractive: true,
      ask: {
        asked = true
        return "y"
      }, install: {})
    XCTAssertEqual(outcome, .upToDate)
    XCTAssertFalse(asked)
  }

  func testOfferNonInteractiveHintsWithoutAsking() {
    var asked = false
    let outcome = offerAgentInstall(
      pending: [report(".claude", .missing)], isInteractive: false,
      ask: {
        asked = true
        return "y"
      }, install: {})
    XCTAssertEqual(outcome, .hint)
    XCTAssertFalse(asked)
  }
}
