import AppKit
import SwiftUI
import VantaShotCore

@MainActor public final class VantaAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  private var keyMonitor: Any?
  public func applicationDidFinishLaunching(_ notification: Notification) {
    GlobalShortcutManager.shared.start()
    AssetFiles.cleanupTemporary()
    MenuBarLauncherController.shared.install()
    NSApp.activate(ignoringOtherApps: true)
    WelcomeWindowController.shared.showIfNeeded()
    // Automation hook used by the UI verification scripts: `VantaShot --open-launcher`.
    if CommandLine.arguments.contains("--open-launcher") {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        MenuBarLauncherController.shared.show()
      }
    }
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
      if e.keyCode == 53, CleanWorkflowCoordinator.shared.isBusy {
        CleanWorkflowCoordinator.shared.cancelCurrent()
        return nil
      }
      return e
    }
  }
  public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool)
    -> Bool
  {
    CleanWorkflowCoordinator.shared.showLauncherWindow()
    return true
  }
  public func applicationDidBecomeActive(_ notification: Notification) {
    if !CleanWorkflowCoordinator.shared.isBusy,
      NSApp.windows.allSatisfy({ !$0.isVisible || $0 is NSPanel })
    {
      CleanWorkflowCoordinator.shared.showLauncherWindow()
    }
  }
  public func windowShouldClose(_ sender: NSWindow) -> Bool {
    sender.orderOut(nil)
    return false
  }
  public func applicationWillTerminate(_ notification: Notification) {
    GlobalShortcutManager.shared.stop()
    DesktopIconsCoverManager.shared.showIcons()
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
  }
}
@main struct VantaShotApp: App {
  @NSApplicationDelegateAdaptor(VantaAppDelegate.self) private var delegate
  @StateObject private var coordinator = CleanWorkflowCoordinator.shared
  init() { NSApplication.shared.setActivationPolicy(.regular) }
  var body: some Scene {
    WindowGroup("VantaShot") {
      LauncherPanelView(coordinator: coordinator, inPopover: false).frame(
        width: MenuBarLauncherController.popoverSize.width,
        height: MenuBarLauncherController.popoverSize.height
      ).background(
        WindowAccessor { w in
          guard let w else { return }
          coordinator.mainLauncherWindow = w
          w.delegate = delegate
          w.isReleasedWhenClosed = false
          w.isRestorable = false
          w.titlebarAppearsTransparent = true
        }
      ).preferredColorScheme(.dark)
    }.windowResizability(.contentSize).commands {
      CommandGroup(replacing: .appSettings) {
        Button("الإعدادات…") { SettingsWindowController.shared.show() }.keyboardShortcut(
          ",", modifiers: .command)
      }
    }
    Settings { AppSettingsView() }
  }
}
struct WindowAccessor: NSViewRepresentable {
  let callback: (NSWindow?) -> Void
  func makeNSView(context: Context) -> NSView {
    let v = NSView()
    DispatchQueue.main.async { callback(v.window) }
    return v
  }
  func updateNSView(_ view: NSView, context: Context) {
    DispatchQueue.main.async { callback(view.window) }
  }
}
