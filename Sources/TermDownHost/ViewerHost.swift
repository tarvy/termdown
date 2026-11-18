import CoreGraphics
import Foundation
import TermDownCore
import TermDownDisplay
import TermDownInteraction
import TermDownLayout
import TermDownMermaid
import TermDownRender

public struct HostServices {
  public var output: TerminalOutput
  public var pasteboard: PasteboardWriting
  public var stagers: (primary: FrameStager, fallback: FrameStager?)
  public var environment: InteractionEnvironment
  public var readFile: (URL) throws -> String
  /// Writes edited markdown. The default replaces the file atomically, keeping its permissions.
  public var writeFile: (URL, String) throws -> Void = writeMarkdown(_:_:)
  public var images: ImageStore
  public var highlighter: SyntaxHighlighter?
  public var mermaid: MermaidRenderer?
  public var resolveTheme: @Sendable (TerminalColorSet) -> ResolvedTheme
  public var crossCheck: @Sendable (ResolvedTheme) -> String?
  public var log: @Sendable (String) -> Void
  public var trace: (@Sendable (String) -> Void)?
  public var screenScale: CGFloat?
  public var watchesFiles: Bool
  public var reduceMotion: () -> Bool

  public init(
    output: TerminalOutput, pasteboard: PasteboardWriting = SystemPasteboard(),
    stagers: (primary: FrameStager, fallback: FrameStager?),
    environment: InteractionEnvironment, readFile: @escaping (URL) throws -> String = readMarkdown(at:),
    images: ImageStore = ImageStore(), highlighter: SyntaxHighlighter? = nil, mermaid: MermaidRenderer? = nil,
    resolveTheme: @escaping @Sendable (TerminalColorSet) -> ResolvedTheme = {
      ResolvedTheme(colors: $0, source: .terminalQuery)
    },
    crossCheck: @escaping @Sendable (ResolvedTheme) -> String? = { _ in nil },
    log: @escaping @Sendable (String) -> Void = { _ in }, trace: (@Sendable (String) -> Void)? = nil,
    screenScale: CGFloat? = nil, watchesFiles: Bool = true, reduceMotion: @escaping () -> Bool = { false }
  ) {
    self.output = output
    self.pasteboard = pasteboard
    self.stagers = stagers
    self.environment = environment
    self.readFile = readFile
    self.images = images
    self.highlighter = highlighter
    self.mermaid = mermaid
    self.resolveTheme = resolveTheme
    self.crossCheck = crossCheck
    self.log = log
    self.trace = trace
    self.screenScale = screenScale
    self.watchesFiles = watchesFiles
    self.reduceMotion = reduceMotion
  }
}

@MainActor
public final class ViewerHost {
  public static let themeQueryTimeout: UInt64 = 200_000_000
  public static let highlightRetryDelay: UInt64 = 1_000_000_000
  public static let maximumHighlightRetries = 3
  public static let assetSettleDelay: UInt64 = 30_000_000
  public static let handoffDrainTimeout: UInt64 = 2_000_000_000

  public internal(set) var interaction: ViewerInteraction
  public private(set) var theme: ResolvedTheme
  public private(set) var palette: RenderPalette
  public let transport: DisplayTransport
  /// With TERMDOWN_LATENCY_LOG set to a path, one line per key: unix microseconds, the key, and the microseconds from
  /// reading it to the first frame written afterwards. A key that draws nothing is charged to the next frame.
  let latencyLog: FileHandle? = {
    guard let path = ProcessInfo.processInfo.environment["TERMDOWN_LATENCY_LOG"], !path.isEmpty else { return nil }
    if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
    let handle = FileHandle(forWritingAtPath: path)
    handle?.seekToEndOfFile()
    return handle
  }()
  var latencyKey: (description: String, at: UInt64)?
  public let driver: DisplayDriver
  public var onQuit: () -> Void = {}
  public var onDocumentShown: (URL) -> Void = { _ in }
  public private(set) var editor: EditorCoordinator?
  public private(set) var handoffActive = false
  public private(set) var pendingDeviceAttributes: Int

  let services: HostServices
  let source: RasterFrameSource
  let worker = LayoutWorker()
  var backingScale: CGFloat
  var sizeTracker = PaneSizeTracker()
  var paneSizeSeen = false
  var parser = InputParser()
  var themeScheduler = ThemeRefreshScheduler()
  var themeReplies: TerminalColorReplyReader?
  var themeQueryID = 0
  var mermaidTheme: MermaidTheme
  var highlighted: PreparedDocument?
  var highlightAttempts: [BlockID: Int] = [:]
  var diagramsInFlight: Set<MermaidCacheKey> = []
  var hasDiagrams = false
  var assetsPending = false
  var inRelayout = false
  var synchronousLayout = false
  var watcher: FileWatcher?
  var tickTimer: DispatchSourceTimer?
  var player = AnimationPlayer()
  let animationFrames = AnimationFrames()
  var animationTimer: DispatchSourceTimer?
  var animationTimerDeadline: UInt64?
  var tickTimerDeadline: UInt64?
  var lastAnimationTick: UInt64 = 0
  var liveBufferNoticeShown = false
  var liveBufferSession = 0
  var diskCheckSession: Int?
  var displaySuspended = false
  var drainCompletion: (() -> Void)?
  var drainID = 0
  var reviewOverlay:
    (marks: ReviewMarks, prepared: PreparedDocument, annotations: [(rendered: Range<Int>, color: RGB)])?
  var typedOverlay: (snapshot: String?, text: String, prepared: PreparedDocument, ranges: [Range<Int>])?
  /// The draft this viewer holds the review lock for, and the marks last written for it.
  var reviewSession: (store: ReviewStore, saved: ReviewMarks)?
  /// The Rex pane showing the changes since the last pass, while one is open.
  /// The Rex pane `D` opened, and the store of the draft it shows changes for.
  var changesPane: (block: String, store: ReviewStore)?

