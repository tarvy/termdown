import Foundation

public let agentStubVersion = "3"
public let agentStubMarkerKey = "termdown-stub"

public let agentStub = """
  ---
  name: termdown
  description: Use when you have written or substantially updated a Markdown file for the user (plan, report, design doc, README), or when the user asks to see, open or preview a Markdown file. Opens it in a Rex preview pane with termdown. To review, mark up or send passes on a draft, use the termdown-review skill instead.
  metadata:
    \(agentStubMarkerKey): "\(agentStubVersion)"
  ---
  <!-- Installed by "termdown agents install". Remove it with "termdown agents remove". -->

  Run `termdown agent-guide` and follow the guide it prints. The guide comes from
  the installed termdown, so it describes the behavior of that version.

  If the command fails, termdown is not available. Mention the file path and continue.

  """

/// The review skill. Its body is the procedure itself, so starting a review needs no routing through the guide.
public let agentReviewStub = """
  ---
  name: termdown-review
  description: Use when the user asks to review, mark up or send passes on a Markdown draft in TermDown, says "review in termdown", or sends a message starting `Review pass`. Opens the draft for interactive review in a Rex preview pane and applies each pass the user sends. TermDown is the reviewer here, not a browser page.
  metadata:
    \(agentStubMarkerKey): "\(agentStubVersion)"
  ---
  <!-- Installed by "termdown agents install". Remove it with "termdown agents remove". -->

  FILE is the draft: the path given with this skill, or the Markdown draft you just wrote for the user.

  To start a review:
  1. Run `termdown review --check FILE`. It prints `REVIEW:` and `NEXT:` lines. Do what `NEXT:` says.
  2. After `termdown review FILE`, tell the user in one line that the draft is open for review in TermDown, then
     end your turn. Each pass arrives later as a message.

  To apply a pass (a message starting `Review pass N on @<draft>`), and for what each mark asks for, run
  `termdown agent-guide review` and follow it.

  TermDown is the only reviewer for this draft: do not open a browser review, run review.py, or start another
  reviewer. If termdown is not installed or a command fails, tell the user and give the file path.

  """

/// A skill `termdown agents install` writes into each agent's skills directory.
public struct AgentSkillStub: Sendable, Equatable {
  public let name: String
  public let content: String
}

public let agentSkillStubs = [
  AgentSkillStub(name: "termdown", content: agentStub),
  AgentSkillStub(name: "termdown-review", content: agentReviewStub),
]

public let agentGuide = """
  termdown opens Markdown files in a Rex preview pane. Pick the command by what the user asked, first match:
  - "review", "mark up", "send passes", "interactive review", or a message starting `Review pass`: run `termdown agent-guide review` and follow it. TermDown is the only reviewer; never start another one.
  - "open", "show", "preview", or you just wrote a deliverable: `termdown open FILE`, below.
  - "pair", "connect", highlights not arriving: see Pairing with agents, below.

  When to open a preview:
  - After writing or substantially updating a Markdown file meant for the user: plans, reports, design docs, READMEs.
  - When the user asks to see or open a .md file.

  When not to:
  - Files you only read or lightly edit, scratch notes, or bulk opens. Open one preview per deliverable.

  How:
  - Run `termdown open /absolute/path/to/file.md`.
  - The preview opens without taking focus: the tab's first preview beside the pane the command runs in (your own pane), later ones below the newest preview. A file that is already shown reuses its preview.
  - Add `--replace` when updating or revising the same deliverable, so the preview you opened last switches to it instead of a new pane opening.
  - Add `--new` when the user should compare documents side by side, so each one opens in its own pane.
  - When unsure, use no flag.
  - Always also print the file path in your reply.

  Editing:
  - Settings: when the user asks to change the editor termdown opens or how it opens, run `termdown config set editor <command>` (for example `nvim`, `hx`, `code`) or `termdown config set edit-mode split|here`. Run `termdown config` to show the current values. Do not edit config.json.
  - Do not open editor panes or run `termdown edit` unless the user asks.
  - The user may be editing a file in an editor beside its preview. If a write is refused because the file changed, re-read it and never overwrite the user's saved changes.

  Reviewing a draft:
  - Run `termdown agent-guide review` for the whole procedure: the `termdown review --check FILE` preflight, starting the review, and applying each pass. Do not run it for files the user did not ask to review.
  - `termdown open` does not start a review. Only `termdown review FILE` does, and the preview only sends passes once it is in review mode.

  Pairing with agents:
  - Each preview is an IDE that Claude Code can connect to; text the user highlights in it reaches the agents it is paired with. By default a preview pairs with the agent in the pane that opened it, but only once that session is connected to it. Claude Code connects when a session starts (`termdown claude`) or when the user runs `/ide`; a session that was already running when the preview opened stays unconnected.
  - After `termdown open`, if your session isn't connected to a termdown preview (it wasn't started by `termdown claude` and didn't connect through `/ide`), tell the user once, next to the file path: "To send highlights from the preview to this session, run `/ide` and pick the termdown preview." Say the same if a preview you were connected to has closed. Never try to connect the session yourself.
  - When the user wants a Claude Code session tied to one preview, suggest `termdown claude <file>` in a Rex pane: it opens the preview beside the pane and starts Claude Code connected to that preview only.
  - When the user asks to change which agent gets a preview's highlights, tell them to press A in the preview, or run Select agent from Rex's command palette (Cmd-Shift-P). `termdown config set agent-pairing opener|all|ask` changes the default.

  If the command fails, or termdown or Rex is unavailable, mention the file path and continue. Do not retry, use another viewer, or install anything.

  """

