import AppKit
import Carbon
import VantaShotCore
import XCTest

@testable import VantaShot

final class GlobalShortcutIntegrationTests: XCTestCase {
  @MainActor func testCarbonRegistrationDispatchRepeatAndDurableConflict() async throws {
    _ = NSApplication.shared
    let name = "VantaShotShortcutTests.\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let store = ShortcutStore(defaults: defaults)
    var c = ShortcutConfiguration()
    c.bindings = [
      ShortcutBinding(command: .area, keyCode: 79),
      ShortcutBinding(command: .showLauncher, keyCode: 80),
    ]
    try store.save(c)
    var commands: [AppCommand] = []
    let manager = GlobalShortcutManager(store: store, dispatch: { commands.append($0) })
    manager.start()
    defer { manager.stop() }
    XCTAssertTrue(manager.errors.isEmpty, "\(manager.errors)")
    let index = UInt32(AppCommand.allCases.firstIndex(of: .showLauncher)! + 1)
    func event(_ kind: UInt32) throws {
      var e: EventRef?
      XCTAssertEqual(CreateEvent(nil, OSType(kEventClassKeyboard), kind, 0, 0, &e), noErr)
      let ref = try XCTUnwrap(e)
      var key = EventHotKeyID(signature: 0x564E_5441, id: index)
      XCTAssertEqual(
        SetEventParameter(
          ref, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
          MemoryLayout<EventHotKeyID>.size, &key), noErr)
      XCTAssertEqual(SendEventToEventTarget(ref, GetApplicationEventTarget()), noErr)
    }
    try event(UInt32(kEventHotKeyPressed))
    try event(UInt32(kEventHotKeyPressed))
    XCTAssertEqual(commands, [.showLauncher])
    try event(UInt32(kEventHotKeyReleased))
    try event(UInt32(kEventHotKeyPressed))
    XCTAssertEqual(commands, [.showLauncher, .showLauncher])
    manager.update(ShortcutBinding(command: .area, keyCode: 80))
    manager.resume()
    XCTAssertNotNil(manager.errors[.area])
    XCTAssertEqual(manager.configuration.bindings.first { $0.command == .area }?.keyCode, 79)
  }
}
