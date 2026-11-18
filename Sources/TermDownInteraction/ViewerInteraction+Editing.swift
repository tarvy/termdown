import CoreGraphics
import Foundation
import TermDownCore
import TermDownDocument
import TermDownLayout
import TermDownRender

struct EditLayoutKey: Equatable {
  var revision: Int
  var reveal: [Range<Int>]
  var placeholder: Int?
}

extension ViewerInteraction {
  public var isEditing: Bool { edit != nil }

  var caretWidth: CGFloat { max(typography.backingScale.rounded(), 1) }

  // MARK: Entering and leaving

  /// Starts editing in place, with the caret at the start of the selection or the first line in view.
  /// Starts editing with the caret at `rendered` (a clicked text offset), else at the selection or the top line.
  mutating func beginEditing(at now: UInt64, rendered clicked: Int? = nil) -> [InteractionEffect] {
    guard file != nil, edit == nil else { return [] }
    if let editRefusal { return show(editRefusal, kind: .error, at: now) }
    if liveBuffer || (editorLink?.syncsLive ?? false) {
      return show("Editing in place is off while an editor syncs this file live", kind: .error, at: now)
    }
    var caret: Int?
    let text = EditableText(source: source)
    if let layout {
      let rendered: Int? = clicked ?? overlay.selection?.lowerBound ?? topLine(in: layout)?.range.lowerBound
      if let rendered, let range = layout.sourceRange(for: rendered..<(rendered + 1)) {
        caret = text.offset(range.start)
      }
    }
    var session = EditSession(source: source, caret: caret)
    if let clicked, let layout, let block = session.block(containing: session.caret) {
      // The view's rendered text of a block equals its caret-free projection, so the click maps through it.
      let unit = layout.unitRange(at: clicked)
      let projection = session.projection(of: block, caret: nil)
      let within = clicked - unit.lowerBound
      if within >= 0, within <= projection.length {
        session.move(to: projection.source(atRendered: within), extend: false)
      }
    }
    edit = session
    overlay.selection = nil
    selectionAnchor = nil
    caretShown = true
    blinkDeadline = now + timing.blinkNanoseconds
    return show("Editing: Esc to finish", kind: .info, at: now) + editLayout(force: true) + [.redrawStatusBar]
  }

  /// The save for the session's current text, if it has unsaved changes.
  func saveRequest(force: Bool = false) -> SaveRequest? {
    guard let session = edit, let file, session.isDirty || force else { return nil }
    return SaveRequest(text: session.source, revision: session.revision, file: file, base: session.base, force: force)
  }

  /// Leaves editing. With unsaved changes it saves first and leaves once the save is confirmed; while the file
  /// has changed on disk it stays, so neither version is lost.
  mutating func endEditing(at now: UInt64) -> [InteractionEffect] {
    guard edit != nil else { return [] }
    if editConflict {
      return show("File changed on disk: Cmd-S keeps your text, Cmd-R takes the file's", kind: .error, at: now)
    }
    if let request = saveRequest() {
      pendingExit = true
      return [.save(request)]
    }
    return finishEditing()
  }

  mutating func finishEditing() -> [InteractionEffect] {
    guard let session = edit else { return [] }
    var effects: [InteractionEffect] = []
    source = session.source
    edit = nil
    editLayoutKey = nil
    autosaveDeadline = nil
    blinkDeadline = nil
    caretShown = true
    caretRect = nil
    pendingExit = false
    editConflict = false
    let old = overlay.caret
    overlay.caret = nil
    overlay.selection = nil
    effects += old.map { [.redraw($0.insetBy(dx: -2, dy: -2))] } ?? []
    effects += requestLayout(source: source, anchor: .offset(offset))
    effects.append(.redrawStatusBar)
    return effects
  }

