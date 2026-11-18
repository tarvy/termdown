import Foundation
import TermDownCore
import TermDownInteraction

extension ViewerHost {
  /// Review mode turned on: log the draft as it stands, so a bad pass can be recovered.
  func launchReview() {
    guard let file = interaction.file else { return }
    let store = ReviewStore(draft: file)
    // One reviewer per draft: the interaction already turned review on, so a refusal turns it back off.
    guard store.acquireLock(pid: getpid()) else {
      perform(interaction.cancelReview(message: Self.reviewLockedMessage, at: Self.now()))
      return
    }
    reviewSession = (store, ReviewMarks())
    interaction.setReviewPass(store.nextPass() - 1)
    pinReviewAgent()
    if let marks = savedMarks(in: store) {
      reviewSession?.saved = marks
      perform(interaction.restoreMarks(marks, at: Self.now()))
    }
    do {
      try store.logLaunch(
        snapshot: interaction.review.snapshot ?? interaction.source, about: store.about(pass: store.nextPass()))
      trace("review launch \(store.logFile.path)")
    } catch {
      perform(interaction.show("Could not write the review log", kind: .error, at: Self.now()))
    }
  }

  static let reviewLockedMessage = "Review is already running for this file in another preview"

  /// The marks an earlier viewer left for this draft, moved from the text they were made on to the text now shown. A
  /// file with nothing left that fits is removed.
  func savedMarks(in store: ReviewStore) -> ReviewMarks? {
    guard let saved = store.loadMarks() else { return nil }
    let then = Array(saved.snapshot.utf8)
    var marks = ReviewMarks(restoring: saved.marks, within: then.count)
    marks.remap(from: then, to: Array(interaction.source.utf8))
    guard !marks.isEmpty else {
      store.clearMarks()
      return nil
    }
    return marks
  }

  /// After any batch of effects: write the marks if they changed (and remove the file when none are left), and let go of
  /// the review lock once review is off, whether by stopping, sending, discarding or leaving the file. A changes pane
  /// for a draft no longer shown closes. The checks compare two small arrays and two paths, so they cost nothing.
  func keepReviewSafe() {
    if let shown = changesPane?.store.draft.path, shown != interaction.file.map({ ReviewStore(draft: $0).draft.path }) {
      closeChanges()
    }
    guard var session = reviewSession else { return }
    let marks = interaction.review.marks
    if marks != session.saved {
      if marks.isEmpty {
        session.store.clearMarks()
        session.saved = marks
      } else if (try? session.store.saveMarks(marks.saved, snapshot: interaction.source)) != nil {
        session.saved = marks
      } else {
        trace("review marks not saved \(session.store.marksFile.path)")
      }
    }
    if interaction.review.isOn {
      reviewSession = session
    } else {
      releaseReviewLock()
    }
  }

  func releaseReviewLock() {
    reviewSession?.store.releaseLock()
    reviewSession = nil
  }

  /// `D`: what changed since the last pass sent for this draft, written to the review store and shown in a Rex pane to
  /// the right of the preview, with review on or off. Pressing it again rewrites the file, which the pane watches, rather
  /// than opening a second pane. The pane stays until the preview quits or shows another file.
  func showChanges() {
    guard let file = interaction.file else { return }
    let store = reviewSession?.store ?? ReviewStore(draft: file)
    let text = interaction.edit?.source ?? interaction.source
    guard let changes = AppliedChanges.compute(log: store.logFile, current: text) else {
      return perform(interaction.show("No earlier pass to compare against", kind: .info, at: Self.now()))
    }
    let shown = "Changes since pass \(changes.fromPass) shown beside the preview"
    do {
      try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
      try Data(changes.markdown().utf8).write(to: store.changesFile, options: .atomic)
    } catch {
      return perform(interaction.show("Could not write the changes", kind: .error, at: Self.now()))
    }
    if let pane = changesPane?.block, editor?.isClosed(pane) == false {
      trace("review changes refreshed \(store.changesFile.path)")
      return perform(interaction.show(shown, kind: .info, at: Self.now()))
    }
    changesPane = nil
    guard let pane = editor?.openChanges(file: store.changesFile) else {
      try? FileManager.default.removeItem(at: store.changesFile)
      return perform(
        interaction.show("Could not open the changes: not running in a Rex pane", kind: .error, at: Self.now()))
    }
    changesPane = (pane, store)
    trace("review changes \(pane) \(store.changesFile.path)")
    perform(interaction.show(shown, kind: .info, at: Self.now()))
  }

