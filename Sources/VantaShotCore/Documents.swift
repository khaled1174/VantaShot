import CoreGraphics
import Foundation

public struct PixelSize: Codable, Equatable, Sendable {
  public var width: Int
  public var height: Int
  public init(width: Int, height: Int) {
    self.width = width
    self.height = height
  }
  public var rect: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }
}
public struct RGBA: Codable, Equatable, Sendable {
  public var red: Double
  public var green: Double
  public var blue: Double
  public var alpha: Double
  public init(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) {
    self.red = red
    self.green = green
    self.blue = blue
    self.alpha = alpha
  }
  public var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
}
public enum AnnotationTool: String, Codable, CaseIterable, Sendable {
  case select, crop, arrow, rectangle, filledRect, ellipse, line, freehand, highlighter, text,
    counter, pixelate, redact, spotlight, image
  public var title: String {
    switch self {
    case .select: return "تحريك"
    case .crop: return "قص"
    case .arrow: return "سهم"
    case .rectangle: return "إطار"
    case .filledRect: return "تعبئة"
    case .ellipse: return "دائرة"
    case .line: return "خط"
    case .freehand: return "قلم"
    case .highlighter: return "تظليل"
    case .text: return "نص"
    case .counter: return "ترقيم"
    case .pixelate: return "تمويه"
    case .redact: return "حجب"
    case .spotlight: return "إبراز"
    case .image: return "صورة"
    }
  }
  public var icon: String {
    switch self {
    case .select: return "cursorarrow"
    case .crop: return "crop"
    case .arrow: return "arrow.up.right"
    case .rectangle: return "rectangle"
    case .filledRect: return "rectangle.fill"
    case .ellipse: return "circle"
    case .line: return "line.diagonal"
    case .freehand: return "scribble"
    case .highlighter: return "highlighter"
    case .text: return "textformat"
    case .counter: return "1.circle"
    case .pixelate: return "checkerboard.rectangle"
    case .redact: return "rectangle.inset.filled"
    case .spotlight: return "flashlight.on.fill"
    case .image: return "photo.badge.plus"
    }
  }
}
public struct AnnotationObject: Identifiable, Codable, Equatable, Sendable {
  public var id = UUID()
  public var tool: AnnotationTool
  public var points: [CGPoint]
  public var color: RGBA
  public var lineWidth: CGFloat
  public var text: String
  public var fontFamily: String?
  public var fontSize: CGFloat
  public var stepIndex: Int
  public var imageData: Data?
  public var doubleArrow = false
  public init(
    tool: AnnotationTool, points: [CGPoint], color: RGBA = RGBA(1, 0.2, 0.3),
    lineWidth: CGFloat = 5, text: String = "", fontSize: CGFloat = 32, stepIndex: Int = 1
  ) {
    self.tool = tool
    self.points = points
    self.color = color
    self.lineWidth = lineWidth
    self.text = text
    self.fontSize = fontSize
    self.stepIndex = stepIndex
  }
  public var start: CGPoint { points.first ?? .zero }
  public var end: CGPoint { points.last ?? start }
  public var bounds: CGRect {
    if tool == .counter { return CGRect(x: start.x - 20, y: start.y - 20, width: 40, height: 40) }
    let xs = points.map(\.x)
    let ys = points.map(\.y)
    return CGRect(
      x: xs.min() ?? 0, y: ys.min() ?? 0, width: max(1, (xs.max() ?? 0) - (xs.min() ?? 0)),
      height: max(1, (ys.max() ?? 0) - (ys.min() ?? 0)))
  }
  public mutating func translate(by delta: CGSize) {
    points = points.map { CGPoint(x: $0.x + delta.width, y: $0.y + delta.height) }
  }
}
public enum BackgroundFrame: String, Codable, Sendable { case none, macWindow }
public struct DocumentBackground: Codable, Equatable, Sendable {
  public var enabled = false
  public var wallpaperPNG: Data?
  public var padding: CGFloat = 42
  public var cornerRadius: CGFloat = 14
  public var shadowRadius: CGFloat = 16
  public var first = RGBA(0.1, 0.5, 0.95)
  public var second = RGBA(0.4, 0.2, 0.8)
  /// Optional device chrome drawn around the capture (title bar + traffic lights).
  public var frame: BackgroundFrame = .none
  public init() {}
  /// Height of the fake title bar in source pixels; 0 when no frame is drawn.
  public func chromeHeight(forCropWidth width: CGFloat) -> CGFloat {
    guard enabled, frame == .macWindow else { return 0 }
    return max(28, min(64, (width * 0.035).rounded()))
  }
  private enum CodingKeys: String, CodingKey {
    case enabled, wallpaperPNG, padding, cornerRadius, shadowRadius, first, second, frame
  }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
    wallpaperPNG = try c.decodeIfPresent(Data.self, forKey: .wallpaperPNG)
    padding = try c.decodeIfPresent(CGFloat.self, forKey: .padding) ?? 42
    cornerRadius = try c.decodeIfPresent(CGFloat.self, forKey: .cornerRadius) ?? 14
    shadowRadius = try c.decodeIfPresent(CGFloat.self, forKey: .shadowRadius) ?? 16
    first = try c.decodeIfPresent(RGBA.self, forKey: .first) ?? RGBA(0.1, 0.5, 0.95)
    second = try c.decodeIfPresent(RGBA.self, forKey: .second) ?? RGBA(0.4, 0.2, 0.8)
    frame = try c.decodeIfPresent(BackgroundFrame.self, forKey: .frame) ?? .none
  }
}
public struct AnnotationDocument: Codable, Equatable, Sendable {
  public var schemaVersion = 1
  public var sourceAssetID: UUID
  public var sourcePixelSize: PixelSize
  public var cropRect: CGRect
  public var objects: [AnnotationObject] = []
  public var nextCounter = 1
  public var background = DocumentBackground()
  public init(size: PixelSize, sourceAssetID: UUID = UUID()) {
    self.sourceAssetID = sourceAssetID
    self.sourcePixelSize = size
    self.cropRect = size.rect
  }
  /// Document-space rect covered by the rendered image (crop + padding + window chrome above).
  public var renderedSourceRect: CGRect {
    let pad = background.enabled ? max(0, background.padding.rounded()) : 0
    let chrome = background.chromeHeight(forCropWidth: cropRect.width)
    return CGRect(
      x: cropRect.minX - pad, y: cropRect.minY - pad - chrome,
      width: cropRect.width + pad * 2, height: cropRect.height + pad * 2 + chrome)
  }
}
public struct DocumentTransform {
  public let sourceRect: CGRect
  public let imageRect: CGRect
  public var scale: CGFloat { imageRect.width / sourceRect.width }
  public init(sourceRect: CGRect, viewport: CGSize) {
    self.sourceRect = sourceRect
    let s = min(
      viewport.width / max(1, sourceRect.width), viewport.height / max(1, sourceRect.height))
    imageRect = CGRect(
      x: (viewport.width - sourceRect.width * s) / 2,
      y: (viewport.height - sourceRect.height * s) / 2, width: sourceRect.width * s,
      height: sourceRect.height * s)
  }
  public func viewToDocument(_ point: CGPoint) -> CGPoint? {
    guard imageRect.contains(point), scale > 0 else { return nil }
    return CGPoint(
      x: sourceRect.minX + (point.x - imageRect.minX) / scale,
      y: sourceRect.minY + (point.y - imageRect.minY) / scale)
  }
  public func documentToView(_ point: CGPoint) -> CGPoint {
    CGPoint(
      x: imageRect.minX + (point.x - sourceRect.minX) * scale,
      y: imageRect.minY + (point.y - sourceRect.minY) * scale)
  }
}
public struct DocumentHistory {
  public private(set) var current: AnnotationDocument
  private var past: [AnnotationDocument] = []
  private var future: [AnnotationDocument] = []
  public init(_ document: AnnotationDocument) { current = document }
  public var canUndo: Bool { !past.isEmpty }
  public var canRedo: Bool { !future.isEmpty }
  public mutating func apply(_ document: AnnotationDocument) {
    guard document != current else { return }
    past.append(current)
    if past.count > 100 { past.removeFirst() }
    current = document
    future.removeAll()
  }
  public mutating func undo() {
    guard let d = past.popLast() else { return }
    future.append(current)
    current = d
  }
  public mutating func redo() {
    guard let d = future.popLast() else { return }
    past.append(current)
    current = d
  }
}

extension AnnotationObject {
  public mutating func resize(to rect: CGRect, from referenceBounds: CGRect? = nil) {
    let old = referenceBounds ?? bounds
    guard old.width > 0, old.height > 0, rect.width > 0, rect.height > 0 else { return }
    points = points.map {
      CGPoint(
        x: rect.minX + ($0.x - old.minX) * rect.width / old.width,
        y: rect.minY + ($0.y - old.minY) * rect.height / old.height)
    }
    if tool == .text { fontSize = max(8, fontSize * rect.height / old.height) }
  }
}
