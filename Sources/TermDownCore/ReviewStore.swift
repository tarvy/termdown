import CryptoKit
import Foundation

/// One mark in termdown's `.edits.json` contract (see `termdown agent-guide review`). Lines are 1-based, columns
/// 0-based UTF-16.
public struct ReviewAnnotation: Equatable, Sendable, Encodable {
  public var type: String
  public var label: String
  public var text: String
  public var note: String?
  public var context: String
  public var line: Int
  public var colFrom: Int
  public var endLine: Int
  public var colTo: Int
  public var occurrence: Int
  public var seq: Int

  public init(
    type: String, label: String, text: String, note: String?, context: String, line: Int, colFrom: Int, endLine: Int,
    colTo: Int, occurrence: Int, seq: Int
  ) {
    self.type = type
    self.label = label
    self.text = text
    self.note = note
    self.context = context
    self.line = line
    self.colFrom = colFrom
    self.endLine = endLine
    self.colTo = colTo
    self.occurrence = occurrence
    self.seq = seq
  }

  enum CodingKeys: String, CodingKey {
    case type, label, text, note, context, line, occurrence, seq
    case colFrom = "col_from"
    case endLine = "end_line"
    case colTo = "col_to"
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(type, forKey: .type)
    try c.encode(label, forKey: .label)
    try c.encode(text, forKey: .text)
    try c.encode(note, forKey: .note)
    try c.encode(context, forKey: .context)
    try c.encode(line, forKey: .line)
    try c.encode(colFrom, forKey: .colFrom)
    try c.encode(endLine, forKey: .endLine)
    try c.encode(colTo, forKey: .colTo)
    try c.encode(occurrence, forKey: .occurrence)
    try c.encode(seq, forKey: .seq)
  }
}

/// One review mark as kept between viewer runs: a source byte range, its hotkey's type and label, press order.
public struct SavedMark: Codable, Equatable, Sendable {
  public var start: Int
  public var end: Int
  public var type: String
  public var label: String
  public var note: String?
  public var seq: Int

  public init(start: Int, end: Int, type: String, label: String, note: String?, seq: Int) {
    self.start = start
    self.end = end
    self.type = type
    self.label = label
    self.note = note
    self.seq = seq
  }
}

public enum ReviewAction: String, Sendable, Encodable {
  case go, finish
}

/// The review sidecars for one draft: its edits, pass files, log, marks and lock, in one folder named for the draft.
public struct ReviewStore: Sendable {
  public static let format = "viewer"
  public static let manualEditsNote =
    "The user already made these edits by hand and they are saved in the draft. Keep them "
    + "as-is: do not revert, redo, or comment on them. `annotations` are the actual requests "
    + "and take precedence where the two overlap."

  public let draft: URL
  public let directory: URL

  public init(
    draft: URL, environment: [String: String] = ProcessInfo.processInfo.environment,
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) {
    self.draft = Self.resolved(draft)
    directory = Self.root(environment: environment, home: home).appendingPathComponent(
      Self.directoryName(for: self.draft))
  }

  /// The latest pass's edits, kept under the old name for anything that reads it.
  public var editsFile: URL { directory.appendingPathComponent(draft.lastPathComponent + ".edits.json") }
  public var logFile: URL { directory.appendingPathComponent(draft.lastPathComponent + ".review.jsonl") }

  /// The marks not yet sent, kept so a viewer that dies or restarts does not lose them.
  public var marksFile: URL { directory.appendingPathComponent(draft.lastPathComponent + ".marks.json") }
  /// The pid of the viewer reviewing this draft: one reviewer per file.
  public var lockFile: URL { directory.appendingPathComponent(draft.lastPathComponent + ".review.lock") }

  /// What changed since the last pass, as Markdown for the preview pane `D` opens. Removed when review ends.
  public var changesFile: URL { directory.appendingPathComponent(draft.lastPathComponent + ".changes.md") }

  /// One pass's own edits, so a queued pass is never overwritten by the next one.
  public func passEditsFile(_ pass: Int) -> URL {
    directory.appendingPathComponent(draft.lastPathComponent + ".pass-\(pass).edits.json")
  }

  /// Where every draft's review files live: termdown's own support folder, or `TERMDOWN_REVIEW_HOME` when set.
  public static let homeVariable = "TERMDOWN_REVIEW_HOME"

