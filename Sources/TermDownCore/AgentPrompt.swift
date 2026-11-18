import Foundation

/// The text termdown pastes into the agent's pane when you ask about a selection (`a` or Cmd-L).
/// It names the file and its source lines the way Claude Code reads file references, quotes the
/// selection, and leaves a blank line for your note.
public enum AgentPrompt {
  public static let quoteLimit = 600

  public static func message(file: String, startLine: Int, endLine: Int, quote: String) -> String {
    let lines = startLine == endLine ? "line \(startLine)" : "lines \(startLine)-\(endLine)"
    var text = "In @\(file) \(lines):"
    var excerpt = quote.trimmingCharacters(in: .whitespacesAndNewlines)
    if excerpt.count > quoteLimit { excerpt = String(excerpt.prefix(quoteLimit)) + "…" }
    if !excerpt.isEmpty {
      text += "\n" + excerpt.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
    }
    return text + "\n\n"
  }

  /// The handoff for one review pass. It points the agent at termdown's own guide for how to apply the edits file.
  /// Each pass stands alone: the agent applies it and carries on with the conversation, and the person starts another
  /// pass from TermDown if they want one.
  public static func review(draft: String, edits: String, pass: Int) -> String {
    "Review pass \(pass) on @\(draft): apply \(edits). Run `termdown agent-guide review` for how."
      + " The draft is open in TermDown, so just edit the file in place; do not start another reviewer."
      + " This pass is complete on its own: do not start another one, and carry on with the conversation.\n\n"
  }

  /// Bracketed paste, so the agent's prompt takes the lines as text instead of submitting at the first newline.
  public static func paste(_ text: String) -> String {
    "\u{1b}[200~" + text + "\u{1b}[201~"
  }
}
