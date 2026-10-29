import CoreGraphics
import VantaShotCore
import XCTest

@testable import VantaShotRendering

final class DocumentRendererTests: XCTestCase {
  func source() -> CGImage {
    let c = CGContext(
      data: nil, width: 100, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    c.fill(CGRect(x: 0, y: 0, width: 100, height: 80))
    return c.makeImage()!
  }
  func testCropRetainsOpaqueRedactionAtOriginalResolution() throws {
    var d = AnnotationDocument(size: PixelSize(width: 100, height: 80))
    d.cropRect = CGRect(x: 20, y: 10, width: 50, height: 40)
    d.objects = [
      AnnotationObject(
        tool: .redact, points: [CGPoint(x: 25, y: 15), CGPoint(x: 45, y: 35)], color: RGBA(0, 0, 0))
    ]
    let out = try DocumentRenderer().render(document: d, source: source())
    XCTAssertEqual(out.width, 50)
    XCTAssertEqual(out.height, 40)
    let data = out.dataProvider!.data!
    let p = CFDataGetBytePtr(data)!
    let offset = 10 * out.bytesPerRow + 10 * 4
    XCTAssertEqual(p[offset], 0)
    XCTAssertEqual(p[offset + 1], 0)
    XCTAssertEqual(p[offset + 2], 0)
    XCTAssertEqual(p[offset + 3], 255)
  }
  func testRenderingFailureThrows() {
    var d = AnnotationDocument(size: PixelSize(width: 100, height: 80))
    d.cropRect = .zero
    XCTAssertThrowsError(try DocumentRenderer().render(document: d, source: source()))
  }
}

final class AnnotationGeometryTests: XCTestCase {
  func testCurvedStrokeUsesIntermediatePoints() {
    let r = DocumentRenderer()
    let o = AnnotationObject(
      tool: .freehand, points: [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 80), CGPoint(x: 100, y: 0)])
    XCTAssertTrue(r.hitTest(CGPoint(x: 50, y: 80), object: o, tolerance: 2))
    XCTAssertFalse(r.hitTest(CGPoint(x: 50, y: 0), object: o, tolerance: 2))
  }
  func testTextBoundsIncludeWholeText() {
    let r = DocumentRenderer()
    let o = AnnotationObject(
      tool: .text, points: [CGPoint(x: 10, y: 10)], text: "VantaShot long text", fontSize: 32)
    let b = r.textBounds(o)
    XCTAssertGreaterThan(b.width, 150)
    XCTAssertTrue(r.hitTest(CGPoint(x: b.maxX - 2, y: b.midY), object: o, tolerance: 1))
  }
  func testResizePreservesShapeAndUndoableState() {
    var o = AnnotationObject(
      tool: .freehand,
      points: [CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 30), CGPoint(x: 30, y: 10)])
    o.resize(to: CGRect(x: 0, y: 0, width: 100, height: 200))
    XCTAssertEqual(o.points[1], CGPoint(x: 50, y: 200))
  }
}
extension DocumentRendererTests {
  func testOverlappingSpotlightsStayVisible() throws {
    var d = AnnotationDocument(size: PixelSize(width: 100, height: 80))
    d.objects = [
      AnnotationObject(tool: .spotlight, points: [CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 60)]),
      AnnotationObject(tool: .spotlight, points: [CGPoint(x: 40, y: 20), CGPoint(x: 90, y: 70)]),
    ]
    let out = try DocumentRenderer().render(document: d, source: source())
    let data = out.dataProvider!.data!
    let p = CFDataGetBytePtr(data)!
    XCTAssertEqual(p[30 * out.bytesPerRow + 50 * 4], 255)
    XCTAssertEqual(p[30 * out.bytesPerRow + 20 * 4], 255)
    XCTAssertLessThan(p[5 * out.bytesPerRow + 5 * 4], 150)
  }
  func testPixelationSurvivesCrop() throws {
    let c = CGContext(
      data: nil, width: 100, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.setFillColor(CGColor(gray: 1, alpha: 1))
    c.fill(CGRect(x: 0, y: 0, width: 100, height: 80))
    c.setFillColor(CGColor(gray: 0, alpha: 1))
    for x in stride(from: 0, to: 100, by: 2) { c.fill(CGRect(x: x, y: 0, width: 1, height: 80)) }
    var d = AnnotationDocument(size: PixelSize(width: 100, height: 80))
    d.cropRect = CGRect(x: 20, y: 10, width: 50, height: 40)
    d.objects = [
      AnnotationObject(tool: .pixelate, points: [CGPoint(x: 20, y: 10), CGPoint(x: 70, y: 50)])
    ]
    let image = try DocumentRenderer().render(document: d, source: c.makeImage()!)
    let data = image.dataProvider!.data!
    let p = CFDataGetBytePtr(data)!
    var transitions = 0
    for x in 1..<50 {
      if abs(Int(p[10 * image.bytesPerRow + x * 4]) - Int(p[10 * image.bytesPerRow + (x - 1) * 4]))
        > 200
      {
        transitions += 1
      }
    }
    XCTAssertLessThan(transitions, 8)
  }
}
extension DocumentRendererTests {
  func testImageOrientationAndBackgroundDimensions() throws {
    let c = CGContext(
      data: nil, width: 100, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    c.fill(CGRect(x: 0, y: 40, width: 100, height: 40))
    c.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
    c.fill(CGRect(x: 0, y: 0, width: 100, height: 40))
    var d = AnnotationDocument(size: PixelSize(width: 100, height: 80))
    d.background.enabled = true
    d.background.padding = 10
    d.background.cornerRadius = 0
    d.background.shadowRadius = 0
    let out = try DocumentRenderer().render(document: d, source: c.makeImage()!)
    XCTAssertEqual(out.width, 120)
    XCTAssertEqual(out.height, 100)
    let p = CFDataGetBytePtr(out.dataProvider!.data!)!
    XCTAssertGreaterThan(p[20 * out.bytesPerRow + 30 * 4], 240)
    XCTAssertGreaterThan(p[70 * out.bytesPerRow + 30 * 4 + 2], 240)
  }
  func testFilledRectangleAndLineUseDocumentCoordinates() throws {
    var d = AnnotationDocument(size: PixelSize(width: 100, height: 80))
    d.objects = [
      AnnotationObject(
        tool: .filledRect, points: [CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 30)],
        color: RGBA(0, 1, 0)),
      AnnotationObject(
        tool: .line, points: [CGPoint(x: 50, y: 10), CGPoint(x: 50, y: 70)], color: RGBA(0, 0, 1),
        lineWidth: 4),
    ]
    let out = try DocumentRenderer().render(document: d, source: source())
    let p = CFDataGetBytePtr(out.dataProvider!.data!)!
    XCTAssertEqual(p[20 * out.bytesPerRow + 20 * 4 + 1], 255)
    XCTAssertEqual(p[40 * out.bytesPerRow + 50 * 4 + 2], 255)
    XCTAssertEqual(p[40 * out.bytesPerRow + 80 * 4], 255)
  }
}
extension DocumentRendererTests {
  func testLaterPixelationCannotOverwriteOpaqueRedaction() throws {
    var d = AnnotationDocument(size: PixelSize(width: 100, height: 80))
    d.cropRect = CGRect(x: 10, y: 10, width: 80, height: 60)
    d.objects = [
      AnnotationObject(
        tool: .redact, points: [CGPoint(x: 20, y: 20), CGPoint(x: 60, y: 60)], color: RGBA(0, 0, 0)),
      AnnotationObject(tool: .pixelate, points: [CGPoint(x: 10, y: 10), CGPoint(x: 80, y: 70)]),
    ]
    let image = try DocumentRenderer().render(document: d, source: source())
    let p = CFDataGetBytePtr(image.dataProvider!.data!)!
    let i = 20 * image.bytesPerRow + 20 * 4
    XCTAssertEqual(p[i], 0)
    XCTAssertEqual(p[i + 1], 0)
    XCTAssertEqual(p[i + 2], 0)
    XCTAssertEqual(p[i + 3], 255)
  }
}
extension AnnotationGeometryTests {
  func testSelectedFontAndTextResizeUseRenderedBounds() throws {
    let r = DocumentRenderer()
    var o = AnnotationObject(
      tool: .text, points: [CGPoint(x: 10, y: 10), CGPoint(x: 11, y: 11)], text: "iiiiiiii",
      fontSize: 32)
    let a = r.textBounds(o)
    o.fontFamily = "Courier"
    let b = r.textBounds(o)
    XCTAssertGreaterThan(b.width, a.width * 1.5)
    o.resize(to: CGRect(x: 10, y: 10, width: b.width * 2, height: b.height * 2), from: b)
    XCTAssertEqual(o.fontSize, 64, accuracy: 0.1)
    let decoded = try JSONDecoder().decode(AnnotationObject.self, from: JSONEncoder().encode(o))
    XCTAssertEqual(decoded.fontFamily, "Courier")
  }
}
extension DocumentRendererTests {
  func testMacWindowFrameAddsTitleBarWithTrafficLights() throws {
    let c = CGContext(
      data: nil, width: 400, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    c.fill(CGRect(x: 0, y: 0, width: 400, height: 100))
    var d = AnnotationDocument(size: PixelSize(width: 400, height: 100))
    d.background.enabled = true
    d.background.padding = 0
    d.background.cornerRadius = 0
    d.background.shadowRadius = 0
    d.background.frame = .macWindow
    let out = try DocumentRenderer().render(document: d, source: c.makeImage()!)
    XCTAssertEqual(out.width, 400)
    XCTAssertEqual(out.height, 128)
    let p = CFDataGetBytePtr(out.dataProvider!.data!)!
    // Title bar (row 14) far from the dots is dark chrome; the image below (row 60) is white.
    XCTAssertLessThan(p[14 * out.bytesPerRow + 300 * 4], 90)
    XCTAssertGreaterThan(p[60 * out.bytesPerRow + 300 * 4], 240)
    // First traffic light (red) sits at x≈14+ in the title bar.
    let dot = 14 * out.bytesPerRow + 16 * 4
    XCTAssertGreaterThan(p[dot], 200)
    XCTAssertLessThan(p[dot + 1], 140)
  }
}