  public static func root(environment: [String: String], home: URL) -> URL {
    if let custom = environment[homeVariable], !custom.isEmpty {
      return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
    }
    return SupportPaths(home: home).reviewsDirectory
  }

  /// `<stem>-<first 12 hex of SHA-1 over the resolved path>`, the stem cut to 60 with unsafe characters as `-`.
  public static func directoryName(for resolvedDraft: URL) -> String {
    let digest = Insecure.SHA1.hash(data: Data(resolvedDraft.path.utf8)).map { String(format: "%02x", $0) }.joined()
    var stem = String(
      String.UnicodeScalarView(
        stemOf(resolvedDraft.lastPathComponent).unicodeScalars.map { scalar in
          scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "._-".unicodeScalars.contains(scalar))
            ? scalar : "-"
        }
      ).prefix(60))
    if stem.isEmpty { stem = "draft" }
    return "\(stem)-\(digest.prefix(12))"
  }

  /// pathlib's `stem`: the name without its last suffix, where a leading or trailing dot is not a suffix.
  static func stemOf(_ name: String) -> String {
    guard let dot = name.lastIndex(of: "."), dot != name.startIndex, name.index(after: dot) != name.endIndex
    else { return name }
    return String(name[..<dot])
  }

  /// Python's `Path.resolve()`: symlinks resolved as far as the path exists, without Foundation's `/private` trimming.
  static func resolved(_ url: URL) -> URL {
    let path = url.standardizedFileURL.path
    if let real = realpath(path, nil) {
      defer { free(real) }
      return URL(fileURLWithPath: String(cString: real))
    }
    let parent = url.standardizedFileURL.deletingLastPathComponent()
    guard parent.path != path else { return url.standardizedFileURL }
    return resolved(parent).appendingPathComponent(url.lastPathComponent)
  }

  /// The pass the next submit will be: one more than the records in the log that are not launches.
  public func nextPass() -> Int {
    guard let text = try? String(contentsOf: logFile, encoding: .utf8) else { return 1 }
    var passes = 0
    for line in text.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
      guard let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
      if (record["pass"] as? Int) != 0 { passes += 1 }
    }
    return passes + 1
  }

  public func about(client: String? = nil, about: String? = nil, pass: Int?) -> ReviewAbout {
    ReviewAbout(draft: draft, client: client, about: about, pass: pass)
  }

  /// Appends the launch record: the draft as it stands before the pass, so a bad pass can be recovered.
  public func logLaunch(snapshot: String, about: ReviewAbout?, now: Date = Date()) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let record = LaunchRecord(
      preReview: !FileManager.default.fileExists(atPath: logFile.path), beforePass: nextPass(),
      ts: Self.timestamp(now), about: about, snapshot: snapshot)
    try append(record)
  }

  /// Writes the pass's edits file and `.edits.json` whole, then appends the submit record. Returns the pass number.
  @discardableResult
  public func submit(
    action: ReviewAction, annotations: [ReviewAnnotation], launchText: String, finalText: String,
    about: ReviewAbout?, now: Date = Date()
  ) throws -> Int {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let diff = Self.manualEditDiff(from: launchText, to: finalText)
    let manual = diff.flatMap { $0.isEmpty ? nil : ManualEdits(note: Self.manualEditsNote, diff: $0) }
    let edits = EditsFile(draft: draft.path, action: action, annotations: annotations, manualEdits: manual)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
    let data = try encoder.encode(edits)
    let pass = nextPass()
    try data.write(to: passEditsFile(pass), options: .atomic)
    try data.write(to: editsFile, options: .atomic)
    try append(
      SubmitRecord(
        pass: pass, ts: Self.timestamp(now), about: about, action: action, snapshot: finalText, diff: diff,
        annotations: annotations))
    return pass
  }

  // MARK: Unsent marks

  struct MarksFile: Codable {
    var snapshot: String
    var marks: [SavedMark]
  }

  /// Writes the marks with the draft text their byte ranges refer to, whole or not at all.
  public func saveMarks(_ marks: [SavedMark], snapshot: String) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
    try encoder.encode(MarksFile(snapshot: snapshot, marks: marks)).write(to: marksFile, options: .atomic)
  }

  /// The saved marks and the text they refer to, or nil when there is no readable file.
  public func loadMarks() -> (marks: [SavedMark], snapshot: String)? {
    guard let data = try? Data(contentsOf: marksFile), let file = try? JSONDecoder().decode(MarksFile.self, from: data)
    else { return nil }
    return (file.marks, file.snapshot)
  }

  public func clearMarks() {
    try? FileManager.default.removeItem(at: marksFile)
  }

  // MARK: Reviewer lock

  /// Takes the lock for the viewer with this pid. It is taken when nobody holds it, when the holder is this pid, or when
  /// the holder is gone (a crashed viewer leaves its file behind).
  public func acquireLock(pid: Int32) -> Bool {
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for _ in 0..<2 {
      if createLock(pid: pid) { return true }
      if let holder = lockHolder(), holder == pid { return true }
      if let holder = lockHolder(), Self.isRunning(holder) { return false }
      try? FileManager.default.removeItem(at: lockFile)
    }
    return false
  }

  public func releaseLock() {
    try? FileManager.default.removeItem(at: lockFile)
  }

  /// Whether a running viewer holds this draft's lock. Reads only: a dead holder's file is left for the next viewer.
  public func reviewIsLive() -> Bool {
    lockHolder().map(Self.isRunning) ?? false
  }

  /// Creates the lock file only if it does not exist, so two viewers cannot both win.
  private func createLock(pid: Int32) -> Bool {
    let descriptor = open(lockFile.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }
    let bytes = Array("\(pid)\n".utf8)
    return write(descriptor, bytes, bytes.count) == bytes.count
  }

  private func lockHolder() -> Int32? {
    guard let text = try? String(contentsOf: lockFile, encoding: .utf8) else { return nil }
    return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  /// A process exists when it can be signalled, or when the signal is refused for lack of permission.
  static func isRunning(_ pid: Int32) -> Bool {
    pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
  }

  /// difflib's unified diff from the text at launch to the submitted text, or nil when they are equal.
  public static func manualEditDiff(from old: String, to new: String) -> String? {
    guard old != new else { return nil }
    return UnifiedDiff.lines(from: pythonLines(old), to: pythonLines(new), fromFile: "at-open", toFile: "submitted")
      .joined(separator: "\n")
  }

  /// Python's `str.splitlines()`: no empty entry after a final newline.
  static func pythonLines(_ text: String) -> [String] {
    guard !text.isEmpty else { return [] }
    var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
    if text.last?.isNewline == true { lines.removeLast() }
    return lines
  }

  static func timestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    return formatter.string(from: date)
  }

  private func append(_ record: some Encodable) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    let line = try encoder.encode(record) + Data("\n".utf8)
    if let handle = try? FileHandle(forWritingTo: logFile) {
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: line)
    } else {
      try line.write(to: logFile)
    }
  }

  struct ManualEdits: Encodable {
    let note: String
    let diff: String
  }

  struct EditsFile: Encodable {
    let draft: String
    let action: ReviewAction
    let annotations: [ReviewAnnotation]
    let manualEdits: ManualEdits?

    enum CodingKeys: String, CodingKey {
      case draft, action, annotations
      case manualEdits = "manual_edits"
    }

    func encode(to encoder: Encoder) throws {
      var c = encoder.container(keyedBy: CodingKeys.self)
      try c.encode(draft, forKey: .draft)
      try c.encode(action, forKey: .action)
      try c.encode(annotations, forKey: .annotations)
      try c.encode(manualEdits, forKey: .manualEdits)
    }
  }

  struct LaunchRecord: Encodable {
    let preReview: Bool
    let beforePass: Int
    let ts: String
    let about: ReviewAbout?
    let snapshot: String

    enum CodingKeys: String, CodingKey {
      case pass, ts, format, about, event, annotations
      case preReview = "pre_review"
      case beforePass = "before_pass"
      case snapshot = "draft_snapshot"
      case diff = "manual_edit_diff"
    }

    func encode(to encoder: Encoder) throws {
      var c = encoder.container(keyedBy: CodingKeys.self)
      try c.encode(0, forKey: .pass)
      try c.encode(preReview, forKey: .preReview)
      try c.encode(beforePass, forKey: .beforePass)
      try c.encode(ts, forKey: .ts)
      try c.encode(ReviewStore.format, forKey: .format)
      try c.encode(about, forKey: .about)
      try c.encode("launch", forKey: .event)
      try c.encode(snapshot, forKey: .snapshot)
      try c.encodeNil(forKey: .diff)
      try c.encode([ReviewAnnotation](), forKey: .annotations)
    }
  }

  struct SubmitRecord: Encodable {
    let pass: Int
    let ts: String
    let about: ReviewAbout?
    let action: ReviewAction
    let snapshot: String
    let diff: String?
    let annotations: [ReviewAnnotation]

    enum CodingKeys: String, CodingKey {
      case pass, ts, format, about, action, annotations
      case snapshot = "draft_snapshot"
      case diff = "manual_edit_diff"
    }

    func encode(to encoder: Encoder) throws {
      var c = encoder.container(keyedBy: CodingKeys.self)
      try c.encode(pass, forKey: .pass)
      try c.encode(ts, forKey: .ts)
      try c.encode(ReviewStore.format, forKey: .format)
      try c.encode(about, forKey: .about)
      try c.encode(action, forKey: .action)
      try c.encode(snapshot, forKey: .snapshot)
      try c.encode(diff, forKey: .diff)
      try c.encode(annotations, forKey: .annotations)
    }
  }
}

