import AVFoundation
import CoreImage
import XCTest

@testable import VantaShot

final class RecordingMediaTests: XCTestCase {
  func sample(seconds: Double, red: Double) throws -> CMSampleBuffer {
    var pixel: CVPixelBuffer?
    XCTAssertEqual(
      CVPixelBufferCreate(
        kCFAllocatorDefault, 160, 100, kCVPixelFormatType_32BGRA,
        [
          kCVPixelBufferCGImageCompatibilityKey: true,
          kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ] as CFDictionary, &pixel), kCVReturnSuccess)
    let p = try XCTUnwrap(pixel)
    CIContext().render(
      CIImage(color: CIColor(red: red, green: 0, blue: 1 - red)).cropped(
        to: CGRect(x: 0, y: 0, width: 160, height: 100)), to: p)
    var desc: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(
      allocator: kCFAllocatorDefault, imageBuffer: p, formatDescriptionOut: &desc)
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: 30),
      presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 60000),
      decodeTimeStamp: .invalid)
    var buffer: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault, imageBuffer: p, formatDescription: try XCTUnwrap(desc),
      sampleTiming: &timing, sampleBufferOut: &buffer)
    return try XCTUnwrap(buffer)
  }
  func testWriterAndGIFRetainFrameAfterThirtySeconds() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("test.mp4")
    let writer = try MediaWriter(url: url, width: 160, height: 100, system: false, mic: false)
    let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
    for (offset, red) in [(0.0, 1.0), (35.0, 0.0), (42.0, 1.0)] {
      let sample = try sample(seconds: now - 45 + offset, red: red)
      writer.queue.sync { writer.appendVideo(sample) }
    }
    let (_, duration) = try await writer.finish()
    XCTAssertGreaterThan(duration, 44)
    let asset = AVURLAsset(url: url)
    let actualDuration = try await asset.load(.duration).seconds
    XCTAssertGreaterThan(actualDuration, 42)
    let gen = AVAssetImageGenerator(asset: asset)
    gen.requestedTimeToleranceBefore = .zero
    gen.requestedTimeToleranceAfter = .zero
    let late = try gen.copyCGImage(
      at: CMTime(seconds: 36, preferredTimescale: 600), actualTime: nil)
    XCTAssertEqual(late.width, 160)
    let gif = try await GIFExportService.export(video: url, duration: duration)
    let src = try XCTUnwrap(CGImageSourceCreateWithURL(gif as CFURL, nil))
    XCTAssertGreaterThan(CGImageSourceGetCount(src), 210)
    let last = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 210, nil))
    XCTAssertEqual(last.width, 160)
  }
}
extension RecordingMediaTests {
  func testExportProvidedLiveRecording() async throws {
    guard let path = ProcessInfo.processInfo.environment["VANTASHOT_LIVE_RECORDING"],
      let output = ProcessInfo.processInfo.environment["VANTASHOT_EVIDENCE_DIR"]
    else { throw XCTSkip("Requires an explicitly supplied local live-recording fixture") }
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    let duration = try await asset.load(.duration).seconds
    let gif = try await GIFExportService.export(video: asset.url, duration: duration)
    let src = try XCTUnwrap(CGImageSourceCreateWithURL(gif as CFURL, nil))
    let count = CGImageSourceGetCount(src)
    XCTAssertGreaterThan(count, 225)
    let late = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, count - 2, nil))
    XCTAssertGreaterThan(late.width, 500)
    let destination = URL(fileURLWithPath: output).appendingPathComponent("live-recording.gif")
    try FileManager.default.copyItem(at: gif, to: destination)
  }
}
extension RecordingMediaTests {
  func testCompletedSourceSurvivesDownstreamFailure() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("recovery.mp4")
    let w = try MediaWriter(url: url, width: 160, height: 100, system: false, mic: false)
    let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
    let a = try sample(seconds: now - 2, red: 1)
    let b = try sample(seconds: now - 1, red: 0)
    w.queue.sync {
      w.appendVideo(a)
      w.appendVideo(b)
    }
    _ = try await w.finish()
    w.cancel(discardCompleted: false)
    w.queue.sync {}
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    let duration = try await AVURLAsset(url: url).load(.duration).seconds
    XCTAssertGreaterThan(duration, 1)
  }
}
extension RecordingMediaTests {
  func testCancellingGIFExportStopsWorkerAndCleansPartialOutput()async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
    let w=try MediaWriter(url:root.appendingPathComponent("source.mp4"),width:160,height:100,system:false,mic:false);let now=CMClockGetTime(CMClockGetHostTimeClock()).seconds
    for offset in [0.0,100.0,200.0,299.0]{let b=try sample(seconds:now-300+offset,red:offset<100 ? 1:0);w.queue.sync{w.appendVideo(b)}};let (_,duration)=try await w.finish()
    let export=Task{try await GIFExportService.export(video:w.url,duration:duration)}
    try await Task.sleep(nanoseconds:100_000_000);let start=Date();export.cancel()
    do{_ = try await export.value;XCTFail("Cancelled export must throw")}catch{XCTAssertTrue(error is CancellationError,"\(error)")}
    XCTAssertLessThan(Date().timeIntervalSince(start),2);let files=try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil);XCTAssertFalse(files.contains{$0.pathExtension=="gif"});XCTAssertTrue(FileManager.default.fileExists(atPath:w.url.path))
  }
}
