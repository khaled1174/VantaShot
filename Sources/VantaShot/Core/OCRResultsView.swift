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
        styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered,
        defer: false)
      w.isReleasedWhenClosed = false
      w.title = "Extracted Text and Links"
      VantaWindowGlass.configure(w)
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
        Label("Extracted Text", systemImage: "text.viewfinder").font(VantaTheme.Font.title)
        Spacer()
        Text("\(result.text.count) \(result.text.count == 1 ? "character" : "characters")").font(VantaTheme.Font.caption)
          .foregroundStyle(VantaTheme.Palette.textSecondary)
        VantaIconButton(title: "Copy All", icon: "doc.on.doc", role: .prominent, compact: true) {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(result.text, forType: .string)
          ToastBannerHUD.shared.show(message: "Text copied", icon: "text.viewfinder")
        }
      }
      ScrollView {
        Text(result.text).font(VantaTheme.Font.body).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading).padding(12)
      }
      .vantaSurfaceCard(radius: VantaTheme.Radius.medium)
      if !result.detectedURLs.isEmpty {
        Text("Detected links").font(VantaTheme.Font.label)
          .foregroundStyle(VantaTheme.Palette.textSecondary)
        ForEach(result.detectedURLs, id: \.absoluteString) { u in
          HStack {
            Text(u.absoluteString).font(VantaTheme.Font.number).textSelection(.enabled).lineLimit(1)
              .truncationMode(.middle)
            Spacer()
            PillButton(icon: "safari", help: "Open link") { NSWorkspace.shared.open(u) }
            PillButton(icon: "doc.on.doc", help: "Copy link") {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(u.absoluteString, forType: .string)
            }
          }
          .padding(.horizontal, 10).padding(.vertical, 6)
          .vantaSurfaceCard(radius: VantaTheme.Radius.small)
        }
      }
    }
    .frame(minWidth: 500, minHeight: 360)
    .padding(18)
    .padding(.top, 16)
    .vantaWindowBackground()
    .foregroundStyle(VantaTheme.Palette.text)
    .preferredColorScheme(.dark)
    .environment(\.layoutDirection, .leftToRight)
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
        Text("Copied \(result.text.count) \(result.text.count == 1 ? "character" : "characters") to the clipboard").font(VantaTheme.Font.label)
        Text(result.text.replacingOccurrences(of: "\n", with: " ")).font(VantaTheme.Font.caption)
          .foregroundStyle(VantaTheme.Palette.textSecondary).lineLimit(1).truncationMode(.tail)
      }
      Spacer(minLength: 6)
      if !result.detectedURLs.isEmpty {
        VantaIconButton(
          title: "Links", icon: "link", shortcut: "\(result.detectedURLs.count)",
          compact: true, action: onOpen)
      }
      VantaIconButton(title: "Open Text", icon: "doc.text", role: .prominent, compact: true, action: onOpen)
      PillButton(icon: "xmark", help: "Close", action: onClose)
    }
    .padding(.horizontal, 14).padding(.vertical, 8)
    .frame(width: OCRFloatingBar.size.width, height: OCRFloatingBar.size.height)
    .vantaGlassCard(radius: OCRFloatingBar.size.height / 2, shadow: false)
    .foregroundStyle(VantaTheme.Palette.text)
    .preferredColorScheme(.dark)
    .environment(\.layoutDirection, .leftToRight)
    .onHover(perform: onHover)
  }
}
