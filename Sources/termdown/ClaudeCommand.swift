import Foundation
import TermDownCore
import TermDownHost

/// `termdown claude [file] [-- agent arguments]`: start the agent (the `agent` setting, `claude` by default) in this
/// pane, pinned to the viewer this pane opened, so the viewer's highlights reach this agent and no other. With a file,
/// open its preview beside the pane first.
enum ClaudeCommand {
  static let usage = "usage: termdown claude [<file>] [-- <agent arguments>]"
  static let lockWait: TimeInterval = 10

  static func run(_ arguments: [String]) -> Never {
    let split = arguments.firstIndex(of: "--")
    let own = split.map { Array(arguments[..<$0]) } ?? arguments
    let extra = split.map { Array(arguments[($0 + 1)...]) } ?? []
    guard own.count <= 1, !(own.first?.hasPrefix("-") ?? false) else { fail(usage, status: 64) }
    let file = own.first

    let settings = SettingsStore.load(currentPaths())
    guard let words = ShellWords.split(settings.agent), !words.isEmpty else {
      fail("termdown: the agent setting is not a command: \(settings.agent)", status: 64)
    }

    let environment = ProcessInfo.processInfo.environment
    var port: Int?
    if let pane = environment["REX_BLOCK"], !pane.isEmpty {
      let session = environment["REX_SESSION"]
      var name: String?
      if let file {
        open(file)
        name = URL(fileURLWithPath: file).lastPathComponent
      }
      let deadline = Date().addingTimeInterval(file == nil ? 0 : lockWait)
      repeat {
        port = ViewerLocks.pick(ViewerLocks.read(IDEBridge.lockDirectory), pane: pane, session: session, file: name)?.port
        if port != nil || Date() >= deadline { break }
        Thread.sleep(forTimeInterval: 0.1)
      } while true
      if port == nil {
        note(
          file == nil
            ? "no preview was opened from this pane; starting \(words[0]) without one (termdown claude <file> opens one)"
            : "the preview did not start; starting \(words[0]) without it")
      }
    } else {
      note("not in a Rex pane; starting \(words[0]) without a preview")
    }

    if let port { setenv("CLAUDE_CODE_SSE_PORT", String(port), 1) }
    let argv = (words + extra).map { strdup($0) } + [nil]
    execvp(words[0], argv)
    fail("termdown: could not run \(words[0]): \(String(cString: strerror(errno)))", status: 127)
  }

  /// Opens the file's preview beside this pane, as `termdown open` does.
  static func open(_ file: String) {
    let process = Process()
    process.executableURL = ownExecutable()
    process.arguments = ["open", file]
    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      fail("termdown: could not open \(file): \(error)", status: 1)
    }
    if process.terminationStatus != 0 { exit(process.terminationStatus) }
  }

  static func note(_ message: String) {
    FileHandle.standardError.write(Data("termdown: \(message)\n".utf8))
  }
}
