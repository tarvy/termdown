import CoreGraphics
import Foundation
import TermDownCore
import TermDownLayout
import TermDownRender

public enum InteractionEffect: Equatable {
  case redraw(CGRect)
  case redrawStatusBar
  case redrawAll
  case scroll(to: CGFloat)
  case layoutChanged
  case regionScrolled(BlockID, offset: CGFloat)
  case requestLayout(LayoutRequest)
  case writeClipboard(String, markdown: Bool)
  /// Put HTML and its plain-text twin on the clipboard together, so mail clients paste the formatting.
  case writeRichClipboard(html: String, plain: String)
  case pointerShape(PointerShape)
  case loadDocument(URL)
  case reload
  case quit
  case edit(EditRequest)
  case openEditorPicker
  case chooseEditor(EditorCandidate, mode: EditMode, pending: EditRequest?)
  case jumpEditor(line: Int)
  case askAgent(AgentRequest)
  /// Show which agents the selection goes to, and let the person pick (A, or Rex's palette).
  case openAgentPicker
  case chooseAgent(AgentPickerRow.Action)
  /// Write edited markdown atomically; answer with `saved` or `saveRefused`.
  case save(SaveRequest)
  /// Read the file again and replace the edited text with it (the person chose the file's version).
  case reloadEdit(URL)
  /// `m` with several agents and none chosen: the host opens the agent picker in its review form, and on a choice
  /// routes to that agent and calls `startReview`.
  case chooseReviewAgent
  /// Review mode turned on: write the launch record.
  case reviewLaunched
  /// `s`: write the edits file and the log record, then hand the pass to the agent.
  case submitReview
  /// `D` while reviewing: the host works out what changed since the last pass and shows it in a pane beside the preview.
  case showChanges
}

/// A review pass over the shown file: whether review mode is on, its marks, and the source at review start or
/// the last Go, which the manual-edits diff is taken against.
public struct ReviewState: Equatable, Sendable {
  public var isOn = false
  public var marks = ReviewMarks()
  public var snapshot: String?
  public var pass = 0

  public init() {}
}

/// Which agent session a review goes to, as the host last reported it. Review goes to exactly one session, so
/// "all connected agents" is never a choice.
public struct ReviewAgentStatus: Equatable, Sendable {
  /// Agent sessions connected to the viewer.
  public var connected: Int
  /// The paired agent's pane title, when known.
  public var title: String?
  /// Exactly one agent is the review target, in a Rex pane.
  public var chosen: Bool
  /// The one agent the selection goes to runs outside Rex: it is connected, but a review has no pane to paste into.
  public var outsideRex: Bool

  public init(connected: Int, title: String?, chosen: Bool, outsideRex: Bool = false) {
    self.connected = connected
    self.title = title
    self.chosen = chosen
    self.outsideRex = outsideRex
  }
}

/// What a yes at a discard prompt does.
public enum ConfirmAction: Equatable, Sendable {
  case discardAndStop
  case discardAndQuit
  case discardAndOpen(URL)
}

/// A yes/no question shown in the status bar that takes the next key before anything else.
public struct ReviewConfirm: Equatable, Sendable {
  public var prompt: String
  public var action: ConfirmAction

  public init(prompt: String, action: ConfirmAction) {
    self.prompt = prompt
    self.action = action
  }
}

/// Ask the agent pane about a selection: its source lines and text.
public struct AgentRequest: Equatable, Sendable {
  public var startLine: Int
  public var endLine: Int
  public var quote: String

  public init(startLine: Int, endLine: Int, quote: String) {
    self.startLine = startLine
    self.endLine = endLine
    self.quote = quote
  }
}

public struct EditRequest: Equatable, Sendable {
  public var mode: EditRequestMode
  public var line: Int

  public init(mode: EditRequestMode, line: Int) {
    self.mode = mode
    self.line = line
  }
}

public struct EditorLink: Equatable, Sendable {
  public var name: String
  public var syncsLive: Bool
  public var followsShownFile: Bool

