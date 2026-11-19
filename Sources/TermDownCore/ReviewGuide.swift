import Foundation

/// `termdown agent-guide review`: how an agent starts a review and applies a pass. termdown owns this text and the
/// hotkey `apply` lines it prints, so a review never depends on a skill or plugin from anywhere else.
public func reviewGuide(hotkeys: [ReviewHotkey] = ReviewHotkeys.load()) -> String {
  let marks = hotkeys.map { hotkey in
    "- `\(hotkey.type)` (key \(hotkey.key), \(hotkey.label)): \(hotkey.apply ?? hint(hotkey))"
  }.joined(separator: "\n")
  return """
    termdown review: start a review of a draft, then apply each pass the user sends.

    Your own pane. Start with `rex whoami --json`: $REX_SESSION and $REX_BLOCK name your session and pane, and only
    that pane's tab counts. Run termdown from your own shell. Never pick, attach to or reason from a TermDown pane in
    another tab or session, and never say a draft is open in TermDown from memory or because some termdown pane exists.

    Start a review. Only when the user asks to review, mark up or send passes on a draft:
    1. Run `termdown review --check FILE`. It judges only your own tab and prints `REVIEW:`, `PREVIEW:` (here, none or
       unknown), `CONNECTED:` (yes, no or unknown: whether your pane is connected to that preview) and `NEXT:`.
       Follow `NEXT:`.
       - `REVIEW: READY`: run `termdown review FILE` from your own shell.
       - `REVIEW: OPEN`: the draft is already under review in the preview beside you. Do not start another.
       - `REVIEW: LOCKED`: a preview in another tab or session is reviewing it. Tell the user and ask them to end that
         review or close that preview. Never say it is open beside them.
       - `REVIEW: NO_REX` or `REVIEW: NO_FILE`: tell the user which, give the file path, and carry on without a review.
    2. After `termdown review FILE`, run the check again. Only with `PREVIEW: here` may you tell the user, in one line,
       that the draft is open for review in the preview beside them.
    3. If `CONNECTED:` is not `yes` (and this session was not started by `termdown claude`), prefill `/ide` in your
       own prompt as the last thing you do: `rex send -b "$REX_BLOCK" "/ide"`, with no newline. Tell the user to press
       Enter and pick the termdown preview, so passes reach this session. Never press Enter or pick for them.
    4. End your turn. Each pass arrives later as a message.
    - Never run a second reviewer, a browser page or a script for the same draft. TermDown is the only reviewer.
    - Use `termdown open FILE`, not `review`, when the user only wants to look at a file.

    Apply a pass. When a message starts with `Review pass N on @<draft>`:
    1. Read the edits file the message names. Re-read the draft: it already holds anything the user typed by hand.
    2. Apply every annotation, working from the bottom of the file upward so earlier positions stay valid.
    3. Edit the real draft in place, never a copy. The user may save edits at any time, so re-read the file before each
       change and never overwrite their saved text.
    4. Do not start another pass or wait for one. Every pass stands alone, and the user starts the next from TermDown.
       Carry on with the conversation.
    5. Say in your summary which annotations you applied and which you could not, and why. Never skip one silently.

    The edits file:
    ```
    { "draft": "/abs/draft.md", "action": "finish",
      "annotations": [
        { "type": "delete", "label": "Delete", "text": "<exact highlighted text>", "note": null,
          "line": 12, "col_from": 17, "end_line": 12, "col_to": 32, "occurrence": 2, "seq": 3,
          "context": "<raw Markdown of the line(s) the selection touched>" } ],
      "manual_edits": { "note": "<already applied by the user>", "diff": "<unified diff>" } }
    ```
    - `annotations` are the requests. `manual_edits` is context: changes the user already made and saved. Keep them as
      they are; do not revert, redo or comment on them. Where an annotation covers text they also edited by hand, the
      annotation is what they want.
    - Find each annotation by position first. Lines are 1-based, columns 0-based UTF-16 within their own line.
      `col_to` belongs to `end_line`, not to `line`, because a selection can cross blocks. Slice the span out of the
      draft and compare it with `text`; when they differ, fall back to `context` and `text` instead of editing at a
      guessed offset.
    - `occurrence` says which instance of `text` on that line it is.
    - `seq` is press order. Apply overlapping annotations in ascending `seq`. If two truly conflict, the later one
      wins, and you say so in your summary.

    What each `type` asks for:
    \(marks)
    """
}

private func hint(_ hotkey: ReviewHotkey) -> String { hotkey.hint }

/// The topics `termdown agent-guide <topic>` prints, besides the main guide.
public let agentGuideTopics = ["review"]
