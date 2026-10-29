import AppKit
import Combine
import SwiftUI
import VantaShotCore

// MARK: - Menu-bar launcher: NSStatusItem + glass NSPopover (left click) and a plain menu (right click)

@MainActor final class MenuBarLauncherController: NSObject, NSPopoverDelegate {
  static let shared = MenuBarLauncherController()
  static let popoverSize = NSSize(width: 384, height: 548)

  private var statusItem: NSStatusItem?
  private var popover: NSPopover?
  private var cancellables: [AnyCancellable] = []

  func install() {
    guard statusItem == nil else { return }
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.button?.image = NSImage(
      systemSymbolName: "camera.viewfinder", accessibilityDescription: "VantaShot")
    item.button?.target = self
    item.button?.action = #selector(statusItemClicked(_:))
    item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    item.button?.toolTip = "VantaShot — انقر للإطلاق، انقر بالزر الأيمن للقائمة"
    statusItem = item
    LiveScreenRecorderController.shared.$isRecording
      .receive(on: RunLoop.main)
      .sink { [weak self] recording in self?.updateIcon(recording: recording) }
      .store(in: &cancellables)
  }

  private func updateIcon(recording: Bool) {
    guard let button = statusItem?.button else { return }
    button.image = NSImage(
      systemSymbolName: recording ? "record.circle.fill" : "camera.viewfinder",
      accessibilityDescription: "VantaShot")
    button.contentTintColor = recording ? .systemRed : nil
  }

  @objc private func statusItemClicked(_ sender: Any?) {
    if NSApp.currentEvent?.type == .rightMouseUp {
      showContextMenu()
    } else {
      toggle()
    }
  }

  func toggle() {
    if let popover, popover.isShown {
      popover.performClose(nil)
    } else {
      show()
    }
  }

  func show() {
    guard let button = statusItem?.button else { return }
    let p = popover ?? makePopover()
    popover = p
    p.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    p.contentViewController?.view.window?.makeKey()
  }

  func close() { popover?.performClose(nil) }

  private func makePopover() -> NSPopover {
    let p = NSPopover()
    p.behavior = .transient
    p.animates = true
    p.appearance = NSAppearance(named: .vibrantDark)
    p.contentSize = Self.popoverSize
    p.delegate = self
    p.contentViewController = NSHostingController(
      rootView: LauncherPanelView(coordinator: CleanWorkflowCoordinator.shared, inPopover: true)
        .frame(width: Self.popoverSize.width, height: Self.popoverSize.height))
    return p
  }