  public init(name: String, syncsLive: Bool, followsShownFile: Bool) {
    self.name = name
    self.syncsLive = syncsLive
    self.followsShownFile = followsShownFile
  }
}

public struct EditorCursor: Equatable, Sendable {
  public var line: Int
  public var top: Int
  public var height: Int

  public init(line: Int, top: Int, height: Int) {
    self.line = line
    self.top = top
    self.height = height
  }
}

public struct ViewGeometry: Equatable, Sendable {
  public var width: CGFloat
  public var contentHeight: CGFloat
  public var rowHeight: CGFloat

  public init(width: CGFloat, contentHeight: CGFloat, rowHeight: CGFloat) {
    self.width = width
    self.contentHeight = contentHeight
    self.rowHeight = rowHeight
  }
}

public struct InteractionEnvironment {
  public var fileExists: (URL) -> Bool
  public var isSafeToOpenLocally: (URL) -> Bool
  public var openURL: (URL) -> Bool
  public var copyOnSelect: () -> Bool

  public init(
    fileExists: @escaping (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
    isSafeToOpenLocally: @escaping (URL) -> Bool = TermDownCore.isSafeToOpenLocally,
    openURL: @escaping (URL) -> Bool,
    copyOnSelect: @escaping () -> Bool = { RexPreferences().copyOnSelect }
  ) {
    self.fileExists = fileExists
    self.isSafeToOpenLocally = isSafeToOpenLocally
    self.openURL = openURL
    self.copyOnSelect = copyOnSelect
  }
}

public enum Focusable: Hashable, Sendable {
  case link(Range<Int>, href: String)
  case details(BlockID)
  case codeBlock(BlockID)
  case table(BlockID)
  case video(Int, href: String)
}

/// One save: the text, the file it belongs to, and the disk bytes it was edited from. Unless forced, the host
/// writes only while the disk still holds `base`.
public struct SaveRequest: Equatable, Sendable {
  public var text: String
  public var revision: Int
  public var file: URL
  public var base: [UInt8]
  public var force: Bool
}

public struct InteractionTiming: Sendable {
  public var multiClickNanoseconds: UInt64 = 400_000_000
  public var autoScrollNanoseconds: UInt64 = 30_000_000
  public var wheelStreakNanoseconds: UInt64 = 60_000_000
  public var copiedNanoseconds: UInt64 = 1_500_000_000
  public var infoNanoseconds: UInt64 = 2_500_000_000
  public var successNanoseconds: UInt64 = 2_000_000_000
  public var errorNanoseconds: UInt64 = 4_000_000_000
  public var autosaveNanoseconds: UInt64 = 500_000_000
  /// Half a caret blink, as on macOS.
  public var blinkNanoseconds: UInt64 = 530_000_000

  public init() {}
}

public struct WheelAccelerator: Sendable {
  public static let maximumMultiplier = 4

  public var streakWindow: UInt64
  private var lastEvent: UInt64?
  private var lastDirection = 0
  private var streak = 0

  public init(streakWindow: UInt64 = InteractionTiming().wheelStreakNanoseconds) {
    self.streakWindow = streakWindow
  }

  public mutating func multiplier(direction: Int, at now: UInt64) -> Int {
    if let lastEvent, now >= lastEvent, now - lastEvent <= streakWindow, direction == lastDirection {
      streak += 1
    } else {
      streak = 0
    }
    lastEvent = now
    lastDirection = direction
    return min(1 + streak / 3, Self.maximumMultiplier)
  }
}

public enum ZoomSteps {
  public static let levels: [CGFloat] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]

  public static func next(after zoom: CGFloat) -> CGFloat {
    levels.first { $0 > zoom + 0.001 } ?? levels[levels.count - 1]
  }

  public static func previous(before zoom: CGFloat) -> CGFloat {
    levels.last { $0 < zoom - 0.001 } ?? levels[0]
  }
}
