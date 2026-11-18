import Foundation
import TermDownCore
import Network

/// What the viewer has selected, in the shape Claude Code's IDE protocol expects: 0-based lines, UTF-8 byte
/// columns, exclusive end. An empty selection is a caret.
public struct IDESelection: Equatable, Sendable {
  public var filePath: String
  public var text: String
  public var startLine: Int
  public var startCharacter: Int
  public var endLine: Int
  public var endCharacter: Int

  public init(filePath: String, text: String, startLine: Int, startCharacter: Int, endLine: Int, endCharacter: Int) {
    self.filePath = filePath
    self.text = text
    self.startLine = startLine
    self.startCharacter = startCharacter
    self.endLine = endLine
    self.endCharacter = endCharacter
  }

  public var isEmpty: Bool { startLine == endLine && startCharacter == endCharacter }

  var json: [String: Any] {
    [
      "text": text, "filePath": filePath, "fileUrl": URL(fileURLWithPath: filePath).absoluteString,
      "selection": [
        "start": ["line": startLine, "character": startCharacter],
        "end": ["line": endLine, "character": endCharacter],
        "isEmpty": isEmpty,
      ],
    ]
  }
}

/// Makes termdown an IDE that Claude Code's `/ide` can connect to: a localhost WebSocket MCP server announced
/// by a lock file in ~/.claude/ide, pushing `selection_changed` as the person selects text.
public final class IDEBridge: @unchecked Sendable {
  public static let ideName = "termdown"
  /// What Claude Code's `/ide` picker shows for this viewer: the product name and the open file, so several
  /// viewers can be told apart.
  public let displayName: String

  private let queue = DispatchQueue(label: "termdown.ide")
  private let token: String
  private let workspaceFolders: [String]
  private let log: @Sendable (String) -> Void
  private var listener: NWListener?
  private var connections: [ObjectIdentifier: NWConnection] = [:]
  private var agents: [ObjectIdentifier: ConnectedAgent] = [:]
  private var nextAgentID = 1
  private let pairing: AgentPairing
  private let rex: RexPlacement
  private var choice: AgentChoice?
  private var lockURL: URL?
  private var latest: IDESelection?
  private var keepalive: DispatchSourceTimer?

  /// Where the viewer runs in Rex and which pane opened it; written to the lock file so `termdown claude` can find
  /// the viewer its pane opened, and used to pair with the opener's agent.
  public struct RexPlacement: Equatable, Sendable {
    public var session: String?
    public var block: String?
    public var opener: String?

    public init(session: String? = nil, block: String? = nil, opener: String? = nil) {
      self.session = session
      self.block = block
      self.opener = opener
    }
  }

  /// Called on the main queue when an agent connects, identifies itself or leaves.
  public var onAgentsChanged: (@Sendable () -> Void)?

  public init(
    workspaceFolders: [String], file: URL? = nil, pairing: AgentPairing = .opener, rex: RexPlacement = RexPlacement(),
    log: @escaping @Sendable (String) -> Void = { _ in }
  ) {
    self.pairing = pairing
    self.rex = rex
    displayName = file.map { "\(Self.ideName): \($0.lastPathComponent)" } ?? Self.ideName
    var bytes = [UInt8](repeating: 0, count: 16)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    token = bytes.map { String(format: "%02x", $0) }.joined()
    var seen = Set<String>()
    self.workspaceFolders = workspaceFolders.filter { !$0.isEmpty && seen.insert($0).inserted }
    self.log = log
  }