  /// The host wrote `text` (the text of `revision`) to disk.
  public mutating func saved(revision: Int, text: String) -> [InteractionEffect] {
    guard var session = edit else { return [] }
    session.markSaved(revision: revision, text: text)
    edit = session
    editConflict = false
    if pendingExit, !session.isDirty { return finishEditing() }
    pendingExit = false
    return [.redrawStatusBar]
  }

  /// The host did not write: the file changed on disk since editing began (or the write failed).
  public mutating func saveRefused(_ reason: String, conflict: Bool, at now: UInt64) -> [InteractionEffect] {
    pendingExit = false
    autosaveDeadline = nil
    if conflict { editConflict = true }
    return show(reason, kind: .error, at: now) + [.redrawStatusBar]
  }

  /// The file's text replaces the edited text (after Cmd-R in a conflict).
  public mutating func takeDiskVersion(_ text: String) -> [InteractionEffect] {
    guard var session = edit else { return [] }
    session.reload(text)
    edit = session
    editConflict = false
    return editLayout(force: true) + [.redrawStatusBar]
  }

  /// Why the shown file cannot be edited in place (not UTF-8, unreadable), or nil.
  public mutating func setEditRefusal(_ reason: String?) { editRefusal = reason }

  /// The shown file disappeared: stop autosaving, so a save does not recreate it unasked.
  public mutating func fileMissing(at now: UInt64) -> [InteractionEffect] {
    guard edit != nil else { return [] }
    editConflict = true
    autosaveDeadline = nil
    return [.redrawStatusBar]
  }

  public var editBadge: String? {
    guard let edit else { return nil }
    if editConflict { return "editing, file changed on disk" }
    return edit.isDirty ? "editing, unsaved" : "editing"
  }

  // MARK: Layout and overlay

  private func layoutKey(for session: EditSession) -> EditLayoutKey {
    EditLayoutKey(
      revision: session.revision, reveal: session.revealKey(at: session.caret),
      placeholder: session.blankStop(at: session.caret) == session.caret ? session.caret : nil)
  }

  /// Requests a layout when the source or the revealed syntax changed; otherwise only moves the caret.
  mutating func editLayout(force: Bool = false) -> [InteractionEffect] {
    guard let session = edit else { return [] }
    let key = layoutKey(for: session)
    if force || key != editLayoutKey {
      editLayoutKey = key
      source = session.source
      return requestLayout(source: session.source, anchor: .offset(offset), keepAnchor: true)
    }
    return syncEditOverlay(reveal: true)
  }

  /// Places the caret and selection overlays from the session, scrolling the caret into view when asked.
  mutating func syncEditOverlay(reveal: Bool) -> [InteractionEffect] {
    guard let session = edit, let layout else { return [] }
    var effects: [InteractionEffect] = []
    let prepared = layout.prepared
    let caretRendered = prepared.renderedOffset(forSource: session.caret)
    let rect = caretRendered.flatMap { layout.caretRect(atRendered: $0, width: caretWidth) }
    caretRect = rect
    let shown = caretShown ? rect : nil
    if shown != overlay.caret {
      for old in [overlay.caret, shown].compactMap({ $0 }) { effects.append(.redraw(old.insetBy(dx: -2, dy: -2))) }
      overlay.caret = shown
    }
    var rendered: Range<Int>?
    if let selection = session.selection, let start = nearestRendered(selection.lowerBound, in: prepared),
      let end = nearestRendered(selection.upperBound, in: prepared), start < end
    {
      rendered = start..<end
    }
    effects += setSelection(rendered)
    if reveal, let rect { effects += self.reveal(rect, margin: geometry.rowHeight * 2) }
    return effects
  }

  /// The rendered offset of a source offset, or of the nearest editable text before it.
  func nearestRendered(_ source: Int, in prepared: PreparedDocument) -> Int? {
    if let exact = prepared.renderedOffset(forSource: source) { return exact }
    if let before = prepared.editRegions.last(where: { $0.source.upperBound <= source }) {
      return before.range.lowerBound + before.projection.length
    }
    return prepared.editRegions.first.map(\.range.lowerBound)
  }