/// A port of review.py's `draft_about`: who the draft is for and what it pertains to, from frontmatter and folders.
public struct ReviewAbout: Equatable, Sendable, Encodable {
  public var client: String?
  public var kind: String?
  public var engagement: String?
  public var status: String?
  public var started: String?
  public var forClient: String?
  public var pertainsTo: String?
  public var dir: String?
  public var source: String?
  public var file: String
  public var path: String
  public var pass: Int?

  static let clientKeys = ["client", "customer"]
  static let aboutKeys = ["about", "re", "subject"]
  static let customerParents: Set<String> = ["40-customers", "customers"]
  static let overviewKinds = ["customer": "client", "project": "project"]
  static let maxWalk = 12
  static let frontmatterMax = 8192
  static let labelMax = 60

  public init(
    draft: URL, client: String? = nil, about: String? = nil, pass: Int?,
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) {
    let md = ReviewStore.resolved(draft)
    let fm = Self.readFrontmatter(md)
    var client = client
    var about = about
    var kind = "client"
    var source: String?
    if client != nil {
      source = "--client"
    } else if let key = Self.clientKeys.first(where: { Self.filled(fm[$0]) != nil }) {
      client = Self.filled(fm[key])
      source = "draft frontmatter"
    }
    if about == nil || about == "" {
      about = Self.aboutKeys.lazy.compactMap { Self.filled(fm[$0]) }.first
    }
    let found = Self.findEngagementDir(md)
    let ofm = found?.frontmatter ?? [:]
    if let found {
      if client == nil || client == "" {
        client = Self.engagementLabel(found.dir, ofm)
        kind = ofm["type"].flatMap { Self.overviewKinds[$0] } ?? "client"
        source = found.source
      }
      if about == nil || about == "" {
        let inside = Array(md.deletingLastPathComponent().pathComponents.dropFirst(found.dir.pathComponents.count))
        about = inside.joined(separator: "/")
      }
    } else if client == nil || client == "", let label = Self.projectLabel(md, home: home) {
      client = label
      kind = "context"
      source = "CLAUDE.md"
    }
    self.client = client?.isEmpty == false ? client : nil
    self.kind = self.client == nil ? nil : kind
    engagement = Self.filled(ofm["engagement"])
    status = Self.filled(ofm["status"])
    started = Self.filled(ofm["started"])
    forClient = ofm["type"] == "project" ? Self.filled(ofm["client"]) : nil
    pertainsTo = about?.isEmpty == false ? about : nil
    dir = found?.dir.path
    self.source = source
    file = md.lastPathComponent
    path = md.path
    self.pass = pass
  }