  private func showContextMenu() {
    guard let item = statusItem else { return }
    let menu = NSMenu()
    menu.addItem(withTitle: "فتح اللوحة", action: #selector(openPanel), keyEquivalent: "")
    menu.addItem(withTitle: "الإعدادات…", action: #selector(openSettings), keyEquivalent: ",")
    menu.addItem(.separator())
    let cancel = menu.addItem(
      withTitle: "إلغاء العملية الحالية", action: #selector(cancelCurrent), keyEquivalent: "")
    cancel.isEnabled = CleanWorkflowCoordinator.shared.isBusy
    menu.addItem(.separator())
    menu.addItem(withTitle: "إنهاء VantaShot", action: #selector(quit), keyEquivalent: "q")
    for i in menu.items { i.target = self }
    item.menu = menu
    item.button?.performClick(nil)
    item.menu = nil
  }

  @objc private func openPanel() { show() }
  @objc private func openSettings() { SettingsWindowController.shared.show() }
  @objc private func cancelCurrent() { CleanWorkflowCoordinator.shared.cancelCurrent() }
  @objc private func quit() { NSApp.terminate(nil) }

  func popoverDidClose(_ notification: Notification) {}
}

// MARK: - Shared launcher content (popover + main window)

struct LauncherPanelView: View {
  @ObservedObject var coordinator: CleanWorkflowCoordinator
  @ObservedObject private var shortcuts = GlobalShortcutManager.shared
  @ObservedObject private var ocr = OCRResultsController.shared
  var inPopover: Bool

  private let tiles: [AppCommand] = [.area, .window, .fullscreen, .scrolling]
  private let secondTiles: [AppCommand] = [.ocr, .recordToggle, .selfTimer, .previousArea]
  private let rows: [AppCommand] = [.annotate, .clipboard, .history, .restore, .hideIcons]

  var body: some View {
    VStack(spacing: 14) {
      header
      primaryButton
      tileRow(tiles)
      tileRow(secondTiles)
      recentStrip
      secondaryRows
      Spacer(minLength: 0)
      footer
    }
    .padding(16)
    .foregroundStyle(VantaTheme.Palette.text)
    .background(inPopover ? Color.clear : Color(red: 0.06, green: 0.075, blue: 0.12))
    .environment(\.layoutDirection, .rightToLeft)
    .onReceive(
      NotificationCenter.default.publisher(
        for: NSTextInputContext.keyboardSelectionDidChangeNotification)
    ) { _ in shortcuts.objectWillChange.send() }
  }

  private var header: some View {
    HStack(spacing: 10) {
      Image(systemName: "camera.viewfinder")
        .font(.system(size: 22, weight: .semibold))
        .foregroundStyle(VantaTheme.Palette.accent)
      VStack(alignment: .leading, spacing: 1) {
        Text("VantaShot").font(VantaTheme.Font.title)
        Text("التقط، عدّل، واحفظ").font(VantaTheme.Font.caption)
          .foregroundStyle(VantaTheme.Palette.textSecondary)
      }
      Spacer()
      if coordinator.isBusy {
        Button {
          coordinator.cancelCurrent()
        } label: {
          HStack(spacing: 4) {
            Image(systemName: "xmark.circle.fill")
            Text("إلغاء").font(VantaTheme.Font.label)
          }
          .foregroundStyle(VantaTheme.Palette.danger)
        }.buttonStyle(.plain).help("إلغاء العملية الحالية (Esc)")
      } else {
        HStack(spacing: 5) {
          Circle().fill(VantaTheme.Palette.success).frame(width: 7, height: 7)
          Text("جاهز").font(VantaTheme.Font.caption)
            .foregroundStyle(VantaTheme.Palette.textSecondary)
        }
      }
    }
  }

  private var primaryButton: some View {
    Button {
      MenuBarLauncherController.shared.close()
      CommandRouter.shared.perform(.allInOne)
    } label: {
      HStack {
        Image(systemName: "sparkles.rectangle.stack").font(.system(size: 16, weight: .semibold))
        Text("الكل في واحد").font(.system(size: 14, weight: .semibold))
        Spacer()
        Text(shortcuts.label(.allInOne)).font(VantaTheme.Font.number).opacity(0.75)
      }
      .foregroundStyle(VantaTheme.Palette.accentText)
      .padding(.horizontal, 14).padding(.vertical, 11)
      .background(
        RoundedRectangle(cornerRadius: VantaTheme.Radius.medium, style: .continuous)
          .fill(VantaTheme.Palette.accent))
    }
    .buttonStyle(.plain)
    .help("الكل في واحد — اختر الوضع من شريط التحديد")
  }

  private func tileRow(_ commands: [AppCommand]) -> some View {
    HStack(spacing: 8) {
      ForEach(commands) { c in
        VantaIconButton(
          title: shortTitle(c), icon: icon(c), shortcut: nil,
          role: c == .recordToggle && LiveScreenRecorderController.shared.isRecording
            ? .destructive : .neutral
        ) {
          MenuBarLauncherController.shared.close()
          CommandRouter.shared.perform(c)
        }
        .frame(maxWidth: .infinity)
      }
    }
  }

  private var recentStrip: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("آخر اللقطات").font(VantaTheme.Font.label)
          .foregroundStyle(VantaTheme.Palette.textSecondary)
        Spacer()
        if !coordinator.history.isEmpty {
          Button("السجل كاملًا") {
            MenuBarLauncherController.shared.close()
            CommandRouter.shared.perform(.history)
          }
          .buttonStyle(.plain).font(VantaTheme.Font.caption)
          .foregroundStyle(VantaTheme.Palette.accent)
        }
      }
      if coordinator.history.isEmpty {
        Text("لا توجد لقطات بعد — ابدأ بالتقاط منطقة")
          .font(VantaTheme.Font.caption).foregroundStyle(VantaTheme.Palette.textSecondary)
          .frame(maxWidth: .infinity, minHeight: 64)
          .background(
            RoundedRectangle(cornerRadius: VantaTheme.Radius.small, style: .continuous)
              .fill(VantaTheme.Palette.fillSubtle))
      } else {
        HStack(spacing: 8) {
          ForEach(coordinator.history.prefix(4)) { a in
            RecentThumbnail(asset: a) {
              MenuBarLauncherController.shared.close()
              QuickAccessPopupController.shared.present(asset: a)
            }
          }
          Spacer(minLength: 0)
        }
      }
    }
  }

  private var secondaryRows: some View {
    VStack(spacing: 3) {
      ForEach(rows) { c in
        Button {
          MenuBarLauncherController.shared.close()
          CommandRouter.shared.perform(c)
        } label: {
          HStack(spacing: 10) {
            Image(systemName: icon(c)).frame(width: 18)
              .foregroundStyle(VantaTheme.Palette.accent)
            Text(c.title).font(VantaTheme.Font.body)
            Spacer()
            Text(c == .history ? "\u{2066}\(coordinator.history.count)\u{2069}" : shortcuts.label(c))
              .font(VantaTheme.Font.number).foregroundStyle(VantaTheme.Palette.textSecondary)
          }
          .padding(.horizontal, 10).padding(.vertical, 6)
          .contentShape(Rectangle())
        }
        .buttonStyle(LauncherRowStyle())
      }
    }
  }

  private var footer: some View {
    HStack(spacing: 8) {
      Button {
        ScreenCaptureService.requestPermissionAndOpenSettings()
      } label: {
        HStack(spacing: 5) {
          Circle()
            .fill(
              ScreenCaptureService.hasScreenPermission
                ? VantaTheme.Palette.success : VantaTheme.Palette.warning
            )
            .frame(width: 7, height: 7)
          Text(ScreenCaptureService.hasScreenPermission ? "إذن الشاشة مفعّل" : "تفعيل إذن الشاشة")
            .font(VantaTheme.Font.caption)
        }
        .foregroundStyle(VantaTheme.Palette.textSecondary)
      }.buttonStyle(.plain)
      if ocr.result != nil {
        Button("نتيجة OCR") {
          MenuBarLauncherController.shared.close()
          ocr.show()
        }
        .buttonStyle(.plain).font(VantaTheme.Font.caption)
        .foregroundStyle(VantaTheme.Palette.accent)
      }
      Spacer()
      Button {
        MenuBarLauncherController.shared.close()
        SettingsWindowController.shared.show()
      } label: {
        Image(systemName: "gearshape").font(.system(size: 13, weight: .semibold))
      }.buttonStyle(.plain).help("الإعدادات والاختصارات ⌘,")
      if inPopover {
        Button {
          NSApp.terminate(nil)
        } label: {
          Image(systemName: "power").font(.system(size: 13, weight: .semibold))
        }.buttonStyle(.plain).help("إنهاء VantaShot")
      }
    }
    .foregroundStyle(VantaTheme.Palette.textSecondary)
  }

  private func shortTitle(_ c: AppCommand) -> String {
    switch c {
    case .area: return "منطقة"
    case .window: return "نافذة"
    case .fullscreen: return "الشاشة"
    case .scrolling: return "تمرير"
    case .ocr: return "نص"
    case .recordToggle: return LiveScreenRecorderController.shared.isRecording ? "إيقاف" : "تسجيل"
    case .selfTimer: return "مؤقت"
    case .previousArea: return "السابقة"
    default: return c.title
    }
  }

  func icon(_ c: AppCommand) -> String {
    switch c {
    case .area: return "viewfinder"
    case .previousArea: return "arrow.uturn.backward.square"
    case .fullscreen: return "rectangle.inset.filled"
    case .window: return "macwindow"
    case .selfTimer: return "timer"
    case .scrolling: return "arrow.up.and.down.text.horizontal"
    case .ocr: return "text.viewfinder"
    case .recordToggle: return "record.circle"
    case .annotate: return "pencil.and.outline"
    case .clipboard: return "doc.on.clipboard"
    case .history: return "clock"
    case .restore: return "clock.arrow.circlepath"
    case .hideIcons: return "eye.slash"
    default: return "camera.viewfinder"
    }
  }
}

struct LauncherRowStyle: ButtonStyle {
  @State private var hovering = false
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(
        RoundedRectangle(cornerRadius: VantaTheme.Radius.small, style: .continuous)
          .fill(
            configuration.isPressed
              ? VantaTheme.Palette.fillHover
              : hovering ? VantaTheme.Palette.fillHover : VantaTheme.Palette.fillSubtle)
      )
      .onHover { hovering = $0 }
      .animation(VantaTheme.Motion.fade, value: hovering)
  }
}

