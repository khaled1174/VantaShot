import AVFoundation
import Foundation

enum AudioMixService {
  /// Align inputs on the host timeline first; export multiple requested sources into one audible track.
  static func mixIfNeeded(_ sourceURL: URL) async throws -> URL {
    let source = AVURLAsset(url: sourceURL)
    let audio = try await source.loadTracks(withMediaType: .audio)
    guard audio.count > 1 else { return sourceURL }
    let duration = try await source.load(.duration)
    let composition = AVMutableComposition()
    for track in try await source.loadTracks(withMediaType: .video) {
      guard
        let dest = composition.addMutableTrack(
          withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
      else { throw RecordingError.encoding("تعذر تركيب الفيديو") }
      try dest.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
      dest.preferredTransform = try await track.load(.preferredTransform)
    }
    var parameters: [AVAudioMixInputParameters] = []
    for track in audio {
      guard
        let dest = composition.addMutableTrack(
          withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
      else { throw RecordingError.encoding("تعذر مزج الصوت") }
      let range = CMTimeRangeGetIntersection(
        CMTimeRange(start: .zero, duration: duration), otherRange: try await track.load(.timeRange))
      if range.duration > CMTime.zero {
        try dest.insertTimeRange(range, of: track, at: range.start)
      }
      let p = AVMutableAudioMixInputParameters(track: dest)
      p.setVolume(0.8, at: .zero)
      parameters.append(p)
    }
    let mix = AVMutableAudioMix()
    mix.inputParameters = parameters
    guard
      let export = AVAssetExportSession(
        asset: composition, presetName: AVAssetExportPresetHighestQuality)
    else { throw RecordingError.encoding("تعذر إنشاء مخرج الصوت") }
    let output = sourceURL.deletingLastPathComponent().appendingPathComponent(
      "VantaShot-\(UUID()).mp4")
    export.outputURL = output
    export.outputFileType = .mp4
    export.audioMix = mix
    var success = false
    defer { if !success { try? FileManager.default.removeItem(at: output) } }
    await withTaskCancellationHandler(
      operation: {
        await withCheckedContinuation { c in export.exportAsynchronously { c.resume() } }
      }, onCancel: { export.cancelExport() })
    try Task.checkCancellation()
    guard export.status == .completed else {
      throw export.error ?? RecordingError.encoding("تعذر إنهاء مزج الصوت")
    }
    success = true
    return output
  }
}
