import AppKit
import XCTest

@testable import VantaShot

final class RecordingSetupTests: XCTestCase {
  @MainActor func testRecordingWaitsForAnExplicitFormatChoiceAndCanCancel() async throws {
    _ = NSApplication.shared
    let recorder = LiveScreenRecorderController()
    var cancellations = 0
    var results = 0
    recorder.onCancel = { cancellations += 1 }
    recorder.startRecording(rectInAppKit: CGRect(x: 200, y: 200, width: 400, height: 300)) { _ in
      results += 1
    }
    XCTAssertFalse(recorder.isStarting, "Selecting an area must offer GIF/video before starting capture")
    XCTAssertFalse(recorder.isRecording)
    recorder.cancel()
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertFalse(recorder.isStarting)
    XCTAssertFalse(recorder.isRecording)
    XCTAssertEqual(cancellations, 1)
    XCTAssertEqual(results, 0)
  }
}
