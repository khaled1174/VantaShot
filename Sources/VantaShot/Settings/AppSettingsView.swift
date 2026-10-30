import AppKit
import Combine
import ServiceManagement
import SwiftUI
import Vision

@MainActor final class AppSettings: ObservableObject {
  static let shared = AppSettings()
  @AppStorage("outputDirectory") var outputPath = FileManager.default.urls(
    for: .desktopDirectory, in: .userDomainMask
  ).first!.path
  @AppStorage("imageFormat") var imageFormat = "png"
  @AppStorage("jpegQuality") var jpegQuality = 0.9
  @AppStorage("recordFormat") var recordFormat = "mp4"
  @AppStorage("systemAudio") var systemAudio = false
  @AppStorage("microphone") var microphone = false
  @AppStorage("captureCursor") var captureCursor = true
  @AppStorage("timerSeconds") var timerSeconds = 5
  @AppStorage("historyLimit") var historyLimit = 100
  @AppStorage("ocrLanguages") var ocrLanguages = "ar-SA,en-US"
  @AppStorage("recordCountdownSeconds") var recordCountdownSeconds = 3
  @AppStorage("highlightCursor") var highlightCursor = false
  @AppStorage("showKeystrokes") var showKeystrokes = false
  @AppStorage("hasSeenWelcome") var hasSeenWelcome = false
  @AppStorage("hideDockIcon") var hideDockIcon = false
  var outputDirectory: URL { URL(fileURLWithPath: outputPath, isDirectory: true) }

  var launchAtLogin: Bool {
    get { SMAppService.mainApp.status == .enabled }
    set {
      do {
        if newValue {
          try SMAppService.mainApp.register()
        } else {
          try SMAppService.mainApp.unregister()
        }
        objectWillChange.send()
      } catch {
        AssetFiles.showError(error)
      }
    }
  }

  func applyActivationPolicy() {
    NSApplication.shared.setActivationPolicy(hideDockIcon ? .accessory : .regular)
    if hideDockIcon {
      CleanWorkflowCoordinator.shared.mainLauncherWindow?.orderOut(nil)
    }
  }
}
@MainActor final class SettingsWindowController {
  static let shared = SettingsWindowController()
  private var window: NSWindow?
  func show() {
    if window == nil {
      let w = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 660, height: 650),
        styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered,
        defer: false)
      w.isReleasedWhenClosed = false
      w.title = "VantaShot Settings"
      VantaWindowGlass.configure(w)
      w.contentView = NSHostingView(rootView: AppSettingsView())
      w.center()
      window = w
    }
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
}
struct AppSettingsView: View {
  @ObservedObject private var settings = AppSettings.shared
  var body: some View {
    TabView {
      Form {
        Section("App and System") {
          Toggle(
            "Launch at login",
            isOn: Binding(
              get: { settings.launchAtLogin },
              set: { settings.launchAtLogin = $0 }
            ))
          Toggle("Hide the Dock icon (menu bar only)", isOn: $settings.hideDockIcon)
            .onChange(of: settings.hideDockIcon) { _ in settings.applyActivationPolicy() }
        }
        Section("Saving and Capture") {
          HStack {
            Text(settings.outputPath).lineLimit(2)
            Button("Choose Folder…") {
              let p = NSOpenPanel()
              p.canChooseDirectories = true
              p.canChooseFiles = false
              if p.runModal() == .OK, let u = p.url { settings.outputPath = u.path }
            }
          }
          Picker("Image format", selection: $settings.imageFormat) {
            Text("PNG — full quality").tag("png")
            Text("JPEG").tag("jpg")
          }
          Slider(value: $settings.jpegQuality, in: 0.1...1) { Text("JPEG quality") }.disabled(
            settings.imageFormat != "jpg")
          Toggle("Show the pointer in recordings", isOn: $settings.captureCursor)
          Stepper(
            "Timer: \(settings.timerSeconds) \(settings.timerSeconds == 1 ? "second" : "seconds")", value: $settings.timerSeconds, in: 1...30)
          Stepper(
            "Keep the last \(settings.historyLimit) items", value: $settings.historyLimit,
            in: 10...1000, step: 10)
        }
        Section("Recording") {
          Picker("Format", selection: $settings.recordFormat) {
            Text("MP4 video").tag("mp4")
            Text("Animated GIF (no audio)").tag("gif")
          }
          Toggle("System audio", isOn: $settings.systemAudio).disabled(settings.recordFormat == "gif")
          Toggle("Microphone", isOn: $settings.microphone).disabled(settings.recordFormat == "gif")
          Text("Microphone permission is requested when a recording uses it.").font(.caption)
          Stepper(
            settings.recordCountdownSeconds == 0
              ? "Start recording immediately"
              : "Countdown before recording: \(settings.recordCountdownSeconds) \(settings.recordCountdownSeconds == 1 ? "second" : "seconds")",
            value: $settings.recordCountdownSeconds, in: 0...10)
          Toggle("Highlight the pointer and show click rings while recording", isOn: $settings.highlightCursor)
          Toggle("Show keystrokes while recording", isOn: $settings.showKeystrokes)
            .onChange(of: settings.showKeystrokes) { enabled in
              if enabled { _ = RecordingDecorations.keystrokeMonitoringAllowed(prompt: true) }
            }
          Text("Keystrokes need Input Monitoring permission in System Settings. Nothing is shown without it.")
            .font(.caption).foregroundStyle(.secondary)
        }
        Section("Text recognition languages") {
          TextField("Language codes, separated by commas", text: $settings.ocrLanguages)
          Text(
            (try? VNRecognizeTextRequest().supportedRecognitionLanguages().joined(separator: ", "))
              ?? "Checked when text is extracted"
          ).font(.caption).foregroundStyle(.secondary)
        }
      }.formStyle(.grouped).scrollContentBackground(.hidden).tabItem {
        Label("General", systemImage: "gear")
      }
      ShortcutsSettingsView().tabItem { Label("Shortcuts", systemImage: "keyboard") }
      PermissionsAndAboutView().tabItem { Label("Permissions and About", systemImage: "checkmark.shield") }
    }
    .padding(.top, 16)
    .frame(minWidth: 620, minHeight: 570)
    .vantaWindowBackground()
    .preferredColorScheme(.dark)
    .environment(\.layoutDirection, .leftToRight)
  }
}