public struct AgentSkillTarget: Sendable, Equatable {
  public let agents: String
  public let parent: String
  /// What `termdown agents install NAME` accepts for this directory, first the name usage shows.
  public let names: [String]

  public func relativeDirectory(_ skill: String) -> String { "\(parent)/skills/\(skill)" }

  public init(agents: String, parent: String, names: [String] = []) {
    self.agents = agents
    self.parent = parent
    self.names = names
  }
}

public let agentSkillTargets = [
  AgentSkillTarget(agents: "Claude Code", parent: ".claude", names: ["claude", "claude-code"]),
  AgentSkillTarget(
    agents: "Codex, Pi, OpenCode, Devin CLI", parent: ".agents",
    names: ["codex", "pi", "opencode", "devin", "agents"]),
  AgentSkillTarget(agents: "cursor-agent", parent: ".cursor", names: ["cursor", "cursor-agent"]),
]

/// A name `termdown agents` does not know.
public struct UnknownAgentName: Error, Equatable, CustomStringConvertible {
  public let name: String
  public var description: String {
    "unknown agent \"\(name)\"; use \(agentSkillTargets.compactMap(\.names.first).joined(separator: ", "))"
  }
}

/// The targets the names pick, in the usual order, or every target when there are no names. Codex, Pi, OpenCode and
/// Devin CLI share one directory, so naming any of them picks it.
public func agentSkillTargets(named names: [String]) throws -> [AgentSkillTarget] {
  guard !names.isEmpty else { return agentSkillTargets }
  var picked = Set<String>()
  for name in names {
    guard let target = agentSkillTargets.first(where: { $0.names.contains(name.lowercased()) }) else {
      throw UnknownAgentName(name: name)
    }
    picked.insert(target.parent)
  }
  return agentSkillTargets.filter { picked.contains($0.parent) }
}

public enum AgentSkillState: String, Sendable, Equatable {
  case installed, current, outdated, missing, skipped, foreign
}

public struct AgentSkillReport: Sendable, Equatable {
  public let target: AgentSkillTarget
  public let skill: String
  public let state: AgentSkillState
  public let directory: URL
}

public func stubVersion(of content: String) -> String? {
  guard content.hasPrefix("---\n"), let end = content.range(of: "\n---\n") else { return nil }
  let frontmatter = content[content.startIndex..<end.lowerBound]
  let quotes = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'"))
  for line in frontmatter.split(separator: "\n") {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("\(agentStubMarkerKey):") else { continue }
    return trimmed.dropFirst(agentStubMarkerKey.count + 1).trimmingCharacters(in: quotes)
  }
  return nil
}

public struct AgentSkills: Sendable {
  public let home: URL
  public let targets: [AgentSkillTarget]
  public let stubs: [AgentSkillStub]

  public init(
    home: URL, targets: [AgentSkillTarget] = agentSkillTargets, stubs: [AgentSkillStub] = agentSkillStubs
  ) {
    self.home = home
    self.targets = targets
    self.stubs = stubs
  }

