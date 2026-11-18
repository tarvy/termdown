import Foundation
import TermDownCore

/// How long `termdown review` keeps trying while a freshly opened preview starts listening.
let reviewDeliveryWindow: TimeInterval = 5

enum ReviewCommand {
  static func run(_ arguments: [String]) -> Never {
    switch ReviewArguments.parse(arguments) {
    case .failure(let error):
      fail(error.description, status: 64)
    case .success(let review) where review.check:
      let file = URL(fileURLWithPath: review.file).standardizedFileURL
      let check = ReviewCheck(
        file: file.path, fileExists: FileManager.default.fileExists(atPath: file.path),
        rexSession: ProcessInfo.processInfo.environment["REX_SESSION"],
        reviewIsLive: ReviewStore(draft: file).reviewIsLive())
      print(check.text, terminator: "")
      exit(check.status)
    case .success(let review):
      do {
        let paths = currentPaths()
        let prepared = try OpenCommand.prepare(OpenArguments(file: review.file))
        let delivery = try openAndDeliverEdit(
          lock: paths.openLock, open: { try OpenCommand.open(prepared, requiresBlock: true) },
          deliver: { block in
            deliverWithRetry(window: reviewDeliveryWindow) {
              ViewerSocketClient.sendReview(path: prepared.file.path, to: paths.viewerSocket(block: block))
            }
          })
        switch delivery {
        case .noPreview: fail("could not find the preview block for \(review.file)", status: 1)
        case .unreachable: fail("could not reach the preview to start the review", status: 1)
        case .delivered: exit(0)
        }
      } catch {
        fail("\(error)", status: 1)
      }
    }
  }
}