  /// The lock file directory: $CLAUDE_CONFIG_DIR/ide or ~/.claude/ide.
  public static var lockDirectory: URL {
    if let config = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !config.isEmpty {
      return URL(fileURLWithPath: config).appendingPathComponent("ide", isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/ide", isDirectory: true)
  }

  // MARK: Lifecycle

  public func start() {
    queue.async { [self] in
      removeStaleLocks()
      let options = NWProtocolWebSocket.Options()
      options.autoReplyPing = true
      options.setClientRequestHandler(queue) { [token] subprotocols, headers in
        let supplied = headers.first { $0.name.lowercased() == "x-claude-code-ide-authorization" }?.value ?? ""
        let accepted = Self.constantTimeEqual(supplied, token)
        // Claude Code asks for a subprotocol and its client refuses a reply that does not echo one.
        let subprotocol = subprotocols.first
        return NWProtocolWebSocket.Response(status: accepted ? .accept : .reject, subprotocol: subprotocol)
      }
      let parameters = NWParameters.tcp
      parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
      parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
      parameters.acceptLocalOnly = true
      do {
        let listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
          guard let self else { return }
          switch state {
          case .ready:
            if let port = listener.port?.rawValue { self.writeLock(port: Int(port)) }
          case .failed(let error):
            self.log("ide: listener failed: \(error)")
          default: break
          }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        self.listener = listener
        startKeepalive()
      } catch {
        log("ide: could not listen: \(error)")
      }
    }
  }

  /// Removes the lock file and closes connections. Safe to call more than once, from any thread.
  public func stop() {
    queue.sync {
      if let lockURL { try? FileManager.default.removeItem(at: lockURL) }
      lockURL = nil
      keepalive?.cancel()
      keepalive = nil
      for connection in connections.values { connection.cancel() }
      connections = [:]
      agents = [:]
      listener?.cancel()
      listener = nil
    }
  }

  /// Sends the selection to the agents it is routed to when it changed.
  public func update(_ selection: IDESelection?) {
    queue.async { [self] in
      guard let selection, selection != latest else { return }
      latest = selection
      broadcast(["jsonrpc": "2.0", "method": "selection_changed", "params": selection.json])
    }
  }

  /// The listening port, once the lock file is written.
  public var port: Int? { queue.sync { listener?.port.map { Int($0.rawValue) } } }

  /// The connected agents, oldest first, and the ones the selection goes to.
  public func agentState() -> (agents: [ConnectedAgent], recipients: [Int], choice: AgentChoice?) {
    queue.sync {
      let list = orderedAgents
      return (list, AgentRouting.recipients(list, pairing: pairing, opener: rex.opener, choice: choice), choice)
    }
  }

  /// Whether the person should be asked which agent gets the selection (`agent-pairing ask`).
  public var needsChoice: Bool {
    queue.sync { AgentRouting.needsChoice(orderedAgents, pairing: pairing, choice: choice) }
  }

  /// The pane `a` pastes into: the chosen or paired agent's, else the opener.
  public var askTarget: String? {
    queue.sync { AgentRouting.askTarget(orderedAgents, pairing: pairing, opener: rex.opener, choice: choice) }
  }

  /// The pane a review pass goes to: the single recipient's own Rex pane, never the opener. Nil when the selection goes
  /// to several agents or to one outside Rex.
  public var reviewTarget: String? { reviewAgent?.block }

  /// The agent a review goes to: the single recipient, while it runs in a Rex pane.
  public var reviewAgent: ConnectedAgent? {
    queue.sync { AgentRouting.reviewAgent(orderedAgents, pairing: pairing, opener: rex.opener, choice: choice) }
  }

  /// Routes the selection to the chosen agent (or all of them), and sends the current selection to it.
  public func choose(_ choice: AgentChoice?) {
    queue.async { [self] in
      self.choice = choice
      if let latest { broadcast(["jsonrpc": "2.0", "method": "selection_changed", "params": latest.json]) }
    }
  }

  /// Agents a test stands in for without a socket.
  var standIns: [ConnectedAgent] = []

  private var orderedAgents: [ConnectedAgent] { (Array(agents.values) + standIns).sorted { $0.id < $1.id } }

  private var recipientKeys: [ObjectIdentifier] {
    let ids = Set(AgentRouting.recipients(orderedAgents, pairing: pairing, opener: rex.opener, choice: choice))
    return agents.filter { ids.contains($0.value.id) }.map(\.key)
  }

  private func agentsChanged() {
    guard let onAgentsChanged else { return }
    DispatchQueue.main.async { onAgentsChanged() }
  }

  // MARK: Lock file

  private func writeLock(port: Int) {
    let manager = FileManager.default
    let directory = Self.lockDirectory
    try? manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let url = directory.appendingPathComponent("\(port).lock")
    var body: [String: Any] = [
      "pid": Int(ProcessInfo.processInfo.processIdentifier), "workspaceFolders": workspaceFolders,
      "ideName": displayName, "transport": "ws", "runningInWindows": false, "authToken": token,
    ]
    if let session = rex.session { body[ViewerLocks.sessionKey] = session }
    if let block = rex.block { body[ViewerLocks.blockKey] = block }
    if let opener = rex.opener { body[ViewerLocks.openerKey] = opener }
    guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else { return }
    let temporary = directory.appendingPathComponent("\(port).lock.tmp.\(ProcessInfo.processInfo.processIdentifier)")
    guard manager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
      return
    }
    if rename(temporary.path, url.path) == 0 {
      lockURL = url
      log("ide: listening on \(port) for \(workspaceFolders.joined(separator: ", "))")
    }
  }

  /// Lock files of termdowns that are no longer running.
  private func removeStaleLocks() {
    let manager = FileManager.default
    guard let names = try? manager.contentsOfDirectory(atPath: Self.lockDirectory.path) else { return }
    for name in names where name.hasSuffix(".lock") {
      let url = Self.lockDirectory.appendingPathComponent(name)
      guard let data = try? Data(contentsOf: url),
        let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        (body["ideName"] as? String)?.hasPrefix(Self.ideName) == true, let pid = body["pid"] as? Int
      else { continue }
      if kill(pid_t(pid), 0) != 0 && errno == ESRCH { try? manager.removeItem(at: url) }
    }
  }

  // MARK: Connections

  private func accept(_ connection: NWConnection) {
    let key = ObjectIdentifier(connection)
    connections[key] = connection
    agents[key] = ConnectedAgent(id: nextAgentID)
    nextAgentID += 1
    connection.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      switch state {
      case .ready:
        self.log("ide: Claude Code connected")
      case .failed, .cancelled:
        self.connections[key] = nil
        if self.agents.removeValue(forKey: key) != nil { self.agentsChanged() }
      default: break
      }
    }
    connection.start(queue: queue)
    receive(on: connection)
  }

