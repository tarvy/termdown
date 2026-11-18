import AppKit

public protocol PasteboardWriting: AnyObject {
  func write(_ text: String, markdown: Bool) -> Bool
  func writeRich(html: String, plain: String) -> Bool
}

public final class SystemPasteboard: PasteboardWriting {
  public static let markdownType = NSPasteboard.PasteboardType("net.daringfireball.markdown")

  private let pasteboard: NSPasteboard

  public init(pasteboard: NSPasteboard = .general) {
    self.pasteboard = pasteboard
  }

  public func write(_ text: String, markdown: Bool) -> Bool {
    pasteboard.clearContents()
    let types: [NSPasteboard.PasteboardType] = markdown ? [Self.markdownType, .string] : [.string]
    pasteboard.declareTypes(types, owner: nil)
    return types.allSatisfy { pasteboard.setString(text, forType: $0) }
  }

  public func writeRich(html: String, plain: String) -> Bool {
    pasteboard.clearContents()
    let types: [NSPasteboard.PasteboardType] = [.html, .string]
    pasteboard.declareTypes(types, owner: nil)
    return pasteboard.setString(html, forType: .html) && pasteboard.setString(plain, forType: .string)
  }
}
