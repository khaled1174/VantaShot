import XCTest

@testable import VantaShotCore

final class DocumentTransformTests: XCTestCase {
  func testAspectFitMapsImageNotLetterbox() {
    let t = DocumentTransform(
      sourceRect: CGRect(x: 0, y: 0, width: 2000, height: 1000),
      viewport: CGSize(width: 760, height: 475))
    XCTAssertEqual(t.imageRect, CGRect(x: 0, y: 47.5, width: 760, height: 380))
    XCTAssertEqual(t.viewToDocument(CGPoint(x: 380, y: 237.5)), CGPoint(x: 1000, y: 500))
    XCTAssertNil(t.viewToDocument(CGPoint(x: 380, y: 10)))
  }
}
final class DocumentHistoryTests: XCTestCase {
  func testCropAndMoveUndoPreserveRedactionAndCounter() {
    var d = AnnotationDocument(size: PixelSize(width: 1000, height: 500))
    var h = DocumentHistory(d)
    d.objects.append(
      AnnotationObject(tool: .pixelate, points: [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 200)]))
    d.nextCounter = 2
    h.apply(d)
    d.cropRect = CGRect(x: 50, y: 50, width: 400, height: 250)
    h.apply(d)
    d.objects[0].translate(by: CGSize(width: 30, height: 0))
    h.apply(d)
    h.undo()
    XCTAssertEqual(h.current.objects[0].points[0].x, 100)
    XCTAssertEqual(h.current.cropRect.width, 400)
    h.undo()
    XCTAssertEqual(h.current.cropRect.width, 1000)
    XCTAssertEqual(h.current.objects.count, 1)
    h.redo()
    XCTAssertEqual(h.current.cropRect.width, 400)
    var cleared = h.current
    cleared.objects = []
    cleared.nextCounter = 1
    h.apply(cleared)
    h.undo()
    XCTAssertEqual(h.current.objects.count, 1)
    XCTAssertEqual(h.current.nextCounter, 2)
    h.apply(h.current)
    XCTAssertTrue(h.canRedo)
  }
  func testNewEditClearsRedo() {
    let d = AnnotationDocument(size: PixelSize(width: 20, height: 20))
    var h = DocumentHistory(d)
    var a = d
    a.nextCounter = 2
    h.apply(a)
    h.undo()
    a.nextCounter = 3
    h.apply(a)
    XCTAssertFalse(h.canRedo)
  }
}
final class OCRResultTests: XCTestCase {
  func testDetectedLinksAreReturnedWithoutOpeningThem() {
    let r = OCRResult(text: "مرحبا https://example.com/a\nVantaShot https://example.com/a")
    XCTAssertEqual(r.detectedURLs, [URL(string: "https://example.com/a")!])
  }
}
final class BackgroundFrameTests: XCTestCase {
  func testOldDocumentsWithoutFrameKeyDecodeAsNoFrame() throws {
    let json = """
      {"enabled":true,"padding":10,"cornerRadius":4,"shadowRadius":0,
       "first":{"red":0,"green":0,"blue":0,"alpha":1},"second":{"red":1,"green":1,"blue":1,"alpha":1}}
      """.data(using: .utf8)!
    let b = try JSONDecoder().decode(DocumentBackground.self, from: json)
    XCTAssertEqual(b.frame, .none)
    XCTAssertTrue(b.enabled)
  }
  func testFrameRoundTripsAndChromeHeightScalesWithWidth() throws {
    var b = DocumentBackground()
    b.enabled = true
    b.frame = .macWindow
    let data = try JSONEncoder().encode(b)
    XCTAssertEqual(try JSONDecoder().decode(DocumentBackground.self, from: data).frame, .macWindow)
    XCTAssertEqual(b.chromeHeight(forCropWidth: 400), 28)
    XCTAssertEqual(b.chromeHeight(forCropWidth: 2000), 64)
    XCTAssertEqual(b.chromeHeight(forCropWidth: 1000), 35)
    b.frame = .none
    XCTAssertEqual(b.chromeHeight(forCropWidth: 1000), 0)
    b.frame = .macWindow
    b.enabled = false
    XCTAssertEqual(b.chromeHeight(forCropWidth: 1000), 0)
  }
  func testRenderedSourceRectIncludesPaddingAndChrome() {
    var d = AnnotationDocument(size: PixelSize(width: 400, height: 300))
    d.background.enabled = true
    d.background.padding = 10
    d.background.frame = .macWindow
    XCTAssertEqual(d.renderedSourceRect, CGRect(x: -10, y: -38, width: 420, height: 348))
    d.background.enabled = false
    XCTAssertEqual(d.renderedSourceRect, CGRect(x: 0, y: 0, width: 400, height: 300))
  }
}
