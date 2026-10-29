import AppKit
import XCTest

@testable import VantaShot
@testable import VantaShotCore

final class ScreenFlowLayoutTests: XCTestCase {
  // MARK: Pinned image placement

  func testPinnedFrameIsClampedInsideVisibleFrame() {
    let visible = CGRect(x: 0, y: 70, width: 1512, height: 880)
    let r = PinnedImageLayout.frame(
      imageSize: CGSize(width: 2000, height: 400), visibleFrame: visible)
    XCTAssertTrue(visible.contains(r), "pinned panel must be fully on-screen: \(r)")
    XCTAssertLessThanOrEqual(r.width, PinnedImageLayout.maxWidth)
    XCTAssertGreaterThanOrEqual(r.width, PinnedImageLayout.minWidth)
  }

  func testPinnedFrameKeepsAspectRatio() {
    let visible = CGRect(x: 0, y: 0, width: 1512, height: 950)
    let r = PinnedImageLayout.frame(
      imageSize: CGSize(width: 800, height: 600), visibleFrame: visible)
    XCTAssertEqual(r.width / r.height, 800.0 / 600.0, accuracy: 0.01)
  }

  func testPinnedFrameClampsHugeTallImage() {
    let visible = CGRect(x: 0, y: 0, width: 1512, height: 950)
    let r = PinnedImageLayout.frame(
      imageSize: CGSize(width: 300, height: 6000), visibleFrame: visible)
    XCTAssertTrue(visible.contains(r))
  }

  // MARK: Recording capsule placement

  func testRecordingCapsuleSitsAboveTheRegionWhenThereIsRoom() {
    let visible = CGRect(x: 0, y: 0, width: 1512, height: 950)
    let region = CGRect(x: 300, y: 200, width: 600, height: 400)
    let r = RecordingCapsuleLayout.frame(
      region: region, visibleFrame: visible, size: CGSize(width: 360, height: 48))
    XCTAssertEqual(r.midX, region.midX, accuracy: 0.5)
    XCTAssertGreaterThan(r.minY, region.maxY)
    XCTAssertTrue(visible.contains(r))
  }

  func testRecordingCapsuleFallsBelowRegionNearTopEdge() {
    let visible = CGRect(x: 0, y: 0, width: 1512, height: 950)
    let region = CGRect(x: 300, y: 880, width: 600, height: 60)
    let r = RecordingCapsuleLayout.frame(
      region: region, visibleFrame: visible, size: CGSize(width: 360, height: 48))
    XCTAssertLessThan(r.maxY, region.minY)
    XCTAssertTrue(visible.contains(r))
  }

  func testRecordingCapsuleStaysOnScreenForFullScreenRegion() {
    let visible = CGRect(x: 0, y: 0, width: 1512, height: 950)
    let r = RecordingCapsuleLayout.frame(
      region: visible, visibleFrame: visible, size: CGSize(width: 360, height: 48))
    XCTAssertTrue(visible.contains(r))
  }

  // MARK: History presentation

  func testMediaKindFriendlyNamesAreArabic() {
    XCTAssertEqual(MediaKind.stillImage.friendlyName, "صورة")
    XCTAssertEqual(MediaKind.animatedImage.friendlyName, "GIF")
    XCTAssertEqual(MediaKind.video.friendlyName, "فيديو")
  }

  func testHistoryFilterMatchesTitleAndKind() {
    let a = MediaAsset(
      kind: .stillImage, title: "لقطة نافذة Safari", fileURL: URL(fileURLWithPath: "/a.png"),
      pixelSize: PixelSize(width: 1, height: 1))
    let b = MediaAsset(
      kind: .video, title: "تسجيل MP4", fileURL: URL(fileURLWithPath: "/b.mp4"),
      pixelSize: PixelSize(width: 1, height: 1))
    XCTAssertEqual(HistoryFilter(query: "safari", kind: nil).apply(to: [a, b]).map(\.id), [a.id])
    XCTAssertEqual(HistoryFilter(query: "", kind: .video).apply(to: [a, b]).map(\.id), [b.id])
    XCTAssertEqual(HistoryFilter(query: "", kind: nil).apply(to: [a, b]).count, 2)
    XCTAssertEqual(HistoryFilter(query: "فيديو", kind: nil).apply(to: [a, b]).map(\.id), [b.id])
  }

