import Foundation

/// One review hotkey. `type` is the published contract: it appears in every edits file termdown writes, so it is never
/// renamed. `apply` is what the agent does with a mark of this type; the viewer never shows it.
public struct ReviewHotkey: Equatable, Sendable, Decodable {
  public let key: String
  public let type: String
  public let label: String
  public let hint: String
  public let color: String
  public let prompt: String?
  public let apply: String?
}

/// The review hotkey set, owned by termdown. There is one copy, bundled here, and nothing outside this repository
/// supplies or overrides it.
public enum ReviewHotkeys {
  public static func load() -> [ReviewHotkey] {
    (try? parse(Data(bundled.utf8))) ?? []
  }

  public static func parse(_ data: Data) throws -> [ReviewHotkey] {
    struct File: Decodable { let hotkeys: [ReviewHotkey] }
    return try JSONDecoder().decode(File.self, from: data).hotkeys
  }

  public static let bundled = """
    {
      "hotkeys": [
        {"key": "1", "type": "delete", "label": "Delete", "hint": "cut this entirely", "color": "#ef4444",
         "apply": "Remove the highlighted `text`, or the whole block if the selection is the block."},
        {"key": "2", "type": "awkward", "label": "Awkward", "hint": "reads clunky — take another pass", "color": "#f97316",
         "apply": "The passage reads clunky. Rephrase it. No direction was given, so use your judgment: keep the meaning and make it read cleanly."},
        {"key": "3", "type": "cringe", "label": "Cringe", "hint": "AI tells: em dashes, emojis, hype", "color": "#eab308",
         "apply": "Strip the AI tells: em dashes, emojis, hype, filler, staccato fragments. Make it sound like the user, not a model."},
        {"key": "4", "type": "shorten", "label": "Shorten", "hint": "trim ~10-20%", "color": "#a78bfa",
         "apply": "Tighten lightly: trim roughly 10-20%, same meaning and structure."},
        {"key": "5", "type": "shorten_hard", "label": "Shorten a lot", "hint": "cut it roughly in half", "color": "#6d28d9",
         "apply": "Cut it roughly in half. Keep only the essential point and drop everything that is not load-bearing."},
        {"key": "6", "type": "expand", "label": "Add detail", "hint": "thin / vague — expand it", "color": "#16a34a",
         "apply": "The passage is thin or vague. Add the obvious missing specifics or a data point."},
        {"key": "7", "type": "source", "label": "Source?", "hint": "unsupported stat/claim — verify/cite", "color": "#0d9488",
         "apply": "Check the claim before touching it; this key asks for verification, not a marker. Look in the project's own material (transcripts, data, documents already in the repo). If it holds, keep it and make it more specific. If it is contradicted, correct it. Only when there is nothing to check it against, mark it with a backticked `[source?]`; the backticks matter, because a bare [source?] is Markdown link syntax. Say in your summary which claims you verified, which you could not, and where you looked."},
        {"key": "8", "type": "overstated", "label": "Overstated", "hint": "soften / don't overhype / too harsh", "color": "#db2777",
         "apply": "Soften the claim. Dial back overstatement, hype and over-harsh framing so it is accurate and measured."},
        {"key": "9", "type": "note", "label": "Note...", "hint": "freeform: exact wording, reorder, etc.", "color": "#9ca3af",
         "prompt": "Instruction for this passage:",
         "apply": "Do exactly what `note` says. It is the user's own instruction: exact replacement wording, a reorder, a restructure, a formatting change. A note phrased as a question gets an answer in your summary, and the smallest edit that fits."}
      ]
    }
    """
}
