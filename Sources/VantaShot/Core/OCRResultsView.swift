import AppKit
import SwiftUI
import VantaShotCore

@MainActor final class OCRResultsController: ObservableObject {
  static let shared = OCRResultsController()
  @Published var result: OCRResult?
  private var window: NSWindow?
  func show() {
    guard let result else { return }
    if window == nil {
      let w = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
      w.isReleasedWhenClosed = false
      w.title = "النص المستخرج والروابط"
      w.titlebarAppearsTransparent = true
      w.backgroundColor = NSColor(red: 0.06, green: 0.075, blue: 0.12, alpha: 1)
      w.center()
      window = w
    }
    window?.contentView = NSHostingView(rootView: OCRResultView(result: result))
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
}
struct OCRResultView: View {
  let result: OCRResult
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label("النص المستخرج", systemImage: "text.viewfinder").font(VantaTheme.Font.title)
        Spacer()
        Text("\u{2066}\(result.text.count)\u{2069} حرفًا").font(VantaTheme.Font.caption)
          .foregroundStyle(VantaTheme.Palette.textSecondary)
        VantaIconButton(title: "نسخ الكل", icon: "doc.on.doc", role: .prominent, compact: true) {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(result.text, forType: .string)
          ToastBannerHUD.shared.show(message: "تم نسخ النص", icon: "text.viewfinder")
        }
      }
      ScrollView {
        Text(result.text).font(VantaTheme.Font.body).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading).padding(12)
      }
      .background(
        RoundedRectangle(cornerRadius: VantaTheme.Radius.medium, style: .continuous)
          .fill(VantaTheme.Palette.fillSubtle))
      if !result.detectedURLs.isEmpty {
        Text("الروابط المكتشفة").font(VantaTheme.Font.label)
          .foregroundStyle(VantaTheme.Palette.textSecondary)
        ForEach(result.detectedURLs, id: \.absoluteString) { u in
          HStack {
            Text(u.absoluteString).font(VantaTheme.Font.number).textSelection(.enabled).lineLimit(1)
              .truncationMode(.middle)
            Spacer()
            PillButton(icon: "safari", help: "فتح الرابط") { NSWorkspace.shared.open(u) }
            PillButton(icon: "doc.on.doc", help: "نسخ الرابط") {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(u.absoluteString, forType: .string)
            }
          }
        }
      }
    }
    .frame(minWidth: 500, minHeight: 360)
    .padding(18)
    .background(Color(red: 0.06, green: 0.075, blue: 0.12))
    .foregroundStyle(VantaTheme.Palette.text)
    .preferredColorScheme(.dark)
    .environment(\.layoutDirection, .rightToLeft)
  }
}

// MARK: - Floating OCR bar: replaces the plain toast after a successful extraction.

@MainActor final class OCRFloatingBar {
  static let shared = OCRFloatingBar()
  static let size = CGSize(width: 480, height: 64)
  static let autoHideSeconds: TimeInterval = 7
  private var panel: NSPanel?
  private var hideTask: Task<Void, Never>?

  func show(result: OCRResult) {
    hide()
    let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    guard let visible = screen?.visibleFrame else { return }
    let frame = CGRect(
      x: visible.midX - Self.size.width / 2, y: visible.maxY - Self.size.height - 18,
      width: Self.size.width, height: Self.size.height)
    let p = NSPanel(
      contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)
    p.isReleasedWhenClosed = false
    p.hidesOnDeactivate = false
    p.isOpaque = false
    p.backgroundColor = .clear
    p.hasShadow = true
    p.level = .screenSaver
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    p.contentView = NSHostingView(
      rootView: OCRFloatingBarView(
        result: result,
        onOpen: { [weak self] in
          self?.hide()
          OCRResultsController.shared.show()
        },
        onClose: { [weak self] in self?.hide() },
        onHover: { [weak self] hovering in
          if hovering { self?.hideTask?.cancel() } else { self?.scheduleHide() }
        }))
    panel = p
    VantaPanelMotion.present(p, from: CGPoint(x: 0, y: 16))
    scheduleHide()
  }

  private func scheduleHide() {
    hideTask?.cancel()
    hideTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(Self.autoHideSeconds * 1_000_000_000))
      guard !Task.isCancelled else { return }
      self?.hide()
    }
  }

  func hide() {
    hideTask?.cancel()
    hideTask = nil
    guard let p = panel else { return }
    panel = nil
    VantaPanelMotion.dismiss(p) { p.close() }
  }
}

struct OCRFloatingBarView: View {
  let result: OCRResult
  let onOpen: () -> Void
  let onClose: () -> Void
  let onHover: (Bool) -> Void
  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "text.viewfinder").font(.system(size: 18, weight: .semibold))
        .foregroundStyle(VantaTheme.Palette.success)
      VStack(alignment: .leading, spacing: 2) {
        Text("نُسخ \u{2066}\(result.text.count)\u{2069} حرفًا إلى الحافظة").font(VantaTheme.Font.label)
        Text(result.text.replacingOccurrences(of: "\n", with: " ")).font(VantaTheme.Font.caption)
          .foregroundStyle(VantaTheme.Palette.textSecondary).lineLimit(1).truncationMode(.tail)
      }
      Spacer(minLength: 6)
      if !result.detectedURLs.isEmpty {
        VantaIconButton(
          title: "الروابط", icon: "link", shortcut: "\u{2066}\(result.detectedURLs.count)\u{2069}",
          compact: true, action: onOpen)
      }
      VantaIconButton(title: "فتح النص", icon: "doc.text", role: .prominent, compact: true, action: onOpen)
      PillButton(icon: "xmark", help: "إغلاق", action: onClose)
    }
    .padding(.horizontal, 14).padding(.vertical, 8)
    .frame(width: OCRFloatingBar.size.width, height: OCRFloatingBar.size.height)
    .vantaGlassCard(radius: OCRFloatingBar.size.height / 2, shadow: false)
    .foregroundStyle(VantaTheme.Palette.text)
    .preferredColorScheme(.dark)
    .environment(\.layoutDirection, .rightToLeft)
    .onHover(perform: onHover)
  }
}
