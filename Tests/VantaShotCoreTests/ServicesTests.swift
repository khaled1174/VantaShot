import XCTest

@testable import VantaShotCore

final class CaptureSessionTests: XCTestCase {
  func testStaleCompletionIgnored() {
    var s = CaptureSession()
    let a = s.begin(.selecting)
    s.cancel()
    let b = s.begin(.countdown)
    XCTAssertFalse(s.finish(a))
    XCTAssertEqual(s.id, b)
    XCTAssertTrue(s.finish(b))
    XCTAssertEqual(s.state, .idle)
  }
}
final class ShortcutValidationTests: XCTestCase {
  func testDuplicateAndSystemReservedRejected() {
    let a = ShortcutBinding(command: .area, keyCode: 0)
    let b = ShortcutBinding(command: .window, keyCode: 0)
    XCTAssertNotNil(ShortcutValidation.conflicts([a, b])[.window])
    XCTAssertNotNil(
      ShortcutValidation.conflicts([
        ShortcutBinding(command: .area, keyCode: 20, modifiers: [.command, .shift])
      ])[.area])
  }
  func testSaveLoadAndCorruptDefaults() throws {
    let name = "VantaShotTests.\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let store = ShortcutStore(defaults: defaults)
    var c = ShortcutConfiguration()
    c.bindings[0].isEnabled = false
    try store.save(c)
    XCTAssertEqual(store.load(), c)
    defaults.set(Data([0, 1]), forKey: "shortcuts.v1")
    XCTAssertEqual(store.load(), ShortcutConfiguration())
  }
}
final class HistoryStoreContractTests: XCTestCase {
  func testRestartAndRestoreDoesNotDuplicate() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let input = root.appendingPathComponent("input.gif")
    try Data([1, 2, 3]).write(to: input)
    let a = MediaAsset(
      kind: .animatedImage, title: "Test", fileURL: input,
      pixelSize: PixelSize(width: 10, height: 10))
    let store = HistoryStore(rootURL: root.appendingPathComponent("store"))
    try await store.insert(a)
    try await store.markClosed(a.id)
    let fresh = HistoryStore(rootURL: root.appendingPathComponent("store"))
    let restored = try await fresh.restoreLastClosed()
    XCTAssertEqual(restored?.id, a.id)
    let manifest = try await fresh.load()
    XCTAssertEqual(manifest.entries.count, 1)
    XCTAssertEqual(manifest.entries[0].kind, .animatedImage)
    XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.entries[0].fileURL.path))
  }
  func testExportNeverOverwrites() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let e = MediaExportService()
    let a = try e.write(Data([1]), extension: "png", directory: root)
    let b = try e.write(Data([2]), extension: "png", directory: root)
    XCTAssertNotEqual(a, b)
    XCTAssertEqual(try Data(contentsOf: a), Data([1]))
  }
  func testProjectRoundTrip() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".vantashot")
    defer { try? FileManager.default.removeItem(at: url) }
    var d = AnnotationDocument(size: PixelSize(width: 100, height: 80))
    d.objects = [AnnotationObject(tool: .redact, points: [.zero, CGPoint(x: 20, y: 20)])]
    d.cropRect = CGRect(x: 0, y: 0, width: 50, height: 40)
    try DocumentStore.save(document: d, sourcePNG: Data([1, 2]), to: url)
    let p = try DocumentStore.load(from: url)
    XCTAssertEqual(p.document, d)
    XCTAssertEqual(p.sourcePNG, Data([1, 2]))
  }
}
extension HistoryStoreContractTests {
  func testCorruptManifestIsPreservedAndRecoverable() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let corrupt = Data("bad JSON".utf8)
    try corrupt.write(to: root.appendingPathComponent("history.json"))
    let store = HistoryStore(rootURL: root)
    let manifest = try await store.load()
    XCTAssertTrue(manifest.entries.isEmpty)
    XCTAssertNotNil(manifest.warning)
    let files = try FileManager.default.contentsOfDirectory(
      at: root, includingPropertiesForKeys: nil)
    let backup = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("history-corrupt-") })
    XCTAssertEqual(try Data(contentsOf: backup), corrupt)
  }
  func testFileFailureIsThrown() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data([1]).write(to: root)
    XCTAssertThrowsError(
      try MediaExportService().write(Data([2]), extension: "png", directory: root))
    XCTAssertEqual(try Data(contentsOf: root), Data([1]))
  }
}
extension HistoryStoreContractTests {
  func testFailedCommitCanRetrySameIDWithoutOrphanPoisoning() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("input.png")
    try Data([1, 2]).write(to: file)
    let a = MediaAsset(
      kind: .stillImage, title: "A", fileURL: file, pixelSize: PixelSize(width: 10, height: 10))
    let store = HistoryStore(
      rootURL: root.appendingPathComponent("store"), commitCheck: { throw StorageError.invalidData }
    )
    do {
      try await store.insert(a)
      XCTFail("Should fail")
    } catch {}
    let retry = HistoryStore(rootURL: root.appendingPathComponent("store"))
    try await retry.insert(a)
    let result = try await retry.load()
    XCTAssertEqual(result.entries.map(\.id), [a.id])
  }
  func testCancelledLeaseCannotCommitMedia() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("a.png")
    try Data([1]).write(to: file)
    let a = MediaAsset(
      kind: .stillImage, title: "A", fileURL: file, pixelSize: PixelSize(width: 1, height: 1))
    let lease = RequestLease()
    let store = HistoryStore(
      rootURL: root.appendingPathComponent("store"), commitCheck: { lease.cancel() })
    do {
      try await store.insert(a, lease: lease)
      XCTFail("Cancelled insertion should fail")
    } catch {}
    let m = try await store.load()
    XCTAssertTrue(m.entries.isEmpty)
  }
}
extension HistoryStoreContractTests {
  func testTrashSurvivesRestartAndCanBeRestored() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("input.png")
    try Data([1]).write(to: file)
    let a = MediaAsset(
      kind: .stillImage, title: "A", fileURL: file, pixelSize: PixelSize(width: 10, height: 10))
    let s = HistoryStore(rootURL: root.appendingPathComponent("store"))
    try await s.insert(a)
    try await s.moveToTrash(a.id)
    let fresh = HistoryStore(rootURL: root.appendingPathComponent("store"))
    let m = try await fresh.load()
    XCTAssertEqual(m.deletedItemIDs, [a.id])
    try await fresh.restoreFromTrash(a.id)
    let restored = try await fresh.load()
    XCTAssertEqual(restored.deletedItemIDs, [])
    XCTAssertEqual(restored.entries.count, 1)
    XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
  }
}