  /// The preview quit or moved to another file: the changes pane, if it is still there, and its file go with it.
  func closeChanges() {
    guard let (pane, store) = changesPane else { return }
    editor?.closePane(pane)
    changesPane = nil
    try? FileManager.default.removeItem(at: store.changesFile)
  }

  /// `s`: once the review agent's own pane is at an idle, empty prompt, write the pass's edits file and log record, send
  /// the handoff with Enter, and end review. Every pass is written as `finish`: it stands alone, and the agent carries
  /// on with the conversation rather than waiting for another. With no agent in a Rex pane to send to there is no
  /// fallback to the opener: nothing is written or sent. Focus stays here. A refused pass writes nothing and keeps the
  /// marks with review on, and nothing goes to the clipboard while reviewing. A pass that was written but left
  /// unsubmitted in the agent's prompt still counts; one Rex could not deliver keeps the marks for a resend.
  func submitReview() {
    let action = ReviewAction.finish
    guard let file = interaction.file else { return }
    flushEdits()
    if interaction.edit?.isDirty == true {
      perform(interaction.show("Save the draft before submitting the review", kind: .error, at: Self.now()))
      return
    }
    guard let editor else {
      return perform(interaction.show(ViewerInteraction.noAgentMessage, kind: .info, at: Self.now()))
    }
    let store = ReviewStore(draft: file)
    let text = interaction.source
    let annotations = interaction.review.marks.annotations(in: Array(text.utf8))
    let launchText = interaction.review.snapshot ?? text
    var pass = 0
    let result: ReviewSendResult
    do {
      result = try editor.sendReview(
        prompt: { [self] in
          pass = try store.submit(
            action: action, annotations: annotations, launchText: launchText, finalText: text,
            about: store.about(pass: store.nextPass()))
          let edits = store.passEditsFile(pass)
          trace("review pass \(pass) \(action.rawValue) \(edits.path)")
          return AgentPrompt.review(draft: store.draft.path, edits: edits.path, pass: pass)
        }, target: ide?.reviewTarget)
    } catch {
      perform(interaction.show("Could not write the review files", kind: .error, at: Self.now()))
      return
    }
    switch result {
    case .sent(let title):
      perform(interaction.reviewSubmitted(pass: pass))
      let agent = (title ?? interaction.reviewAgent.title).map { " to \($0)" } ?? ""
      perform(interaction.show("Pass \(pass) sent\(agent)", kind: .success, at: Self.now()))
    case .pasted(let dialog):
      // Never tell the person to press Enter: the pane may be showing a dialog that Enter would answer.
      perform(interaction.reviewSubmitted(pass: pass))
      let why = dialog ? "a dialog is open in the agent's pane" : "check the agent's pane"
      perform(interaction.show("Pass \(pass) written but not submitted: \(why)", kind: .info, at: Self.now()))
    case .unreachable:
      perform(
        interaction.show(
          "Could not reach the agent's pane: pass \(pass) is saved, press s to resend", kind: .error, at: Self.now()))
    case .busy:
      perform(interaction.show(Self.agentBusyMessage, kind: .error, at: Self.now()))
    case .noAgent:
      perform(interaction.show(ViewerInteraction.noAgentMessage, kind: .info, at: Self.now()))
    }
  }

  static let agentBusyMessage = "Agent is busy or has unsent text: finish there, then press s again"

  /// The marks as the painter takes them, rebuilt only when the marks or the prepared document change.
  func reviewAnnotations() -> [(rendered: Range<Int>, color: RGB)] {
    let marks = interaction.review.marks
    guard !marks.isEmpty, let prepared = interaction.layout?.prepared else { return [] }
    if let cached = reviewOverlay, cached.marks == marks, cached.prepared === prepared { return cached.annotations }
    let annotations = interaction.renderedReviewMarks.map {
      (rendered: $0.rendered, color: parseHexColor($0.color) ?? RGB(hex: 0x9ca3af))
    }
    reviewOverlay = (marks, prepared, annotations)
    return annotations
  }

  /// The typed edits as rendered ranges, rebuilt only when the draft, its snapshot or the prepared document change.
  func reviewTypedEdits() -> [Range<Int>] {
    guard interaction.review.isOn, let prepared = interaction.layout?.prepared else { return [] }
    let snapshot = interaction.review.snapshot
    let text = interaction.edit?.source ?? interaction.source
    if let cached = typedOverlay, cached.snapshot == snapshot, cached.text == text, cached.prepared === prepared {
      return cached.ranges
    }
    let ranges = interaction.renderedTypedEdits
    typedOverlay = (snapshot, text, prepared, ranges)
    return ranges
  }
}
