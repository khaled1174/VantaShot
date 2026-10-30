import AppKit
import VantaShotCore
import XCTest

@testable import VantaShot

final class WindowAndProjectTests: XCTestCase {
  @MainActor func testHistoryWindowHasUsableMinimumSize() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = CleanWorkflowCoordinator(historyRoot: root)
    coordinator.perform(.history)
    await Task.yield()
    let window = try XCTUnwrap(NSApp.windows.first { $0.title == "VantaShot History" })
    defer {
      window.close()
      window.contentView = nil
    }
    XCTAssertGreaterThanOrEqual(window.frame.width, 640)
    XCTAssertGreaterThanOrEqual(window.frame.height, 400)
    XCTAssertFalse(window.isReleasedWhenClosed)
  }
  @MainActor func testValidProjectReopensSourceLayersCropAndFont() async throws {
    _ = NSApplication.shared
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".vantashot")
    defer { try? FileManager.default.removeItem(at: path) }
    let c = CGContext(
      data: nil, width: 100, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.setFillColor(CGColor(gray: 1, alpha: 1))
    c.fill(CGRect(x: 0, y: 0, width: 100, height: 80))
    let image = NSImage(cgImage: c.makeImage()!, size: NSSize(width: 100, height: 80))
    var d = AnnotationDocument(size: PixelSize(width: 100, height: 80))
    d.cropRect = CGRect(x: 10, y: 10, width: 60, height: 50)
    var text = AnnotationObject(
      tool: .text, points: [CGPoint(x: 20, y: 20)], text: "مرحبا", fontSize: 20)
    text.fontFamily = "Geeza Pro"
    d.objects = [
      text,
      AnnotationObject(
        tool: .redact, points: [CGPoint(x: 30, y: 30), CGPoint(x: 50, y: 50)], color: RGBA(0, 0, 0)),
    ]
    try DocumentStore.save(document: d, sourcePNG: AssetFiles.png(image), to: path)
    let controller = AnnotateWindowController.shared
    VantaAppDelegate.openFiles([path])
    XCTAssertEqual(controller.document, d)
    let exported = try controller.renderFinalImage()
    let cg = try XCTUnwrap(exported.cgImage(forProposedRect: nil, context: nil, hints: nil))
    XCTAssertEqual(cg.width, 60)
    XCTAssertEqual(cg.height, 50)
    NSApp.windows.first { $0.title == path.lastPathComponent }?.close()
  }

  @MainActor func testLiveInspectorEditsUpdateSelectedAnnotationImmediately() throws {
    _ = NSApplication.shared
    let c = CGContext(
      data: nil, width: 100, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let image = NSImage(cgImage: c.makeImage()!, size: NSSize(width: 100, height: 80))
    let controller = AnnotateWindowController.shared
    controller.open(with: image, title: "اختبار التحديث الفوري")
    defer {
      NSApp.windows.first { $0.title == "اختبار التحديث الفوري" }?.close()
    }
    let arrow = AnnotationObject(
      tool: .arrow, points: [CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 50)], lineWidth: 4)
    var d = controller.document
    d.objects = [arrow]
    controller.commit(d)
    controller.select(arrow.id)
    controller.strokeWidth = 12
    controller.doubleArrow = true
    let updated = try XCTUnwrap(controller.document.objects.first { $0.id == arrow.id })
    XCTAssertEqual(updated.lineWidth, 12)
    XCTAssertTrue(updated.doubleArrow)
  }

  @MainActor func testVisibleFloatingPanelPreventsUnwantedLauncherReopenOnActivate() {
    _ = NSApplication.shared
    let launcher = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    launcher.isReleasedWhenClosed = false
    launcher.orderOut(nil)
    CleanWorkflowCoordinator.shared.mainLauncherWindow = launcher

    let panel = NSPanel(
      contentRect: NSRect(x: 50, y: 50, width: 120, height: 80),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.orderFrontRegardless()
    defer {
      panel.close()
      launcher.close()
    }

    let delegate = VantaAppDelegate()
    delegate.applicationDidBecomeActive(
      Notification(name: NSApplication.didBecomeActiveNotification))
    XCTAssertFalse(launcher.isVisible)
  }
}