  public init(size: PaneSize, theme: ResolvedTheme, themeQueryTimedOut: Bool = false, services: HostServices) {
    self.services = services
    self.theme = theme
    pendingDeviceAttributes = themeQueryTimedOut ? 1 : 0
    palette = theme.palette
    mermaidTheme = MermaidTheme(palette: palette)
    let cellHeight = CGFloat(size.rows > 0 ? size.pixelHeight / size.rows : 0)
    backingScale = Self.backingScale(for: size, services: services)
    let viewport = DisplayViewport(size: size, backingScale: backingScale, pageHeight: 0)
    let typography = Typography(bodySize: Typography.defaultBodySize, zoom: 1, backingScale: backingScale)
    interaction = ViewerInteraction(
      geometry: Self.geometry(viewport), typography: typography, environment: services.environment)
    interaction.reviewHotkeys = ReviewHotkeys.load()
    let empty = PreparedDocument(markdown: "", typography: typography).layout(width: CGFloat(viewport.frameWidth))
    source = RasterFrameSource(rasterizer: Rasterizer(layout: empty, palette: palette))
    transport = DisplayTransport(
      viewport: viewport, output: services.output, source: source, stager: services.stagers.primary,
      fallback: services.stagers.fallback
    ) { _, viewport in viewport }
    driver = DisplayDriver(transport: transport)
    if themeQueryTimedOut { themeScheduler.queryTimedOut(at: Self.seconds()) }
    services.images.setDisplayWidth(viewport.frameWidth)
    transport.relayout = { [unowned self] size, old in relayout(size, old) }
    transport.onEvent = { [unowned self] event in displayEvent(event) }
  }

  public nonisolated static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

  nonisolated static func seconds() -> TimeInterval { TimeInterval(now()) / 1e9 }

  static func geometry(_ viewport: DisplayViewport) -> ViewGeometry {
    ViewGeometry(
      width: CGFloat(viewport.frameWidth), contentHeight: CGFloat(viewport.contentHeight),
      rowHeight: CGFloat(viewport.cellHeight))
  }

  // MARK: Entry points

  public func start(file: URL, windowSize: PaneSize) {
    synchronousLayout = true
    do {
      perform(interaction.open(file: file, source: try read(file), at: Self.now()))
      interaction.setEditRefusal(Self.editRefusal(for: file))
    } catch {
      perform(interaction.open(file: file, source: Self.unreadableDocument(file), at: Self.now()))
      interaction.setEditRefusal("\(file.lastPathComponent) could not be read, so it cannot be edited")
      perform(interaction.show(Self.cannotRead(file), kind: .error, at: Self.now()))
    }
    synchronousLayout = false
    onDocumentShown(file)
    watch(file)
    apply(sizeTracker.windowChanged(windowSize))
    settle()
  }