  private func receive(on connection: NWConnection) {
    connection.receiveMessage { [weak self] data, context, _, error in
      guard let self else { return }
      if let error {
        self.log("ide: receive failed: \(error)")
        connection.cancel()
        return
      }
      let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
      if metadata?.opcode == .close {
        connection.cancel()
        return
      }
      if let data, !data.isEmpty, metadata?.opcode == .text { self.handle(data, on: connection) }
      self.receive(on: connection)
    }
  }

  private func handle(_ data: Data, on connection: NWConnection) {
    guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]], on: connection)
    }
    let method = message["method"] as? String ?? ""
    guard let id = message["id"], !(id is NSNull) else {
      // A notification (notifications/initialized, ide_connected): nothing to answer. `ide_connected` names the
      // agent's process, whose environment says which Rex pane it runs in. Then send what is selected now.
      let key = ObjectIdentifier(connection)
      if method == "ide_connected", let pid = ((message["params"] as? [String: Any])?["pid"] as? NSNumber)?.int32Value {
        let environment = ProcessEnvironment.read(pid)
        agents[key]?.pid = pid
        agents[key]?.block = environment?["REX_BLOCK"].flatMap { $0.isEmpty ? nil : $0 }
        agents[key]?.session = environment?["REX_SESSION"].flatMap { $0.isEmpty ? nil : $0 }
        log("ide: agent \(pid) in \(agents[key]?.block ?? "no Rex pane")")
        agentsChanged()
      }
      if method == "notifications/initialized" || method == "ide_connected", let latest, recipientKeys.contains(key) {
        send(["jsonrpc": "2.0", "method": "selection_changed", "params": latest.json], on: connection)
      }
      return
    }
    let params = message["params"] as? [String: Any] ?? [:]
    switch method {
    case "initialize":
      reply(id, result: [
        "protocolVersion": "2024-11-05",
        "capabilities": ["logging": [String: Any](), "prompts": ["listChanged": true], "tools": ["listChanged": true]],
        "serverInfo": ["name": "termdown", "version": "1.0.0"],
      ], on: connection)
    case "tools/list":
      reply(id, result: ["tools": Self.tools], on: connection)
    case "prompts/list":
      reply(id, result: ["prompts": [Any]()], on: connection)
    case "tools/call":
      let name = params["name"] as? String ?? ""
      if let result = Self.diffToolResult(name) { return reply(id, result: result, on: connection) }
      guard let text = toolResult(name) else {
        return send(
          ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found", "data": "Unknown tool: \(name)"]],
          on: connection)
      }
      reply(id, result: ["content": [["type": "text", "text": text]]], on: connection)
    default:
      send(
        ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found", "data": "Unknown method: \(method)"]],
        on: connection)
    }
  }

  private static var tools: [[String: Any]] { [
    ("getCurrentSelection", "The text selected in termdown, with its file and lines"),
    ("getLatestSelection", "The most recent selection in termdown"),
    ("getOpenEditors", "The file termdown is showing"),
    ("getWorkspaceFolders", "The folders termdown was opened for"),
  ].map { name, description in
    ["name": name, "description": description, "inputSchema": ["type": "object", "properties": [String: Any]()]]
  } + diffTools }

  /// The diff tools as the Claude Code extension declares them.
  private static var diffTools: [[String: Any]] {
    let path = "Path to the file to show diff for. If not provided, uses active editor."
    let contents = "Contents of the new file. If not provided then the current file contents of new_file_path will be used."
    func string(_ description: String?) -> [String: Any] {
      description.map { ["type": "string", "description": $0] } ?? ["type": "string"]
    }
    return [
      [
        "name": "openDiff", "description": "Open a git diff for the file",
        "inputSchema": [
          "type": "object",
          "properties": [
            "old_file_path": string(path), "new_file_path": string(path), "new_file_contents": string(contents),
            "tab_name": string(path),
          ],
          "required": ["old_file_path", "new_file_path", "new_file_contents", "tab_name"],
        ],
      ],
      ["name": "close_tab", "inputSchema": ["type": "object", "properties": ["tab_name": string(nil)], "required": ["tab_name"]]],
      [
        "name": "closeAllDiffTabs", "description": "Close all diff tabs in the editor",
        "inputSchema": ["type": "object", "properties": [String: Any]()],
      ],
    ]
  }

  /// Claude Code shows an edit's diff in the IDE as its permission prompt, racing the terminal prompt: FILE_SAVED or
  /// TAB_CLOSED approves the edit and DIFF_REJECTED denies it. termdown has no diff view to ask the person in, so
  /// openDiff fails and the terminal prompt keeps the decision; a write that is approved there reaches an unsaved
  /// edit through the file watcher's merge.
  static func diffToolResult(_ name: String) -> [String: Any]? {
    switch name {
    case "openDiff":
      return ["content": [["type": "text", "text": "termdown has no diff view; approve or reject the edit in Claude Code"]], "isError": true]
    case "close_tab":
      return ["content": [["type": "text", "text": "TAB_CLOSED"]]]
    case "closeAllDiffTabs":
      return ["content": [["type": "text", "text": "CLOSED_0_DIFF_TABS"]]]
    default:
      return nil
    }
  }

  private func toolResult(_ name: String) -> String? {
    let body: [String: Any]
    switch name {
    case "getCurrentSelection", "getLatestSelection":
      guard let latest else { return #"{"success":false,"message":"No selection"}"# }
      var json = latest.json
      json["success"] = true
      body = json
    case "getOpenEditors":
      guard let latest else { return #"{"tabs":[]}"# }
      let url = URL(fileURLWithPath: latest.filePath)
      body = ["tabs": [["uri": url.absoluteString, "isActive": true, "label": url.lastPathComponent, "languageId": "markdown", "isDirty": false]]]
    case "getWorkspaceFolders":
      body = [
        "success": true, "rootPath": workspaceFolders.first ?? "",
        "folders": workspaceFolders.map {
          ["name": URL(fileURLWithPath: $0).lastPathComponent, "uri": URL(fileURLWithPath: $0).absoluteString, "path": $0]
        },
      ]
    default:
      return nil
    }
    guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
    return String(decoding: data, as: UTF8.self)
  }

  private func reply(_ id: Any, result: [String: Any], on connection: NWConnection) {
    send(["jsonrpc": "2.0", "id": id, "result": result], on: connection)
  }

  /// Sends to the agents the selection is routed to.
  private func broadcast(_ message: [String: Any]) {
    for key in recipientKeys { if let connection = connections[key] { send(message, on: connection) } }
  }

  private func send(_ message: [String: Any], on connection: NWConnection) {
    guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
    let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
    let context = NWConnection.ContentContext(identifier: "message", metadata: [metadata])
    connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
  }

  private func startKeepalive() {
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + 30, repeating: 30)
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      let metadata = NWProtocolWebSocket.Metadata(opcode: .ping)
      let context = NWConnection.ContentContext(identifier: "ping", metadata: [metadata])
      for connection in self.connections.values {
        connection.send(content: Data(), contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
      }
    }
    timer.resume()
    keepalive = timer
  }

  static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
    let a = Array(lhs.utf8)
    let b = Array(rhs.utf8)
    guard a.count == b.count, a.count >= 10 else { return false }
    var difference: UInt8 = 0
    for index in a.indices { difference |= a[index] ^ b[index] }
    return difference == 0
  }
}

