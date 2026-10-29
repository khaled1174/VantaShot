import XCTest

@testable import VantaShotCore

final class RecordingTimelineTests: XCTestCase {
  func testPauseRemovedFromTimeline() {
    var t = RecordingTimeline()
    XCTAssertEqual(t.presentationTime(100), 0)
    XCTAssertEqual(t.presentationTime(102), 2)
    t.pause(at: 102)
    XCTAssertNil(t.presentationTime(104))
    t.resume(at: 105)
    XCTAssertEqual(t.presentationTime(107), 4)
  }
  func testBeyondThirtySecondsIsNotCapped() {
    var t = RecordingTimeline()
    _ = t.presentationTime(100)
    XCTAssertEqual(t.presentationTime(145), 45)
  }
}