  enum CodingKeys: String, CodingKey {
    case client, kind, engagement, status, started, dir, source, file, path, pass
    case forClient = "for"
    case pertainsTo = "pertains_to"
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(client, forKey: .client)
    try c.encode(kind, forKey: .kind)
    try c.encode(engagement, forKey: .engagement)
    try c.encode(status, forKey: .status)
    try c.encode(started, forKey: .started)
    try c.encode(forClient, forKey: .forClient)
    try c.encode(pertainsTo, forKey: .pertainsTo)
    try c.encode(dir, forKey: .dir)
    try c.encode(source, forKey: .source)
    try c.encode(file, forKey: .file)
    try c.encode(path, forKey: .path)
    try c.encode(pass, forKey: .pass)
  }

  static func parents(_ url: URL) -> [URL] {
    var out: [URL] = []
    var current = url
    while current.path != "/" {
      current = current.deletingLastPathComponent()
      out.append(current)
    }
    return Array(out.prefix(maxWalk))
  }

  static func strip(_ text: some StringProtocol) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Top-level `key: value` scalars from a leading frontmatter block closed by `---` or `...`.
  static func parseFrontmatter(_ text: String) -> [String: String] {
    let lines = text.components(separatedBy: "\n")
    guard let first = lines.first, strip(first) == "---",
      let end = lines.indices.dropFirst().first(where: { ["---", "..."].contains(strip(lines[$0])) })
    else { return [:] }
    var out: [String: String] = [:]
    for line in lines[1..<end] {
      guard let head = line.first, !head.isWhitespace, head != "#", let colon = line.firstIndex(of: ":") else {
        continue
      }
      let value = strip(line[line.index(after: colon)...]).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
      out[strip(line[..<colon]).lowercased()] = value
    }
    return out
  }

