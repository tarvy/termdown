import Foundation

public enum ReviewVerdict: String, Sendable, Equatable {
  case ready = "READY"
  case locked = "LOCKED"
  case noRex = "NO_REX"
  case noFile = "NO_FILE"
}

/// The preflight `termdown review --check` prints, so an agent reads one verdict instead of reasoning about
/// conditions. It reports only what termdown can know. Whether the agent's own session is connected to the preview is
/// the agent's to tell the user, because only Claude Code knows it.
public struct ReviewCheck: Equatable, Sendable {
  public var verdict: ReviewVerdict
  public var file: String
  public var detail: String
  public var next: String

  /// The order matters: a missing file or Rex outranks a lock, and READY is only what is left.
  public init(file: String, fileExists: Bool, rexSession: String?, reviewIsLive: Bool) {
    self.file = file
    if !fileExists {
      verdict = .noFile
      detail = "there is no file at that path"
      next = "tell the user the file is missing, then carry on without a review"
    } else if rexSession?.isEmpty ?? true {
      verdict = .noRex
      detail = "this terminal is not inside a Rex session, so there is no pane to open a preview in"
      next = "tell the user, give them the file path, and carry on without a review"
    } else if reviewIsLive {
      verdict = .locked
      detail = "a TermDown viewer is already reviewing this draft"
      next = "tell the user in one line that it is already open for review, and do nothing else"
    } else {
      verdict = .ready
      detail = "no review is open for this draft"
      next = "run `termdown review \(file)`, then end your turn"
    }
  }

  public var text: String {
    "REVIEW: \(verdict.rawValue)\nFILE: \(file)\nDETAIL: \(detail)\nNEXT: \(next)\n"
  }

  /// Exit status: 0 only for READY, so a script can branch on it.
  public var status: Int32 { verdict == .ready ? 0 : 1 }
}
