import AVFoundation
import AppKit
import ImageIO
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers
import Vision

// MARK: - Capture Mode Definition

public enum CaptureMode: String, CaseIterable, Identifiable {
  case allInOne = "الكل في واحد"
  case area = "منطقة"
  case window = "نافذة"
  case fullscreen = "شاشة كاملة"
  case scrolling = "تمرير متدرج"
  case ocr = "نسخ نص OCR"
  case record = "تسجيل فيديو/GIF"

  public var id: String { rawValue }

  public var icon: String {
    switch self {
    case .allInOne: return "sparkles.rectangle.stack"
    case .area: return "viewfinder"
    case .window: return "macwindow"
    case .fullscreen: return "rectangle.inset.filled"
    case .scrolling: return "arrow.up.and.down.text.horizontal"
    case .ocr: return "text.viewfinder"
    case .record: return "record.circle.fill"
    }
  }

  public var shortcutKey: String {
    switch self {
    case .allInOne: return "Space"
    case .area: return "A"
    case .window: return "W"
    case .fullscreen: return "F"
    case .scrolling: return "S"
    case .ocr: return "O"
    case .record: return "R"
    }
  }
}

public struct DetectedWindowInfo {
  public let windowID: CGWindowID
  public let ownerName: String
  public let title: String
  /// Screen coordinates in AppKit bottom-left origin
  public let appKitFrame: CGRect
  /// Screen coordinates in Quartz top-left origin
  public let cgFrame: CGRect
}

// MARK: - Core Screen Capture Service (Never Fails Silently)

@MainActor
public enum ScreenCaptureService {

  public static var hasScreenPermission: Bool {
    CGPreflightScreenCaptureAccess()
  }

  public static func requestPermissionAndOpenSettings() {
    _ = CGRequestScreenCaptureAccess()
    if let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    {
      NSWorkspace.shared.open(url)
    }
  }

  public static func captureAppKitRect(_ rect: CGRect) async throws -> NSImage {
    try await ScreenCaptureProvider.capture(rect: rect)
  }
  public static func captureFullDisplay() async throws -> NSImage {
    guard
      let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
        ?? NSScreen.main
    else { throw CaptureError.noDisplay }
    return try await captureAppKitRect(screen.frame)
  }
  public static func captureWindow(windowInfo: DetectedWindowInfo) async throws -> NSImage {
    try await ScreenCaptureProvider.capture(
      rect: windowInfo.appKitFrame, windowID: windowInfo.windowID)
  }

  /// Lists all visible standard application windows on screen (excluding our own overlay windows)
  public static func visibleWindows(on screen: NSScreen, excludingPID: pid_t)
    -> [DetectedWindowInfo]
  {
    guard
      let infoList = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
      ) as? [[String: Any]]
    else {
      return []
    }

    let screenHeight = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
    var results: [DetectedWindowInfo] = []

    for entry in infoList {
      guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
        pid != excludingPID,
        let layer = entry[kCGWindowLayer as String] as? Int,
        layer == 0,
        let windowID = entry[kCGWindowNumber as String] as? CGWindowID,
        let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
        let cgRect = CGRect(dictionaryRepresentation: boundsDict),
        cgRect.width > 60, cgRect.height > 60
      else {
        continue
      }

      let owner = (entry[kCGWindowOwnerName as String] as? String) ?? "تطبيق"
      let title = (entry[kCGWindowName as String] as? String) ?? owner
      let appKitRect = CGRect(
        x: cgRect.minX,
        y: screenHeight - cgRect.maxY,
        width: cgRect.width,
        height: cgRect.height
      )
      results.append(
        DetectedWindowInfo(
          windowID: windowID,
          ownerName: owner,
          title: title,
          appKitRect: appKitRect,
          cgFrame: cgRect
        )
      )
    }
    return results
  }

  public static func playShutterSound() {
    NSSound(named: NSSound.Name("Tink"))?.play()
  }
}

extension DetectedWindowInfo {
  init(windowID: CGWindowID, ownerName: String, title: String, appKitRect: CGRect, cgFrame: CGRect)
  {
    self.windowID = windowID
    self.ownerName = ownerName
    self.title = title
    self.appKitFrame = appKitRect
    self.cgFrame = cgFrame
  }
}

// MARK: - Instant Toast Banner HUD (Confirms Every User Action on Screen)

@MainActor
public final class ToastBannerHUD {
  public static let shared = ToastBannerHUD()
  private var panel: NSPanel?
  private var dismissTask: Task<Void, Never>?
  static let autoHideSeconds: TimeInterval = 2.6

  public func hide() {
    dismissTask?.cancel()
    dismissTask = nil
    guard let p = panel else { return }
    panel = nil
    VantaPanelMotion.dismiss(p) { p.close() }
  }

  public func show(message: String, subtitle: String? = nil, icon: String = "checkmark.circle.fill")
  {
    dismissTask?.cancel()
    panel?.close()
    panel = nil

    guard
      let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
        ?? NSScreen.main
    else { return }
    let width: CGFloat = 420
    let height: CGFloat = subtitle == nil ? 52 : 68
    let rect = NSRect(
      x: screen.frame.midX - width / 2,
      y: screen.visibleFrame.maxY - height - 18,
      width: width,
      height: height
    )

    let p = NSPanel(
      contentRect: rect,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    p.isReleasedWhenClosed = false
    p.level = .screenSaver
    p.isOpaque = false
    p.backgroundColor = .clear
    p.hasShadow = true
    p.ignoresMouseEvents = true
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

    let tint: Color
    if icon.hasPrefix("exclamationmark") {
      tint = VantaTheme.Palette.warning
    } else if icon == "timer" {
      tint = VantaTheme.Palette.accent
    } else {
      tint = VantaTheme.Palette.success
    }
    p.contentView = NSHostingView(
      rootView: ToastBannerView(
        message: message, subtitle: subtitle, icon: icon, tint: tint, height: height))
    VantaPanelMotion.present(p, from: CGPoint(x: 0, y: 16))
    panel = p
    dismissTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(Self.autoHideSeconds * 1_000_000_000))
      guard !Task.isCancelled, self?.panel === p else { return }
      self?.hide()
    }
  }
}

struct ToastBannerView: View {
  let message: String
  let subtitle: String?
  let icon: String
  let tint: Color
  let height: CGFloat
  @State private var iconShown = false

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: icon)
        .font(.system(size: 20, weight: .bold))
        .foregroundStyle(tint)
        .scaleEffect(iconShown ? 1 : 0.6)
        .opacity(iconShown ? 1 : 0)
      VStack(alignment: .leading, spacing: 2) {
        Text(message)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(VantaTheme.Palette.text)
        if let subtitle, !subtitle.isEmpty {
          Text(subtitle)
            .font(VantaTheme.Font.label)
            .foregroundStyle(VantaTheme.Palette.textSecondary)
            .lineLimit(1)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 10)
    .frame(height: height)
    .vantaGlassCard(radius: height / 2, shadow: false)
    .environment(\.layoutDirection, .rightToLeft)
    .onAppear { withAnimation(VantaTheme.Motion.spring.delay(0.08)) { iconShown = true } }
  }
}
