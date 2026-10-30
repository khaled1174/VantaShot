import CoreGraphics
import Foundation

public enum AppCommand: String, CaseIterable, Codable, Identifiable, Sendable {
  case allInOne, area, previousArea, fullscreen, window, selfTimer, scrolling, ocr, recordToggle,
    annotate, clipboard, history, restore, hideIcons, showLauncher
  public var id: String { rawValue }
  public var title: String {
    switch self {
    case .allInOne: return "All in One"
    case .area: return "Capture Area"
    case .previousArea: return "Previous Area"
    case .fullscreen: return "Full Screen"
    case .window: return "Capture Window"
    case .selfTimer: return "Self Timer"
    case .scrolling: return "Scrolling Capture"
    case .ocr: return "Extract Text"
    case .recordToggle: return "Start / Stop Recording"
    case .annotate: return "Editor"
    case .clipboard: return "Clipboard Image"
    case .history: return "History"
    case .restore: return "Restore Closed"
    case .hideIcons: return "Desktop Icons"
    case .showLauncher: return "Show Panel"
    }
  }
}
public struct CaptureSession: Sendable {
  public enum State: String, Sendable {
    case idle, selecting, countdown, scrolling, recording, pausedRecording, exporting
  }
  public private(set) var id = UUID()
  public private(set) var state: State = .idle
  public init() {}
  @discardableResult public mutating func begin(_ state: State) -> UUID {
    id = UUID()
    self.state = state
    return id
  }
  public mutating func transition(_ state: State, id: UUID) {
    guard self.id == id else { return }
    self.state = state
  }
  @discardableResult public mutating func finish(_ id: UUID) -> Bool {
    guard self.id == id else { return false }
    state = .idle
    return true
  }
  public mutating func cancel() {
    id = UUID()
    state = .idle
  }
}
public struct ShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
  public var rawValue: UInt32
  public init(rawValue: UInt32) { self.rawValue = rawValue }
  public static let command = Self(rawValue: 1), option = Self(rawValue: 2),
    control = Self(rawValue: 4), shift = Self(rawValue: 8)
}
public struct ShortcutBinding: Codable, Equatable, Identifiable, Sendable {
  public var command: AppCommand
  public var keyCode: UInt32
  public var modifiers: ShortcutModifiers
  public var isEnabled: Bool
  public var id: AppCommand { command }
  public init(
    command: AppCommand, keyCode: UInt32,
    modifiers: ShortcutModifiers = [.control, .option, .command], isEnabled: Bool = true
  ) {
    self.command = command
    self.keyCode = keyCode
    self.modifiers = modifiers
    self.isEnabled = isEnabled
  }
}
public struct ShortcutConfiguration: Codable, Equatable, Sendable {
  public var schemaVersion = 1
  public var bindings: [ShortcutBinding]
  public init() {
    let values: [(AppCommand, UInt32)] = [
      (.allInOne, 49), (.area, 0), (.fullscreen, 3), (.window, 13), (.previousArea, 2),
      (.scrolling, 1), (.ocr, 31), (.recordToggle, 15), (.showLauncher, 9),
    ]
    bindings = values.map { ShortcutBinding(command: $0.0, keyCode: $0.1) }
  }
}
public enum ShortcutConflict: String, Codable { case duplicate, systemReserved, invalid }
public enum ShortcutValidation {
  public static func conflicts(_ bindings: [ShortcutBinding]) -> [AppCommand: ShortcutConflict] {
    var result: [AppCommand: ShortcutConflict] = [:]
    var used: Set<String> = []
    for b in bindings where b.isEnabled {
      let key = "\(b.keyCode):\(b.modifiers.rawValue)"
      if !used.insert(key).inserted { result[b.command] = .duplicate }
      if b.modifiers.intersection([.command, .control, .option]).isEmpty || b.keyCode > 127 {
        result[b.command] = .invalid
      }
      if b.modifiers == [.command, .shift] && [20, 21, 23].contains(b.keyCode) {
        result[b.command] = .systemReserved
      }
    }
    return result
  }
}
public final class ShortcutStore {
  private let defaults: UserDefaults
  public init(defaults: UserDefaults) { self.defaults = defaults }
  public func load() -> ShortcutConfiguration {
    guard let data = defaults.data(forKey: "shortcuts.v1"),
      let c = try? JSONDecoder().decode(ShortcutConfiguration.self, from: data),
      c.schemaVersion == 1, Set(c.bindings.map(\.command)).count == c.bindings.count
    else { return ShortcutConfiguration() }
    return c
  }
  public func save(_ c: ShortcutConfiguration) throws {
    guard c.schemaVersion == 1, ShortcutValidation.conflicts(c.bindings).isEmpty else {
      throw StorageError.invalidData
    }
    defaults.set(try JSONEncoder().encode(c), forKey: "shortcuts.v1")
  }
}
public enum MediaKind: String, Codable, Sendable { case stillImage, animatedImage, video }
public struct MediaAsset: Codable, Identifiable, Equatable, Sendable {
  public var id: UUID
  public var kind: MediaKind
  public var title: String
  public var fileURL: URL
  public var previewURL: URL?
  public var pixelSize: PixelSize
  public var duration: Double?
  public var date: Date
  public init(
    id: UUID = UUID(), kind: MediaKind, title: String, fileURL: URL, previewURL: URL? = nil,
    pixelSize: PixelSize, duration: Double? = nil, date: Date = Date()
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.fileURL = fileURL
    self.previewURL = previewURL
    self.pixelSize = pixelSize
    self.duration = duration
    self.date = date
  }
}
public enum StorageError: LocalizedError {
  case invalidData, missingFile, unsupportedVersion
  public var errorDescription: String? {
    switch self {
    case .invalidData: return "The file data is invalid."
    case .missingFile: return "The media file is missing."
    case .unsupportedVersion: return "This document version is not supported."
    }
  }
}
public final class MediaExportService {
  public init() {}
  public func write(_ data: Data, extension ext: String, directory: URL) throws -> URL {
    guard !data.isEmpty, ["png", "jpg", "gif", "mp4", "mov", "json"].contains(ext) else {
      throw StorageError.invalidData
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let name =
      "VantaShot-\(ISO8601DateFormatter().string(from:Date()).replacingOccurrences(of:":",with:"-"))-\(UUID().uuidString).\(ext)"
    let url = directory.appendingPathComponent(name)
    let staging = directory.appendingPathComponent(".\(UUID().uuidString).partial")
    defer { try? FileManager.default.removeItem(at: staging) }
    try data.write(to: staging, options: .atomic)
    try FileManager.default.moveItem(at: staging, to: url)
    return url
  }
  public func export(_ asset: MediaAsset, to directory: URL) throws -> URL {
    guard FileManager.default.fileExists(atPath: asset.fileURL.path) else {
      throw StorageError.missingFile
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let out = directory.appendingPathComponent(
      "VantaShot-\(UUID().uuidString).\(asset.fileURL.pathExtension)")
    let staging = directory.appendingPathComponent(".\(UUID().uuidString).partial")
    defer { try? FileManager.default.removeItem(at: staging) }
    try FileManager.default.copyItem(at: asset.fileURL, to: staging)
    try FileManager.default.moveItem(at: staging, to: out)
    return out
  }
}
public struct ProjectFile: Codable {
  public var schemaVersion = 1
  public var document: AnnotationDocument
  public var sourcePNG: Data
}
public enum DocumentStore {
  public static func save(document: AnnotationDocument, sourcePNG: Data, to url: URL) throws {
    guard document.schemaVersion == 1, !sourcePNG.isEmpty else { throw StorageError.invalidData }
    try JSONEncoder().encode(ProjectFile(document: document, sourcePNG: sourcePNG)).write(
      to: url, options: .atomic)
  }
  public static func load(from url: URL) throws -> ProjectFile {
    let p = try JSONDecoder().decode(ProjectFile.self, from: Data(contentsOf: url))
    guard p.schemaVersion == 1, p.document.schemaVersion == 1 else {
      throw StorageError.unsupportedVersion
    }
    return p
  }
}
public struct HistoryManifest: Codable {
  public var schemaVersion = 1
  public var entries: [MediaAsset] = []
  public var closedItemIDs: [UUID] = []
  public var warning: String?
  public var deletedItemIDs: [UUID]?
  public init() {}
}
public actor HistoryStore {
  public let rootURL: URL
  private var limit: Int
  private let commitCheck: @Sendable () throws -> Void
  public init(
    rootURL: URL, retentionLimit: Int = 100, commitCheck: @escaping @Sendable () throws -> Void = {}
  ) {
    self.commitCheck = commitCheck
    self.rootURL = rootURL
    limit = max(1, retentionLimit)
  }
  private var manifestURL: URL { rootURL.appendingPathComponent("history.json") }
  public func load() throws -> HistoryManifest {
    guard FileManager.default.fileExists(atPath: manifestURL.path) else { return HistoryManifest() }
    let data = try Data(contentsOf: manifestURL)
    var m: HistoryManifest
    do { m = try JSONDecoder().decode(HistoryManifest.self, from: data) } catch {
      let backup = rootURL.appendingPathComponent("history-corrupt-\(UUID()).json")
      try FileManager.default.moveItem(at: manifestURL, to: backup)
      var recovered = HistoryManifest()
      recovered.warning = "Could not read the history index. A backup was saved, and the original media files are still there."
      return recovered
    }
    guard m.schemaVersion == 1 else { throw StorageError.unsupportedVersion }
    for i in m.entries.indices {
      m.entries[i].fileURL = try resolve(m.entries[i].fileURL)
      if let p = m.entries[i].previewURL { m.entries[i].previewURL = try resolve(p) }
    }
    return m
  }
  private func resolve(_ url: URL) throws -> URL {
    guard url.scheme == nil, !url.relativeString.contains(".."), !url.relativeString.hasPrefix("/")
    else { throw StorageError.invalidData }
    return rootURL.appendingPathComponent(url.relativeString)
  }
  private func persist(_ manifest: HistoryManifest) throws {
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    var m = manifest
    for i in m.entries.indices {
      m.entries[i].fileURL = URL(string: "Media/" + m.entries[i].fileURL.lastPathComponent)!
      if let p = m.entries[i].previewURL {
        m.entries[i].previewURL = URL(string: "Media/" + p.lastPathComponent)!
      }
    }
    try JSONEncoder().encode(m).write(to: manifestURL, options: .atomic)
  }
  public func updateRetentionLimit(_ value: Int) { limit = max(1, value) }
  public func insert(_ asset: MediaAsset, lease: RequestLease? = nil) throws {
    try Task.checkCancellation()
    try lease?.check()
    var m = try load()
    guard !m.entries.contains(where: { $0.id == asset.id }) else { return }
    var a = asset
    let media = rootURL.appendingPathComponent("Media", isDirectory: true)
    try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
    var created: [URL] = []
    var committed = false
    defer { if !committed { for url in created { try? FileManager.default.removeItem(at: url) } } }
    func copy(_ input: URL, suffix: String) throws -> URL {
      try Task.checkCancellation()
      try lease?.check()
      guard FileManager.default.fileExists(atPath: input.path) else {
        throw StorageError.missingFile
      }
      let output = media.appendingPathComponent(
        "\(a.id.uuidString)\(suffix).\(input.pathExtension)")
      if input.standardizedFileURL != output.standardizedFileURL
        && !FileManager.default.fileExists(atPath: output.path)
      {
        let staging = media.appendingPathComponent(".\(UUID()).partial")
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: input, to: staging)
        try Task.checkCancellation()
        try lease?.check()
        try FileManager.default.moveItem(at: staging, to: output)
        created.append(output)
      }
      return output
    }
    a.fileURL = try copy(asset.fileURL, suffix: "")
    if let p = asset.previewURL { a.previewURL = try copy(p, suffix: "-preview") }
    m.entries.insert(a, at: 0)
    let overflow = Array(m.entries.dropFirst(limit))
    m.entries = Array(m.entries.prefix(limit))
    m.closedItemIDs.removeAll { id in !m.entries.contains { $0.id == id } }
    m.deletedItemIDs?.removeAll { id in !m.entries.contains { $0.id == id } }
    try commitCheck()
    try Task.checkCancellation()
    try lease?.check()
    try persist(m)
    committed = true
    for old in overflow {
      try? FileManager.default.removeItem(at: old.fileURL)
      if let p = old.previewURL { try? FileManager.default.removeItem(at: p) }
    }
  }
  public func moveToTrash(_ id: UUID) throws {
    try moveToTrash([id])
  }
  public func moveToTrash(_ ids: [UUID]) throws {
    var m = try load()
    let targets = ids.filter { id in m.entries.contains { $0.id == id } }
    guard !targets.isEmpty else { return }
    var trashed = m.deletedItemIDs ?? []
    for id in targets where !trashed.contains(id) { trashed.append(id) }
    m.deletedItemIDs = trashed
    m.closedItemIDs.removeAll { targets.contains($0) }
    try persist(m)
  }
  /// Removes trashed entries and their files from disk. Cannot be undone.
  @discardableResult public func emptyTrash() throws -> Int {
    var m = try load()
    let trashed = Set(m.deletedItemIDs ?? [])
    let removed = m.entries.filter { trashed.contains($0.id) }
    guard !removed.isEmpty else { return 0 }
    m.entries.removeAll { trashed.contains($0.id) }
    m.deletedItemIDs = []
    try persist(m)
    for a in removed {
      try? FileManager.default.removeItem(at: a.fileURL)
      if let p = a.previewURL { try? FileManager.default.removeItem(at: p) }
    }
    return removed.count
  }
  public func restoreFromTrash(_ id: UUID) throws {
    var m = try load()
    m.deletedItemIDs?.removeAll { $0 == id }
    try persist(m)
  }
  public func markClosed(_ id: UUID) throws {
    var m = try load()
    guard m.entries.contains(where: { $0.id == id }) else { return }
    m.closedItemIDs.removeAll { $0 == id }
    m.closedItemIDs.append(id)
    try persist(m)
  }
  public func restoreLastClosed() throws -> MediaAsset? {
    var m = try load()
    guard let id = m.closedItemIDs.popLast() else { return nil }
    try persist(m)
    return m.entries.first { $0.id == id }
  }
}
