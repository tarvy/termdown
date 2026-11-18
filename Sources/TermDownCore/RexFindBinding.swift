import Foundation

public enum RexFindBinding {
  public static let actionName = "termdown_find"
  public static let restartActionName = "termdown_restart"
  public static let copyPathActionName = "termdown_copy_path"
  public static let selectAgentActionName = "termdown_select_agent"
  public static let beginMarker = "-- >>> termdown: Cmd-F binding (managed by termdown setup; edits are replaced) >>>"
  public static let endMarker = "-- <<< termdown <<<"

  public static let lua = """
    \(beginMarker)
    local function termdown_pane(block)
      if block == nil then return false end
      local terminal = "com.superlogical.terminal"
      local process = rex.block.call(terminal, "process", { block_id = block })
      if process ~= nil then
        return process.foreground ~= nil and process.foreground.name == "termdown"
      end
      local listed = rex.session.list_blocks{}
      for _, entry in ipairs((listed or {}).blocks or {}) do
        if entry.block_id == block then return entry.label == "termdown" end
      end
      return false
    end

    rex.action{
      name = "\(actionName)",
      title = "Find (TermDown aware)",
      description = "Opens TermDown's find in a TermDown pane and Rex's Find everywhere else.",
      run = function(ctx, args)
        if termdown_pane(ctx.block_id) then
          local _, err = rex.block.call(
            "com.superlogical.terminal", "write", { block_id = ctx.block_id, data = "\\27[102;9u" })
          if err == nil then return { target = "termdown" } end
        end
        rex.client.queue("client.find.open")
        return { target = "rex" }
      end,
    }

    rex.bind("cmd+f", "\(actionName)")

    rex.action{
      name = "\(restartActionName)",
      title = "Restart TermDown",
      description = "Restarts every TermDown pane in this session on its own file, keeping unsaved edits.",
      keywords = "termdown markdown restart reload viewer",
      run = function(ctx, args)
        local targets = {}
        if termdown_pane(ctx.block_id) then targets[#targets + 1] = ctx.block_id end
        local listed = rex.session.list_blocks{}
        for _, entry in ipairs((listed or {}).blocks or {}) do
          if entry.block_id ~= ctx.block_id and termdown_pane(entry.block_id) then
            targets[#targets + 1] = entry.block_id
          end
        end
        local restarted = 0
        for _, block in ipairs(targets) do
          local _, err = rex.block.call(
            "com.superlogical.terminal", "write", { block_id = block, data = "\\27[998~" })
          if err == nil then restarted = restarted + 1 end
        end
        return { restarted = restarted }
      end,
    }

    -- The termdown pane to act on: the focused one, else the only one in the session.
    local function termdown_target(ctx)
      if termdown_pane(ctx.block_id) then return ctx.block_id end
      local listed = rex.session.list_blocks{}
      local found = {}
      for _, entry in ipairs((listed or {}).blocks or {}) do
        if termdown_pane(entry.block_id) then found[#found + 1] = entry.block_id end
      end
      if #found > 1 then error("focus a termdown pane first; " .. #found .. " are open", 0) end
      if #found == 0 then error("no termdown pane is open", 0) end
      return found[1]
    end

    local function termdown_write(ctx, data)
      local target = termdown_target(ctx)
      local _, err = rex.block.call("com.superlogical.terminal", "write", { block_id = target, data = data })
      if err ~= nil then error(err, 0) end
      return { target = "termdown" }
    end

    rex.action{
      name = "\(copyPathActionName)",
      title = "Copy open file path",
      description = "Copies the path of the file open in termdown, relative to the folder it was opened from.",
      keywords = "termdown markdown copy path file relative",
      run = function(ctx, args) return termdown_write(ctx, "\\27[997~") end,
    }

    rex.action{
      name = "\(selectAgentActionName)",
      title = "Select agent",
      description = "Chooses which Claude Code session gets termdown's highlights, or starts one beside it.",
      keywords = "termdown termdown markdown agent claude ide select pair highlights",
      run = function(ctx, args) return termdown_write(ctx, "\\27[996~") end,
    }
    \(endMarker)
    """

  public static func configFile(environment: [String: String], home: URL) -> URL {
    if let path = environment["REX_CONFIG"], !path.isEmpty {
      return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }
    if let base = environment["XDG_CONFIG_HOME"], !base.isEmpty {
      return URL(fileURLWithPath: base).appendingPathComponent("rex/init.lua")
    }
    return home.appendingPathComponent(".config/rex/init.lua")
  }

