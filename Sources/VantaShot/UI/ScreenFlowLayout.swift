import AppKit
import SwiftUI
import VantaShotCore

// MARK: - Pure, unit-tested layout helpers for the screens added in steps 3–5.

enum PinnedImageLayout {
  static let minWidth: CGFloat = 300
  static let maxWidth: CGFloat = 520
  static let margin: CGFloat = 24

  /// Fits the pinned panel in the top-trailing corner of `visibleFrame` without leaving the screen.
  static func frame(imageSize: CGSize, visibleFrame: CGRect) -> CGRect {
    let ratio = max(0.05, imageSize.width / max(1, imageSize.height))
    let maxW = min(maxWidth, visibleFrame.width - margin * 2)
    let maxH = visibleFrame.height - margin * 2
    var width = min(maxW, max(minWidth, imageSize.width * 0.55))
    var height = width / ratio
    if height > maxH {
      height = maxH
      width = max(min(minWidth, maxW), height * ratio)
    }
    width = min(width, maxW)
    return CGRect(
      x: visibleFrame.maxX - width - margin,
      y: visibleFrame.maxY - height - margin,
      width: width, height: height
    ).integral
  }
}

enum RecordingCapsuleLayout {
  static let gap: CGFloat = 14

  /// Centers the live capsule above the recorded region; falls back below it, then clamps.
  static func frame(region: CGRect, visibleFrame: CGRect, size: CGSize) -> CGRect {
    var x = region.midX - size.width / 2
    x = min(max(x, visibleFrame.minX + gap), visibleFrame.maxX - size.width - gap)
    var y = region.maxY + gap
    if y + size.height > visibleFrame.maxY - gap {
      y = region.minY - gap - size.height
    }
    if y < visibleFrame.minY + gap {
      y = visibleFrame.maxY - gap - size.height
    }
    return CGRect(x: x, y: y, width: size.width, height: size.height).integral
  }
}

enum CountdownSequence {
  static func steps(from seconds: Int) -> [Int] {
    guard seconds > 0 else { return [] }
    return Array(stride(from: seconds, through: 1, by: -1))
  }
}

extension MediaKind {
  var friendlyName: String {
    switch self {
    case .stillImage: return "صورة"
    case .animatedImage: return "GIF"
    case .video: return "فيديو"
    }
  }
  var icon: String {
    switch self {
    case .stillImage: return "photo"
    case .animatedImage: return "photo.stack"
    case .video: return "film"
    }
  }
}

struct HistoryFilter: Equatable {
  var query: String = ""
  var kind: MediaKind? = nil

  func apply(to assets: [MediaAsset]) -> [MediaAsset] {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return assets.filter { a in
      if let kind, a.kind != kind { return false }
      guard !q.isEmpty else { return true }
      return a.title.lowercased().contains(q) || a.kind.friendlyName.lowercased().contains(q)
        || a.fileURL.lastPathComponent.lowercased().contains(q)
    }
  }
}

enum InspectorSection: Equatable { case color, stroke, text, arrowStyle }

enum InspectorSections {
  static func `for`(_ tool: AnnotationTool) -> [InspectorSection] {
    switch tool {
    case .select, .crop, .pixelate, .redact, .spotlight, .image: return []
    case .text, .counter: return [.color, .text]
    case .arrow: return [.color, .stroke, .arrowStyle]
    case .rectangle, .filledRect, .ellipse, .line, .freehand, .highlighter: return [.color, .stroke]
    }
  }
}

struct BackgroundTemplate: Identifiable, Equatable {
  let id: String
  let name: String
  let first: RGBA
  let second: RGBA

  static let all: [BackgroundTemplate] = [
    .init(id: "ocean", name: "محيط", first: RGBA(0.10, 0.50, 0.95), second: RGBA(0.40, 0.20, 0.80)),
    .init(id: "sunset", name: "غروب", first: RGBA(0.98, 0.45, 0.30), second: RGBA(0.75, 0.20, 0.55)),
    .init(id: "mint", name: "نعناع", first: RGBA(0.18, 0.80, 0.62), second: RGBA(0.10, 0.45, 0.75)),
    .init(id: "gold", name: "ذهبي", first: RGBA(0.98, 0.76, 0.28), second: RGBA(0.90, 0.40, 0.25)),
    .init(id: "night", name: "ليل", first: RGBA(0.10, 0.12, 0.22), second: RGBA(0.25, 0.20, 0.45)),
    .init(id: "rose", name: "وردي", first: RGBA(0.95, 0.55, 0.75), second: RGBA(0.60, 0.30, 0.85)),
    .init(id: "graphite", name: "رمادي", first: RGBA(0.30, 0.32, 0.36), second: RGBA(0.12, 0.13, 0.16)),
    .init(id: "lime", name: "ليموني", first: RGBA(0.70, 0.90, 0.30), second: RGBA(0.15, 0.65, 0.45)),
  ]

  var gradient: LinearGradient {
    LinearGradient(
      colors: [
        Color(red: first.red, green: first.green, blue: first.blue),
        Color(red: second.red, green: second.green, blue: second.blue),
      ], startPoint: .topLeading, endPoint: .bottomTrailing)
  }
}

// MARK: - Microphone level meter (pure)

enum AudioLevelMeter {
  /// Root mean square of float samples.
  static func rms(_ samples: UnsafeBufferPointer<Float>) -> Float {
    guard !samples.isEmpty else { return 0 }
    var acc: Float = 0
    for s in samples { acc += s * s }
    return (acc / Float(samples.count)).squareRoot()
  }
  /// Maps an RMS (0…1) to a 0…1 meter value on a 50 dB scale.
  static func level(fromRMS rms: Float) -> Float {
    guard rms > 0 else { return 0 }
    let db = 20 * log10(rms)
    return min(1, max(0, (db + 50) / 50))
  }
  /// How many of `count` bars light up for `level`.
  static func litBars(level: Float, count: Int) -> Int {
    guard level > 0.02 else { return 0 }
    return min(count, max(1, Int((level * Float(count)).rounded(.up))))
  }
}

// MARK: - History multi-selection (pure)

struct HistorySelectionModel: Equatable {
  var ids: Set<UUID> = []
  private(set) var anchor: UUID?

  var isEmpty: Bool { ids.isEmpty }
  func contains(_ id: UUID) -> Bool { ids.contains(id) }

  /// Finder-like semantics: plain click selects one, ⌘ toggles, ⇧ extends from the anchor.
  mutating func click(_ id: UUID, in ordered: [UUID], command: Bool, shift: Bool) {
    if shift, let anchor, let a = ordered.firstIndex(of: anchor), let b = ordered.firstIndex(of: id) {
      ids = Set(ordered[min(a, b)...max(a, b)])
      return
    }
    if command {
      if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
    } else {
      ids = [id]
    }
    anchor = id
  }
  mutating func selectAll(_ ordered: [UUID]) {
    ids = Set(ordered)
    anchor = ordered.first
  }
  mutating func clear() {
    ids = []
    anchor = nil
  }
  mutating func prune(keeping ordered: [UUID]) {
    ids = ids.intersection(ordered)
    if let anchor, !ordered.contains(anchor) { self.anchor = nil }
  }
}
