import AppKit
import SwiftUI
import os

// MARK: - Cursor halo / click ripples / keystroke capsule shown *inside* the recording.
// These windows are deliberately excepted from the capture filter so they appear in the video.

@MainActor final class RecordingDecorations {
  static let shared = RecordingDecorations()
  private static let logger = Logger(subsystem: "dev.vantashot.macos", category: "Decorations")
  /// Keystroke capture needs the Input Monitoring permission; returns the current state and prompts once.
  static func keystrokeMonitoringAllowed(prompt: Bool) -> Bool {
    if ScreenCaptureService.hasInputMonitoringPermission { return true }
    if prompt { ScreenCaptureService.promptInputMonitoringOnce() }
    return ScreenCaptureService.hasInputMonitoringPermission
  }
  private var haloWindow: NSWindow?
  private var haloView: CursorHaloView?
  private var keysWindow: NSPanel?
  private let keysModel = KeystrokeModel()
  private var monitors: [Any] = []
  private var keysHideTask: Task<Void, Never>?
  /// Global mouse monitors miss warped/synthetic pointer moves, so the halo also polls the pointer.
  private var haloPoll: Timer?

  var windowIDs: Set<CGWindowID> {
    Set([haloWindow, keysWindow].compactMap { $0 }.map { CGWindowID($0.windowNumber) })
  }

  /// Creates whichever decoration windows are enabled in settings, on the screen containing `region`.
  func prepare(region: CGRect) {
    stop()
    let settings = AppSettings.shared
    guard settings.highlightCursor || settings.showKeystrokes else { return }
    guard
      let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: region.midX, y: region.midY)) })
        ?? NSScreen.main
    else { return }
    if settings.highlightCursor {
      let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
      w.isReleasedWhenClosed = false
      w.isOpaque = false
      w.backgroundColor = .clear
      w.hasShadow = false
      w.ignoresMouseEvents = true
      w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow)))
      w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
      let v = CursorHaloView(frame: NSRect(origin: .zero, size: screen.frame.size))
      v.screenOrigin = screen.frame.origin
      w.contentView = v
      w.orderFrontRegardless()
      haloWindow = w
      haloView = v
      v.update(mouse: NSEvent.mouseLocation)
      haloPoll = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak v] _ in
        v?.update(mouse: NSEvent.mouseLocation)
      }
      Self.logger.info("cursor halo window \(w.windowNumber, privacy: .public) prepared for capture")
      monitors.append(
        NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) {
          [weak self] e in
          Task { @MainActor in self?.haloView?.update(mouse: NSEvent.mouseLocation) }
        } as Any)
      monitors.append(
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
          Task { @MainActor in self?.haloView?.ripple(at: NSEvent.mouseLocation) }
        } as Any)
    }
    if settings.showKeystrokes {
      let allowed = Self.keystrokeMonitoringAllowed(prompt: true)
      Self.logger.info("keystroke overlay requested; input monitoring granted=\(allowed, privacy: .public)")
      if !allowed {
        ToastBannerHUD.shared.show(
          message: "Keystrokes need Input Monitoring permission.",
          subtitle: "Turn it on in System Settings → Privacy & Security, then record again.",
          icon: "exclamationmark.triangle")
      }
      let size = CGSize(width: 320, height: 54)
      let frame = CGRect(
        x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.minY + 40,
        width: size.width, height: size.height)
      let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
      p.isReleasedWhenClosed = false
      p.isOpaque = false
      p.backgroundColor = .clear
      p.hasShadow = false
      p.ignoresMouseEvents = true
      p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow)))
      p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
      p.contentView = NSHostingView(rootView: KeystrokeCapsuleView(model: keysModel))
      p.alphaValue = 0
      p.orderFrontRegardless()
      keysWindow = p
      monitors.append(
        NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] e in
          let text = KeystrokeFormatter.describe(e)
          Task { @MainActor in self?.showKeys(text) }
        } as Any)
    }
  }

  private func showKeys(_ text: String) {
    guard let p = keysWindow, !text.isEmpty else { return }
    keysModel.text = text
    keysModel.generation += 1
    p.animator().alphaValue = 1
    keysHideTask?.cancel()
    keysHideTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 1_400_000_000)
      guard !Task.isCancelled, let self, let p = self.keysWindow else { return }
      p.animator().alphaValue = 0
    }
  }

  func stop() {
    for m in monitors { NSEvent.removeMonitor(m) }
    monitors = []
    haloPoll?.invalidate()
    haloPoll = nil
    keysHideTask?.cancel()
    keysHideTask = nil
    haloWindow?.orderOut(nil)
    haloWindow = nil
    haloView = nil
    keysWindow?.orderOut(nil)
    keysWindow = nil
  }
}

