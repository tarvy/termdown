import Foundation

/// A line-based three-way merge: the file as it was when editing began (base), the file as another writer left
/// it on disk, and the text being edited (mine). Changes from disk that touch lines mine left alone are applied;
/// where both changed the same lines, mine wins and the hunk is counted as kept.
enum LineMerge {
  struct Hunk {
    var base: Range<Int>
    var replacement: [[UInt8]]
  }

  struct Result {
    var text: [UInt8]
    var applied: Int
    var keptMine: Int
  }

  static func lines(_ bytes: [UInt8]) -> [[UInt8]] {
    var out: [[UInt8]] = []
    var start = 0
    for (index, byte) in bytes.enumerated() where byte == 0x0a {
      out.append(Array(bytes[start...index]))
      start = index + 1
    }
    if start < bytes.count { out.append(Array(bytes[start...])) }
    return out
  }

  /// Hunks turning `from` into `to`, from a longest-common-subsequence over the lines between the common prefix
  /// and suffix.
  static func hunks(from: [[UInt8]], to: [[UInt8]]) -> [Hunk] {
    var prefix = 0
    while prefix < from.count, prefix < to.count, from[prefix] == to[prefix] { prefix += 1 }
    var suffix = 0
    while suffix < from.count - prefix, suffix < to.count - prefix, from[from.count - 1 - suffix] == to[to.count - 1 - suffix] {
      suffix += 1
    }
    let a = Array(from[prefix..<(from.count - suffix)])
    let b = Array(to[prefix..<(to.count - suffix)])
    if a.isEmpty && b.isEmpty { return [] }
    if a.isEmpty || b.isEmpty { return [Hunk(base: prefix..<(prefix + a.count), replacement: b)] }
    // LCS table over the middle; notes are a few thousand lines at most and the middle is usually tiny.
    let n = a.count, m = b.count
    var table = [Int](repeating: 0, count: (n + 1) * (m + 1))
    func at(_ i: Int, _ j: Int) -> Int { table[i * (m + 1) + j] }
    for i in stride(from: n - 1, through: 0, by: -1) {
      for j in stride(from: m - 1, through: 0, by: -1) {
        table[i * (m + 1) + j] = a[i] == b[j] ? at(i + 1, j + 1) + 1 : max(at(i + 1, j), at(i, j + 1))
      }
    }
    var out: [Hunk] = []
    var i = 0, j = 0
    var hunkStart: Int? = nil
    var replacement: [[UInt8]] = []
    func close(_ end: Int) {
      if let start = hunkStart {
        out.append(Hunk(base: (prefix + start)..<(prefix + end), replacement: replacement))
        hunkStart = nil
        replacement = []
      }
    }
    while i < n || j < m {
      if i < n, j < m, a[i] == b[j] {
        close(i)
        i += 1
        j += 1
      } else if j < m, i == n || at(i, j + 1) >= at(i + 1, j) {
        if hunkStart == nil { hunkStart = i }
        replacement.append(b[j])
        j += 1
      } else {
        if hunkStart == nil { hunkStart = i }
        i += 1
      }
    }
    close(n)
    return out
  }

  static func overlap(_ x: Range<Int>, _ y: Range<Int>) -> Bool {
    if x.isEmpty && y.isEmpty { return x.lowerBound == y.lowerBound }
    if x.isEmpty { return y.lowerBound < x.lowerBound && x.lowerBound < y.upperBound }
    if y.isEmpty { return x.lowerBound < y.lowerBound && y.lowerBound < x.upperBound }
    return x.lowerBound < y.upperBound && y.lowerBound < x.upperBound
  }

  static func merge(base: [UInt8], disk: [UInt8], mine: [UInt8]) -> Result {
    let baseLines = lines(base)
    let diskHunks = hunks(from: baseLines, to: lines(disk))
    let mineHunks = hunks(from: baseLines, to: lines(mine))
    var out: [[UInt8]] = []
    var cursor = 0
    var di = 0, mi = 0
    var applied = 0, kept = 0
    func emitBase(upTo end: Int) {
      if end > cursor { out.append(contentsOf: baseLines[cursor..<end]) }
      cursor = max(cursor, end)
    }
    while di < diskHunks.count || mi < mineHunks.count {
      let d = di < diskHunks.count ? diskHunks[di] : nil
      let m = mi < mineHunks.count ? mineHunks[mi] : nil
      if let d, let m, overlap(d.base, m.base) {
        // A conflict region: grow it while later hunks on either side still touch it, then emit mine's version.
        var lo = min(d.base.lowerBound, m.base.lowerBound)
        var hi = max(d.base.upperBound, m.base.upperBound)
        var dEnd = di + 1, mEnd = mi + 1
        var grew = true
        while grew {
          grew = false
          while dEnd < diskHunks.count, overlap(diskHunks[dEnd].base, lo..<hi) {
            hi = max(hi, diskHunks[dEnd].base.upperBound)
            lo = min(lo, diskHunks[dEnd].base.lowerBound)
            dEnd += 1
            grew = true
          }
          while mEnd < mineHunks.count, overlap(mineHunks[mEnd].base, lo..<hi) {
            hi = max(hi, mineHunks[mEnd].base.upperBound)
            lo = min(lo, mineHunks[mEnd].base.lowerBound)
            mEnd += 1
            grew = true
          }
        }
        emitBase(upTo: lo)
        var inner = lo
        for hunk in mineHunks[mi..<mEnd] {
          if hunk.base.lowerBound > inner { out.append(contentsOf: baseLines[inner..<hunk.base.lowerBound]) }
          out.append(contentsOf: hunk.replacement)
          inner = hunk.base.upperBound
        }
        if hi > inner { out.append(contentsOf: baseLines[inner..<hi]) }
        cursor = hi
        kept += 1
        di = dEnd
        mi = mEnd
        continue
      }
      let takeDisk: Bool
      if let d, let m { takeDisk = d.base.lowerBound <= m.base.lowerBound } else { takeDisk = d != nil }
      let hunk = takeDisk ? d! : m!
      emitBase(upTo: hunk.base.lowerBound)
      out.append(contentsOf: hunk.replacement)
      cursor = hunk.base.upperBound
      if takeDisk {
        applied += 1
        di += 1
      } else {
        mi += 1
      }
    }
    emitBase(upTo: baseLines.count)
    return Result(text: out.flatMap { $0 }, applied: applied, keptMine: kept)
  }
}
