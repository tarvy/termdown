import Foundation
import TermDownCore

enum AgentsCommand {
  static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

  static func skills(_ targets: [AgentSkillTarget] = agentSkillTargets) -> AgentSkills {
    AgentSkills(home: home, targets: targets)
  }

  static let usage = "usage: termdown agents install|status|remove [claude|codex|cursor ...]"

  static func run(_ arguments: [String]) -> Never {
    guard let action = arguments.first else { fail(usage, status: 64) }
    let targets: [AgentSkillTarget]
    do {
      targets = try agentSkillTargets(named: Array(arguments.dropFirst()))
    } catch {
      fail("\(error)\n\(usage)", status: 64)
    }
    do {
      switch action {
      case "install":
        print(agentStatusLines(try skills(targets).install()).joined(separator: "\n"))
      case "remove":
        print(agentStatusLines(try skills(targets).remove()).joined(separator: "\n"))
      case "status":
        let reports = skills(targets).status()
        print(agentStatusLines(reports).joined(separator: "\n"))
        exit(agentStatusExitCode(reports))
      default:
        fail(usage, status: 64)
      }
    } catch {
      fail("agents \(action) failed: \(error)", status: 1)
    }
    exit(0)
  }

  static func offerInstall() {
    let pending = agentOfferPending(skills().status())
    let outcome = offerAgentInstall(
      pending: pending,
      isInteractive: isatty(STDIN_FILENO) != 0,
      ask: {
        print(agentOfferQuestion(pending, home: home.path), terminator: "")
        return readLine()
      },
      install: {
        do {
          print(agentStatusLines(try skills(pending.map(\.target)).install()).joined(separator: "\n"))
        } catch {
          FileHandle.standardError.write(Data("agents install failed: \(error)\n".utf8))
        }
      })
    if outcome == .hint {
      print("To teach coding agents to use termdown, run: termdown agents install")
    }
  }

  static func removeQuietly() {
    do {
      _ = try skills().remove()
    } catch {
      FileHandle.standardError.write(Data("agents remove failed: \(error)\n".utf8))
    }
  }
}
