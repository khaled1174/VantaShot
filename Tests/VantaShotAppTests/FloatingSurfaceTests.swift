import AppKit
import XCTest

@testable import VantaShot

final class FloatingSurfaceTests: XCTestCase {
  private func windowServerEntry(for number: Int) -> [String: Any]? {
    let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.first { ($0[kCGWindowNumber as String] as? Int) == number }
  }

  @MainActor func testToastKeepsItsFrameAndFadesIn() async throws {
    _ = NSApplication.shared
    ToastBannerHUD.shared.show(message: "تم النسخ", subtitle: "اختبار")
    defer { ToastBannerHUD.shared.hide() }
    let panel = try XCTUnwrap(NSApp.windows.first { $0.level == .screenSaver && $0.isVisible })
    XCTAssertEqual(panel.frame.width, 420)
    XCTAssertEqual(panel.frame.height, 68)
    try await Task.sleep(nanoseconds: 600_000_000)
    XCTAssertEqual(panel.alphaValue, 1, accuracy: 0.01)
    XCTAssertEqual(panel.frame.width, 420)
    XCTAssertEqual(panel.frame.height, 68)
    let screen = try XCTUnwrap(panel.screen ?? NSScreen.main)
    XCTAssertEqual(panel.frame.maxY, screen.visibleFrame.maxY - 18, accuracy: 0.5)
    let entry = try XCTUnwrap(
      windowServerEntry(for: panel.windowNumber), "toast window is unknown to the window server")
    XCTAssertEqual(entry[kCGWindowIsOnscreen as String] as? Bool, true)
    let bounds = try XCTUnwrap(entry[kCGWindowBounds as String] as? [String: CGFloat])
    XCTAssertEqual(bounds["Width"], 420)
    XCTAssertEqual(bounds["Height"], 68)
  }
}
