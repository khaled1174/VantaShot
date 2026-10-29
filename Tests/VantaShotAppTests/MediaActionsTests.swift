import AVFoundation
import AppKit
import VantaShotCore
import XCTest

@testable import VantaShot

final class MediaActionsTests: XCTestCase {
  @MainActor func testAnimatedClipboardKeepsOriginalBytesAndSurvivesHistoryEviction() throws {
    let pb = NSPasteboard.general
    let saved = (NSPasteboard.general.pasteboardItems ?? []).map { item -> NSPasteboardItem in
      let copy = NSPasteboardItem()
      for type in item.types {
        if let d = item.data(forType: type) { copy.setData(d, forType: type) }
      }
      return copy
    }
    defer {
      pb.clearContents()
      pb.writeObjects(saved)
    }
    let input = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".gif")
    let bytes = Data([71, 73, 70, 56, 57, 97, 1, 2, 3])
    try bytes.write(to: input)
    let a = MediaAsset(
      kind: .animatedImage, title: "GIF", fileURL: input, pixelSize: PixelSize(width: 1, height: 1))
    try AssetFiles.copy(a)
    let item = try XCTUnwrap(pb.pasteboardItems?.first)
    XCTAssertEqual(pb.pasteboardItems?.count, 1)
    XCTAssertNil(item.data(forType: .png))
    let copy = try XCTUnwrap(item.string(forType: .fileURL).flatMap { URL(string: $0) })
    defer { try? FileManager.default.removeItem(at: copy) }
    XCTAssertNotEqual(copy, input)
    try FileManager.default.removeItem(at: input)
    XCTAssertEqual(try Data(contentsOf: copy), bytes)
  }
  @MainActor func testTrimOneToThreePreservesSourceAndCreatesTwoSeconds() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let w = try MediaWriter(
      url: root.appendingPathComponent("source.mp4"), width: 160, height: 100, system: false,
      mic: false)
    let helper = RecordingMediaTests()
    let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
    for offset in [0.0, 1.0, 2.0, 3.0] {
      let buffer = try helper.sample(seconds: now - 4 + offset, red: offset < 2 ? 1 : 0)
      w.queue.sync { w.appendVideo(buffer) }
    }
    let (_, duration) = try await w.finish()
    let original = try Data(contentsOf: w.url)
    let a = MediaAsset(
      kind: .video, title: "Source", fileURL: w.url, pixelSize: PixelSize(width: 160, height: 100),
      duration: duration)
    let out = try await MediaTrimService.trim(a, start: 1, end: 3)
    defer {
      try? FileManager.default.removeItem(at: out.fileURL)
      if let p = out.previewURL { try? FileManager.default.removeItem(at: p) }
    }
    let result = try await AVURLAsset(url: out.fileURL).load(.duration).seconds
    XCTAssertEqual(result, 2, accuracy: 0.05)
    XCTAssertEqual(try Data(contentsOf: w.url), original)
  }
}
