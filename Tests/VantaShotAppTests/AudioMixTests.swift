import AVFoundation
import XCTest

@testable import VantaShot

final class AudioMixTests: XCTestCase {
  func audio(seconds: Double, frequency: Double) throws -> CMSampleBuffer {
    let n = 4800
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    var desc: CMAudioFormatDescription?
    XCTAssertEqual(
      CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault, asbd: format.streamDescription, layoutSize: 0, layout: nil,
        magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &desc), noErr)
    let samples = (0..<n).map { Float(sin(2 * Double.pi * frequency * Double($0) / 48000) * 0.2) }
    var block: CMBlockBuffer?
    XCTAssertEqual(
      CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: n * 4,
        blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
        dataLength: n * 4, flags: 0, blockBufferOut: &block), noErr)
    let b = try XCTUnwrap(block)
    let status = samples.withUnsafeBytes {
      CMBlockBufferReplaceDataBytes(
        with: $0.baseAddress!, blockBuffer: b, offsetIntoDestination: 0, dataLength: n * 4)
    }
    XCTAssertEqual(status, noErr)
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: 48000),
      presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 60000),
      decodeTimeStamp: .invalid)
    var buffer: CMSampleBuffer?
    XCTAssertEqual(
      CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault, dataBuffer: b, formatDescription: try XCTUnwrap(desc),
        sampleCount: n, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
        sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &buffer), noErr)
    return try XCTUnwrap(buffer)
  }
  func testTwoSourcesMixIntoOneAudibleTrack() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let w = try MediaWriter(
      url: root.appendingPathComponent("two.mp4"), width: 160, height: 100, system: true, mic: true)
    let helper = RecordingMediaTests()
    let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
    let video = try helper.sample(seconds: now - 3, red: 1)
    w.queue.sync { w.appendVideo(video) }
    for i in 0..<30 {
      let t = now - 3 + Double(i) / 10
      let a = try audio(seconds: t, frequency: 440)
      let b = try audio(seconds: t, frequency: 880)
      w.queue.sync {
        w.appendAudio(a, microphone: false)
        w.appendAudio(b, microphone: true)
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    _ = try await w.finish()
    let inputTracks = try await AVURLAsset(url: w.url).loadTracks(withMediaType: .audio)
    XCTAssertEqual(inputTracks.count, 2)
    let out = try await AudioMixService.mixIfNeeded(w.url)
    let asset = AVURLAsset(url: out)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    XCTAssertEqual(tracks.count, 1)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
      track: tracks[0],
      outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true,
        AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 1,
        AVSampleRateKey: 48000,
      ])
    reader.add(output)
    XCTAssertTrue(reader.startReading())
    var pcm: [Float] = []
    while pcm.count < 48000, let sample = output.copyNextSampleBuffer() {
      if let data = sample.dataBuffer {
        let length = CMBlockBufferGetDataLength(data)
        var bytes = [UInt8](repeating: 0, count: length)
        CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: length, destination: &bytes)
        bytes.withUnsafeBytes { raw in pcm.append(contentsOf: raw.bindMemory(to: Float.self)) }
      }
    }
    XCTAssertGreaterThan(pcm.count, 24000)
    func amplitude(_ f: Double) -> Double {
      let n = min(48000, pcm.count)
      var re = 0.0
      var im = 0.0
      for i in 0..<n {
        let angle = 2 * Double.pi * f * Double(i) / 48000
        re += Double(pcm[i]) * cos(angle)
        im += Double(pcm[i]) * sin(angle)
      }
      return 2 * hypot(re, im) / Double(n)
    }
    XCTAssertGreaterThan(amplitude(440), 0.04)
    XCTAssertGreaterThan(amplitude(880), 0.04)
    XCTAssertLessThan(amplitude(1300), 0.02)
  }
}