  // MARK: Caret blink

  /// Shows the caret solidly and starts the blink over, after typing, moving or clicking.
  mutating func restartBlink(at now: UInt64) -> [InteractionEffect] {
    guard edit != nil else { return [] }
    blinkDeadline = now + timing.blinkNanoseconds
    guard !caretShown else { return [] }
    caretShown = true
    overlay.caret = caretRect
    return caretRect.map { [.redraw($0.insetBy(dx: -2, dy: -2))] } ?? []
  }

  mutating func blink(at now: UInt64) -> [InteractionEffect] {
    guard edit != nil else {
      blinkDeadline = nil
      return []
    }
    caretShown.toggle()
    blinkDeadline = now + timing.blinkNanoseconds
    let old = overlay.caret
    overlay.caret = caretShown ? caretRect : nil
    return [old, overlay.caret].compactMap { $0 }.map { .redraw($0.insetBy(dx: -2, dy: -2)) }
  }

  // MARK: Keys

  mutating func handleEditing(key: Key, at now: UInt64) -> [InteractionEffect] {
    let effects = handleEditingKey(key, at: now)
    return restartBlink(at: now) + effects
  }

  mutating func handleEditingKey(_ key: Key, at now: UInt64) -> [InteractionEffect] {
    guard var session = edit else { return [] }
    let modifiers = key.modifiers
    let extend = modifiers.contains(.shift)
    let word = modifiers.contains(.alt) || modifiers.contains(.control)
    var changed = true
    switch key.base {
    case .escape:
      return endEditing(at: now)
    case .ctrl("c"), .ctrl("q"):
      // The host flushes unsaved edits before it quits.
      edit = session
      return [.quit]
    case .char(let character):
      if let (hotkey, range) = reviewHotkey(for: character) { return annotate(hotkey, range: range, at: now) }
      session.insert(String(character))
    case .enter:
      if modifiers.contains(.shift) { session.softBreak() } else { session.newParagraph() }
    case .tab:
      session.insert("\t")
    case .backspace, .shiftBackspace:
      // macOS and VS Code: Option deletes a word, Command deletes to the line edge.
      if modifiers.contains(.command) {
        edit = session
        return deleteToLineEdge(end: false, at: now)
      }
      session.deleteBackward(word: word)
    case .delete:
      if modifiers.contains(.command) {
        edit = session
        return deleteToLineEdge(end: true, at: now)
      }
      session.deleteForward(word: word)
    case .left, .right:
      if modifiers.contains(.command) {
        edit = session
        return moveToLineEdge(end: key.base == .right, extend: extend)
      }
      session.moveHorizontally(forward: key.base == .right, word: word, extend: extend)
      changed = false
    case .up, .down:
      edit = session
      if modifiers.contains(.command) { return moveToDocumentEdge(end: key.base == .down, extend: extend) }
      return moveVertically(down: key.base == .down, lines: 1, extend: extend)
    case .home, .end:
      edit = session
      return moveToLineEdge(end: key.base == .end, extend: extend)
    case .pageUp, .pageDown:
      edit = session
      let lines = max(Int(geometry.contentHeight / max(geometry.rowHeight * 2, 1)), 1)
      return moveVertically(down: key.base == .pageDown, lines: lines, extend: extend)
    case .command("z"):
      if modifiers.contains(.shift) { session.redo() } else { session.undo() }
    case .command("a"):
      session.selectAll()
      changed = false
    case .command("c"):
      guard let text = session.selectedSource else { return show("Nothing selected", kind: .info, at: now) }
      return copy(text, markdown: true, at: now)
    case .command("x"):
      guard let text = session.selectedSource else { return [] }
      session.deleteSelection()
      edit = session
      return copy(text, markdown: true, at: now) + editLayout() + [.redrawStatusBar]
    case .command("b"):
      return formatSelection(.bold, at: now)
    case .command("i"):
      return formatSelection(.italic, at: now)
    case .command("k"):
      return askLinkURL(at: now)
    case .command("="), .command("+"):
      edit = session
      return setZoom(ZoomSteps.next(after: zoom), at: now)
    case .command("-"):
      edit = session
      return setZoom(ZoomSteps.previous(before: zoom), at: now)
    case .command("0"):
      edit = session
      return setZoom(1, at: now)
    case .command("s"):
      edit = session
      // An explicit save overwrites a file that changed on disk: the person chose their text.
      return saveRequest(force: editConflict).map { [.save($0)] } ?? []
    case .command("r"):
      guard editConflict, let file else { return [] }
      edit = session
      editConflict = false
      return [.reloadEdit(file)]
    case .command("l"):
      edit = session
      // Save first, so the agent reads the same lines the person sees.
      let save = saveRequest().map { [InteractionEffect.save($0)] } ?? []
      return file == nil ? [] : save + [.askAgent(editAgentRequest(session))]
    default:
      return []
    }
    edit = session
    if changed, session.isDirty, !editConflict { autosaveDeadline = now + timing.autosaveNanoseconds }
    return editLayout() + (changed ? [.redrawStatusBar] : [])
  }

