import Foundation

/// An agent (a Claude Code session) connected to the viewer's IDE bridge.
public struct ConnectedAgent: Equatable, Sendable {
  /// Stable for the life of the connection; the picker and the choice refer to agents by it.
  public var id: Int
  /// The agent's process, from its `ide_connected` notification. Nil until it sends one.
  public var pid: Int32?
  /// The Rex pane the agent runs in, from its environment's `REX_BLOCK`.
  public var block: String?
  public var session: String?
  /// The pane's title, when Rex reports one.
  public var title: String?

  public init(id: Int, pid: Int32? = nil, block: String? = nil, session: String? = nil, title: String? = nil) {
    self.id = id
    self.pid = pid
    self.block = block
    self.session = session
    self.title = title
  }
}

/// What the person picked in the viewer, overriding the `agent-pairing` default.
public enum AgentChoice: Equatable, Sendable {
  case agent(Int)
  case all
}

public enum AgentRouting {
  /// The agents that receive the selection.
  ///
  /// A choice wins while its agent is connected. Otherwise `opener` sends to the agents in the pane that opened the
  /// viewer, or to every agent when none is there (a viewer opened by clicking a file has no agent opener). `ask`
  /// sends to the only agent, and to none while several wait for the person to pick.
  public static func recipients(
    _ agents: [ConnectedAgent], pairing: AgentPairing, opener: String?, choice: AgentChoice?
  ) -> [Int] {
    let all = agents.map(\.id)
    switch choice {
    case .all: return all
    case .agent(let id) where all.contains(id): return [id]
    default: break
    }
    switch pairing {
    case .all:
      return all
    case .opener:
      let paired = agents.filter { $0.block != nil && $0.block == opener }.map(\.id)
      return paired.isEmpty ? all : paired
    case .ask:
      return all.count <= 1 ? all : []
    }
  }

  /// Whether the viewer should ask which agent gets the selection: `ask` mode, several agents and no live choice.
  public static func needsChoice(_ agents: [ConnectedAgent], pairing: AgentPairing, choice: AgentChoice?) -> Bool {
    guard pairing == .ask, agents.count > 1 else { return false }
    switch choice {
    case .all: return false
    case .agent(let id): return !agents.contains { $0.id == id }
    case nil: return true
    }
  }

  /// The agent a review goes to: the only recipient, while it runs in a Rex pane. An agent connected from outside Rex
  /// has no pane to paste into, so there is none.
  public static func reviewAgent(
    _ agents: [ConnectedAgent], pairing: AgentPairing, opener: String?, choice: AgentChoice?
  ) -> ConnectedAgent? {
    let recipients = recipients(agents, pairing: pairing, opener: opener, choice: choice)
    guard recipients.count == 1, let agent = agents.first(where: { $0.id == recipients[0] }), agent.block != nil
    else { return nil }
    return agent
  }

  /// The pane a review pass is pasted into and entered: the review agent's own, never the opener. A review that
  /// reached the opener could press Enter in a session that is not connected.
  public static func reviewTarget(
    _ agents: [ConnectedAgent], pairing: AgentPairing, opener: String?, choice: AgentChoice?
  ) -> String? {
    reviewAgent(agents, pairing: pairing, opener: opener, choice: choice)?.block
  }

  /// The pane that `a` (ask the agent) pastes into: the only recipient's pane, else the opener.
  public static func askTarget(
    _ agents: [ConnectedAgent], pairing: AgentPairing, opener: String?, choice: AgentChoice?
  ) -> String? {
    let recipients = recipients(agents, pairing: pairing, opener: opener, choice: choice)
    if recipients.count == 1, let block = agents.first(where: { $0.id == recipients[0] })?.block { return block }
    return opener
  }
}

/// Reads another process's environment (same user only) through `KERN_PROCARGS2`.
public enum ProcessEnvironment {
  public static func read(_ pid: Int32) -> [String: String]? {
    var size = 0
    var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
    var argmax: Int32 = 0
    var argmaxSize = MemoryLayout<Int32>.size
    guard sysctl(&mib, 2, &argmax, &argmaxSize, nil, 0) == 0, argmax > 0 else { return nil }
    size = Int(argmax)
    var buffer = [UInt8](repeating: 0, count: size)
    mib = [CTL_KERN, KERN_PROCARGS2, pid]
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
    return parse(Array(buffer.prefix(size)))
  }

  /// `KERN_PROCARGS2` layout: argc (Int32), the executable path, NUL padding, argc arguments, then the environment,
  /// each NUL-terminated, ending at an empty string.
  static func parse(_ bytes: [UInt8]) -> [String: String]? {
    guard bytes.count > 4 else { return nil }
    let argc = bytes.prefix(4).withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
    var index = 4
    while index < bytes.count, bytes[index] != 0 { index += 1 }  // executable path
    while index < bytes.count, bytes[index] == 0 { index += 1 }  // padding
    func next() -> String? {
      guard index < bytes.count else { return nil }
      let start = index
      while index < bytes.count, bytes[index] != 0 { index += 1 }
      defer { index += 1 }
      return String(decoding: bytes[start..<index], as: UTF8.self)
    }
    for _ in 0..<argc { guard next() != nil else { return nil } }
    var environment: [String: String] = [:]
    while let entry = next(), !entry.isEmpty {
      guard let equals = entry.firstIndex(of: "=") else { continue }
      environment[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
    }
    return environment
  }
}