  public func receive(_ bytes: [UInt8]) {
    let now = Self.now()
    if services.trace != nil, bytes.count <= 64, !bytes.starts(with: Array("\u{1b}_G".utf8)) {
      trace("input \(String(decoding: bytes, as: UTF8.self).debugDescription)")
    }
    let collecting = themeReplies != nil
    themeReplies?.feed(bytes)
    for event in parser.feed(bytes, at: now) { handle(event, answeringThemeQuery: collecting, at: now) }
    if collecting, themeReplies?.isComplete == true { finishThemeQuery() }
    if let deadline = parser.escapeDeadline {
      DispatchQueue.main.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: deadline)) { [weak self] in
        MainActor.assumeIsolated { self?.flushEscape() }
      }
    }
    settle()
  }

  public func windowChanged(_ size: PaneSize) {
    guard !handoffActive else { return }
    apply(sizeTracker.windowChanged(size))
    settle()
  }

  public func open(_ url: URL) {
    leaveLiveBuffer()
    perform(interaction.clearEditorCursor())
    perform(interaction.open(url))
    settle()
  }

  /// `termdown review`: show the file and turn review on, now or when an agent connects.
  public func review(_ url: URL) {
    if url.standardizedFileURL.path != interaction.file?.standardizedFileURL.path {
      leaveLiveBuffer()
      perform(interaction.clearEditorCursor())
    }
    perform(interaction.openForReview(url, at: Self.now()))
    settle()
  }

  public func fileChanged() {
    if interaction.liveBuffer {
      scheduleDiskChangeNotice()
    } else {
      reloadFile()
    }
    settle()
  }

  func scheduleDiskChangeNotice() {
    guard !liveBufferNoticeShown, diskCheckSession != liveBufferSession else { return }
    let session = liveBufferSession
    diskCheckSession = session
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.editorSaveGrace) { [weak self] in
      MainActor.assumeIsolated { self?.noticeDiskChange(session: session) }
    }
  }

  func noticeDiskChange(session: Int) {
    guard session == liveBufferSession else { return }
    diskCheckSession = nil
    guard interaction.liveBuffer, !liveBufferNoticeShown else { return }
    if let url = interaction.file, (try? read(url)) == interaction.source { return }
    liveBufferNoticeShown = true
    perform(interaction.show(Self.liveBufferNotice, kind: .info, at: Self.now()))
    settle()
  }

  public func themeChanged() {
    requestTheme(.reload)
    settle()
  }

  public func shutdown() {
    flushEdits()
    releaseReviewLock()
    closeChanges()
    ide?.stop()
    editor?.shutdown()
    watcher?.stop()
    watcher = nil
    tickTimer?.cancel()
    tickTimer = nil
    animationTimer?.cancel()
    animationTimer = nil
    worker.stop()
    services.mermaid?.shutDown()
    transport.shutdown()
  }

  /// Claude Code's `/ide` connection, when termdown announces itself as an IDE.
  public var ide: IDEBridge?
  /// The open agent picker is the review form: a choice starts review instead of only routing highlights.
  var reviewPickerOpen = false
  /// Asked to replace this process with a fresh one on the same file (after a rebuild, or from Rex's palette).
  public var onRestart: (() -> Void)?
  /// The command "Start a new agent" runs (the `agent` setting).
  public var agentCommand = Settings.defaultAgent
  /// A pane started from the agent picker; the selection goes to its agent once it connects.
  var pendingAgentPane: String?
  /// Counts `refreshReviewAgent` calls, so a pane describe that lands after a newer refresh is dropped.
  var reviewAgentGeneration = 0
  /// Roots the copied file path is made relative to, outermost first.
  public var workspaceFolders: [String] {
    get { interaction.workspaceFolders }
    set { interaction.workspaceFolders = newValue }
  }

  func settle() {
    if let ide, let file = interaction.file, let selection = interaction.sourceSelection {
      ide.update(
        IDESelection(
          filePath: file.path, text: selection.text, startLine: selection.startLine,
          startCharacter: selection.startCharacter, endLine: selection.endLine, endCharacter: selection.endCharacter))
    }
    scheduleTick()
    updateAnimations()
    driver.kick()
  }

  func flushEscape() {
    let now = Self.now()
    for event in parser.flushEscape(at: now) { handle(event, answeringThemeQuery: false, at: now) }
    settle()
  }

  func handle(_ event: InputEvent, answeringThemeQuery: Bool, at now: UInt64) {
    if handoffActive {
      if event == .deviceAttributes { deviceAttributesArrived() }
      return
    }
    switch event {
    case .key, .mouse, .paste:
      if transport.isStopped { transport.resume() }
      if latencyLog != nil, case .key(let key) = event { latencyKey = ("\(key)", now) }
      perform(interaction.handle(event, at: now))
    case .colorScheme:
      if !answeringThemeQuery { requestTheme(.colorScheme) }
    case .deviceAttributes:
      deviceAttributesArrived()
      themeScheduler.deviceAttributesReceived()
    case .paneSize(let size):
      apply(sizeTracker.inBandReport(size))
    case .cellSize(let width, let height):
      apply(sizeTracker.cellSizeReport(width: width, height: height))
    case .modeReport(let report):
      apply(sizeTracker.modeReport(report))
    case .graphics(let response):
      driver.handle(response)
    case .restart:
      flushEdits()
      onRestart?()
    case .copyPath:
      perform(interaction.copyFilePath(at: now))
    case .selectAgent:
      openAgentPicker()
    }
  }

  func apply(_ actions: [PaneSizeTracker.Action]) {
    for action in actions {
      switch action {
      case .observe(let size):
        nudgeUnsizedPane(size)
        driver.observe(size)
      case .queryCellSize: services.output.write(TerminalSequences.queryCellSize)
      }
    }
  }

  func nudgeUnsizedPane(_ size: PaneSize) {
    guard !paneSizeSeen, size.pixelWidth > 0, size.pixelHeight > 0 else { return }
    paneSizeSeen = true
    guard size == PaneNudge.placeholder, let context = editor?.context, let rexPath = context.rexPath,
      let session = context.session, let block = context.block
    else { return }
    let log = services.log
    DispatchQueue.global(qos: .utility).async {
      PaneNudge.run(
        rexPath: rexPath, session: session, block: block,
        runner: ProcessRunner(timeout: EditorCoordinator.rexTimeout), log: log)
    }
  }

  // MARK: Effects

  func perform(_ effects: [InteractionEffect]) {
    for effect in effects { perform(effect) }
    keepReviewSafe()
  }

  func trace(_ message: @autoclosure () -> String) {
    services.trace?(message())
  }

  func perform(_ effect: InteractionEffect) {
    switch effect {
    case .scroll(let offset):
      trace("scroll \(offset)")
      if !inRelayout { transport.scroll(to: offset) }
      source.status = interaction.status
      if hasDiagrams { updateDiagrams() }
    case .redraw(let rect):
      syncFrameSource()
      invalidate(rect)
    case .redrawStatusBar:
      source.status = interaction.status
      if services.trace != nil {
        let status = interaction.status
        trace("status \(status.findField.map { "find [\($0)] " } ?? "")\(status.message?.text ?? "")")
      }
      if !inRelayout { transport.invalidateStatusBar() }
    case .redrawAll:
      syncFrameSource()
      if !inRelayout { transport.invalidateAll() }
    case .layoutChanged:
      layoutChanged()
    case .regionScrolled(let id, let offset):
      trace("region \(id) offset \(offset)")
      source.rasterizer.setScrollOffset(offset, for: id)
    case .requestLayout(let request):
      runLayout(request)
    case .writeClipboard(let text, let markdown):
      trace("clipboard \(text.count) characters\(markdown ? " as Markdown" : "")")
      if !services.pasteboard.write(text, markdown: markdown) {
        perform(interaction.show("Could not copy to the clipboard", kind: .error, at: Self.now()))
      }
    case .writeRichClipboard(let html, let plain):
      trace("clipboard \(plain.count) characters as rich text")
      if !services.pasteboard.writeRich(html: html, plain: plain) {
        perform(interaction.show("Could not copy to the clipboard", kind: .error, at: Self.now()))
      }
    case .pointerShape(let shape):
      trace("pointer \(shape.rawValue)")
      services.output.write(TerminalSequences.pointerShape(shape))
    case .loadDocument(let url):
      trace("load \(url.lastPathComponent)")
      load(url)
    case .reload:
      watcher?.rearmIfNeeded()
      leaveLiveBuffer()
      reloadFile()
      requestTheme(.reload)
      editor?.refreshEnvironment()
    case .quit:
      flushEdits()
      keepReviewSafe()
      releaseReviewLock()
      closeChanges()
      onQuit()
    case .edit(let request):
      editor?.edit(request)
    case .openEditorPicker:
      editor?.openPicker()
    case .chooseEditor(let candidate, let mode, let pending):
      editor?.choose(candidate, mode: mode, pending: pending)
    case .jumpEditor(let line):
      editor?.jump(line: line)
    case .save(let request):
      save(request)
    case .reloadEdit(let url):
      if let text = try? read(url) { perform(interaction.takeDiskVersion(text)) }
    case .openAgentPicker:
      openAgentPicker()
    case .chooseReviewAgent:
      openAgentPicker(forReview: true)
    case .chooseAgent(let action):
      chooseAgent(action)
    case .askAgent(let request):
      guard let file = interaction.file else { return }
      trace("ask lines \(request.startLine)-\(request.endLine)")
      if editor?.ask(request, file: file, target: ide?.askTarget) == true {
        perform(interaction.show("Added to the agent's prompt", kind: .success, at: Self.now()))
      } else {
        let text = AgentPrompt.message(
          file: file.path, startLine: request.startLine, endLine: request.endLine, quote: request.quote)
        perform(.writeClipboard(text, markdown: false))
        perform(interaction.show("No agent pane; copied the reference to the clipboard", kind: .info, at: Self.now()))
      }
    case .reviewLaunched:
      launchReview()
    case .submitReview:
      submitReview()
    case .showChanges:
      showChanges()
    }
  }

  // MARK: Agents

  /// An agent connected, identified itself or left: route to a pane started from the picker, ask when
  /// `agent-pairing ask` needs a choice, and keep an open picker current.
  public func agentsChanged() {
    guard let ide else { return }
    if let pane = pendingAgentPane, let agent = ide.agentState().agents.first(where: { $0.block == pane }) {
      pendingAgentPane = nil
      ide.choose(.agent(agent.id))
      perform(interaction.show("Highlights go to the new agent", kind: .success, at: Self.now()))
    }
    if interaction.agentPicker != nil || ide.needsChoice {
      openAgentPicker(forReview: interaction.agentPicker != nil && reviewPickerOpen)
    }
    refreshReviewAgent()
  }

  /// Tells the interaction how many agents are connected and which one a review goes to: the single recipient, with
  /// its pane title, while it runs in a Rex pane. A single recipient outside Rex is connected but not chosen. The
  /// title comes back from Rex later; an answer that lands after a newer refresh is stale and dropped.
  func refreshReviewAgent() {
    guard let ide else { return }
    let state = ide.agentState()
    let single = state.recipients.count == 1 ? state.agents.first { $0.id == state.recipients[0] } : nil
    let target = single?.block == nil ? nil : single
    reviewAgentGeneration += 1
    let generation = reviewAgentGeneration
    let apply: @MainActor @Sendable (AgentPanes) -> Void = { [weak self] panes in
      guard let self, generation == reviewAgentGeneration else { return }
      let title = target?.block.flatMap { panes.titles[$0] } ?? single?.title
      let status = ReviewAgentStatus(
        connected: state.agents.count, title: title, chosen: target != nil, outsideRex: single != nil && target == nil)
      perform(interaction.setReviewAgent(status, at: Self.now()))
    }
    if let editor, let target { editor.describeAgents([target], completion: apply) } else { apply(AgentPanes()) }
  }

  /// Review started with the only agent as its target without anyone picking it: pin that agent, so one connecting
  /// mid-review does not turn the target into no choice or open the picker.
  func pinReviewAgent() {
    guard let ide else { return }
    guard let agent = ide.reviewAgent, ide.agentState().choice != .agent(agent.id) else { return }
    ide.choose(.agent(agent.id))
  }

  func openAgentPicker(forReview: Bool = false) {
    reviewPickerOpen = forReview
    guard let ide else { return perform(interaction.show("Agents are not available", kind: .info, at: Self.now())) }
    let state = ide.agentState()
    let command = agentCommand
    let show: @MainActor @Sendable (AgentPanes) -> Void = { [weak self] panes in
      guard let self else { return }
      var agents = state.agents
      for index in agents.indices {
        if let block = agents[index].block { agents[index].title = panes.titles[block] }
      }
      perform(
        interaction.showAgentPicker(
          AgentPickerContent.make(
            agents: agents, recipients: state.recipients, agentCommand: command, windows: panes.windows,
            viewerWindow: panes.viewerWindow, forReview: forReview)))
    }
    if let editor { editor.describeAgents(state.agents, completion: show) } else { show(AgentPanes()) }
  }

  func chooseAgent(_ action: AgentPickerRow.Action) {
    guard let ide else { return }
    let forReview = reviewPickerOpen
    reviewPickerOpen = false
    switch action {
    case .agent(let id):
      ide.choose(.agent(id))
      refreshReviewAgent()
      if forReview {
        // An agent outside Rex has no pane to send a pass to, so its review never starts.
        guard ide.reviewTarget != nil else {
          return perform(interaction.show(ViewerInteraction.outsideRexMessage, kind: .info, at: Self.now()))
        }
        perform(interaction.startReview(at: Self.now()))
      } else {
        perform(interaction.show("Highlights go to the chosen agent", kind: .success, at: Self.now()))
      }
    case .all:
      // A review goes to one session, so the review picker has no such row.
      guard !forReview else { return }
      ide.choose(.all)
      refreshReviewAgent()
      perform(interaction.show("Highlights go to every connected agent", kind: .success, at: Self.now()))
    case .startNew:
      guard let port = ide.port, let editor else {
        return perform(interaction.show("Can't start an agent from here", kind: .info, at: Self.now()))
      }
      editor.startAgent(command: agentCommand, port: port, directory: workspaceFolders.first) { [weak self] result in
        guard let self else { return }
        switch result {
        case .success(let pane):
          pendingAgentPane = pane
          // Picked from the review picker: the review starts once this agent connects.
          if forReview { interaction.awaitReviewAgent() }
          perform(interaction.show("Starting \(agentCommand) beside this viewer", kind: .info, at: Self.now()))
        case .failure(let error):
          perform(interaction.show(error.message, kind: .info, at: Self.now()))
        }
      }
    }
  }

  func syncFrameSource() {
    source.showsHelp = interaction.helpVisible
    source.editMode = interaction.editMode
    source.editorPicker = interaction.editorPicker
    source.agentPicker = interaction.agentPicker
    source.marksList = interaction.marksList
    source.overlay = interaction.overlay
    source.overlay.annotations = reviewAnnotations()
    source.overlay.typedEdits = reviewTypedEdits()
    source.status = interaction.status
  }

  func invalidate(_ rect: CGRect) {
    guard !inRelayout, !rect.isEmpty else { return }
    transport.invalidate(page: rect)
  }

  // MARK: Documents

  func read(_ url: URL) throws -> String {
    guard isRegularFile(url.path) else { throw CocoaError(.fileReadNoSuchFile) }
    return try services.readFile(url)
  }

  func load(_ url: URL) {
    let now = Self.now()
    do {
      perform(interaction.open(file: url, source: try read(url), at: now))
      interaction.setEditRefusal(Self.editRefusal(for: url))
      refreshEditorLink()
      onDocumentShown(url)
      watch(url)
    } catch {
      perform(interaction.loadFailed(url, reason: Self.cannotRead(url), at: now))
    }
  }

  func reloadFile() {
    guard let url = interaction.file else { return }
    services.images.forgetFailures()
    do {
      let text = try read(url)
      if interaction.edit == nil { interaction.setEditRefusal(Self.editRefusal(for: url)) }
      perform(interaction.fileChanged(source: text))
    } catch {
      perform(interaction.show(Self.cannotRead(url), kind: .error, at: Self.now()))
    }
  }

  func watch(_ url: URL) {
    watcher?.stop()
    watcher = nil
    guard services.watchesFiles else { return }
    watcher = FileWatcher(
      url: url, onChange: { [unowned self] in fileChanged() },
      onMissing: { [unowned self] in
        perform(interaction.fileMissing(at: Self.now()))
        perform(interaction.show("\(url.lastPathComponent) is missing; r to reload", kind: .error, at: Self.now()))
        settle()
      })
  }

  static func cannotRead(_ url: URL) -> String { "Cannot read \(url.lastPathComponent)" }

  // MARK: Saving edits

  /// Why a file cannot be edited in place: saving rewrites it as UTF-8 without a byte-order mark, which would
  /// change every byte of a file in another encoding.
  static func editRefusal(for url: URL) -> String? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    if data.starts(with: [0xEF, 0xBB, 0xBF]) {
      return "\(url.lastPathComponent) starts with a byte-order mark; editing in place is off"
    }
    if String(data: data, encoding: .utf8) == nil {
      return "\(url.lastPathComponent) is not UTF-8; editing in place is off"
    }
    return nil
  }

  /// Writes a save when the disk still holds the text it was edited from (or when forced).
  func save(_ request: SaveRequest) {
    let disk = try? Data(contentsOf: request.file)
    if !request.force, disk.map({ Array($0) }) != request.base {
      let reason =
        disk == nil
        ? "\(request.file.lastPathComponent) is gone: Cmd-S writes it again"
        : "File changed on disk: Cmd-S keeps your text, Cmd-R takes the file's"
      perform(interaction.saveRefused(reason, conflict: true, at: Self.now()))
      return
    }
    do {
      try services.writeFile(request.file, request.text)
      trace("saved revision \(request.revision)")
      if request.file.standardizedFileURL == interaction.file?.standardizedFileURL {
        perform(interaction.saved(revision: request.revision, text: request.text))
      }
      watcher?.rearmIfNeeded()
    } catch {
      perform(interaction.saveRefused("Could not save \(request.file.lastPathComponent)", conflict: false, at: Self.now()))
    }
  }

  /// On quit, shutdown or a signal: unsaved edits go to the file when it is unchanged on disk, and to a backup
  /// copy otherwise, so neither the person's text nor someone else's change is lost.
  public func flushEdits() {
    guard var session = interaction.edit, session.isDirty, let file = interaction.file else { return }
    var disk = try? Data(contentsOf: file)
    if let bytes = disk.map({ Array($0) }), bytes != session.base, let text = String(bytes: bytes, encoding: .utf8) {
      // The file changed while we were not looking: fold that change in before writing, as a live change would.
      _ = interaction.fileChanged(source: text)
      guard let merged = interaction.edit else { return }
      session = merged
      disk = try? Data(contentsOf: file)
      if !session.isDirty { return }
    }
    if disk.map({ Array($0) }) == session.base, (try? services.writeFile(file, session.source)) != nil {
      _ = interaction.saved(revision: session.revision, text: session.source)
      return
    }
    let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("termdown/unsaved", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    let backup = folder.appendingPathComponent("\(stamp)-\(file.lastPathComponent)")
    try? Data(session.source.utf8).write(to: backup, options: .atomic)
    services.log("unsaved edits to \(file.path) kept in \(backup.path)")
  }

  // MARK: Editor

  public static let liveBufferNotice = "File changed on disk; showing the editor's unsaved text"
  static let editorSaveGrace: TimeInterval = 0.5

  public func attachEditor(_ editor: EditorCoordinator) {
    self.editor = editor
    editor.host = self
    refreshEditorLink()
  }

  public func setEditMode(_ mode: EditMode) {
    guard interaction.editMode != mode else { return }
    interaction.editMode = mode
    source.editMode = mode
    guard interaction.helpVisible else { return }
    transport.invalidateAll()
    settle()
  }

  public func receiveEditor(_ message: EditorMessage) {
    guard let editor else { return }
    if case .edit(let mode, let line) = message {
      editor.edit(EditRequest(mode: mode, line: line), fromSocket: true)
      return
    }
    guard editor.accept(message, shownFile: interaction.file) else {
      trace("editor message dropped \(message)")
      return
    }
    switch message {
    case .cursor(_, let line, let top, let height):
      perform(interaction.applyEditorCursor(EditorCursor(line: line, top: top, height: height)))
    case .buffer(_, let text):
      showLiveBuffer(text, buffers: editor.buffersDirectory)
    case .clean:
      leaveLiveBuffer()
      reloadFile()
    case .follow(let envelope):
      followEditor(to: URL(fileURLWithPath: envelope.file))
    case .unlinked(let envelope):
      if editor.unlinked(token: envelope.token) { editorEnded(status: EditorCoordinator.relinkedMessage) }
    case .exit(let envelope):
      editor.exited(token: envelope.token)
    case .edit:
      break
    }
    refreshEditorLink()
    settle()
  }

  func showLiveBuffer(_ text: URL, buffers: URL) {
    guard let url = validateBufferPath(text.path, buffersDirectory: buffers), let source = try? read(url) else {
      return
    }
    if !interaction.liveBuffer { liveBufferNoticeShown = false }
    perform(interaction.fileChanged(source: source))
    perform(interaction.setLiveBuffer(true))
  }

  func leaveLiveBuffer() {
    if interaction.liveBuffer { liveBufferSession += 1 }
    perform(interaction.setLiveBuffer(false))
  }

  func followEditor(to url: URL) {
    let wasLive = interaction.liveBuffer
    leaveLiveBuffer()
    perform(interaction.clearEditorCursor())
    if let file = interaction.file, canonicalPath(file.path) == canonicalPath(url.path) {
      if wasLive { reloadFile() }
    } else {
      perform(interaction.open(url))
    }
  }

  func dropLiveBuffer() {
    guard interaction.liveBuffer else { return }
    leaveLiveBuffer()
    reloadFile()
    settle()
  }

  func editorEnded(status: String) {
    perform(interaction.clearEditorCursor())
    leaveLiveBuffer()
    reloadFile()
    refreshEditorLink()
    perform(interaction.show(status, kind: .info, at: Self.now()))
    settle()
  }

  func editorLinkChanged() {
    refreshEditorLink()
    settle()
  }

  func refreshEditorLink() {
    var current: EditorLink?
    if let link = editor?.link, link.block != nil, let kind = link.kind {
      current = EditorLink(
        name: kind.displayName, syncsLive: kind == .neovim && link.token != nil,
        followsShownFile: interaction.file.map(link.follows) ?? false)
    }
    perform(interaction.setEditorLink(current))
  }

  func showEditorStatus(_ text: String, kind: StatusMessage.Kind) {
    perform(interaction.show(text, kind: kind, at: Self.now()))
    settle()
  }

  func showEditorPicker(_ candidates: [EditorCandidate], mode: EditMode, pending: EditRequest? = nil) {
    perform(interaction.showEditorPicker(candidates: candidates, mode: mode, pending: pending))
    settle()
  }

  static func unreadableDocument(_ url: URL) -> String {
    var run = 0
    var longest = 0
    for character in url.path {
      run = character == "`" ? run + 1 : 0
      longest = max(longest, run)
    }
    let fence = String(repeating: "`", count: longest + 1)
    return "> [!CAUTION]\n> **Cannot read this file.**\n>\n> \(fence) \(url.path) \(fence)\n"
  }

  // MARK: Handoff

  public func beginHandoff() {
    handoffActive = true
    watcher?.stop()
    watcher = nil
    suspendDisplay()
  }

  public func suspendDisplay() {
    displaySuspended = true
    if themeReplies != nil {
      themeReplies = nil
      themeQueryID += 1
      themeScheduler.finish(now: Self.seconds(), queryTimedOut: false)
    }
    transport.suspend()
    updateAnimations()
  }

  public func awaitSentinelReply(
    timeout: UInt64 = ViewerHost.handoffDrainTimeout, then completion: @escaping () -> Void
  ) {
    pendingDeviceAttributes += 1
    drainID += 1
    let drain = drainID
    drainCompletion = completion
    DispatchQueue.main.asyncAfter(deadline: .now() + .nanoseconds(Int(timeout))) { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.drainID == drain else { return }
        self.endDrain()
      }
    }
  }

  func deviceAttributesArrived() {
    pendingDeviceAttributes = max(pendingDeviceAttributes - 1, 0)
    if pendingDeviceAttributes == 0 { endDrain() }
  }

  func endDrain() {
    guard let completion = drainCompletion else { return }
    drainCompletion = nil
    drainID += 1
    pendingDeviceAttributes = 0
    DispatchQueue.main.async { completion() }
  }

  public func resetInput() {
    parser = InputParser()
  }

  public func resumeDisplay(size: PaneSize?) {
    displaySuspended = false
    transport.resume()
    if let size { apply(sizeTracker.windowChanged(size)) }
    settle()
  }

  public func endHandoff(block: String?) {
    handoffActive = false
    if let file = interaction.file { watch(file) }
    let linked = block.map { editor?.isLinked(to: $0) == true } ?? false
    if let block { editor?.blockEnded(block) }
    if !linked {
      perform(interaction.clearEditorCursor())
      leaveLiveBuffer()
      reloadFile()
    }
    requestTheme(.reload)
    settle()
  }

  public func applyHandoffCursor(_ message: EditorMessage?, shownBefore: URL?) {
    guard case .cursor(let envelope, let line, let top, let height) = message, let file = interaction.file,
      let shownBefore, canonicalPath(file.path) == canonicalPath(shownBefore.path),
      canonicalPath(envelope.file) == canonicalPath(file.path)
    else { return }
    perform(interaction.applyEditorCursor(EditorCursor(line: line, top: top, height: height)))
    settle()
  }

  // MARK: Layout

  func runLayout(_ request: LayoutRequest) {
    let providers = layoutProviders(for: request)
    if inRelayout || synchronousLayout {
      let page = worker.perform { request.perform(providers) }
      perform(interaction.apply(page, for: request, at: Self.now()))
      return
    }
    worker.layout(request, providers: providers) { page in
      DispatchQueue.main.async { [weak self] in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.perform(self.interaction.apply(page, for: request, at: Self.now()))
          self.settle()
        }
      }
    }
  }

  func layoutProviders(for request: LayoutRequest) -> LayoutProviders {
    let context = DiagramContext(theme: mermaidTheme, pageWidth: request.width, typography: request.typography)
    var diagramSize: @Sendable (String) -> CGSize? = { _ in nil }
    if let mermaid = services.mermaid {
      diagramSize = mermaid.sizeProvider(theme: context.theme, width: context.width, scale: context.scale)
    }
    return LayoutProviders(
      prefersDark: palette.dark, imageSize: services.images.sizeProvider(relativeTo: interaction.file),
      diagramSize: diagramSize)
  }

  /// The scale the pane's own cell size implies. The placeholder Rex gives a pane before its window sizes it says
  /// nothing about the display the pane ends up on.
  static func backingScale(for size: PaneSize, services: HostServices) -> CGFloat {
    let cellHeight = CGFloat(size.rows > 0 ? size.pixelHeight / size.rows : 0)
    return Typography.backingScale(
      cellPixelHeight: cellHeight, screenScale: size == PaneNudge.placeholder ? services.screenScale : nil)
  }

  func relayout(_ size: PaneSize, _ old: DisplayViewport) -> DisplayViewport {
    inRelayout = true
    defer { inRelayout = false }
    if size != PaneNudge.placeholder, size.pixelHeight > 0 {
      let scale = Self.backingScale(for: size, services: services)
      if scale != backingScale {
        backingScale = scale
        trace("backing scale \(scale) from cell height \(size.pixelHeight / max(size.rows, 1))")
        perform(interaction.setBackingScale(scale))
      }
    }
    var viewport = DisplayViewport(
      size: size, backingScale: backingScale, pageHeight: old.pageHeight, offset: old.offset)
    services.images.setDisplayWidth(viewport.frameWidth)
    perform(interaction.resize(Self.geometry(viewport)))
    viewport.setPageHeight(interaction.pageHeight)
    viewport.scroll(to: interaction.offset)
    syncFrameSource()
    return viewport
  }

  func layoutChanged() {
    if let layout = interaction.layout {
      trace("layout \(interaction.file?.lastPathComponent ?? "") height \(layout.height) zoom \(interaction.zoom)")
    }
    rebuildRasterizer()
    if !inRelayout, let layout = interaction.layout {
      var viewport = transport.viewport
      viewport.setPageHeight(layout.height)
      transport.replaceViewport(viewport)
    }
    requestImages()
    updateDiagrams()
  }

  func rebuildRasterizer() {
    guard let layout = interaction.layout else { return }
    var highlights = source.rasterizer.highlights
    if highlighted !== layout.prepared {
      highlighted = layout.prepared
      highlightAttempts = [:]
      highlights = requestHighlights(layout.prepared)
    }
    let context = DiagramContext(theme: mermaidTheme, pageWidth: layout.width, typography: layout.prepared.typography)
    var diagram: @Sendable (String) -> CGImage? = { _ in nil }
    if let mermaid = services.mermaid {
      diagram = mermaid.imageProvider(theme: context.theme, width: context.width, scale: context.scale)
    }
    source.rasterizer = Rasterizer(
      layout: layout, palette: palette,
      assets: RenderAssets(image: animatedImageProvider(), diagram: diagram),
      highlights: highlights)
  }

  func animatedImageProvider() -> @Sendable (String) -> CGImage? {
    let images = services.images
    let document = interaction.file
    let frames = animationFrames
    return { source in images.image(for: source, relativeTo: document)?.frame(frames.index(for: source)) }
  }

  // MARK: Animation

  func updateAnimations() {
    var visible: [String: AnimationPlayer.Clip] = [:]
    if !displaySuspended, !services.reduceMotion(), !interaction.helpVisible, interaction.editorPicker == nil,
      !transport.isStopped,
      let layout = interaction.layout
    {
      for box in layout.images {
        guard case .image(let source) = box.content, visible[source] == nil,
          layout.displayRect(box.rect, region: box.region).intersects(visibleRect),
          let image = services.images.image(for: source, relativeTo: interaction.file), image.isAnimated
        else { continue }
        visible[source] = AnimationPlayer.Clip(delays: image.delays, loopCount: image.loopCount)
      }
    }
    player.show(visible, at: Self.now())
    scheduleAnimation()
  }

  func scheduleAnimation() {
    guard let deadline = player.nextDeadline else {
      if animationTimerDeadline != nil { animationTimer?.schedule(deadline: .distantFuture) }
      animationTimerDeadline = nil
      return
    }
    if animationTimer == nil {
      let timer = DispatchSource.makeTimerSource(queue: .main)
      timer.setEventHandler { [weak self] in
        MainActor.assumeIsolated { self?.animationTick() }
      }
      timer.schedule(deadline: .distantFuture)
      timer.resume()
      animationTimer = timer
    }
    let at = max(deadline, lastAnimationTick + AnimationPlayer.minimumTickInterval)
    animationTimerDeadline = at
    animationTimer?.schedule(deadline: DispatchTime(uptimeNanoseconds: at))
  }

  func animationTick() {
    let now = Self.now()
    lastAnimationTick = now
    guard let layout = interaction.layout else { return }
    for source in player.advance(at: now) {
      let frame = player.frame(for: source)
      animationFrames.set(frame, for: source)
      trace("animate \(source) frame \(frame)")
      for box in layout.images where box.content == .image(source: source) {
        let rect = layout.displayRect(box.rect, region: box.region).intersection(visibleRect)
        if !rect.isNull { invalidate(rect) }
      }
    }
    settle()
  }

  // MARK: Highlighting

  func requestHighlights(_ prepared: PreparedDocument) -> [BlockID: HighlightResult] {
    guard let highlighter = services.highlighter else { return [:] }
    return highlighter.highlight(prepared, queue: .main) { [weak self] id, result in
      let code = prepared.codeBlocks[id]?.code
      MainActor.assumeIsolated { self?.highlightArrived(id, result, code: code) }
    }
  }

  func highlightArrived(_ id: BlockID, _ result: HighlightResult, code: String?) {
    guard let layout = interaction.layout, let block = layout.prepared.codeBlocks[id], block.code == code else {
      return
    }
    if result.outcome == .timedOut {
      retryHighlight(id, block)
      return
    }
    trace("highlight \(id) \(result.outcome)")
    source.rasterizer.highlights[id] = result
    invalidate(Self.band(of: block, in: layout))
    settle()
  }

  func retryHighlight(_ id: BlockID, _ block: CodeBlockInfo) {
    guard let highlighter = services.highlighter else { return }
    let attempt = (highlightAttempts[id] ?? 0) + 1
    guard attempt <= Self.maximumHighlightRetries else { return }
    highlightAttempts[id] = attempt
    let delay = Self.highlightRetryDelay * UInt64(attempt)
    DispatchQueue.main.asyncAfter(deadline: .now() + .nanoseconds(Int(delay))) { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.interaction.layout?.prepared.codeBlocks[id]?.code == block.code else { return }
        highlighter.highlight(code: block.code, language: block.language, queue: .main) { [weak self] result in
          MainActor.assumeIsolated { self?.highlightArrived(id, result, code: block.code) }
        }
      }
    }
  }

  static func band(of block: CodeBlockInfo, in layout: PageLayout) -> CGRect {
    guard let first = block.lineRanges.first, let last = block.lineRanges.last else { return .null }
    let rects = layout.rects(for: first.lowerBound..<max(last.upperBound, first.lowerBound + 1), scrolled: false)
    guard let union = rects.map(\.rect).reduce(nil, { ($0 ?? $1).union($1) }) else { return .null }
    let typography = layout.prepared.typography
    let pad = typography.pixels(em: typography.codePadding * 2)
    return CGRect(x: 0, y: union.minY - pad, width: layout.width, height: union.height + pad * 2)
  }

  // MARK: Images and diagrams

  func requestImages() {
    guard let layout = interaction.layout else { return }
    let document = interaction.file
    services.images.pin(
      layout.images.compactMap { if case .image(let source) = $0.content { source } else { nil } },
      relativeTo: document)
    for box in layout.images {
      guard case .image(let image) = box.content else { continue }
      let arrived: @Sendable (Bool) -> Void = { [weak self] available in
        MainActor.assumeIsolated { self?.imageArrived(image, available: available) }
      }
      if let video = box.video, video == image {
        services.images.loadPoster(image, relativeTo: document, queue: .main, completion: arrived)
      } else {
        services.images.load(image, relativeTo: document, queue: .main, completion: arrived)
      }
    }
  }

  func imageArrived(_ image: String, available: Bool) {
    trace("image \(image) \(available ? "loaded" : "failed")")
    guard available, let layout = interaction.layout,
      layout.images.contains(where: { $0.content == .image(source: image) })
    else { return }
    scheduleAssetsChanged()
  }

  var visibleRect: CGRect {
    CGRect(
      x: 0, y: interaction.offset, width: interaction.geometry.width, height: interaction.geometry.contentHeight)
  }

  func diagramContext(for layout: PageLayout) -> DiagramContext {
    DiagramContext(theme: mermaidTheme, pageWidth: layout.width, typography: layout.prepared.typography)
  }

  func updateDiagrams() {
    guard let mermaid = services.mermaid, let layout = interaction.layout else { return }
    let codes = DiagramPlan.codes(in: layout, visible: visibleRect)
    guard !codes.isEmpty || hasDiagrams else { return }
    hasDiagrams = !codes.isEmpty
    let context = diagramContext(for: layout)
    let requests = codes.map(context.request)
    mermaid.setCurrentDiagrams(requests)
    for request in requests where !diagramsInFlight.contains(request.key) && mermaid.cached(request) == nil {
      diagramsInFlight.insert(request.key)
      mermaid.render(request, queue: .main) { [weak self] diagram in
        MainActor.assumeIsolated { self?.diagramArrived(request, diagram) }
      }
    }
  }

  func diagramArrived(_ request: MermaidRequest, _ diagram: MermaidDiagram) {
    diagramsInFlight.remove(request.key)
    trace("diagram \(diagram.size) \(diagram.failure.map { "\($0)" } ?? "ok")")
    guard let layout = interaction.layout, diagramContext(for: layout).request(request.code).key == request.key
    else { return }
    if diagram.failure == .cancelled {
      updateDiagrams()
      return
    }
    let boxes = layout.images.filter { $0.content == .diagram(code: request.code) }
    if boxes.contains(where: { !$0.hasIntrinsicSize }) {
      scheduleAssetsChanged()
    } else {
      for box in boxes { invalidate(layout.displayRect(box.rect, region: box.region)) }
      settle()
    }
  }

  func scheduleAssetsChanged() {
    guard !assetsPending else { return }
    assetsPending = true
    DispatchQueue.main.asyncAfter(deadline: .now() + .nanoseconds(Int(Self.assetSettleDelay))) { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.assetsPending = false
        self.perform(self.interaction.assetsChanged())
        self.settle()
      }
    }
  }

  // MARK: Theme

  func requestTheme(_ trigger: ThemeRefreshScheduler.Trigger) {
    themeScheduler.request(trigger, now: Self.seconds())
    scheduleThemeQuery()
  }

  func scheduleThemeQuery() {
    guard let due = themeScheduler.dueAt, !themeScheduler.inFlight else { return }
    let delay = max(due - Self.seconds(), 0)
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
      MainActor.assumeIsolated { self?.startThemeQuery() }
    }
  }

  func startThemeQuery() {
    guard !displaySuspended, themeReplies == nil, !themeScheduler.inFlight else { return }
    guard themeScheduler.start(now: Self.seconds()) else { return scheduleThemeQuery() }
    let includeScheme = themeScheduler.sendsColorSchemeQuery
    themeReplies = TerminalColorReplyReader(expectsPalette: true, expectsColorScheme: includeScheme)
    themeQueryID += 1
    let query = themeQueryID
    trace("theme query \(query)\(includeScheme ? " with scheme" : "")")
    services.output.write(TerminalColorQuery.request(includePalette: true, includeColorSchemeQuery: includeScheme))
    pendingDeviceAttributes += 1
    DispatchQueue.main.asyncAfter(deadline: .now() + .nanoseconds(Int(Self.themeQueryTimeout))) { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.themeQueryID == query else { return }
        self.finishThemeQuery()
      }
    }
  }

  func finishThemeQuery() {
    guard let replies = themeReplies else { return }
    themeReplies = nil
    let timedOut = !replies.isComplete
    trace("theme replies \(timedOut ? "timed out" : "complete")")
    let colors = replies.colors
    let resolve = services.resolveTheme
    let crossCheck = services.crossCheck
    let log = services.log
    let trace = services.trace
    DispatchQueue.global(qos: .userInitiated).async {
      let started = Self.now()
      let resolved = resolve(colors)
      trace?("theme resolved in \((Self.now() - started) / 1_000_000) ms")
      DispatchQueue.main.async { [weak self] in
        MainActor.assumeIsolated { self?.themeResolved(resolved, queryTimedOut: timedOut) }
      }
      if let note = crossCheck(resolved) { log(note) }
    }
  }

  func themeResolved(_ resolved: ResolvedTheme, queryTimedOut: Bool) {
    if queryTimedOut { services.log("theme: the terminal did not answer the color query in time") }
    applyTheme(resolved)
    themeScheduler.finish(now: Self.seconds(), queryTimedOut: queryTimedOut)
    scheduleThemeQuery()
    settle()
  }

  func applyTheme(_ resolved: ResolvedTheme) {
    theme = resolved
    let next = resolved.palette
    trace("theme \(resolved.source) background \(next.pageBackground) changed \(next != palette)")
    guard next != palette else { return }
    palette = next
    mermaidTheme = MermaidTheme(palette: next)
    rebuildRasterizer()
    perform(interaction.assetsChanged())
    transport.invalidateAll()
  }

  // MARK: Timers and display events

  func scheduleTick() {
    guard let deadline = interaction.nextDeadline else {
      if tickTimerDeadline != nil { tickTimer?.schedule(deadline: .distantFuture) }
      tickTimerDeadline = nil
      return
    }
    if tickTimer == nil {
      let timer = DispatchSource.makeTimerSource(queue: .main)
      timer.setEventHandler { [weak self] in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.perform(self.interaction.tick(at: Self.now()))
          self.settle()
        }
      }
      timer.schedule(deadline: .distantFuture)
      timer.resume()
      tickTimer = timer
    }
    tickTimerDeadline = deadline
    tickTimer?.schedule(deadline: DispatchTime(uptimeNanoseconds: deadline))
  }

  func displayEvent(_ event: DisplayEvent) {
    if services.trace != nil { trace(Self.describe(event)) }
    if let latencyLog, case .sent = event, let key = latencyKey {
      let micros = (Self.now() - key.at) / 1_000
      let stamp = UInt64(Date().timeIntervalSince1970 * 1_000_000)
      latencyLog.write(Data("\(stamp) \(key.description) \(micros)\n".utf8))
      latencyKey = nil
    }
    guard case .failed(let message) = event else { return }
    services.log("display: \(message)")
    services.output.write("\u{1b}[1;1H\u{1b}[2Ktermdown: \(message). Press a key to retry or q to quit.")
  }

  static func describe(_ event: DisplayEvent) -> String {
    switch event {
    case .sent(let record): "sent \(record.kind) \(record.width)x\(record.height) image \(record.imageID)"
    case .acknowledged(let record, let latency): "ack \(record.kind) image \(record.imageID) \(latency / 1_000_000) ms"
    case .timedOut(let record): "timeout image \(record.imageID)"
    case .holding(let size): "holding \(size.pixelWidth)x\(size.pixelHeight)"
    case .settled(let size): "settled \(size.columns)x\(size.rows) \(size.pixelWidth)x\(size.pixelHeight)"
    case .retired(let ids): "retired \(ids)"
    case .failed(let message): "failed \(message)"
    }
  }
}

/// Replaces a markdown file atomically: writes a sibling temporary file, then swaps it in, keeping the original's
/// permissions, extended attributes and ownership. Follows a symlink to the real file.
public func writeMarkdown(_ url: URL, _ text: String) throws {
  let manager = FileManager.default
  let target = url.resolvingSymlinksInPath()
  guard manager.fileExists(atPath: target.path) else {
    try Data(text.utf8).write(to: target, options: .atomic)
    return
  }
  let temporary = target.deletingLastPathComponent()
    .appendingPathComponent(".\(target.lastPathComponent).termdown-\(UUID().uuidString)")
  try Data(text.utf8).write(to: temporary)
  if let permissions = (try? manager.attributesOfItem(atPath: target.path))?[.posixPermissions] {
    try? manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
  }
  do {
    _ = try manager.replaceItemAt(target, withItemAt: temporary)
  } catch {
    try? manager.removeItem(at: temporary)
    throw error
  }
}
