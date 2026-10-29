import CoreGraphics
import XCTest

@testable import VantaShotRendering

final class ScrollStitcherTests: XCTestCase {
  func frame(start: Int) -> CGImage {
    let w = 120
    let h = 160
    let c = CGContext(
      data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    for y in 0..<h {
      let v = Double(((y + start) * 37) % 251) / 255
      c.setFillColor(
        CGColor(red: v, green: Double(((y + start) * 71) % 251) / 255, blue: 0.4, alpha: 1))
      c.fill(CGRect(x: 0, y: h - y - 1, width: w, height: 1))
    }
    return c.makeImage()!
  }
  func testStationaryDoesNotAppend() throws {
    var s = ScrollStitcher(first: frame(start: 0))
    XCTAssertFalse(try s.append(frame(start: 0)))
    XCTAssertEqual(s.image.height, 160)
  }
  func testKnownOverlapUsesConsecutiveRawFrames() throws {
    var s = ScrollStitcher(first: frame(start: 0))
    XCTAssertTrue(try s.append(frame(start: 50)))
    XCTAssertEqual(s.image.height, 210)
    XCTAssertTrue(try s.append(frame(start: 100)))
    XCTAssertEqual(s.image.height, 260)
  }
}
extension ScrollStitcherTests {
  func chrome(start: Int, extent: Int = 160, vertical: Bool = true) -> CGImage {
    let w = vertical ? 120 : extent
    let h = vertical ? extent : 120
    var bytes = [UInt8](repeating: 255, count: w * h * 4)
    for y in 0..<h {
      for x in 0..<w {
        let p = vertical ? y : x
        let i = (y * w + x) * 4
        if p < 10 {
          bytes[i] = 255
          bytes[i + 1] = 255
          bytes[i + 2] = 255
        } else if p >= extent - 8 {
          bytes[i] = 0
          bytes[i + 1] = 255
          bytes[i + 2] = 0
        } else {
          let n = p - 10 + start
          bytes[i] = UInt8((n * 37) % 251)
          bytes[i + 1] = UInt8((n * 71) % 251)
          bytes[i + 2] = 100
        }
      }
    }
    return CGImage(
      width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false,
      intent: .defaultIntent)!
  }
  func testFixedHeaderFooterSeamsMatchCompletePage() throws {
    for vertical in [true, false] {
      var s = ScrollStitcher(
        first: chrome(start: 0, vertical: vertical), axis: vertical ? .vertical : .horizontal)
      XCTAssertTrue(try s.append(chrome(start: 50, vertical: vertical)))
      XCTAssertTrue(try s.append(chrome(start: 100, vertical: vertical)))
      let expected = chrome(start: 0, extent: 260, vertical: vertical)
      let out = s.image
      XCTAssertEqual(out.width, expected.width)
      XCTAssertEqual(out.height, expected.height)
      let a = CFDataGetBytePtr(out.dataProvider!.data!)!
      let b = CFDataGetBytePtr(expected.dataProvider!.data!)!
      for n in 0..<260 {
        let x = vertical ? 60 : n
        let y = vertical ? n : 60
        let ai = y * out.bytesPerRow + x * 4
        let bi = y * expected.bytesPerRow + x * 4
        for c in 0..<3 {
          XCTAssertEqual(
            Int(a[ai + c]), Int(b[bi + c]), accuracy: 2,
            "axis=\(vertical) seam pixel=\(n) channel=\(c)")
        }
      }
    }
  }
}
