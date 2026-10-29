import AppKit
import ScreenCaptureKit
import SwiftUI
import VantaShotCore
import VantaShotRendering
import Vision

@MainActor public enum OCRService {
  private static var task: Task<Void, Never>?
  private static var generation = UUID()
  static var isRunning: Bool { task != nil }
  static func cancel() {
    generation = UUID()
    task?.cancel()
    task = nil
  }
  static var recognizer: @Sendable (CGImage, [String]) async throws -> String = { cg, languages in
    try await Task.detached(priority: .userInitiated) {
      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      request.usesLanguageCorrection = true
      let supported = try request.supportedRecognitionLanguages()
      let chosen = languages.filter { supported.contains($0) }
      guard languages.isEmpty || chosen.count == languages.count else {
        throw NSError(
          domain: "VantaShot.OCR", code: 1,
          userInfo: [
            NSLocalizedDescriptionKey: "لغة OCR غير مدعومة على هذا النظام. راجع الإعدادات."
          ])
      }
      if !chosen.isEmpty { request.recognitionLanguages = chosen }
      try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
      return request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(
        separator: "\n") ?? ""
    }.value
  }
  public static func extractAndCopyText(from image: NSImage, showNotification: Bool = true) {
    task?.cancel()
    let id = UUID()
    generation = id
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      AssetFiles.showError(StorageError.invalidData)
      return
    }
    let languages = AppSettings.shared.ocrLanguages.split(separator: ",").map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    task = Task {
      defer { if generation == id { task = nil } }
      do {
        let text = try await recognizer(cg, languages)
        guard !Task.isCancelled, generation == id else { return }
        guard !text.isEmpty else {
          if showNotification { ToastBannerHUD.shared.show(message: "لم يُعثر على نص واضح") }
          return
        }
        let result = OCRResult(text: text)
        OCRResultsController.shared.result = result
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        if showNotification { OCRFloatingBar.shared.show(result: result) }
      } catch {
        guard !Task.isCancelled, generation == id else { return }
        AssetFiles.showError(error)
      }
    }
  }
}
@MainActor public final class LiveScrollingCaptureController: ObservableObject {
  public static let shared = LiveScrollingCaptureController()
  @Published public private(set) var mergedImage: NSImage?
  @Published public private(set) var frameCount = 1
  @Published public private(set) var isAutoScrolling = false
  @Published var axis: ScrollAxis = .vertical
  @Published var status = "حرّك الصفحة ثم أضف إطارًا، أو ابدأ التمرير التلقائي"
  public var onCancel: (() -> Void)?
  private var target: CGRect = .zero
  private var expectedTarget: DisplayCaptureTarget?
  private var stitcher: ScrollStitcher?
  private var hud: NSPanel?
  private let regionFrame = RegionFrameWindow()
  var captureFrame: (CGRect) async throws -> NSImage = {
    try await ScreenCaptureService.captureAppKitRect($0)
  }
  var isCapturing: Bool { work != nil }
  private var work: Task<Void, Never>?
  private var autoTask: Task<Void, Never>?
  private var generation = UUID()
  private var completion: ((NSImage) -> Void)?
  public func start(
    rectInAppKit: CGRect, initialImage: NSImage, target captureTarget: DisplayCaptureTarget? = nil,
    onFinish: @escaping (NSImage) -> Void
  ) {
    cleanup()
    generation = UUID()
    self.target = rectInAppKit
    expectedTarget = captureTarget
    completion = onFinish
    mergedImage = initialImage
    frameCount = 1
    if let cg = initialImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
      stitcher = ScrollStitcher(first: cg, axis: axis)
    }
    regionFrame.show(around: target, style: .scrolling)
    let visible =
      (NSScreen.screens.first { $0.frame.intersects(target) } ?? NSScreen.main)?.visibleFrame
      ?? target
    let p = NSPanel(
      contentRect: RecordingCapsuleLayout.frame(
        region: target, visibleFrame: visible, size: ScrollingHUDPanelView.size),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    p.isReleasedWhenClosed = false
    p.hidesOnDeactivate = false
    p.isOpaque = false
    p.backgroundColor = .clear
    p.hasShadow = true
    p.isMovableByWindowBackground = true
    p.level = .floating
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    p.contentView = NSHostingView(rootView: ScrollingHUDPanelView(controller: self))
    hud = p
    VantaPanelMotion.present(p, from: CGPoint(x: 0, y: 12))
  }
  public func captureAndStitchNextFrame() {
    guard work == nil else { return }
    let id = generation
    let capture = captureFrame
    let expected = expectedTarget
    work = Task {
      do {
        let image: NSImage
        if let expected {
          image = try await ScreenCaptureProvider.capture(target: expected)
        } else {
          image = try await capture(target)
        }
        guard generation == id, !Task.isCancelled,
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil), var s = stitcher
        else { return }
        let added = try s.append(cg)
        stitcher = s
        if added {
          mergedImage = NSImage(
            cgImage: s.image, size: NSSize(width: s.image.width, height: s.image.height))
          frameCount += 1
          status = "تم دمج الإطار"
        } else {
          status = "لا محتوى جديد؛ لم يُضف إطار مكرر"
          if isAutoScrolling { stopAuto() }
        }
      } catch {
        guard generation == id, !Task.isCancelled else { return }
        status = error.localizedDescription
        stopAuto()
      }
      guard generation == id else { return }
      work = nil
    }
  }
  func setAxis(_ value: ScrollAxis) {
    guard frameCount == 1,
      let cg = mergedImage?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else { return }
    axis = value
    stitcher = ScrollStitcher(first: cg, axis: value)
  }
  public func toggleAutoScroll() {
    if isAutoScrolling {
      stopAuto()
      return
    }
    guard AXIsProcessTrusted() else {
      status = "يلزم إذن تسهيلات الاستخدام للتمرير التلقائي. يمكنك التمرير يدويًا وإضافة الإطارات."
      return
    }
    isAutoScrolling = true
    let id = generation
    autoTask = Task {
      while !Task.isCancelled, generation == id, isAutoScrolling {
        let point = CGPoint(
          x: target.midX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - target.midY)
        if let e = CGEvent(
          scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
          wheel1: axis == .vertical ? -160 : 0, wheel2: axis == .horizontal ? -160 : 0, wheel3: 0)
        {
          e.location = point
          e.post(tap: .cghidEventTap)
        }
        do { try await Task.sleep(nanoseconds: 450_000_000) } catch { break }
        captureAndStitchNextFrame()
        if let work { await work.value }
      }
    }
  }
  private func stopAuto() {
    autoTask?.cancel()
    autoTask = nil
    isAutoScrolling = false
  }
  public func finish() {
    guard let image = mergedImage else {
      cancel()
      return
    }
    let callback = completion
    cleanup()
    completion = nil
    callback?(image)
  }
  public func cancel() {
    let callback = onCancel
    cleanup()
    completion = nil
    callback?()
  }
  private func cleanup() {
    generation = UUID()
    stopAuto()
    work?.cancel()
    work = nil
    hud?.orderOut(nil)
    hud = nil
    regionFrame.hide()
  }
}
struct ScrollingHUDPanelView: View {
  static let size = CGSize(width: 560, height: 72)
  @ObservedObject var controller: LiveScrollingCaptureController
  var body: some View {
    HStack(spacing: 10) {
      if let image = controller.mergedImage {
        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
          .frame(width: 72, height: 48).clipped()
          .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
          .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(VantaTheme.Palette.stroke, lineWidth: 1))
      }
      VStack(alignment: .leading, spacing: 2) {
        Text("\u{2066}\(controller.frameCount)\u{2069} إطار مدمج").font(VantaTheme.Font.label)
        Text(controller.status).font(VantaTheme.Font.caption)
          .foregroundStyle(VantaTheme.Palette.textSecondary).lineLimit(1).truncationMode(.tail)
      }
      .frame(maxWidth: 150, alignment: .leading)
      Spacer(minLength: 4)
      HStack(spacing: 4) {
        PillButton(icon: "arrow.up.and.down", help: "تمرير رأسي") { controller.setAxis(.vertical) }
          .opacity(controller.axis == .vertical ? 1 : 0.45)
        PillButton(icon: "arrow.left.and.right", help: "تمرير أفقي") { controller.setAxis(.horizontal) }
          .opacity(controller.axis == .horizontal ? 1 : 0.45)
      }
      .disabled(controller.frameCount > 1)
      VantaIconButton(title: "إطار", icon: "plus.rectangle.on.rectangle", compact: true) {
        controller.captureAndStitchNextFrame()
      }
      VantaIconButton(
        title: controller.isAutoScrolling ? "إيقاف" : "تلقائي",
        icon: controller.isAutoScrolling ? "pause.fill" : "play.fill",
        isSelected: controller.isAutoScrolling, compact: true
      ) { controller.toggleAutoScroll() }
      VantaIconButton(title: "إنهاء", icon: "checkmark", shortcut: "⏎", role: .prominent, compact: true) {
        controller.finish()
      }
      PillButton(icon: "xmark", help: "إلغاء (Esc)") { controller.cancel() }
    }
    .padding(.horizontal, 12).padding(.vertical, 8)
    .frame(width: Self.size.width, height: Self.size.height)
    .vantaGlassCard(radius: VantaTheme.Radius.large, shadow: false)
    .foregroundStyle(VantaTheme.Palette.text)
    .preferredColorScheme(.dark)
    .environment(\.layoutDirection, .rightToLeft)
  }
}
