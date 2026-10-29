import AppKit
import ScreenCaptureKit
import XCTest

@testable import VantaShot

final class CaptureResolutionTests: XCTestCase {
  @MainActor func testLiveFractionalCaptureMatchesNativePixelReference() async throws {
    guard let path = ProcessInfo.processInfo.environment["VANTASHOT_PIXEL_FIXTURE_EVIDENCE"] else {
      throw XCTSkip("Requires the explicitly launched pixel-grid fixture")
    }
    let screen = try XCTUnwrap(NSScreen.screens.first)
    guard screen.frame == CGRect(x: 0, y: 0, width: 1920, height: 1080),
      screen.backingScaleFactor == 1
    else { throw XCTSkip("The supplied fixture uses a 1920x1080 1x display") }
    let rect = CGRect(x: 230.25, y: 260.75, width: 500.5, height: 100.5)
    let area = try await ScreenCaptureProvider.capture(rect: rect)
    let full = try await ScreenCaptureProvider.capture(rect: screen.frame)
    let actual = try XCTUnwrap(area.cgImage(forProposedRect: nil, context: nil, hints: nil))
    let fullCG = try XCTUnwrap(full.cgImage(forProposedRect: nil, context: nil, hints: nil))
    let reference = try XCTUnwrap(fullCG.cropping(to: CGRect(x: 230, y: 718, width: 501, height: 102)))
    XCTAssertEqual(actual.width, 501)
    XCTAssertEqual(actual.height, 102)
    guard actual.width == reference.width, actual.height == reference.height else { return }
    func rgba(_ image: CGImage) throws -> [UInt8] {
      let context = try XCTUnwrap(CGContext(
        data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.interpolationQuality = .none
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
      return Array(UnsafeBufferPointer(
        start: try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self),
        count: image.width * image.height * 4))
    }
    let a = try rgba(actual), b = try rgba(reference)
    // Reject a covered/absent fixture: matching two blank backgrounds proves little.
    // The independently drawn fixture has alternating black/white source pixels here.
    for x in 0..<100 {
      let offset = (50 * 501 + x) * 4
      XCTAssertEqual(a[offset], x.isMultiple(of: 2) ? 0 : 255, "The 1-pixel grid must stay sharp")
    }
    let meanDifference = Double(zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(a.count)
    XCTAssertLessThan(meanDifference, 0.01, "Capture must preserve source pixels rather than resample text/grid")
    let output = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    try AssetFiles.png(area).write(to: output.appendingPathComponent("product-fractional.png"))
    try AssetFiles.png(NSImage(cgImage: reference, size: NSSize(width: 501, height: 102)))
      .write(to: output.appendingPathComponent("native-reference.png"))
    try "Mean absolute RGBA difference: \(meanDifference)\n".write(
      to: output.appendingPathComponent("pixel-comparison.txt"), atomically: true, encoding: .utf8)
  }
  @MainActor func testFractionalSelectionUsesWholeSourcePixelsWithoutRescaling() async throws {
    guard CGPreflightScreenCaptureAccess(), let screen = NSScreen.screens.first else {
      throw XCTSkip("Requires screen capture access and a connected display")
    }
    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: true)
    // Express a selection in display-local Quartz points. At 1x its covered pixel bounds
    // are x: 20..<121, y: 40..<122. Truncating width/height resamples 100.5x80.5 into 100x80.
    let rect = CGRect(
      x: screen.frame.minX + 20.25, y: screen.frame.maxY - 121.25,
      width: 100.5, height: 80.5)
    let (_, config) = try ScreenCaptureProvider.configuration(rect: rect, content: content)
    let scale = screen.backingScaleFactor
    XCTAssertEqual(config.sourceRect.minX * scale, (20.25 * scale).rounded(.down))
    XCTAssertEqual(config.sourceRect.minY * scale, (40.75 * scale).rounded(.down))
    XCTAssertEqual(config.sourceRect.maxX * scale, (120.75 * scale).rounded(.up))
    XCTAssertEqual(config.sourceRect.maxY * scale, (121.25 * scale).rounded(.up))
    XCTAssertEqual(CGFloat(config.width), config.sourceRect.width * scale)
    XCTAssertEqual(CGFloat(config.height), config.sourceRect.height * scale)
  }
}
