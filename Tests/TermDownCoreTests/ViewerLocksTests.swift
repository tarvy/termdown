import Foundation
import Testing

@testable import TermDownCore

@Suite struct ViewerLocksTests {
  func directory(_ locks: [Int: [String: Any]]) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    for (port, body) in locks {
      try JSONSerialization.data(withJSONObject: body).write(to: url.appendingPathComponent("\(port).lock"))
    }
    return url
  }

  @Test func readsLiveViewerLocksOnly() throws {
    let url = try directory([
      100: ["pid": 1, "ideName": "termdown: a.md", "rexSession": "s", "rexBlock": "v", "rexOpenerBlock": "p"],
      101: ["pid": 2, "ideName": "Visual Studio Code"],
      102: ["pid": 3, "ideName": "termdown: b.md"],
    ])
    let locks = ViewerLocks.read(url, isAlive: { $0 != 3 })
    #expect(locks.map(\.port) == [100])
    #expect(locks.first?.opener == "p")
    #expect(locks.first?.fileName == "a.md")
  }

  @Test func picksTheNewestViewerThePaneOpened() {
    let old = ViewerLock(port: 1, pid: 1, ideName: "termdown: a.md", opener: "p", modified: Date(timeIntervalSince1970: 1))
    let new = ViewerLock(port: 2, pid: 2, ideName: "termdown: b.md", opener: "p", modified: Date(timeIntervalSince1970: 2))
    let other = ViewerLock(port: 3, pid: 3, ideName: "termdown: c.md", opener: "q", modified: Date(timeIntervalSince1970: 3))
    #expect(ViewerLocks.pick([old, new, other], pane: "p", session: nil, file: nil)?.port == 2)
    #expect(ViewerLocks.pick([old, new, other], pane: "p", session: nil, file: "a.md")?.port == 1)
    #expect(ViewerLocks.pick([old, new, other], pane: "z", session: nil, file: nil) == nil)
  }

  @Test func fallsBackToAViewerOfTheFileInTheSameSession() {
    let shared = ViewerLock(
      port: 4, pid: 4, ideName: "termdown: a.md", session: "s", opener: "q", modified: Date(timeIntervalSince1970: 1))
    #expect(ViewerLocks.pick([shared], pane: "p", session: "s", file: "a.md")?.port == 4)
    #expect(ViewerLocks.pick([shared], pane: "p", session: "t", file: "a.md") == nil)
  }
}
