import AVFoundation
import XCTest

@testable import VantaShot

final class MicLevelTests: XCTestCase {
  private func pcmBuffer(float: Bool, amplitude: Float, frames: Int = 480) throws -> CMSampleBuffer {
    var asbd = AudioStreamBasicDescription(
      mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: float
        ? (kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked)
        : (kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked),
      mBytesPerPacket: float ? 4 : 2, mFramesPerPacket: 1, mBytesPerFrame: float ? 4 : 2,
      mChannelsPerFrame: 1, mBitsPerChannel: float ? 32 : 16, mReserved: 0)
    var format: CMAudioFormatDescription?
    XCTAssertEqual(
      CMAudioFormatDescriptionCreate(
        allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
        magicCookie: nil, extensions: nil, formatDescriptionOut: &format), noErr)
    let bytes = frames * (float ? 4 : 2)
    var block: CMBlockBuffer?
    XCTAssertEqual(
      CMBlockBufferCreateWithMemoryBlock(
        allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
        customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0,
        blockBufferOut: &block), noErr)
    if float {
      var samples = (0..<frames).map { $0 % 2 == 0 ? amplitude : -amplitude }
      XCTAssertEqual(CMBlockBufferReplaceDataBytes(with: &samples, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes), noErr)
    } else {
      var samples = (0..<frames).map { Int16(($0 % 2 == 0 ? amplitude : -amplitude) * 32767) }
      XCTAssertEqual(CMBlockBufferReplaceDataBytes(with: &samples, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes), noErr)
    }
    var sample: CMSampleBuffer?
    XCTAssertEqual(
      CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        allocator: nil, dataBuffer: block!, formatDescription: format!, sampleCount: frames,
        presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &sample), noErr)
    return sample!
  }

  func testFloat32BufferMapsToMeterLevel() throws {
    let level = try XCTUnwrap(MediaWriter.microphoneLevel(from: pcmBuffer(float: true, amplitude: 0.5)))
    XCTAssertEqual(level, 0.88, accuracy: 0.01)  // -6 dB on a 50 dB scale
    let silent = try XCTUnwrap(MediaWriter.microphoneLevel(from: pcmBuffer(float: true, amplitude: 0)))
    XCTAssertEqual(silent, 0)
  }

  func testInt16BufferMapsToMeterLevel() throws {
    let level = try XCTUnwrap(MediaWriter.microphoneLevel(from: pcmBuffer(float: false, amplitude: 0.1)))
    XCTAssertEqual(level, 0.6, accuracy: 0.01)  // -20 dB
  }
}
