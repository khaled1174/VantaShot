import AppKit
import CoreMedia
import ScreenCaptureKit
import VantaShotCore

enum CaptureError: LocalizedError {
  case permissionDenied, noDisplay, noWindow, emptyCapture, timeout
  var errorDescription: String? {
    switch self {
    case .permissionDenied: return "يلزم تفعيل إذن تسجيل الشاشة من إعدادات الخصوصية"
    case .noDisplay: return "الشاشة المحددة غير متاحة"
    case .noWindow: return "النافذة المحددة لم تعد متاحة"
    case .emptyCapture: return "لم يُرجع النظام صورة صالحة"
    case .timeout: return "انتهت مهلة التقاط الشاشة؛ أعد المحاولة"
    }
  }
}
@MainActor enum ScreenCaptureProvider {
  static func target(for rect: CGRect? = nil) throws -> DisplayCaptureTarget {
    guard
      let screen = rect.flatMap({ r in
        NSScreen.screens.first { $0.frame.contains(CGPoint(x: r.midX, y: r.midY)) }
      }) ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
        ?? NSScreen.main,
      let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    else { throw CaptureError.noDisplay }
    return DisplayCaptureTarget(
      displayID: number.uint32Value, displayFrame: screen.frame, rect: rect ?? screen.frame)
  }
  static func capture(target: DisplayCaptureTarget) async throws -> NSImage {
    let displays = Dictionary(
      uniqueKeysWithValues: NSScreen.screens.compactMap { s -> (UInt32, CGRect)? in
        guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        return (n.uint32Value, s.frame)
      })
    do { try target.validate(displays: displays) } catch { throw CaptureError.noDisplay }
    return try await capture(rect: target.rect, expectedTarget: target)
  }
  static func configuration(
    rect: CGRect, content: SCShareableContent, windowID: CGWindowID? = nil,
    expectedTarget: DisplayCaptureTarget? = nil
  )
    throws -> (SCContentFilter, SCStreamConfiguration)
  {
    let config = SCStreamConfiguration()
    config.showsCursor = false
    config.capturesAudio = false
    config.queueDepth = 3
    config.pixelFormat = kCVPixelFormatType_32BGRA
    if #available(macOS 14.0, *) {
      config.captureResolution = .best
    }
    if let windowID {
      guard let w = content.windows.first(where: { $0.windowID == windowID }) else {
        throw CaptureError.noWindow
      }
      let filter = SCContentFilter(desktopIndependentWindow: w)
      let scale =
        NSScreen.screens.first(where: { $0.frame.intersects(rect) })?.backingScaleFactor ?? 1
      config.width = Int(w.frame.width * scale)
      config.height = Int(w.frame.height * scale)
      return (filter, config)
    }
    guard
      let screen = NSScreen.screens.max(by: {
        $0.frame.intersection(rect).area < $1.frame.intersection(rect).area
      }), screen.frame.intersection(rect).area > 0,
      let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
      let display = content.displays.first(where: { $0.displayID == number.uint32Value })
    else { throw CaptureError.noDisplay }
    if let expectedTarget {
      guard expectedTarget.displayID == display.displayID,
        expectedTarget.displayFrame == screen.frame
      else { throw CaptureError.noDisplay }
    }
    let geometry = DisplayGeometry(
      appKitFrame: screen.frame, primaryTop: NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
    )
    let clipped = rect.intersection(screen.frame)
    // Mouse coordinates may have fractions even on a 1x remote display. Passing those
    // through while truncating the output size resamples every pixel and blurs text.
    // Cover the selection with whole source pixels, retaining a 1:1 pixel mapping.
    let scale = screen.backingScaleFactor
    let source = geometry.displayLocalQuartz(global: clipped)
    let pixels = CGRect(
      x: source.minX * scale, y: source.minY * scale,
      width: source.width * scale, height: source.height * scale).integral
    config.sourceRect = CGRect(
      x: pixels.minX / scale, y: pixels.minY / scale,
      width: pixels.width / scale, height: pixels.height / scale)
    config.width = max(2, Int(pixels.width))
    config.height = max(2, Int(pixels.height))
    let own = content.windows.filter {
      $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
        && !DesktopIconsCoverManager.shared.coverWindowIDs.contains($0.windowID)
    }
    return (SCContentFilter(display: display, excludingWindows: own), config)
  }
  static func capture(
    rect: CGRect, windowID: CGWindowID? = nil, expectedTarget: DisplayCaptureTarget? = nil
  ) async throws -> NSImage {
    guard CGPreflightScreenCaptureAccess() else { throw CaptureError.permissionDenied }
    try Task.checkCancellation()
    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: true)
    let (filter, config) = try configuration(
      rect: rect, content: content, windowID: windowID, expectedTarget: expectedTarget)
    let image: CGImage
    if #available(macOS 14.0, *) {
      image = try await SCScreenshotManager.captureImage(
        contentFilter: filter, configuration: config)
    } else {
      let receiver = FirstFrameReceiver()
      let stream = SCStream(filter: filter, configuration: config, delegate: receiver)
      try stream.addStreamOutput(
        receiver, type: .screen,
        sampleHandlerQueue: DispatchQueue(label: "dev.vantashot.first-frame"))
      do {
        image = try await receiver.capture(stream)
        try? await stream.stopCapture()
      } catch {
        try? await stream.stopCapture()
        throw error
      }
    }
    try Task.checkCancellation()
    guard image.width > 1, image.height > 1 else { throw CaptureError.emptyCapture }
    return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
  }
}
extension CGRect { var area: CGFloat { isNull ? 0 : width * height } }
private final class FirstFrameReceiver: NSObject, SCStreamOutput, SCStreamDelegate,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var continuation: CheckedContinuation<CGImage, Error>?
  private var completed = false
  func capture(_ stream: SCStream) async throws -> CGImage {
    try await withTaskCancellationHandler(
      operation: {
        try await withCheckedThrowingContinuation { continuation in
          lock.lock()
          if completed {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
          }
          self.continuation = continuation
          lock.unlock()
          Task {
            do {
              try await stream.startCapture()
              try await Task.sleep(nanoseconds: 3_000_000_000)
              finish(.failure(CaptureError.timeout))
            } catch { finish(.failure(error)) }
          }
        }
      }, onCancel: { self.finish(.failure(CancellationError())) })
  }
  private func finish(_ result: Result<CGImage, Error>) {
    lock.lock()
    guard !completed else {
      lock.unlock()
      return
    }
    completed = true
    let c = continuation
    continuation = nil
    lock.unlock()
    c?.resume(with: result)
  }
  func stream(_ stream: SCStream, didStopWithError error: Error) { finish(.failure(error)) }
  func stream(
    _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    guard type == .screen, sampleBuffer.isValid, let pixel = sampleBuffer.imageBuffer else {
      return
    }
    let ci = CIImage(cvPixelBuffer: pixel)
    guard let cg = CIContext().createCGImage(ci, from: ci.extent) else { return }
    finish(.success(cg))
  }
}