struct RecentThumbnail: View {
  let asset: MediaAsset
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      ZStack(alignment: .bottomLeading) {
        Color.black.opacity(0.3)
          .frame(width: 78, height: 58)
          .overlay {
            if let i = AssetFiles.preview(asset) {
              Image(nsImage: i).resizable().aspectRatio(contentMode: .fill)
            } else {
              Image(systemName: asset.kind.icon).font(.system(size: 18))
                .foregroundStyle(VantaTheme.Palette.textSecondary)
            }
          }
          .clipped()
        if asset.kind != .stillImage {
          Text(asset.kind.friendlyName).font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Capsule().fill(Color.black.opacity(0.6)))
            .padding(4)
        }
      }
      .frame(width: 78, height: 58)
      .clipShape(RoundedRectangle(cornerRadius: VantaTheme.Radius.small, style: .continuous))
      .contentShape(RoundedRectangle(cornerRadius: VantaTheme.Radius.small, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: VantaTheme.Radius.small, style: .continuous)
          .strokeBorder(hovering ? VantaTheme.Palette.accent : VantaTheme.Palette.stroke, lineWidth: 1)
      )
      .scaleEffect(hovering ? 1.04 : 1)
      .animation(VantaTheme.Motion.fade, value: hovering)
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .help(asset.title)
  }
}