  static func readFrontmatter(_ url: URL) -> [String: String] {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
    return parseFrontmatter(String(text.prefix(frontmatterMax)).replacingOccurrences(of: "\r\n", with: "\n"))
  }

  /// A frontmatter value, or nil while it is still a template placeholder.
  static func filled(_ value: String?) -> String? {
    let text = strip(value ?? "")
    if text.isEmpty || text.contains("|") || text.contains(" or ") { return nil }
    if ["null", "none", "tbd", "n/a"].contains(text.lowercased()) { return nil }
    if text.wholeMatch(of: #/(?i)[ymd]{2,4}([-\/][ymd]{2,4})+/#) != nil { return nil }
    return text
  }

  static func firstHeading(_ url: URL) -> String? {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    for line in text.split(separator: "\n", omittingEmptySubsequences: false).prefix(200) where line.hasPrefix("# ") {
      var label = strip(line.dropFirst(2))
      for separator in [" — ", " – ", " -- ", " - "] {
        label = label.components(separatedBy: separator)[0]
      }
      label = strip(strip(label).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
      return label.isEmpty ? nil : String(label.prefix(labelMax))
    }
    return nil
  }

  /// The nearest ancestor CLAUDE.md's heading, skipping anything under `.claude` and stopping at home.
  static func projectLabel(_ md: URL, home: URL) -> String? {
    for ancestor in parents(md) {
      if ancestor.path == home.path { break }
      if ancestor.pathComponents.contains(".claude") { continue }
      let claude = ancestor.appendingPathComponent("CLAUDE.md")
      var isDirectory: ObjCBool = false
      if FileManager.default.fileExists(atPath: claude.path, isDirectory: &isDirectory), !isDirectory.boolValue {
        return firstHeading(claude)
      }
    }
    return nil
  }

  static func isEngagementManifest(_ fm: [String: String]) -> Bool {
    fm["schema_version"] != nil || (fm["company"] != nil && fm["engagement"] != nil)
  }

  static func name(_ url: URL) -> String { url.path == "/" ? "" : url.lastPathComponent }

  static func nestedEngagement(_ dir: URL) -> Bool {
    let parent = dir.deletingLastPathComponent()
    return !customerParents.contains(name(parent)) && customerParents.contains(name(parent.deletingLastPathComponent()))
  }

  static func engagementLabel(_ dir: URL, _ fm: [String: String]) -> String {
    if let company = filled(fm["company"]), let engagement = filled(fm["engagement"]) {
      return "\(company)/\(engagement)"
    }
    if nestedEngagement(dir) { return "\(name(dir.deletingLastPathComponent()))/\(name(dir))" }
    return filled(fm["name"]) ?? name(dir)
  }

  static func findEngagementDir(_ md: URL) -> (dir: URL, frontmatter: [String: String], source: String)? {
    for dir in parents(md) {
      let overview = dir.appendingPathComponent("overview.md")
      var isDirectory: ObjCBool = false
      let fm =
        FileManager.default.fileExists(atPath: overview.path, isDirectory: &isDirectory) && !isDirectory.boolValue
        ? readFrontmatter(overview) : [:]
      if isEngagementManifest(fm) || fm["type"].map({ overviewKinds[$0] != nil }) == true {
        return (dir, fm, "overview.md")
      }
      if customerParents.contains(name(dir.deletingLastPathComponent())) { return (dir, fm, "folder name") }
    }
    return nil
  }
}

/// difflib's `unified_diff` with `lineterm=""`, over the line alignment Swift's `difference(from:)` finds.
enum UnifiedDiff {
  struct Op {
    let equal: Bool
    var i1, i2, j1, j2: Int
  }

  static func lines(from a: [String], to b: [String], fromFile: String, toFile: String, context n: Int = 3)
    -> [String]
  {
    var out: [String] = []
    for group in grouped(opcodes(a, b), n: n) {
      if out.isEmpty { out += ["--- \(fromFile)", "+++ \(toFile)"] }
      let first = group[0]
      let last = group[group.count - 1]
      out.append("@@ -\(range(first.i1, last.i2)) +\(range(first.j1, last.j2)) @@")
      for op in group {
        if op.equal {
          out += a[op.i1..<op.i2].map { " " + $0 }
        } else {
          out += a[op.i1..<op.i2].map { "-" + $0 }
          out += b[op.j1..<op.j2].map { "+" + $0 }
        }
      }
    }
    return out
  }

  static func range(_ start: Int, _ stop: Int) -> String {
    let length = stop - start
    if length == 1 { return "\(start + 1)" }
    return length == 0 ? "\(start),0" : "\(start + 1),\(length)"
  }

  static func opcodes(_ a: [String], _ b: [String]) -> [Op] {
    var removed = Set<Int>()
    var inserted = Set<Int>()
    for change in b.difference(from: a) {
      switch change {
      case .remove(let offset, _, _): removed.insert(offset)
      case .insert(let offset, _, _): inserted.insert(offset)
      }
    }
    var ops: [Op] = []
    var i = 0
    var j = 0
    while i < a.count || j < b.count {
      let (i0, j0) = (i, j)
      if i < a.count, j < b.count, !removed.contains(i), !inserted.contains(j) {
        while i < a.count, j < b.count, !removed.contains(i), !inserted.contains(j) {
          i += 1
          j += 1
        }
        ops.append(Op(equal: true, i1: i0, i2: i, j1: j0, j2: j))
      } else {
        while i < a.count, removed.contains(i) { i += 1 }
        while j < b.count, inserted.contains(j) { j += 1 }
        ops.append(Op(equal: false, i1: i0, i2: i, j1: j0, j2: j))
      }
    }
    return ops
  }

  /// difflib's `get_grouped_opcodes`: hunks with `n` lines of context, split where more than `2n` lines are unchanged.
  static func grouped(_ opcodes: [Op], n: Int) -> [[Op]] {
    var codes = opcodes.isEmpty ? [Op(equal: true, i1: 0, i2: 1, j1: 0, j2: 1)] : opcodes
    if codes[0].equal {
      codes[0].i1 = max(codes[0].i1, codes[0].i2 - n)
      codes[0].j1 = max(codes[0].j1, codes[0].j2 - n)
    }
    let end = codes.count - 1
    if codes[end].equal {
      codes[end].i2 = min(codes[end].i2, codes[end].i1 + n)
      codes[end].j2 = min(codes[end].j2, codes[end].j1 + n)
    }
    var groups: [[Op]] = []
    var group: [Op] = []
    for var op in codes {
      if op.equal, op.i2 - op.i1 > 2 * n {
        group.append(Op(equal: true, i1: op.i1, i2: min(op.i2, op.i1 + n), j1: op.j1, j2: min(op.j2, op.j1 + n)))
        groups.append(group)
        group = []
        op.i1 = max(op.i1, op.i2 - n)
        op.j1 = max(op.j1, op.j2 - n)
      }
      group.append(op)
    }
    if !group.isEmpty, !(group.count == 1 && group[0].equal) { groups.append(group) }
    return groups
  }
}