extension IDEBridge {
  /// Folders to announce: the opener pane's directory (where Claude Code runs), the directory the preview was started
  /// in, and the git roots above the file. The start directory covers a preview launched without `termdown open`, so
  /// the session that started it can still attach; `/` and home are left out because they would match every session.
  public static func workspaceFolders(file: URL, openerDirectory: String?, launchDirectory: String? = nil) -> [String] {
    var folders: [String] = []
    if let openerDirectory { folders.append(trueCase(openerDirectory)) }
    if let launchDirectory {
      let path = URL(fileURLWithPath: launchDirectory).standardizedFileURL.path
      let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
      if path != "/" && trueCase(path) != trueCase(home) { folders.append(trueCase(path)) }
    }
    var directory = file.deletingLastPathComponent().standardizedFileURL
    var roots: [String] = []
    while directory.path != "/" {
      if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) {
        roots.append(trueCase(directory.path))
      }
      directory = directory.deletingLastPathComponent()
    }
    // Outermost repository first: a nested store inside a vault still matches a session at the vault root.
    folders += roots.reversed()
    folders.append(trueCase(file.deletingLastPathComponent().path))
    return folders
  }

  /// A path with each component spelled as it is on disk (Rex can report a different case on macOS).
  static func trueCase(_ path: String) -> String {
    var result = "/"
    for component in path.split(separator: "/").map(String.init) {
      let names = (try? FileManager.default.contentsOfDirectory(atPath: result)) ?? []
      let match = names.first { $0 == component } ?? names.first { $0.lowercased() == component.lowercased() } ?? component
      result = (result as NSString).appendingPathComponent(match)
    }
    return result
  }
}
