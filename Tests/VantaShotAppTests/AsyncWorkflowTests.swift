import AppKit
import XCTest

@testable import VantaShot

actor DeferredRequest {
  private var continuation: CheckedContinuation<Void, Never>?
  private(set) var started = false
  func wait() async {
    await withCheckedContinuation { c in
      continuation = c
      started = true
    }
  }
  func release() {
    continuation?.resume()
    continuation = nil
  }
  func waitForStart() async throws {
    for _ in 0..<200 {
      if started { return }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    throw NSError(domain: "TestTimeout", code: 1)
  }
}
final class AsyncWorkflowTests: XCTestCase {
  @MainActor func image() -> NSImage {
    let c = CGContext(
      data: nil, width: 100, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return NSImage(cgImage: c.makeImage()!, size: NSSize(width: 100, height: 80))
  }
  @MainActor func testCancelledOCRCannotOverwriteNewClipboard() async throws {
    let pb = NSPasteboard.general
    let saved = (pb.pasteboardItems ?? []).map { item -> NSPasteboardItem in
      let copy = NSPasteboardItem()
      for type in item.types {
        if let data = item.data(forType: type) { copy.setData(data, forType: type) }
      }
      return copy
    }
    let old = OCRService.recognizer
    defer {
      OCRService.cancel()
      OCRService.recognizer = old
      pb.clearContents()
      pb.writeObjects(saved)
    }
    let deferred = DeferredRequest()
    OCRService.recognizer = { _, _ in
      await deferred.wait()
      return "STALE"
    }
    OCRService.extractAndCopyText(from: image())
    try await deferred.waitForStart()
    OCRService.cancel()
    pb.clearContents()
    pb.setString("NEW CAPTURE B", forType: .string)
    await deferred.release()
    try await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertEqual(pb.string(forType: .string), "NEW CAPTURE B")
  }
  @MainActor func testOldScrollingFailureCannotClearNewWork() async throws {
    _ = NSApplication.shared
    let a = DeferredRequest()
    let b = DeferredRequest()
    let controller = LiveScrollingCaptureController()
    defer { controller.cancel() }
    controller.captureFrame = { _ in
      await a.wait()
      throw NSError(domain: "Old request", code: 1)
    }
    controller.start(
      rectInAppKit: CGRect(x: 50, y: 50, width: 100, height: 80), initialImage: image()
    ) { _ in }
    controller.captureAndStitchNextFrame()
    try await a.waitForStart()
    controller.cancel()
    controller.captureFrame = { _ in
      await b.wait()
      throw NSError(domain: "New request", code: 2)
    }
    controller.start(
      rectInAppKit: CGRect(x: 50, y: 50, width: 100, height: 80), initialImage: image()
    ) { _ in }
    controller.status = "B active"
    controller.captureAndStitchNextFrame()
    try await b.waitForStart()
    await a.release()
    try await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertTrue(controller.isCapturing)
    XCTAssertEqual(controller.status, "B active")
    controller.cancel()
    await b.release()
  }
  @MainActor func testAutoScrollRequestsAccessibilityPermissionWhenUntrusted() {
    _ = NSApplication.shared
    let controller = LiveScrollingCaptureController()
    defer { controller.cancel() }
    var prompted = false
    controller.isAccessibilityTrusted = { false }
    controller.requestAccessibilityPermission = { prompted = true }
    controller.start(
      rectInAppKit: CGRect(x: 50, y: 50, width: 100, height: 80), initialImage: image()
    ) { _ in }
    controller.toggleAutoScroll()
    XCTAssertTrue(prompted)
    XCTAssertFalse(controller.isAutoScrolling)
  }
}
