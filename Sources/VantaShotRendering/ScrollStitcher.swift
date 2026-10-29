import CoreGraphics
import Foundation

public enum ScrollAxis: String, CaseIterable { case vertical, horizontal }
public enum StitchError: LocalizedError {
  case unmatched, limitReached
  public var errorDescription: String? {
    self == .unmatched
      ? "تعذر إيجاد تداخل موثوق. حرّك مسافة أصغر؛ لم تُضف نسخة مكررة."
      : "بلغت الصورة الحد الأقصى الآمن؛ أنهِ اللقطة الحالية."
  }
}
public struct ScrollStitcher {
  public private(set) var image: CGImage
  private var previous: CGImage
  private var position = 0, minimum = 0, maximum: Int
  public let axis: ScrollAxis
  public init(first: CGImage, axis: ScrollAxis = .vertical) {
    image = first
    previous = first
    self.axis = axis
    maximum = axis == .vertical ? first.height : first.width
  }
  @discardableResult public mutating func append(_ next: CGImage) throws -> Bool {
    guard next.width == previous.width, next.height == previous.height else {
      throw StitchError.unmatched
    }
    let vertical = axis == .vertical
    let dimension = vertical ? next.height : next.width
    let match = try Self.translation(previous, next, vertical: vertical)
    let shift = match.shift
    if abs(shift) < 2 { return false }
    let newPosition = position + shift
    let newMin = min(minimum, newPosition)
    let newMax = max(maximum, newPosition + dimension)
    let width = vertical ? next.width : newMax - newMin
    let height = vertical ? newMax - newMin : next.height
    guard width <= 32768, height <= 32768, Double(width) * Double(height) < 100_000_000 else {
      throw StitchError.limitReached
    }
    guard
      let c = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw StitchError.limitReached }
    c.translateBy(x: 0, y: CGFloat(height))
    c.scaleBy(x: 1, y: -1)
    func draw(_ img: CGImage, _ rect: CGRect) {
      c.saveGState()
      c.translateBy(x: rect.minX, y: rect.maxY)
      c.scaleBy(x: 1, y: -1)
      c.draw(img, in: CGRect(origin: .zero, size: rect.size))
      c.restoreGState()
    }
    let oldOffset = minimum - newMin
    let addedBefore = minimum - newMin
    let addedAfter = newMax - maximum
    c.saveGState()
    if addedAfter > 0, match.footer > 0 {
      c.clip(
        to: vertical
          ? CGRect(x: 0, y: 0, width: width, height: height - addedAfter - match.footer)
          : CGRect(x: 0, y: 0, width: width - addedAfter - match.footer, height: height))
    }
    if addedBefore > 0, match.header > 0 {
      c.clip(
        to: vertical
          ? CGRect(
            x: 0, y: addedBefore + match.header, width: width,
            height: height - addedBefore - match.header)
          : CGRect(
            x: addedBefore + match.header, y: 0, width: width - addedBefore - match.header,
            height: height))
    }
    draw(
      image,
      CGRect(
        x: vertical ? 0 : oldOffset, y: vertical ? oldOffset : 0, width: image.width,
        height: image.height))
    c.restoreGState()
    // Keep existing pixels (including the first sticky header); only draw newly exposed strips.
    if addedBefore > 0 || addedAfter > 0 {
      c.saveGState()
      let strip: CGRect
      if addedAfter > 0 {
        strip =
          vertical
          ? CGRect(
            x: 0, y: height - addedAfter - match.footer, width: width,
            height: addedAfter + match.footer)
          : CGRect(
            x: width - addedAfter - match.footer, y: 0, width: addedAfter + match.footer,
            height: height)
      } else {
        strip =
          vertical
          ? CGRect(x: 0, y: 0, width: width, height: addedBefore + match.header)
          : CGRect(x: 0, y: 0, width: addedBefore + match.header, height: height)
      }
      c.clip(to: strip)
      let offset = newPosition - newMin
      draw(
        next,
        CGRect(
          x: vertical ? 0 : offset, y: vertical ? offset : 0, width: next.width, height: next.height
        ))
      c.restoreGState()
    }
    guard let out = c.makeImage() else { throw StitchError.limitReached }
    image = out
    previous = next
    position = newPosition
    minimum = newMin
    maximum = newMax
    return addedBefore > 0 || addedAfter > 0
  }
  private struct Match {
    var shift: Int
    var header: Int
    var footer: Int
  }
  private static func translation(_ a: CGImage, _ b: CGImage, vertical: Bool) throws -> Match {
    let original = vertical ? a.height : a.width
    let extent = min(500, original)
    let cross = 32
    func sample(_ image: CGImage) -> [UInt8] {
      let w = vertical ? cross : extent
      let h = vertical ? extent : cross
      let c = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
      c.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
      let bytes = Array(
        UnsafeBufferPointer(start: c.data!.assumingMemoryBound(to: UInt8.self), count: w * h))
      return (0..<extent).flatMap { row in
        (0..<cross).map { col in vertical ? bytes[row * w + col] : bytes[col * w + row] }
      }
    }
    let x = sample(a)
    let y = sample(b)
    func difference(_ rowA: Int, _ rowB: Int) -> Double {
      (0..<cross).stride(by: 2).reduce(0) {
        $0 + abs(Double(x[rowA * cross + $1]) - Double(y[rowB * cross + $1]))
      } / Double(cross / 2)
    }
    let stationary =
      (0..<extent).stride(by: 2).reduce(0) { $0 + difference($1, $1) } / Double((extent + 1) / 2)
    if stationary < 0.5 { return Match(shift: 0, header: 0, footer: 0) }
    var header = 0
    var footer = 0
    while header < extent / 5 && difference(header, header) < 1 { header += 1 }
    while footer < extent / 8 && difference(extent - footer - 1, extent - footer - 1) < 1 {
      footer += 1
    }
    var scores: [(Int, Double)] = []
    for shift in (-(extent * 4 / 5))...(extent * 4 / 5) where abs(shift) >= 2 {
      let start = max(header, header - shift)
      let end = min(extent - footer, extent - footer - shift)
      guard end - start >= extent / 5 else { continue }
      var sum = 0.0
      var count = 0
      for row in stride(from: start, to: end, by: 2) {
        sum += difference(row + shift, row)
        count += 1
      }
      scores.append((shift, sum / Double(max(1, count))))
    }
    scores.sort { $0.1 < $1.1 }
    guard let best = scores.first, best.1 < 12 else { throw StitchError.unmatched }
    if let alternate = scores.first(where: { abs($0.0 - best.0) > 3 }),
      alternate.1 < best.1 * 1.15 + 0.3
    {
      throw StitchError.unmatched
    }
    let scale = Double(original) / Double(extent)
    return Match(
      shift: Int((Double(best.0) * scale).rounded()),
      header: Int((Double(header) * scale).rounded()),
      footer: Int((Double(footer) * scale).rounded()))
  }
}
extension Range<Int> {
  fileprivate func stride(by step: Int) -> StrideTo<Int> {
    Swift.stride(from: lowerBound, to: upperBound, by: step)
  }
}