final class CursorHaloView: NSView {
  var screenOrigin: CGPoint = .zero
  private var mouse: CGPoint = .zero
  private var ripples: [(center: CGPoint, start: TimeInterval)] = []
  private var timer: Timer?
  private let haloRadius: CGFloat = 26

  override var isFlipped: Bool { false }

  func update(mouse screenPoint: CGPoint) {
    mouse = CGPoint(x: screenPoint.x - screenOrigin.x, y: screenPoint.y - screenOrigin.y)
    needsDisplay = true
  }

  func ripple(at screenPoint: CGPoint) {
    ripples.append(
      (CGPoint(x: screenPoint.x - screenOrigin.x, y: screenPoint.y - screenOrigin.y), CACurrentMediaTime()))
    if timer == nil {
      timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
        guard let self else { return }
        let now = CACurrentMediaTime()
        self.ripples.removeAll { now - $0.start > 0.45 }
        self.needsDisplay = true
        if self.ripples.isEmpty {
          self.timer?.invalidate()
          self.timer = nil
        }
      }
    }
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    ctx.setFillColor(NSColor(red: 1, green: 0.85, blue: 0.2, alpha: 0.28).cgColor)
    ctx.fillEllipse(in: CGRect(x: mouse.x - haloRadius, y: mouse.y - haloRadius, width: haloRadius * 2, height: haloRadius * 2))
    ctx.setStrokeColor(NSColor(red: 1, green: 0.85, blue: 0.2, alpha: 0.7).cgColor)
    ctx.setLineWidth(1.5)
    ctx.strokeEllipse(in: CGRect(x: mouse.x - haloRadius, y: mouse.y - haloRadius, width: haloRadius * 2, height: haloRadius * 2))
    let now = CACurrentMediaTime()
    for r in ripples {
      let t = min(1, (now - r.start) / 0.45)
      let radius = haloRadius * (0.6 + 1.6 * CGFloat(t))
      ctx.setStrokeColor(NSColor(red: 0.16, green: 0.85, blue: 0.98, alpha: 0.9 * (1 - t)).cgColor)
      ctx.setLineWidth(3 * (1 - t) + 1)
      ctx.strokeEllipse(in: CGRect(x: r.center.x - radius, y: r.center.y - radius, width: radius * 2, height: radius * 2))
    }
  }
}

@MainActor final class KeystrokeModel: ObservableObject {
  @Published var text = ""
  @Published var generation = 0
}

struct KeystrokeCapsuleView: View {
  @ObservedObject var model: KeystrokeModel
  @State private var bump = false
  var body: some View {
    Text(model.text)
      .font(.system(size: 20, weight: .semibold, design: .rounded))
      .foregroundStyle(VantaTheme.Palette.text)
      .padding(.horizontal, 18).padding(.vertical, 9)
      .vantaGlassCard(radius: 27, shadow: true)
      .scaleEffect(bump ? 1.04 : 1)
      .frame(width: 320, height: 54)
      .onChange(of: model.generation) { _ in
        bump = true
        withAnimation(VantaTheme.Motion.spring) { bump = false }
      }
      .environment(\.layoutDirection, .leftToRight)
  }
}

enum KeystrokeFormatter {
  static func describe(_ e: NSEvent) -> String {
    var parts: [String] = []
    let f = e.modifierFlags
    if f.contains(.control) { parts.append("⌃") }
    if f.contains(.option) { parts.append("⌥") }
    if f.contains(.shift) { parts.append("⇧") }
    if f.contains(.command) { parts.append("⌘") }
    let special: [UInt16: String] = [
      36: "↩", 48: "⇥", 49: "␣", 51: "⌫", 53: "⎋", 76: "⌤", 117: "⌦", 123: "←", 124: "→", 125: "↓",
      126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
    ]
    if let s = special[e.keyCode] {
      parts.append(s)
    } else if let c = e.charactersIgnoringModifiers, !c.isEmpty {
      parts.append(c.uppercased())
    }
    return parts.joined(separator: " ")
  }
}
