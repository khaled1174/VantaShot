import AppKit
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
  @AppStorage("quickAccessAutoDismissSeconds") var quickAccessAutoDismissSeconds = 8
  @AppStorage("recordCountdownSeconds") var recordCountdownSeconds = 3
  @AppStorage("highlightCursor") var highlightCursor = false
  @AppStorage("showKeystrokes") var showKeystrokes = false
  @AppStorage("hasSeenWelcome") var hasSeenWelcome = false
  var outputDirectory: URL { URL(fileURLWithPath: outputPath, isDirectory: true) }
}
@MainActor final class SettingsWindowController {
  static let shared = SettingsWindowController()
  private var window: NSWindow?
  func show() {
    if window == nil {
      let w = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 660, height: 650),
        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
      w.isReleasedWhenClosed = false
      w.title = "إعدادات VantaShot"
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
        Section("الحفظ والالتقاط") {
          HStack {
            Text(settings.outputPath).lineLimit(2)
            Button("اختيار المجلد…") {
              let p = NSOpenPanel()
              p.canChooseDirectories = true
              p.canChooseFiles = false
              if p.runModal() == .OK, let u = p.url { settings.outputPath = u.path }
            }
          }
          Picker("صيغة حفظ الصور", selection: $settings.imageFormat) {
            Text("PNG — جودة كاملة").tag("png")
            Text("JPEG").tag("jpg")
          }
          Slider(value: $settings.jpegQuality, in: 0.1...1) { Text("جودة JPEG") }.disabled(
            settings.imageFormat != "jpg")
          Toggle("إظهار المؤشر في التسجيل", isOn: $settings.captureCursor)
          Stepper(
            "المؤقت: \(settings.timerSeconds) ثوانٍ", value: $settings.timerSeconds, in: 1...30)
          Stepper(
            "الاحتفاظ بآخر \(settings.historyLimit) عنصر", value: $settings.historyLimit,
            in: 10...1000, step: 10)
          Stepper(
            settings.quickAccessAutoDismissSeconds == 0
              ? "بطاقة اللقطة تبقى حتى تُغلق يدويًا"
              : "إخفاء بطاقة اللقطة تلقائيًا بعد \(settings.quickAccessAutoDismissSeconds) ثوانٍ",
            value: $settings.quickAccessAutoDismissSeconds, in: 0...60)
        }
        Section("التسجيل") {
          Picker("الصيغة", selection: $settings.recordFormat) {
            Text("MP4 فيديو").tag("mp4")
            Text("GIF متحرك (بدون صوت)").tag("gif")
          }
          Toggle("صوت النظام", isOn: $settings.systemAudio).disabled(settings.recordFormat == "gif")
          Toggle("الميكروفون", isOn: $settings.microphone).disabled(settings.recordFormat == "gif")
          Text("طلب إذن الميكروفون يتم عند بدء تسجيل يستخدمه.").font(.caption)
          Stepper(
            settings.recordCountdownSeconds == 0
              ? "بدء التسجيل فورًا بلا عدّاد"
              : "عدّاد تنازلي قبل التسجيل: \(settings.recordCountdownSeconds) ثوانٍ",
            value: $settings.recordCountdownSeconds, in: 0...10)
          Toggle("هالة حول المؤشر ودوائر النقر أثناء التسجيل", isOn: $settings.highlightCursor)
          Toggle("إظهار ضغطات المفاتيح أثناء التسجيل", isOn: $settings.showKeystrokes)
          Text("ضغطات المفاتيح تحتاج إذن «مراقبة الإدخال» من إعدادات النظام؛ بدونه لا يظهر شيء.")
            .font(.caption).foregroundStyle(.secondary)
        }
        Section("لغات استخراج النص") {
          TextField("رموز اللغات مفصولة بفاصلة", text: $settings.ocrLanguages)
          Text(
            (try? VNRecognizeTextRequest().supportedRecognitionLanguages().joined(separator: ", "))
              ?? "سيتم التحقق عند الاستخراج"
          ).font(.caption).foregroundStyle(.secondary)
        }
      }.formStyle(.grouped).tabItem { Label("عام", systemImage: "gear") }
      ShortcutsSettingsView().tabItem { Label("الاختصارات", systemImage: "keyboard") }
      VStack(spacing: 14) {
        Text("شاشة الترحيب").font(.headline)
        Text("تظهر مرة واحدة عند أول تشغيل. يمكنك إعادة فتحها هنا.").font(.caption)
          .foregroundStyle(.secondary)
        Button("فتح شاشة الترحيب") { WelcomeWindowController.shared.show() }
      }.padding(30).tabItem { Label("مساعدة", systemImage: "questionmark.circle") }
    }.frame(minWidth: 620, minHeight: 570).environment(\.layoutDirection, .rightToLeft)
  }
}
