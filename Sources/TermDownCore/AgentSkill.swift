import Foundation

public let agentStubVersion = "2"
public let agentStubMarkerKey = "termdown-stub"

public let agentStub = """
  ---
  name: termdown
  description: Use when you have written or substantially updated a Markdown file for the user (plan, report, design doc, README), when the user asks to see, open or preview a Markdown file, or when the user asks to review, mark up or send passes on a draft or says "in termdown". Opens it in a Rex preview pane with termdown, and runs the interactive review.
  metadata:
    \(agentStubMarkerKey): "\(agentStubVersion)"
  ---
  <!-- Installed by "termdown agents install". Remove it with "termdown agents remove". -->

  Run `termdown agent-guide` and follow the guide it prints. The guide comes from
  the installed termdown, so it describes the behavior of that version.

  If the command fails, termdown is not available. Mention the file path and continue.

  """

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

  public var relativeDirectory: String { "\(parent)/skills/termdown" }

  public init(agents: String, parent: String) {
    self.agents = agents
    self.parent = parent
  }
}

public let agentSkillTargets = [
  AgentSkillTarget(agents: "Claude Code", parent: ".claude"),
  AgentSkillTarget(agents: "Codex, Pi, OpenCode, Devin CLI", parent: ".agents"),
  AgentSkillTarget(agents: "cursor-agent", parent: ".cursor"),
]

public enum AgentSkillState: String, Sendable, Equatable {
  case installed, current, outdated, missing, skipped, foreign
}

public struct AgentSkillReport: Sendable, Equatable {
  public let target: AgentSkillTarget
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

  public init(home: URL, targets: [AgentSkillTarget] = agentSkillTargets) {
    self.home = home
    self.targets = targets
  }

  private func directory(_ target: AgentSkillTarget) -> URL {
    home.appendingPathComponent(target.relativeDirectory, isDirectory: true)
  }

  private func file(_ target: AgentSkillTarget) -> URL {
    directory(target).appendingPathComponent("SKILL.md")
  }

  private func parentExists(_ target: AgentSkillTarget) -> Bool {
    var isDirectory: ObjCBool = false
    let path = home.appendingPathComponent(target.parent).path
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }

  private func classify(_ target: AgentSkillTarget) -> AgentSkillState {
    guard parentExists(target) else { return .skipped }
    guard let data = try? Data(contentsOf: file(target)) else {
      return FileManager.default.fileExists(atPath: directory(target).path) ? .foreign : .missing
    }
    guard let version = stubVersion(of: String(decoding: data, as: UTF8.self)) else {
      return .foreign
    }
    return version == agentStubVersion ? .current : .outdated
  }

  public func status() -> [AgentSkillReport] {
    targets.map { AgentSkillReport(target: $0, state: classify($0), directory: directory($0)) }
  }

  public func install() throws -> [AgentSkillReport] {
    try targets.map { target in
      var state = classify(target)
      if state == .missing || state == .outdated {
        try FileManager.default.createDirectory(
          at: directory(target), withIntermediateDirectories: true)
        try Data(agentStub.utf8).write(to: file(target), options: .atomic)
        state = .installed
      }
      return AgentSkillReport(target: target, state: state, directory: directory(target))
    }
  }

  public func remove() throws -> [AgentSkillReport] {
    try targets.map { target in
      var state = classify(target)
      if state == .current || state == .outdated {
        try FileManager.default.removeItem(at: directory(target))
        state = .missing
      }
      return AgentSkillReport(target: target, state: state, directory: directory(target))
    }
  }
}

public enum AgentOfferOutcome: Equatable, Sendable {
  case installed
  case declined
  case hint
}

public func offerAgentInstall(
  isInteractive: Bool, ask: () -> String?, install: () -> Void
) -> AgentOfferOutcome {
  guard isInteractive else { return .hint }
  let answer = ask()?.trimmingCharacters(in: .whitespaces).lowercased()
  guard answer == "y" || answer == "yes" else { return .declined }
  install()
  return .installed
}

public func agentStatusLines(_ reports: [AgentSkillReport]) -> [String] {
  reports.map { "\($0.state.rawValue) \($0.directory.path) (\($0.target.agents))" }
}

public func agentStatusExitCode(_ reports: [AgentSkillReport]) -> Int32 {
  reports.contains { $0.state == .outdated || $0.state == .foreign } ? 1 : 0
}