  static let linkPrompt = "Link URL:"
  static let formatRefusal = "Select text in one paragraph, or put the caret in a word"

  /// Cmd-B and Cmd-I while reviewing: bold or italic around the selection or the word at the caret, or off again.
  mutating func formatSelection(_ emphasis: EditSession.Emphasis, at now: UInt64) -> [InteractionEffect] {
    guard review.isOn, var session = edit else { return [] }
    guard session.toggle(emphasis) else { return show(Self.formatRefusal, kind: .info, at: now) }
    edit = session
    if session.isDirty, !editConflict { autosaveDeadline = now + timing.autosaveNanoseconds }
    return editLayout() + [.redrawStatusBar]
  }

  /// Cmd-K while reviewing: ask for a URL in the status bar, then link the selection or word to it.
  mutating func askLinkURL(at now: UInt64) -> [InteractionEffect] {
    guard review.isOn, let session = edit else { return [] }
    guard let target = session.linkTarget() else { return show(Self.formatRefusal, kind: .info, at: now) }
    pendingLink = target
    noteField = ""
    return [.redrawStatusBar]
  }

  mutating func handleLinkField(_ key: Key, at now: UInt64) -> [InteractionEffect] {
    switch key {
    case .char(let character):
      noteField?.append(character)
    case .backspace:
      if noteField?.isEmpty == false { noteField?.removeLast() }
    case .enter:
      let url = MarkdownHTML.normalizeURL(noteField ?? "")
      let pending = pendingLink
      noteField = nil
      pendingLink = nil
      guard !url.isEmpty, let pending, var session = edit else { return [.redrawStatusBar] }
      guard session.link(range: pending.range, text: pending.text, url: url) else {
        return show("The text changed: link not added", kind: .error, at: now)
      }
      edit = session
      if session.isDirty, !editConflict { autosaveDeadline = now + timing.autosaveNanoseconds }
      return editLayout() + [.redrawStatusBar]
    case .escape:
      noteField = nil
      pendingLink = nil
    case .ctrl("c"), .ctrl("q"):
      return [.quit]
    default:
      return []
    }
    return [.redrawStatusBar]
  }

  mutating func handleEditing(paste text: String, at now: UInt64 = 0) -> [InteractionEffect] {
    guard var session = edit else { return [] }
    blinkDeadline = now + timing.blinkNanoseconds
    caretShown = true
    session.paste(text)
    edit = session
    if !editConflict { autosaveDeadline = 0 }
    return editLayout() + [.redrawStatusBar]
  }

  func editAgentRequest(_ session: EditSession) -> AgentRequest {
    let text = EditableText(source: session.source)
    let range = session.selection ?? session.caret..<session.caret
    let start = text.position(ofByte: range.lowerBound).line
    let end = text.position(ofByte: max(range.upperBound - 1, range.lowerBound)).line
    return AgentRequest(startLine: start, endLine: max(start, end), quote: session.selectedSource ?? "")
  }