  private func directory(_ target: AgentSkillTarget, _ stub: AgentSkillStub) -> URL {
    home.appendingPathComponent(target.relativeDirectory(stub.name), isDirectory: true)
  }

  private func file(_ target: AgentSkillTarget, _ stub: AgentSkillStub) -> URL {
    directory(target, stub).appendingPathComponent("SKILL.md")
  }

  private func parentExists(_ target: AgentSkillTarget) -> Bool {
    var isDirectory: ObjCBool = false
    let path = home.appendingPathComponent(target.parent).path
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }

  private func classify(_ target: AgentSkillTarget, _ stub: AgentSkillStub) -> AgentSkillState {
    guard parentExists(target) else { return .skipped }
    guard let data = try? Data(contentsOf: file(target, stub)) else {
      return FileManager.default.fileExists(atPath: directory(target, stub).path) ? .foreign : .missing
    }
    guard let version = stubVersion(of: String(decoding: data, as: UTF8.self)) else {
      return .foreign
    }
    return version == agentStubVersion ? .current : .outdated
  }

  /// Every (agent directory, skill) pair, agent by agent.
  private func each(_ body: (AgentSkillTarget, AgentSkillStub) throws -> AgentSkillState) rethrows
    -> [AgentSkillReport]
  {
    try targets.flatMap { target in
      try stubs.map { stub in
        AgentSkillReport(
          target: target, skill: stub.name, state: try body(target, stub), directory: directory(target, stub))
      }
    }
  }

  public func status() -> [AgentSkillReport] {
    each { target, stub in classify(target, stub) }
  }

  public func install() throws -> [AgentSkillReport] {
    try each { target, stub in
      let state = classify(target, stub)
      guard state == .missing || state == .outdated else { return state }
      try FileManager.default.createDirectory(at: directory(target, stub), withIntermediateDirectories: true)
      try Data(stub.content.utf8).write(to: file(target, stub), options: .atomic)
      return .installed
    }
  }

  public func remove() throws -> [AgentSkillReport] {
    try each { target, stub in
      let state = classify(target, stub)
      guard state == .current || state == .outdated else { return state }
      try FileManager.default.removeItem(at: directory(target, stub))
      return .missing
    }
  }
}

public enum AgentOfferOutcome: Equatable, Sendable {
  case installed
  case declined
  case hint
  /// Every agent found already has the current skill, or none was found: nothing was asked.
  case upToDate
}

/// The reports `termdown setup` offers to install: agents found on this Mac whose skill is missing or outdated.
public func agentOfferPending(_ reports: [AgentSkillReport]) -> [AgentSkillReport] {
  reports.filter { $0.state == .missing || $0.state == .outdated }
}

/// The setup question, naming each agent it would teach and the skills it would write there. Enter means yes.
public func agentOfferQuestion(_ pending: [AgentSkillReport]) -> String {
  var order: [String] = []
  var grouped: [String: (target: AgentSkillTarget, skills: [String])] = [:]
  for report in pending {
    if grouped[report.target.parent] == nil { order.append(report.target.parent) }
    grouped[report.target.parent, default: (report.target, [])].skills.append(report.skill)
  }
  let lines = order.compactMap { grouped[$0] }.map { group in
    "  \(group.target.agents)  (~/\(group.target.parent)/skills: \(group.skills.joined(separator: ", ")))"
  }
  return "Teach these coding agents to use termdown?\n" + lines.joined(separator: "\n") + "\n[Y/n] "
}

/// Offers the skill to the agents in `pending`. Enter or yes installs; no, anything else or end of input declines.
public func offerAgentInstall(
  pending: [AgentSkillReport], isInteractive: Bool, ask: () -> String?, install: () -> Void
) -> AgentOfferOutcome {
  guard !pending.isEmpty else { return .upToDate }
  guard isInteractive else { return .hint }
  guard let answer = ask()?.trimmingCharacters(in: .whitespaces).lowercased(),
    ["", "y", "yes"].contains(answer)
  else { return .declined }
  install()
  return .installed
}

public func agentStatusLines(_ reports: [AgentSkillReport]) -> [String] {
  reports.map { "\($0.state.rawValue) \($0.directory.path) (\($0.target.agents))" }
}

public func agentStatusExitCode(_ reports: [AgentSkillReport]) -> Int32 {
  reports.contains { $0.state == .outdated || $0.state == .foreign } ? 1 : 0
}
