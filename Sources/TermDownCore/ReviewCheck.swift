import Foundation

public enum ReviewVerdict: String, Sendable, Equatable {
  case ready = "READY"
  /// The draft is under review in a preview in the caller's own tab.
  case open = "OPEN"
  /// The draft is under review in a preview outside the caller's tab.
  case locked = "LOCKED"
  case noRex = "NO_REX"
  case noFile = "NO_FILE"
}

/// The preflight `termdown review --check` prints, so an agent reads one verdict instead of reasoning about
/// conditions. It judges only the caller's own tab ($REX_BLOCK's window): a preview in another tab or session never
/// counts as open beside the agent. `PREVIEW` says whether a preview in that tab shows the file, and `CONNECTED`
/// whether the caller's own pane is connected to it through `/ide`.
public struct ReviewCheck: Equatable, Sendable {
  public var verdict: ReviewVerdict
  public var file: String
  public var previewHere: Bool?
  public var connected: Bool?
  public var detail: String
  public var next: String

  /// The order matters: a missing file or Rex outranks a lock, and READY is only what is left.
  public init(
    file: String, fileExists: Bool, rexSession: String?, reviewIsLive: Bool, previewHere: Bool? = nil,
    connected: Bool? = nil
  ) {
    self.file = file
    self.previewHere = previewHere
    self.connected = connected
    if !fileExists {
      verdict = .noFile
      detail = "there is no file at that path"
      next = "tell the user the file is missing, then carry on without a review"
    } else if rexSession?.isEmpty ?? true {
      verdict = .noRex
      detail = "this terminal is not inside a Rex session, so there is no pane to open a preview in"
      next = "tell the user, give them the file path, and carry on without a review"
    } else if reviewIsLive, previewHere == true {
      verdict = .open
      detail = "this draft is already under review in a TermDown preview in your own tab"
      next =
        "tell the user in one line that it is open for review in the preview beside them; if CONNECTED is not yes, "
        + "prefill /ide as the guide says; then end your turn"
    } else if reviewIsLive {
      verdict = .locked
      detail = "a TermDown preview that is not in your tab is reviewing this draft"
      next =
        "tell the user the draft is under review in a preview in another tab or session, and ask them to end that "
        + "review (m) or close that preview, then run this check again. Do not say it is open beside them"
    } else {
      verdict = .ready
      detail = "no review is open for this draft"
      next = "run `termdown review \(file)` from your own shell, then end your turn"
    }
  }

  public var text: String {
    "REVIEW: \(verdict.rawValue)\nFILE: \(file)\nPREVIEW: \(Self.word(previewHere, yes: "here", no: "none"))\n"
      + "CONNECTED: \(Self.word(connected, yes: "yes", no: "no"))\nDETAIL: \(detail)\nNEXT: \(next)\n"
  }

  private static func word(_ value: Bool?, yes: String, no: String) -> String {
    value.map { $0 ? yes : no } ?? "unknown"
  }

  /// Exit status: 0 only for READY, so a script can branch on it.
  public var status: Int32 { verdict == .ready ? 0 : 1 }
}

/// Whether a preview in the caller's own tab shows `file`, and whether the caller's pane is connected to it. `previews`
/// is nil when the caller's tab could not be read (no $REX_BLOCK, or Rex did not answer): both are then unknown. A
/// viewer too old to list its agents leaves `connected` unknown.
public func ownTabPreview(file: String, previews: [PreviewPane]?, callerBlock: String?) -> (
  here: Bool?, connected: Bool?
) {
  guard let previews else { return (nil, nil) }
  let showing = previews.compactMap(\.state).filter { $0.file == file }
  guard !showing.isEmpty else { return (false, false) }
  guard let callerBlock, !callerBlock.isEmpty else { return (true, nil) }
  if showing.contains(where: { $0.agents?.contains(callerBlock) == true }) { return (true, true) }
  return (true, showing.allSatisfy { $0.agents == nil } ? nil : false)
}
