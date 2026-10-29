import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO
import VantaShotCore

public enum RenderError: LocalizedError {
  case invalidDocument, allocationFailed, pixelationFailed, missingImage
  public var errorDescription: String? { "تعذر تركيب الصورة. لم يتم تصدير الأصل غير المعدل." }
}
public final class DocumentRenderer {
  private let ciContext = CIContext(options: [.cacheIntermediates: false])
  public init() {}
  /// Fake macOS title bar: dark chrome with three traffic-light dots at the leading edge.
  private func drawWindowChrome(in bar: CGRect, context c: CGContext) {
    c.saveGState()
    c.setFillColor(CGColor(srgbRed: 0.16, green: 0.17, blue: 0.19, alpha: 1))
    c.fill(bar)
    c.setFillColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.11, alpha: 1))
    c.fill(CGRect(x: bar.minX, y: bar.maxY - 1, width: bar.width, height: 1))
    let dot = (bar.height * 0.43).rounded()
    let gap = dot * 0.6
    let colors = [
      CGColor(srgbRed: 1.0, green: 0.37, blue: 0.34, alpha: 1),
      CGColor(srgbRed: 1.0, green: 0.74, blue: 0.18, alpha: 1),
      CGColor(srgbRed: 0.16, green: 0.79, blue: 0.25, alpha: 1),
    ]
    for (i, color) in colors.enumerated() {
      c.setFillColor(color)
      c.fillEllipse(
        in: CGRect(
          x: bar.minX + gap + CGFloat(i) * (dot + gap), y: bar.midY - dot / 2, width: dot, height: dot))
    }
    c.restoreGState()
  }
  public func render(document d: AnnotationDocument, source: CGImage) throws -> CGImage {
    let crop = d.cropRect.integral
    guard crop.width > 0, crop.height > 0, d.sourcePixelSize.rect.contains(crop),
      source.width == d.sourcePixelSize.width, source.height == d.sourcePixelSize.height
    else { throw RenderError.invalidDocument }
    let pad = d.background.enabled ? max(0, d.background.padding.rounded()) : 0
    let chrome = d.background.chromeHeight(forCropWidth: crop.width)
    let w = Int(crop.width + pad * 2)
    let h = Int(crop.height + pad * 2 + chrome)
    guard w > 0, h > 0, w <= 32768, h <= 32768, Double(w) * Double(h) <= 160_000_000,
      let c = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw RenderError.allocationFailed }
    c.translateBy(x: 0, y: CGFloat(h))
    c.scaleBy(x: 1, y: -1)
    if d.background.enabled, let data = d.background.wallpaperPNG {
      guard let source = CGImageSourceCreateWithData(data as CFData, nil),
        let wallpaper = CGImageSourceCreateImageAtIndex(source, 0, nil)
      else { throw RenderError.missingImage }
      let factor = max(
        CGFloat(w) / CGFloat(wallpaper.width), CGFloat(h) / CGFloat(wallpaper.height))
      let size = CGSize(
        width: CGFloat(wallpaper.width) * factor, height: CGFloat(wallpaper.height) * factor)
      drawImage(
        wallpaper,
        in: CGRect(
          x: (CGFloat(w) - size.width) / 2, y: (CGFloat(h) - size.height) / 2, width: size.width,
          height: size.height), context: c)
    } else if d.background.enabled {
      let colors = [d.background.first.cgColor, d.background.second.cgColor] as CFArray
      guard
        let g = CGGradient(
          colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])
      else { throw RenderError.allocationFailed }
      c.drawLinearGradient(g, start: .zero, end: CGPoint(x: w, y: h), options: [])
    }
    let frame = CGRect(x: pad, y: pad, width: crop.width, height: crop.height + chrome)
    let radius = d.background.enabled ? max(0, d.background.cornerRadius) : 0
    let clip = CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil)
    if d.background.enabled && d.background.shadowRadius > 0 {
      c.saveGState()
      c.setShadow(
        offset: CGSize(width: 0, height: 5), blur: d.background.shadowRadius,
        color: CGColor(gray: 0, alpha: 0.6))
      c.addPath(clip)
      c.setFillColor(CGColor(gray: 0, alpha: 1))
      c.fillPath()
      c.restoreGState()
    }
    c.addPath(clip)
    c.clip()
    if chrome > 0 { drawWindowChrome(in: CGRect(x: pad, y: pad, width: crop.width, height: chrome), context: c) }
    c.translateBy(x: pad - crop.minX, y: pad + chrome - crop.minY)
    drawImage(source, in: d.sourcePixelSize.rect, context: c)
    let spots = d.objects.filter { $0.tool == .spotlight }
    if !spots.isEmpty {
      c.saveGState()
      // Non-zero winding: subtract the union by clipping each hole out of the dim layer in a separate alpha mask.
      guard
        let mask = CGContext(
          data: nil, width: source.width, height: source.height, bitsPerComponent: 8,
          bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
          bitmapInfo: CGImageAlphaInfo.none.rawValue)
      else { throw RenderError.allocationFailed }
      mask.setFillColor(gray: 1, alpha: 1)
      mask.fill(d.sourcePixelSize.rect)
      mask.translateBy(x: 0, y: CGFloat(source.height))
      mask.scaleBy(x: 1, y: -1)
      mask.setFillColor(gray: 0, alpha: 1)
      for o in spots { mask.fill(o.bounds) }
      guard let m = mask.makeImage() else { throw RenderError.allocationFailed }
      c.clip(to: d.sourcePixelSize.rect, mask: m)
      c.setFillColor(CGColor(gray: 0, alpha: 0.6))
      c.fill(d.sourcePixelSize.rect)
      c.restoreGState()
    }
    var pix: CGImage?
    if d.objects.contains(where: { $0.tool == .pixelate }) {
      let input = CIImage(cgImage: source)
      let output = input.applyingFilter(
        "CIPixellate", parameters: [kCIInputScaleKey: max(16, Double(source.width) / 70)])
      guard let image = ciContext.createCGImage(output, from: input.extent) else {
        throw RenderError.pixelationFailed
      }
      pix = image
    }
    let ordered =
      d.objects.filter { $0.tool == .pixelate }
      + d.objects.filter { $0.tool != .pixelate && $0.tool != .spotlight }
    for o in ordered {
      c.saveGState()
      c.setStrokeColor(o.color.cgColor)
      c.setFillColor(o.color.cgColor)
      c.setLineWidth(o.lineWidth)
      c.setLineCap(.round)
      c.setLineJoin(.round)
      switch o.tool {
      case .rectangle: c.stroke(o.bounds)
      case .filledRect: c.fill(o.bounds)
      case .redact:
        c.setFillColor(
          CGColor(srgbRed: o.color.red, green: o.color.green, blue: o.color.blue, alpha: 1))
        c.fill(o.bounds)
      case .ellipse: c.strokeEllipse(in: o.bounds)
      case .line, .arrow, .freehand, .highlighter:
        if o.tool == .highlighter {
          c.setAlpha(0.35)
          c.setLineWidth(max(18, o.lineWidth * 4))
        }
        c.addLines(between: o.points)
        c.strokePath()
        if o.tool == .arrow {
          arrowHead(from: o.start, to: o.end, width: o.lineWidth, context: c)
          if o.doubleArrow { arrowHead(from: o.end, to: o.start, width: o.lineWidth, context: c) }
        }
      case .text:
        drawText(
          o.text, at: o.start, size: o.fontSize, color: o.color, font: o.fontFamily ?? "Helvetica",
          context: c)
      case .counter:
        c.fillEllipse(in: o.bounds)
        drawText(
          String(o.stepIndex), at: CGPoint(x: o.start.x - 11, y: o.start.y - 16), size: 27,
          color: RGBA(1, 1, 1), context: c)
      case .pixelate:
        guard let pix else { throw RenderError.pixelationFailed }
        c.clip(to: o.bounds)
        drawImage(pix, in: d.sourcePixelSize.rect, context: c)
      case .image:
        guard let data = o.imageData,
          let provider = CGImageSourceCreateWithData(data as CFData, nil),
          let img = CGImageSourceCreateImageAtIndex(provider, 0, nil)
        else { throw RenderError.missingImage }
        drawImage(img, in: o.bounds, context: c)
      default: break
      }
      c.restoreGState()
    }
    guard let out = c.makeImage() else { throw RenderError.allocationFailed }
    return out
  }
  private func drawImage(_ image: CGImage, in rect: CGRect, context c: CGContext) {
    c.saveGState()
    c.translateBy(x: rect.minX, y: rect.maxY)
    c.scaleBy(x: 1, y: -1)
    c.draw(image, in: CGRect(origin: .zero, size: rect.size))
    c.restoreGState()
  }
  private func arrowHead(from a: CGPoint, to b: CGPoint, width: CGFloat, context c: CGContext) {
    let angle = atan2(b.y - a.y, b.x - a.x)
    let length = max(16, width * 4)
    c.move(to: CGPoint(x: b.x - length * cos(angle - 0.5), y: b.y - length * sin(angle - 0.5)))
    c.addLine(to: b)
    c.addLine(to: CGPoint(x: b.x - length * cos(angle + 0.5), y: b.y - length * sin(angle + 0.5)))
    c.strokePath()
  }
  public func textBounds(_ o: AnnotationObject) -> CGRect {
    let line = textLine(o.text, size: o.fontSize, color: o.color, font: o.fontFamily ?? "Helvetica")
    var a: CGFloat = 0
    var d: CGFloat = 0
    let w = CTLineGetTypographicBounds(line, &a, &d, nil)
    return CGRect(x: o.start.x, y: o.start.y, width: max(1, w), height: a + d + 4)
  }
  private func textLine(_ text: String, size: CGFloat, color: RGBA, font: String = "Helvetica")
    -> CTLine
  {
    CTLineCreateWithAttributedString(
      NSAttributedString(
        string: text,
        attributes: [
          NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
            font as CFString, size, nil),
          NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
        ]))
  }
  private func drawText(
    _ text: String, at p: CGPoint, size: CGFloat, color: RGBA, font: String = "Helvetica",
    context c: CGContext
  ) {
    c.saveGState()
    c.translateBy(x: p.x, y: p.y + size)
    c.scaleBy(x: 1, y: -1)
    c.textPosition = .zero
    CTLineDraw(textLine(text, size: size, color: color, font: font), c)
    c.restoreGState()
  }
  public func hitTest(_ p: CGPoint, object o: AnnotationObject, tolerance: CGFloat) -> Bool {
    if o.tool == .text { return textBounds(o).insetBy(dx: -tolerance, dy: -tolerance).contains(p) }
    if [.freehand, .highlighter, .arrow, .line].contains(o.tool) {
      for (a, b) in zip(o.points, o.points.dropFirst()) {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / max(1, dx * dx + dy * dy)))
        if hypot(p.x - a.x - t * dx, p.y - a.y - t * dy) <= tolerance + o.lineWidth / 2 {
          return true
        }
      }
      return false
    }
    return o.bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(p)
  }
}
