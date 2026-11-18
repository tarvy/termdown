import Foundation
import TermDownCore
import XCTest

@testable import TermDownHost

/// Connects to the bridge the way Claude Code does: lock file, auth header, MCP over WebSocket.
final class IDEBridgeTests: XCTestCase {
  func testClaudeCodeCanConnectAndSeeTheSelection() async throws {
    let config = FileManager.default.temporaryDirectory.appendingPathComponent("ide-\(UUID().uuidString)")
    setenv("CLAUDE_CONFIG_DIR", config.path, 1)
    defer { unsetenv("CLAUDE_CONFIG_DIR") }
    let bridge = IDEBridge(workspaceFolders: ["/tmp/vault"], file: URL(fileURLWithPath: "/tmp/vault/plan.md"))
    bridge.start()
    defer { bridge.stop() }
    let directory = config.appendingPathComponent("ide")
    var lock: [String: Any]?
    var port = 0
    for _ in 0..<50 {
      if let name = try? FileManager.default.contentsOfDirectory(atPath: directory.path).first(where: { $0.hasSuffix(".lock") }),
        let data = try? Data(contentsOf: directory.appendingPathComponent(name))
      {
        lock = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        port = Int(name.dropLast(5)) ?? 0
        break
      }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    let body = try XCTUnwrap(lock)
    XCTAssertEqual(body["ideName"] as? String, "termdown: plan.md", "the /ide picker names the open file")
    XCTAssertEqual(body["transport"] as? String, "ws")
    XCTAssertEqual(body["workspaceFolders"] as? [String], ["/tmp/vault"])
    let token = try XCTUnwrap(body["authToken"] as? String)
    XCTAssertEqual(token.count, 32)
    let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("\(port).lock").path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

    // A wrong token is refused at the upgrade; the right one is switched to WebSocket.
    func upgrade(_ value: String, protocols: String? = nil) -> String {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
      process.arguments = [
        "-s", "-i", "-N", "--max-time", "2", "--http1.1", "-H", "Connection: Upgrade", "-H", "Upgrade: websocket",
        "-H", "Sec-WebSocket-Version: 13", "-H", "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
        "-H", "x-claude-code-ide-authorization: \(value)", "http://127.0.0.1:\(port)/",
      ]
      if let protocols { process.arguments! += ["-H", "Sec-WebSocket-Protocol: \(protocols)"] }
      let pipe = Pipe()
      process.standardOutput = pipe
      try? process.run()
      process.waitUntilExit()
      let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      return output.split(separator: "\r\n\r\n").first.map(String.init) ?? ""
    }
    func upgradeStatus(_ value: String) -> String { upgrade(value).split(separator: "\r\n").first.map(String.init) ?? "" }
    XCTAssertFalse(upgradeStatus("not-the-token-at-all").contains("101"), "a wrong token is not upgraded")
    XCTAssertTrue(upgradeStatus(token).contains("101"), "the right token is upgraded")
    let echoed = upgrade(token, protocols: "mcp, other").lowercased()
    XCTAssertTrue(echoed.contains("sec-websocket-protocol: mcp"), "Claude Code's client needs its subprotocol echoed: \(echoed)")

    var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)")!)
    request.setValue(token, forHTTPHeaderField: "x-claude-code-ide-authorization")
    let socket = URLSession.shared.webSocketTask(with: request)
    socket.resume()
    func next() async throws -> [String: Any] {
      guard case .string(let text) = try await socket.receive(),
        let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
      else { throw URLError(.cannotParseResponse) }
      return json
    }
    try await socket.send(.string(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#))
    let initialize = try await next()
    let result = try XCTUnwrap(initialize["result"] as? [String: Any])
    XCTAssertEqual((result["serverInfo"] as? [String: Any])?["name"] as? String, "termdown")
    try await socket.send(.string(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
    let tools = try await next()
    let names = ((tools["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
    XCTAssertEqual(names?.contains("getCurrentSelection"), true)

    bridge.update(IDESelection(filePath: "/tmp/vault/note.md", text: "two lines", startLine: 3, startCharacter: 0, endLine: 4, endCharacter: 5))
    let pushed = try await next()
    XCTAssertEqual(pushed["method"] as? String, "selection_changed")
    XCTAssertNil(pushed["id"])
    let params = try XCTUnwrap(pushed["params"] as? [String: Any])
    XCTAssertEqual(params["filePath"] as? String, "/tmp/vault/note.md")
    XCTAssertEqual(params["text"] as? String, "two lines")
    let selection = try XCTUnwrap(params["selection"] as? [String: Any])
    XCTAssertEqual((selection["start"] as? [String: Any])?["line"] as? Int, 3)
    XCTAssertEqual(selection["isEmpty"] as? Bool, false)

    try await socket.send(.string(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"getCurrentSelection","arguments":{}}}"#))
    let call = try await next()
    let content = ((call["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String
    XCTAssertEqual(content?.contains("two lines"), true)
    socket.cancel(with: .goingAway, reason: nil)

    bridge.stop()
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(port).lock").path), "stop removes the lock")
  }

  /// Claude Code's openDiff is its edit permission prompt: FILE_SAVED, TAB_CLOSED and DIFF_REJECTED each decide it.
  func testDiffToolsLeaveTheEditDecisionToClaudeCode() async throws {
    let config = FileManager.default.temporaryDirectory.appendingPathComponent("ide-\(UUID().uuidString)")
    setenv("CLAUDE_CONFIG_DIR", config.path, 1)
    defer { unsetenv("CLAUDE_CONFIG_DIR") }
    let folder = config.appendingPathComponent("vault")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appendingPathComponent("plan.md")
    try "# Plan\n".write(to: file, atomically: true, encoding: .utf8)
    let bridge = IDEBridge(workspaceFolders: [folder.path], file: file)
    bridge.start()
    defer { bridge.stop() }
    let directory = config.appendingPathComponent("ide")
    var lock: [String: Any]?
    var port = 0
    for _ in 0..<50 {
      if let name = try? FileManager.default.contentsOfDirectory(atPath: directory.path).first(where: { $0.hasSuffix(".lock") }),
        let data = try? Data(contentsOf: directory.appendingPathComponent(name))
      {
        lock = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        port = Int(name.dropLast(5)) ?? 0
        break
      }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    let token = try XCTUnwrap(try XCTUnwrap(lock)["authToken"] as? String)
    var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)")!)
    request.setValue(token, forHTTPHeaderField: "x-claude-code-ide-authorization")
    let socket = URLSession.shared.webSocketTask(with: request)
    socket.resume()
    defer { socket.cancel(with: .goingAway, reason: nil) }
    var id = 0
    func call(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
      id += 1
      let message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
      try await socket.send(.string(String(decoding: try JSONSerialization.data(withJSONObject: message), as: UTF8.self)))
      guard case .string(let text) = try await socket.receive(),
        let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
      else { throw URLError(.cannotParseResponse) }
      return try XCTUnwrap(json["result"] as? [String: Any], "\(json)")
    }
    func texts(_ result: [String: Any]) -> [String] {
      (result["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String } ?? []
    }

    let tools = try await call("tools/list", [:])["tools"] as? [[String: Any]] ?? []
    let openDiff = try XCTUnwrap(tools.first { $0["name"] as? String == "openDiff" })
    let schema = try XCTUnwrap(openDiff["inputSchema"] as? [String: Any])
    XCTAssertEqual(
      Set(schema["required"] as? [String] ?? []), ["old_file_path", "new_file_path", "new_file_contents", "tab_name"])
    XCTAssertTrue(tools.contains { $0["name"] as? String == "close_tab" })
    XCTAssertTrue(tools.contains { $0["name"] as? String == "closeAllDiffTabs" })

    for path in [file.path, folder.appendingPathComponent("other.md").path] {
      let result = try await call("tools/call", [
        "name": "openDiff",
        "arguments": ["old_file_path": path, "new_file_path": path, "new_file_contents": "# Plan\n\nAgent line\n", "tab_name": "tab"],
      ])
      XCTAssertEqual(result["isError"] as? Bool, true, "openDiff for \(path) decides nothing")
      XCTAssertTrue(
        Set(texts(result)).isDisjoint(with: ["FILE_SAVED", "TAB_CLOSED", "DIFF_REJECTED"]), "\(texts(result))")
    }
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "# Plan\n", "the IDE never writes the file; Claude Code does")
    XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("other.md").path))

    let closed = try await call("tools/call", ["name": "close_tab", "arguments": ["tab_name": "tab"]])
    XCTAssertEqual(texts(closed), ["TAB_CLOSED"])
    let closedAll = try await call("tools/call", ["name": "closeAllDiffTabs", "arguments": [String: Any]()])
    XCTAssertEqual(texts(closedAll), ["CLOSED_0_DIFF_TABS"])
  }

  /// Two agents connect; each names a process whose REX_BLOCK says which pane it runs in. With `opener` pairing only
  /// the opener pane's agent sees the selection, until the person chooses the other one, and the lock file records
  /// the panes for `termdown claude`.
  func testSelectionGoesOnlyToThePairedAgent() async throws {
    let config = FileManager.default.temporaryDirectory.appendingPathComponent("ide-\(UUID().uuidString)")
    setenv("CLAUDE_CONFIG_DIR", config.path, 1)
    defer { unsetenv("CLAUDE_CONFIG_DIR") }
    // macOS hides the environment of Apple's platform binaries, so the stand-in agent is a re-signed copy of sleep.
    let sleep = config.appendingPathComponent("agent")
    try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: sleep)
    let sign = Process()
    sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    sign.arguments = ["-f", "-s", "-", sleep.path]
    sign.standardError = FileHandle.nullDevice
    try sign.run()
    sign.waitUntilExit()
    func agentProcess(_ block: String) throws -> Process {
      let process = Process()
      process.executableURL = sleep
      process.arguments = ["30"]
      process.environment = ["REX_BLOCK": block, "REX_SESSION": "session:test"]
      try process.run()
      return process
    }
    let opener = try agentProcess("block:opener")
    let other = try agentProcess("block:other")
    defer {
      opener.terminate()
      other.terminate()
    }
    let bridge = IDEBridge(
      workspaceFolders: ["/tmp/vault"], file: URL(fileURLWithPath: "/tmp/vault/plan.md"), pairing: .opener,
      rex: IDEBridge.RexPlacement(session: "session:test", block: "block:viewer", opener: "block:opener"))
    let changed = expectation(description: "agents identified")
    changed.expectedFulfillmentCount = 2
    changed.assertForOverFulfill = false
    bridge.onAgentsChanged = { changed.fulfill() }
    bridge.start()
    defer { bridge.stop() }

    let directory = config.appendingPathComponent("ide")
    var locks: [ViewerLock] = []
    for _ in 0..<50 {
      locks = ViewerLocks.read(directory)
      if !locks.isEmpty { break }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    let lock = try XCTUnwrap(locks.first)
    XCTAssertEqual(lock.session, "session:test")
    XCTAssertEqual(lock.block, "block:viewer")
    XCTAssertEqual(lock.opener, "block:opener")
    let body = try JSONSerialization.jsonObject(
      with: Data(contentsOf: directory.appendingPathComponent("\(lock.port).lock"))) as? [String: Any]
    let token = try XCTUnwrap(body?["authToken"] as? String)

    func connect(as process: Process) async throws -> URLSessionWebSocketTask {
      var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(lock.port)")!)
      request.setValue(token, forHTTPHeaderField: "x-claude-code-ide-authorization")
      let socket = URLSession.shared.webSocketTask(with: request)
      socket.resume()
      try await socket.send(.string(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#))
      _ = try await socket.receive()
      try await socket.send(
        .string(#"{"jsonrpc":"2.0","method":"ide_connected","params":{"pid":\#(process.processIdentifier)}}"#))
      return socket
    }
    let openerSocket = try await connect(as: opener)
    let otherSocket = try await connect(as: other)
    await fulfillment(of: [changed], timeout: 5)
    for _ in 0..<50 where bridge.agentState().agents.contains(where: { $0.block == nil }) {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    let state = bridge.agentState()
    XCTAssertEqual(state.agents.map(\.block), ["block:opener", "block:other"])
    XCTAssertEqual(state.agents.map(\.session), ["session:test", "session:test"])
    XCTAssertEqual(state.recipients, [state.agents[0].id], "opener pairing: only the opener's agent")
    XCTAssertEqual(bridge.askTarget, "block:opener")

    let openerInbox = Inbox(openerSocket)
    let otherInbox = Inbox(otherSocket)
    bridge.update(IDESelection(filePath: "/tmp/vault/plan.md", text: "one", startLine: 1, startCharacter: 0, endLine: 1, endCharacter: 3))
    let toOpener = await openerInbox.first(containing: "\"one\"", within: 2)
    XCTAssertTrue(toOpener?.contains("selection_changed") == true, "the opener's agent sees the selection")
    let notOther = await otherInbox.first(containing: "\"one\"", within: 0.5)
    XCTAssertNil(notOther, "the other agent does not")

    bridge.choose(.agent(state.agents[1].id))
    let toOther = await otherInbox.first(containing: "\"one\"", within: 2)
    XCTAssertNotNil(toOther, "choosing an agent sends it the current selection")
    XCTAssertEqual(bridge.askTarget, "block:other")
    bridge.update(IDESelection(filePath: "/tmp/vault/plan.md", text: "two", startLine: 2, startCharacter: 0, endLine: 2, endCharacter: 3))
    let next = await otherInbox.first(containing: "\"two\"", within: 2)
    XCTAssertNotNil(next)
    let leaked = await openerInbox.first(containing: "\"two\"", within: 0.5)
    XCTAssertNil(leaked, "the opener's agent no longer sees the selection")
    openerSocket.cancel(with: .goingAway, reason: nil)
    otherSocket.cancel(with: .goingAway, reason: nil)
  }

  func testAPreviewOpenedWithoutAnOpenerStillOffersTheDirectoryItWasStartedIn() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("launch-\(UUID().uuidString)")
    let project = root.appendingPathComponent("project"), scratch = root.appendingPathComponent("scratch")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = scratch.appendingPathComponent("draft.md")
    let folders = IDEBridge.workspaceFolders(file: file, openerDirectory: nil, launchDirectory: project.path)
    XCTAssertEqual(folders.first, IDEBridge.trueCase(project.path), "a session in the launching directory can attach")
    XCTAssertTrue(folders.contains(IDEBridge.trueCase(scratch.path)))
  }

  func testTheOpenerComesFirstAndARootOrHomeLaunchDirectoryIsNotOffered() {
    let file = URL(fileURLWithPath: "/tmp/scratch/draft.md")
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    for launch in ["/", home, home + "/"] {
      let folders = IDEBridge.workspaceFolders(file: file, openerDirectory: nil, launchDirectory: launch)
      XCTAssertFalse(folders.contains("/"), launch)
      XCTAssertFalse(folders.contains(IDEBridge.trueCase(home)), "home would match every session: \(launch)")
    }
    let both = IDEBridge.workspaceFolders(file: file, openerDirectory: "/tmp", launchDirectory: "/private")
    XCTAssertEqual(Array(both.prefix(2)), [IDEBridge.trueCase("/tmp"), IDEBridge.trueCase("/private")])
  }

  func testWorkspaceFoldersUseTheOnDiskCase() {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    XCTAssertEqual(IDEBridge.trueCase(home.lowercased()), home)
  }
}

/// Collects a WebSocket's text messages in the background, so a test can wait for one with a timeout.
private final class Inbox: @unchecked Sendable {
  private let lock = NSLock()
  private var messages: [String] = []

  init(_ socket: URLSessionWebSocketTask) {
    Task { [weak self] in
      while let message = try? await socket.receive() {
        guard case .string(let text) = message, let self else { continue }
        self.lock.withLock { self.messages.append(text) }
      }
    }
  }

  func first(containing needle: String, within seconds: Double) async -> String? {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      if let found = lock.withLock({ messages.first { $0.contains(needle) } }) { return found }
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return nil
  }
}
