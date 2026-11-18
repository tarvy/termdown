import Foundation

public enum OpenRoute: Equatable, Sendable {
  case rexPreview
  case forward(bundleID: String)
  case textEditFallback
}

public enum HandlerIdentity {
  public static let bundleID = "com.tarvy.termdown"
  /// Ids earlier builds of the handler app used. They are this app, never a previous handler to record or forward to.
  public static let legacyBundleIDs: Set<String> = ["com.goodbanana.rexworks.termdown"]

  public static func isSelf(_ id: String, selfID: String = bundleID) -> Bool {
    id == selfID || legacyBundleIDs.contains(id)
  }
  public static let rexBundlePrefix = "com.superlogical.rex"
}

public func route(
  senderBundleID: String?,
  previousHandler: String?,
  handlerExists: (String) -> Bool
) -> OpenRoute {
  if let senderBundleID, senderBundleID.hasPrefix(HandlerIdentity.rexBundlePrefix) {
    return .rexPreview
  }
  if let previousHandler, !HandlerIdentity.isSelf(previousHandler), handlerExists(previousHandler) {
    return .forward(bundleID: previousHandler)
  }
  return .textEditFallback
}

public func forwardRoute(previousHandler: String?, handlerExists: (String) -> Bool) -> OpenRoute {
  route(senderBundleID: nil, previousHandler: previousHandler, handlerExists: handlerExists)
}
