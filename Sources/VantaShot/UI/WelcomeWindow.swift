import AppKit
import SwiftUI
import VantaShotCore

// MARK: - First-run welcome: three steps (screen permission, shortcuts, save folder). Shown once.

@MainActor final class WelcomeWindowController {
  static let shared = WelcomeWindowController()
  private var window: NSWindow?

  func showIfNeeded() {
    guard !AppSettings.shared.hasSeenWelcome else { return }
    show()
  }

  func show() {
    if window == nil {
      let w = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 560, height: 500),
        styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
      w.isReleasedWhenClosed = false
      w.titlebarAppearsTransparent = true
      w.titleVisibility = .hidden
      w.isMovableByWindowBackground = true
      w.backgroundColor = NSColor(red: 0.06, green: 0.075, blue: 0.12, alpha: 1)
      w.contentView = NSHostingView(
        rootView: WelcomeView { [weak self] in
          AppSettings.shared.hasSeenWelcome = true
          self?.window?.orderOut(nil)
        })
      w.center()
      window = w
    }
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
}

struct WelcomeView: View {
  let onFinish: () -> Void
  @ObservedObject private var settings = AppSettings.shared
  @ObservedObject private var shortcuts = GlobalShortcutManager.shared
  @State private var step = 0
  @State private var hasPermission = ScreenCaptureService.hasScreenPermission
  private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

  var body: some View {
    VStack(spacing: 18) {
      HStack(spacing: 10) {
        Image(systemName: "camera.viewfinder").font(.system(size: 26, weight: .semibold))
          .foregroundStyle(VantaTheme.Palette.accent)
        VStack(alignment: .leading, spacing: 2) {
          Text("مرحبًا بك في VantaShot").font(.system(size: 20, weight: .bold))
          Text("ثلاث خطوات قصيرة ثم تبدأ الالتقاط").font(VantaTheme.Font.body)
            .foregroundStyle(VantaTheme.Palette.textSecondary)
        }
        Spacer()
      }
      stepIndicator
      Group {
        switch step {
        case 0: permissionStep
        case 1: shortcutsStep
        default: folderStep
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .padding(18)
      .vantaGlassCard(radius: VantaTheme.Radius.large, shadow: false)
      .id(step)
      .transition(.opacity.combined(with: .move(edge: .leading)))
      HStack {
        Button("تخطّي") { onFinish() }.buttonStyle(.plain)
          .foregroundStyle(VantaTheme.Palette.textSecondary)
        Spacer()
        if step > 0 {
          VantaIconButton(title: "السابق", icon: "chevron.backward", compact: true) {
            withAnimation(VantaTheme.Motion.spring) { step -= 1 }
          }
        }
        VantaIconButton(
          title: step == 2 ? "ابدأ الاستخدام" : "التالي",
          icon: step == 2 ? "checkmark" : "chevron.forward", role: .prominent, compact: true
        ) {
          if step == 2 { onFinish() } else { withAnimation(VantaTheme.Motion.spring) { step += 1 } }
        }
      }
    }
    .padding(26)
    .padding(.top, 10)
    .foregroundStyle(VantaTheme.Palette.text)
    .frame(width: 560, height: 500)
    .background(Color(red: 0.06, green: 0.075, blue: 0.12))
    .preferredColorScheme(.dark)
    .environment(\.layoutDirection, .rightToLeft)
    .onReceive(timer) { _ in hasPermission = ScreenCaptureService.hasScreenPermission }
  }

  private var stepIndicator: some View {
    HStack(spacing: 8) {
      ForEach(0..<3) { i in
        Capsule()
          .fill(i <= step ? VantaTheme.Palette.accent : VantaTheme.Palette.fillHover)
          .frame(height: 4)
          .animation(VantaTheme.Motion.fade, value: step)
      }
    }
  }

  private var permissionStep: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("إذن تسجيل الشاشة", systemImage: "lock.shield").font(VantaTheme.Font.title)
      Text("يحتاج VantaShot إذن «تسجيل الشاشة» ليلتقط ويسجّل. يُطلب الإذن مرة واحدة من إعدادات النظام.")
        .font(VantaTheme.Font.body).foregroundStyle(VantaTheme.Palette.textSecondary)
      HStack(spacing: 8) {
        Circle().fill(hasPermission ? VantaTheme.Palette.success : VantaTheme.Palette.warning)
          .frame(width: 8, height: 8)
        Text(hasPermission ? "الإذن مفعّل" : "الإذن غير مفعّل بعد").font(VantaTheme.Font.label)
      }
      if !hasPermission {
        VantaIconButton(title: "فتح إعدادات النظام", icon: "gear", role: .prominent, compact: true) {
          ScreenCaptureService.requestPermissionAndOpenSettings()
        }
      }
    }
  }

  private var shortcutsStep: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("الاختصارات العامة", systemImage: "keyboard").font(VantaTheme.Font.title)
      Text("تعمل من أي تطبيق. يمكنك تغييرها لاحقًا من الإعدادات.")
        .font(VantaTheme.Font.body).foregroundStyle(VantaTheme.Palette.textSecondary)
      ForEach([AppCommand.allInOne, .area, .window, .fullscreen, .recordToggle, .ocr]) { c in
        HStack {
          Text(c.title).font(VantaTheme.Font.body)
          Spacer()
          Text(shortcuts.label(c)).font(VantaTheme.Font.number)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(VantaTheme.Palette.fillSubtle))
        }
      }
      Button("تعديل الاختصارات…") { SettingsWindowController.shared.show() }
        .buttonStyle(.plain).font(VantaTheme.Font.label).foregroundStyle(VantaTheme.Palette.accent)
    }
  }

  private var folderStep: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("مجلد الحفظ", systemImage: "folder").font(VantaTheme.Font.title)
      Text("تُحفظ اللقطات والتسجيلات هنا عند الضغط على «حفظ».")
        .font(VantaTheme.Font.body).foregroundStyle(VantaTheme.Palette.textSecondary)
      Text(settings.outputPath).font(VantaTheme.Font.number).lineLimit(2)
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(
          RoundedRectangle(cornerRadius: VantaTheme.Radius.small, style: .continuous)
            .fill(VantaTheme.Palette.fillSubtle))
      VantaIconButton(title: "اختيار مجلد آخر", icon: "folder.badge.plus", compact: true) {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        if p.runModal() == .OK, let u = p.url { settings.outputPath = u.path }
      }
      Picker("صيغة الصور", selection: $settings.imageFormat) {
        Text("PNG").tag("png")
        Text("JPEG").tag("jpg")
      }.pickerStyle(.segmented).frame(width: 200)
    }
  }
}
