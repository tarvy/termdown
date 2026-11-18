import XCTest

@testable import TermDownCore

final class VersionTests: XCTestCase {
  func testVersionIsSemantic() {
    XCTAssertNotNil(termDownVersion.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression))
  }
}
