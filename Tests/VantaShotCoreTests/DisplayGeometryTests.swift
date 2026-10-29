import XCTest

@testable import VantaShotCore

final class DisplayGeometryTests: XCTestCase {
  func testNegativeSecondaryOriginPreserved() {
    let g = DisplayGeometry(
      appKitFrame: CGRect(x: -1920, y: 300, width: 1920, height: 1080), primaryTop: 900)
    let global = g.globalRect(local: CGRect(x: 100, y: 200, width: 300, height: 100))
    XCTAssertEqual(global, CGRect(x: -1820, y: 500, width: 300, height: 100))
    XCTAssertEqual(g.quartzRect(global: global), CGRect(x: -1820, y: 300, width: 300, height: 100))
    XCTAssertEqual(
      g.displayLocalQuartz(global: global), CGRect(x: 100, y: 780, width: 300, height: 100))
  }
}
extension DisplayGeometryTests {
  func testStableTargetRejectsDisplayReplacementAndReflow() throws {
    let frame = CGRect(x: -1920, y: 300, width: 1920, height: 1080)
    let rect = CGRect(x: -1800, y: 400, width: 400, height: 300)
    let target = DisplayCaptureTarget(displayID: 7, displayFrame: frame, rect: rect)
    try target.validate(displays: [7: frame])
    XCTAssertThrowsError(try target.validate(displays: [8: frame]))
    XCTAssertThrowsError(try target.validate(displays: [7: frame.offsetBy(dx: 1920, dy: 0)]))
  }
}