  /// For text outside any edit region (a code block or table shown normally): the start of its source, so the
  /// caret enters that block and it turns raw.
  func unitSource(_ rendered: Int, in prepared: PreparedDocument) -> Int? {
    guard let session = edit,
      let unit = prepared.units.last(where: { $0.range.lowerBound <= rendered && rendered <= $0.range.upperBound }),
      let offset = session.text.offset(unit.source.start), session.block(containing: offset)?.isRaw == true
    else { return nil }
    return session.stop(near: offset)
  }

  // MARK: Layout-dependent movement

  /// Whether the shown layout was prepared from the session's current text. Moves that read rendered positions
  /// are dropped otherwise, so they never apply an old map to new bytes.
  var layoutIsCurrent: Bool {
    guard let edit, let revision = layout?.prepared.editing?.revision else { return false }
    return revision == edit.revision
  }

  mutating func moveVertically(down: Bool, lines: Int, extend: Bool) -> [InteractionEffect] {
    guard layoutIsCurrent, var session = edit, let layout else { return [] }
    let prepared = layout.prepared
    guard let rendered = prepared.renderedOffset(forSource: session.caret),
      var rect = layout.caretRect(atRendered: rendered, width: 1)
    else { return [] }
    let x = session.goalX ?? rect.midX
    var target = session.caret
    var remaining = lines
    while remaining > 0 {
      // The nearest line strictly above or below, among fragments of editable text.
      let candidates = layout.fragments.filter { fragment in
        down ? fragment.lineTop >= rect.maxY - 0.5 : fragment.lineBottom <= rect.minY + 0.5
      }
      guard let line = down ? candidates.min(by: { $0.lineTop < $1.lineTop }) : candidates.max(by: { $0.lineTop < $1.lineTop })
      else {
        target = down ? (prepared.editRegions.last.map { $0.projection.boundaries.last ?? $0.source.upperBound } ?? target)
          : (prepared.editRegions.first.map { $0.projection.boundaries[0] } ?? target)
        break
      }
      let point = CGPoint(x: x, y: (line.lineTop + line.lineBottom) / 2)
      rect = CGRect(x: rect.minX, y: line.lineTop, width: 1, height: line.lineBottom - line.lineTop)
      guard let position = layout.textPosition(at: point)?.offset,
        let source = prepared.sourceOffset(forRendered: position) ?? unitSource(position, in: prepared)
      else { continue }
      target = source
      remaining -= 1
    }
    session.move(to: target, extend: extend)
    session.goalX = x
    edit = session
    return editLayout()
  }

  mutating func moveToLineEdge(end: Bool, extend: Bool) -> [InteractionEffect] {
    guard layoutIsCurrent, var session = edit, let layout, let rendered = layout.prepared.renderedOffset(forSource: session.caret)
    else { return [] }
    let line = layout.lineFragments(atRendered: rendered)
    let edge = end ? line.map(\.range.upperBound).max() : line.map(\.range.lowerBound).min()
    guard let edge, let source = layout.prepared.sourceOffset(forRendered: edge) else { return [] }
    session.move(to: source, extend: extend)
    session.goalX = nil
    edit = session
    return editLayout()
  }

  /// Cmd-Backspace and Cmd-Delete: remove the text between the caret and the visual line's edge.
  mutating func deleteToLineEdge(end: Bool, at now: UInt64) -> [InteractionEffect] {
    guard var session = edit else { return [] }
    if session.selection != nil {
      session.deleteSelection()
    } else {
      edit = session
      _ = moveToLineEdge(end: end, extend: true)
      guard var moved = edit, moved.selection != nil else { return [] }
      moved.deleteSelection()
      session = moved
    }
    edit = session
    if session.isDirty, !editConflict { autosaveDeadline = now + timing.autosaveNanoseconds }
    return editLayout() + [.redrawStatusBar]
  }

