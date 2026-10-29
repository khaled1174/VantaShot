import AppKit
import Carbon
import SwiftUI
import VantaShotCore
import os

@MainActor
final class GlobalShortcutManager: ObservableObject {
  static let shared = GlobalShortcutManager()
  @Published private(set) var configuration: ShortcutConfiguration
  @Published private(set) var errors: [AppCommand: String] = [:]
  @Published private(set) var suspended = false
  private var refs: [AppCommand: EventHotKeyRef] = [:]
  private var registered: [AppCommand: ShortcutBinding] = [:]
  private var handler: EventHandlerRef?
  private var held: Set<UInt32> = []
  private let store: ShortcutStore
  private let dispatchCommand: @MainActor (AppCommand) -> Void
  private let logger = Logger(subsystem: "dev.vantashot.macos", category: "Shortcuts")
  private let signature: OSType = 0x564E_5441
  init(
    store: ShortcutStore = ShortcutStore(defaults: UserDefaults.standard),
    dispatch: @escaping @MainActor (AppCommand) -> Void = { CommandRouter.shared.perform($0) }
  ) {
    self.store = store
    dispatchCommand = dispatch
    configuration = store.load()
  }
  func start() {
    guard handler == nil else { return }
    var events = [
      EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
      EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
    ]
    let installStatus = InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, user in
        guard let event, let user else { return OSStatus(eventNotHandledErr) }
        var key = EventHotKeyID()
        let status = GetEventParameter(
          event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
          MemoryLayout<EventHotKeyID>.size, nil, &key)
        guard status == noErr else { return status }
        MainActor.assumeIsolated {
          let manager = Unmanaged<GlobalShortcutManager>.fromOpaque(user).takeUnretainedValue()
          manager.receive(key.id, pressed: GetEventKind(event) == UInt32(kEventHotKeyPressed))
        }
        return noErr
      }, events.count, &events, Unmanaged.passUnretained(self).toOpaque(), &handler)
    logger.info("Carbon handler status: \(installStatus)")
    if installStatus != noErr {
      errors[.showLauncher] = "تعذر تشغيل محرك الاختصارات (\(installStatus))"
      return
    }
    apply(configuration.bindings)
  }
  private func receive(_ id: UInt32, pressed: Bool) {
    logger.info("Hotkey received id=\(id) pressed=\(pressed)")
    guard id > 0, id <= AppCommand.allCases.count else { return }
    if !pressed {
      held.remove(id)
      return
    }
    guard !suspended, held.insert(id).inserted else { return }
    dispatchCommand(AppCommand.allCases[Int(id) - 1])
  }
  func stop() {
    unregisterAll()
    if let handler { RemoveEventHandler(handler) }
    handler = nil
  }
  func unregisterAll() {
    for ref in refs.values { UnregisterEventHotKey(ref) }
    refs = [:]
    registered = [:]
    held = []
  }
  func suspend() {
    suspended = true
    unregisterAll()
  }
  func resume() {
    guard suspended else { return }
    suspended = false
    apply(configuration.bindings)
  }
  @discardableResult func apply(_ bindings: [ShortcutBinding]) -> [AppCommand: String] {
    let conflicts = ShortcutValidation.conflicts(bindings)
    var problems: [AppCommand: String] = [:]
    let system = systemBindings()
    for command in AppCommand.allCases {
      guard let b = bindings.first(where: { $0.command == command }), b.isEnabled else {
        if let r = refs.removeValue(forKey: command) { UnregisterEventHotKey(r) }
        registered[command] = nil
        continue
      }
      if let conflict = conflicts[command] {
        problems[command] =
          conflict == .duplicate ? "التركيبة مستخدمة لأمر آخر" : "اختصار غير صالح أو محجوز للنظام"
        continue
      }
      if system.contains("\(b.keyCode):\(carbon(b.modifiers))") {
        problems[command] = "التركيبة مستخدمة في إعدادات النظام"
        continue
      }
      if registered[command] == b { continue }
      let old = registered[command]
      if let r = refs.removeValue(forKey: command) { UnregisterEventHotKey(r) }
      registered[command] = nil
      let result = register(b)
      if result != noErr {
        problems[command] = "تعذر تسجيل الاختصار (\(result)). بقي الاختصار السابق."
        if let old { _ = register(old) }
      }
    }
    errors = problems
    return problems
  }
  private func register(_ b: ShortcutBinding) -> OSStatus {
    var ref: EventHotKeyRef?
    let id = UInt32(AppCommand.allCases.firstIndex(of: b.command)! + 1)
    let status = RegisterEventHotKey(
      b.keyCode, carbon(b.modifiers), EventHotKeyID(signature: signature, id: id),
      GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref)
    if status == noErr, let ref {
      refs[b.command] = ref
      registered[b.command] = b
    }
    logger.info("Registration \(b.command.rawValue, privacy:.public) status=\(status)")
    return status
  }
  func update(_ binding: ShortcutBinding) {
    var c = configuration
    c.bindings.removeAll { $0.command == binding.command }
    c.bindings.append(binding)
    let problems = apply(c.bindings)
    guard problems[binding.command] == nil else { return }
    do {
      try store.save(c)
      configuration = c
    } catch {
      apply(configuration.bindings)
      errors[binding.command] = error.localizedDescription
    }
  }
  func clear(_ command: AppCommand) {
    var b =
      configuration.bindings.first { $0.command == command }
      ?? ShortcutBinding(command: command, keyCode: 0, isEnabled: false)
    b.isEnabled = false
    update(b)
  }
  func reset() {
    let c = ShortcutConfiguration()
    let problems = apply(c.bindings)
    if problems.isEmpty {
      do {
        try store.save(c)
        configuration = c
      } catch { errors[.showLauncher] = error.localizedDescription }
    } else {
      apply(configuration.bindings)
      errors = problems
    }
  }
  func label(_ command: AppCommand) -> String {
    guard let b = configuration.bindings.first(where: { $0.command == command }), b.isEnabled else {
      return "—"
    }
    return Self.display(b)
  }
  private func carbon(_ m: ShortcutModifiers) -> UInt32 {
    var r: UInt32 = 0
    if m.contains(.command) { r |= UInt32(cmdKey) }
    if m.contains(.option) { r |= UInt32(optionKey) }
    if m.contains(.control) { r |= UInt32(controlKey) }
    if m.contains(.shift) { r |= UInt32(shiftKey) }
    return r
  }
  private func systemBindings() -> Set<String> {
    var list: Unmanaged<CFArray>?
    guard CopySymbolicHotKeys(&list) == noErr,
      let array = list?.takeRetainedValue() as? [[String: Any]]
    else { return [] }
    return Set(
      array.compactMap { row in
        guard row[kHISymbolicHotKeyEnabled as String] as? Bool == true,
          let code = row[kHISymbolicHotKeyCode as String] as? UInt32,
          let mods = row[kHISymbolicHotKeyModifiers as String] as? UInt32
        else { return nil }
        return "\(code):\(mods)"
      })
  }
  static func display(_ b: ShortcutBinding) -> String {
    var label = ""
    if b.modifiers.contains(.control) { label += "⌃" }
    if b.modifiers.contains(.option) { label += "⌥" }
    if b.modifiers.contains(.shift) { label += "⇧" }
    if b.modifiers.contains(.command) { label += "⌘" }
    if b.keyCode == 49 { return label + "Space" }
    if let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
      let data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
    {
      let layout = unsafeBitCast(data, to: CFData.self)
      let pointer = UnsafeRawPointer(CFDataGetBytePtr(layout)).assumingMemoryBound(
        to: UCKeyboardLayout.self)
      var dead: UInt32 = 0
      var actual = 0
      var chars = [UniChar](repeating: 0, count: 8)
      let status = UCKeyTranslate(
        pointer, UInt16(b.keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
        OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 8, &actual, &chars)
      if status == noErr, actual > 0 {
        return label + String(utf16CodeUnits: chars, count: actual).uppercased()
      }
    }
    return label + "Key \(b.keyCode)"
  }
}
struct ShortcutRecorderView: NSViewRepresentable {
  let onRecord: (ShortcutBinding?) -> Void
  let command: AppCommand
  func makeNSView(context: Context) -> RecorderKeyView {
    let v = RecorderKeyView()
    v.onRecord = onRecord
    v.command = command
    DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
    return v
  }
  func updateNSView(_ view: RecorderKeyView, context: Context) {}
}
final class RecorderKeyView: NSView {
  var onRecord: ((ShortcutBinding?) -> Void)?
  var command: AppCommand = .area
  override var acceptsFirstResponder: Bool { true }
  override func keyDown(with e: NSEvent) {
    if e.keyCode == 53 {
      onRecord?(nil)
      return
    }
    var m: ShortcutModifiers = []
    if e.modifierFlags.contains(.command) { m.insert(.command) }
    if e.modifierFlags.contains(.option) { m.insert(.option) }
    if e.modifierFlags.contains(.control) { m.insert(.control) }
    if e.modifierFlags.contains(.shift) { m.insert(.shift) }
    onRecord?(ShortcutBinding(command: command, keyCode: UInt32(e.keyCode), modifiers: m))
  }
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    keyDown(with: event)
    return true
  }
}
struct ShortcutsSettingsView: View {
  @ObservedObject var manager = GlobalShortcutManager.shared
  @State private var recording: AppCommand?
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("الاختصارات العامة").font(.title2.bold())
      Text("تعمل من أي تطبيق. اختر تسجيلًا واضغط التركيبة. Esc يلغي الإدخال.").font(.caption)
        .foregroundStyle(.secondary)
      ScrollView {
        ForEach(AppCommand.allCases) { c in
          HStack {
            Toggle(
              c.title,
              isOn: Binding(
                get: {
                  manager.configuration.bindings.first { $0.command == c }?.isEnabled ?? false
                },
                set: { v in
                  var b =
                    manager.configuration.bindings.first { $0.command == c }
                    ?? ShortcutBinding(command: c, keyCode: 0, isEnabled: false)
                  b.isEnabled = v
                  manager.update(b)
                })
            ).frame(width: 210, alignment: .leading)
            Button(manager.label(c)) {
              manager.suspend()
              recording = c
            }.frame(width: 150)
            Button("مسح") { manager.clear(c) }
          }.padding(.vertical, 5)
          if let e = manager.errors[c] { Text(e).font(.caption).foregroundStyle(.orange) }
        }
      }
      Button("استعادة الافتراضي") { manager.reset() }
    }.padding(20).sheet(item: $recording, onDismiss: { manager.resume() }) { c in
      VStack(spacing: 16) {
        Text("اضغط اختصار \(c.title)").font(.headline)
        Text("⌃ / ⌥ / ⌘ + مفتاح • Esc للإلغاء")
        ShortcutRecorderView(
          onRecord: { b in
            recording = nil
            manager.resume()
            if let b { manager.update(b) }
          }, command: c
        ).frame(width: 300, height: 70)
        Button("إلغاء") { recording = nil }
      }.padding(30)
    }.onDisappear { manager.resume() }
  }
}
