import Foundation

public let commandUsage = """
  Usage: termdown <command> [arguments]

  Commands:
    view <file>   Render a Markdown preview in this pane
    open [--new | --replace] <file>
                  Open a Markdown file in a preview pane. --new always opens a
                  new pane. --replace updates the preview this pane opened last.
    edit [--here] [--line N] <file>
                  Open the file's preview and edit it in your editor. --here
                  edits in the preview's own pane. --line N starts at line N.
    review [--check] <file>
                  Open the file's preview with review on: mark the draft up and
                  send each pass to the connected Claude Code session. --check
                  prints READY, LOCKED, NO_REX or NO_FILE and changes nothing.
    claude [<file>] [-- <agent arguments>]
                  Start Claude Code (the agent setting) in this pane, connected
                  to the preview this pane opened, or to <file>'s new preview.
    config [get|set|unset <name> [value]]
                  Show or change settings: previews, edit-mode, editor,
                  editor-kind, agent-pairing, agent
    setup         Install the handler app and register it
    uninstall     Remove the handler app and restore previous handlers
    doctor        Diagnose the installation
    agents <install|status|remove> [claude|codex|cursor ...]
                  Manage the coding-agent skill that opens previews, for every
                  agent found or only the ones named
    agent-guide [review]
                  Print guidance for coding agents; `review` prints how to
                  start a review and apply a pass.
    -v, --version Print the version
    --help        Show this help
  """