  mutating func moveToDocumentEdge(end: Bool, extend: Bool) -> [InteractionEffect] {
    guard var session = edit, let block = end ? session.blocks.last : session.blocks.first else { return [] }
    let projection = session.projection(of: block, caret: nil)
    session.move(to: end ? (projection.boundaries.last ?? block.source.upperBound) : projection.boundaries[0], extend: extend)
    edit = session
    return editLayout()
  }

  // MARK: Pointer

  /// A click (or drag) in edit mode places the caret (or selects) in source terms once the button is up.
  mutating func editingReleased(press current: Press) -> [InteractionEffect] {
    guard layoutIsCurrent, var session = edit, let layout else { return [] }
    let prepared = layout.prepared
    if let selection = overlay.selection, !selection.isEmpty, current.moved || clicks?.count ?? 1 > 1 {
      let pressedAt = current.textOffset ?? selection.lowerBound
      let towardsEnd = current.shiftAnchor.map { $0 <= selection.lowerBound } ?? (pressedAt <= selection.lowerBound)
      let anchorRendered = towardsEnd ? selection.lowerBound : selection.upperBound
      let caretRendered = towardsEnd ? selection.upperBound : selection.lowerBound
      if let anchor = sourceNear(anchorRendered, in: prepared), let caret = sourceNear(caretRendered, in: prepared) {
        session.move(to: anchor, extend: false)
        session.move(to: caret, extend: true)
      }
    } else if let pane = pointer, let position = layout.textPosition(at: pagePoint(pane))?.offset,
      let source = sourceNear(position, in: prepared)
    {
      session.move(to: source, extend: false)
    }
    session.goalX = nil
    edit = session
    return editLayout()
  }

  /// The source offset of a rendered offset, or of the nearest editable text.
  func sourceNear(_ rendered: Int, in prepared: PreparedDocument) -> Int? {
    if let exact = prepared.sourceOffset(forRendered: rendered) { return exact }
    if let unit = unitSource(rendered, in: prepared) { return unit }
    let regions = prepared.editRegions
    guard !regions.isEmpty else { return nil }
    let after = regions.first { $0.range.lowerBound > rendered }
    let before = regions.last { $0.range.upperBound < rendered }
    if let before, after == nil || rendered - before.range.upperBound <= (after!.range.lowerBound - rendered) {
      return before.projection.boundaries.last
    }
    return after?.projection.boundaries.first
  }
}

/// The selection in source terms, for Claude Code's IDE protocol: 0-based lines, UTF-8 byte columns, exclusive
/// end. An empty one is a caret (or, when viewing, the top line in view).
public struct SourceSelection: Equatable, Sendable {
  public var text: String
  public var startLine: Int
  public var startCharacter: Int
  public var endLine: Int
  public var endCharacter: Int
}

extension ViewerInteraction {
  public var sourceSelection: SourceSelection? {
    guard file != nil else { return nil }
    if let session = edit {
      let range = session.selection ?? session.caret..<session.caret
      let start = session.text.position(ofByte: range.lowerBound)
      let end = session.text.position(ofByte: range.upperBound)
      return SourceSelection(
        text: session.selectedSource ?? "", startLine: start.line - 1, startCharacter: start.column - 1,
        endLine: end.line - 1, endCharacter: end.column - 1)
    }
    guard let layout else { return nil }
    if let selection = overlay.selection, !selection.isEmpty, let range = layout.sourceRange(for: selection) {
      return SourceSelection(
        text: layout.plainText(selection), startLine: range.start.line - 1, startCharacter: max(range.start.column - 1, 0),
        endLine: range.end.line - 1, endCharacter: range.end.column)
    }
    let line = max(editLine - 1, 0)
    return SourceSelection(text: "", startLine: line, startCharacter: 0, endLine: line, endCharacter: 0)
  }
}
