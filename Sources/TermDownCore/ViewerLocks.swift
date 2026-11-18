import Foundation

/// A running termdown's IDE lock file in ~/.claude/ide, as `termdown claude` reads it.
public struct ViewerLock: Equatable, Sendable {
  public var port: Int
  public var pid: Int32
  public var ideName: String
  public var session: String?
  public var block: String?
  public var opener: String?
  public var modified: Date

  /// The open file's name, from the `termdown: <name>` display name.
  public var fileName: String? {
    guard let colon = ideName.range(of: ": ") else { return nil }
    return String(ideName[colon.upperBound...])
  }
}

public enum ViewerLocks {
  /// Lock file fields beyond Claude Code's: the viewer's Rex session and pane, and the pane that opened it.
  public static let sessionKey = "rexSession"
  public static let blockKey = "rexBlock"
  public static let openerKey = "rexOpenerBlock"

  /// termdown lock files in `directory` whose process is alive.
  public static func read(
    _ directory: URL, isAlive: (Int32) -> Bool = { kill($0, 0) == 0 || errno != ESRCH }
  ) -> [ViewerLock] {
    let manager = FileManager.default
    guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return [] }
    return names.compactMap { name -> ViewerLock? in
      guard name.hasSuffix(".lock"), let port = Int(name.dropLast(".lock".count)) else { return nil }
      let url = directory.appendingPathComponent(name)
      guard let data = try? Data(contentsOf: url),
        let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let ideName = body["ideName"] as? String,
        ideName.hasPrefix("termdown") || ideName.hasPrefix("termdown"),
        let pid = (body["pid"] as? NSNumber)?.int32Value, isAlive(pid)
      else { return nil }
      let modified = (try? manager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
      return ViewerLock(
        port: port, pid: pid, ideName: ideName, session: body[sessionKey] as? String,
        block: body[blockKey] as? String, opener: body[openerKey] as? String, modified: modified)
    }
  }

  /// The viewer an agent in `pane` should pin to: the newest one that pane opened (showing `file` when given),
  /// else the newest one in the same session showing `file`.
  public static func pick(_ locks: [ViewerLock], pane: String, session: String?, file: String?) -> ViewerLock? {
    let newest = locks.sorted { $0.modified > $1.modified }
    let shows: (ViewerLock) -> Bool = { lock in file.map { lock.fileName == $0 } ?? true }
    if let own = newest.first(where: { $0.opener == pane && shows($0) }) { return own }
    guard let file else { return nil }
    return newest.first { $0.fileName == file && (session == nil || $0.session == session) }
  }
}