  public enum EditError: Error, Equatable, CustomStringConvertible {
    case unreadable(String)
    case notUTF8
    case unterminatedBlock
    case checkFailed(String)

    public var description: String {
      switch self {
      case .unreadable(let reason): "it could not be read (\(reason))"
      case .notUTF8: "it is not valid UTF-8"
      case .unterminatedBlock: "it has a termdown begin marker without the end marker"
      case .checkFailed(let output): "the edited config did not pass rex config check: \(output)"
      }
    }
  }

  public static func removing(from text: String) throws -> String {
    var lines = text.components(separatedBy: "\n")
    while let start = lines.firstIndex(of: beginMarker) {
      guard let end = lines[start...].firstIndex(of: endMarker) else { throw EditError.unterminatedBlock }
      lines.removeSubrange(start...end)
      if start > 0, start <= lines.count, lines[start - 1].isEmpty, start == lines.count || lines[start].isEmpty {
        lines.remove(at: start - 1)
      }
    }
    return lines.joined(separator: "\n")
  }

  public static func installing(into text: String) throws -> String {
    var kept = try removing(from: text)
    while kept.hasSuffix("\n\n") { kept.removeLast() }
    if kept.isEmpty { return lua + "\n" }
    return kept + (kept.hasSuffix("\n") ? "\n" : "\n\n") + lua + "\n"
  }

  public static func read(_ url: URL) throws -> String? {
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return nil
    } catch {
      throw EditError.unreadable(error.localizedDescription)
    }
    guard let text = String(data: data, encoding: .utf8) else { throw EditError.notUTF8 }
    return text
  }

  public struct Editor {
    public var runner: ProcessRunning?
    public var rexPath: String?
    public var synchronize: (URL) throws -> Void

    public init(
      runner: ProcessRunning? = ProcessRunner(timeout: 10), rexPath: String?,
      synchronize: @escaping (URL) throws -> Void = Editor.fsync
    ) {
      self.runner = runner
      self.rexPath = rexPath
      self.synchronize = synchronize
    }

    public static func fsync(_ url: URL) throws {
      let handle = try FileHandle(forWritingTo: url)
      defer { try? handle.close() }
      try handle.synchronize()
    }

    @discardableResult
    public func install(at configured: URL) throws -> Bool {
      try edit(configured, checksCandidate: { _ in true }, change: { try RexFindBinding.installing(into: $0 ?? "") })
    }

    @discardableResult
    public func remove(at configured: URL) throws -> Bool {
      try edit(
        configured, checksCandidate: { (try? check($0)) != nil },
        change: { existing in
          guard let existing else { return nil }
          return try RexFindBinding.removing(from: existing)
        })
    }

    private func edit(
      _ configured: URL, checksCandidate: (URL) -> Bool, change: (String?) throws -> String?
    ) throws -> Bool {
      let url = configured.resolvingSymlinksInPath()
      let existing = try RexFindBinding.read(url)
      guard let updated = try change(existing), updated != existing else { return false }
      let directory = url.deletingLastPathComponent()
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let candidate = directory.appendingPathComponent(".\(url.lastPathComponent).termdown-\(UUID().uuidString)")
      try Data(updated.utf8).write(to: candidate, options: .withoutOverwriting)
      do {
        let permissions = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) ?? 0o644
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: candidate.path)
        try synchronize(candidate)
        if checksCandidate(url) { try check(candidate) }
        guard rename(candidate.path, url.path) == 0 else {
          throw EditError.unreadable(String(cString: strerror(errno)))
        }
      } catch {
        try? FileManager.default.removeItem(at: candidate)
        throw error
      }
      return true
    }

    private func check(_ candidate: URL) throws {
      guard let runner, let rexPath else { return }
      let result = try runner.run(rexPath, ["config", "check", candidate.path, "--autostart=false"], timeout: 10)
      guard result.status == 0 else {
        let output = String(decoding: result.stdout + result.stderr, as: UTF8.self)
          .split(separator: "\n").filter { $0.lowercased().contains("error") }.joined(separator: "; ")
        throw EditError.checkFailed(output.isEmpty ? "exit status \(result.status)" : output)
      }
    }
  }
}

public func uninstallThenRemoveFindBinding(
  restore: () async throws -> [String], removeFindBinding: () -> Void
) async rethrows -> [String] {
  let failures = try await restore()
  if failures.isEmpty { removeFindBinding() }
  return failures
}