struct PermissionsAndAboutView: View {
  @State private var screenGranted = ScreenCaptureService.hasScreenPermission
  @State private var micGranted = ScreenCaptureService.hasMicrophonePermission
  @State private var accessibilityGranted = ScreenCaptureService.hasAccessibilityPermission
  @State private var inputMonitoringGranted = ScreenCaptureService.hasInputMonitoringPermission
  private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

  private var versionText: String {
    let version =
      Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.3.1"
    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "7"
    return "Version \(version) (\(build))"
  }

  var body: some View {
    Form {
      Section("System Permissions") {
        permissionRow(
          title: "Screen Recording",
          subtitle: "Required to capture areas and windows and to record video",
          granted: screenGranted,
          action: ScreenCaptureService.requestPermissionAndOpenSettings
        )
        permissionRow(
          title: "Microphone",
          subtitle: "To record voiceover with video",
          granted: micGranted,
          action: ScreenCaptureService.requestMicrophonePermissionAndOpenSettings
        )
        permissionRow(
          title: "Accessibility",
          subtitle: "To scroll pages automatically during a scrolling capture",
          granted: accessibilityGranted,
          action: ScreenCaptureService.requestAccessibilityPermissionAndOpenSettings
        )
        permissionRow(
          title: "Input Monitoring",
          subtitle: "To show keystrokes in video recordings",
          granted: inputMonitoringGranted,
          action: ScreenCaptureService.requestInputMonitoringPermissionAndOpenSettings
        )
      }
      Section("About VantaShot") {
        HStack {
          VStack(alignment: .leading, spacing: 4) {
            Text("VantaShot").font(.headline)
            Text(versionText).font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          Button("Open Welcome Screen") { WelcomeWindowController.shared.show() }
        }
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .onReceive(timer) { _ in refreshPermissions() }
    .onReceive(NotificationCenter.default.publisher(for: ScreenCaptureService.didChangeNotification))
    { _ in refreshPermissions() }
  }

  private func refreshPermissions() {
    screenGranted = ScreenCaptureService.hasScreenPermission
    micGranted = ScreenCaptureService.hasMicrophonePermission
    accessibilityGranted = ScreenCaptureService.hasAccessibilityPermission
    inputMonitoringGranted = ScreenCaptureService.hasInputMonitoringPermission
  }

  private func permissionRow(
    title: String, subtitle: String, granted: Bool,
    action: @escaping () -> Void
  ) -> some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Circle()
            .fill(granted ? Color.green : Color.orange)
            .frame(width: 8, height: 8)
          Text(title).font(.body.weight(.medium))
          Text(granted ? "On" : "Off")
            .font(.caption)
            .foregroundStyle(granted ? .green : .orange)
        }
        Text(subtitle).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      if !granted {
        Button("Turn On…", action: action)
      }
    }
  }
}