  // MARK: Editor inspector

  func testInspectorSectionsFollowTheSelectedTool() {
    XCTAssertEqual(InspectorSections.for(.text), [.color, .text])
    XCTAssertEqual(InspectorSections.for(.arrow), [.color, .stroke, .arrowStyle])
    XCTAssertEqual(InspectorSections.for(.rectangle), [.color, .stroke])
    XCTAssertEqual(InspectorSections.for(.pixelate), [])
    XCTAssertEqual(InspectorSections.for(.crop), [])
    XCTAssertEqual(InspectorSections.for(.counter), [.color, .text])
  }

  func testBackgroundTemplatesAreDistinct() {
    let ids = BackgroundTemplate.all.map(\.id)
    XCTAssertEqual(Set(ids).count, ids.count)
    XCTAssertGreaterThanOrEqual(ids.count, 8)
  }

  // MARK: Countdown

  func testCountdownSequenceIsDescendingAndEndsAtOne() {
    XCTAssertEqual(CountdownSequence.steps(from: 3), [3, 2, 1])
    XCTAssertEqual(CountdownSequence.steps(from: 0), [])
  }
}

final class MeterAndSelectionTests: XCTestCase {
  func testRMSAndLevelMapping() {
    let samples: [Float] = [0.5, -0.5, 0.5, -0.5]
    samples.withUnsafeBufferPointer { XCTAssertEqual(AudioLevelMeter.rms($0), 0.5, accuracy: 0.0001) }
    XCTAssertEqual(AudioLevelMeter.level(fromRMS: 0), 0)
    XCTAssertEqual(AudioLevelMeter.level(fromRMS: 1), 1)
    XCTAssertEqual(AudioLevelMeter.level(fromRMS: 0.1), 0.6, accuracy: 0.001)  // -20 dB
    XCTAssertEqual(AudioLevelMeter.level(fromRMS: 0.001), 0)  // -60 dB clamps
    XCTAssertEqual(AudioLevelMeter.litBars(level: 0, count: 5), 0)
    XCTAssertEqual(AudioLevelMeter.litBars(level: 0.5, count: 5), 3)
    XCTAssertEqual(AudioLevelMeter.litBars(level: 1, count: 5), 5)
  }

  func testSelectionClickCommandAndShiftSemantics() {
    let ids = (0..<5).map { _ in UUID() }
    var s = HistorySelectionModel()
    s.click(ids[1], in: ids, command: false, shift: false)
    XCTAssertEqual(s.ids, [ids[1]])
    s.click(ids[3], in: ids, command: true, shift: false)
    XCTAssertEqual(s.ids, [ids[1], ids[3]])
    s.click(ids[3], in: ids, command: true, shift: false)
    XCTAssertEqual(s.ids, [ids[1]])
    // ⌘-click moved the anchor to ids[3] (Finder semantics), so ⇧ extends from there.
    s.click(ids[4], in: ids, command: false, shift: true)
    XCTAssertEqual(s.ids, Set(ids[3...4]))
    s.click(ids[0], in: ids, command: false, shift: false)
    XCTAssertEqual(s.ids, [ids[0]])
    s.selectAll(ids)
    XCTAssertEqual(s.ids.count, 5)
    s.prune(keeping: Array(ids[0..<2]))
    XCTAssertEqual(s.ids, Set(ids[0..<2]))
    s.clear()
    XCTAssertTrue(s.isEmpty)
  }
}
