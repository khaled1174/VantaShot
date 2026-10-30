@preconcurrency import AVFoundation
import AppKit
import os
import ImageIO
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers
import VantaShotCore

enum RecordingError: LocalizedError {
  case setup(String)
  case empty
  case encoding(String)
  var errorDescription: String? {
    switch self {
    case .setup(let s), .encoding(let s): return s
    case .empty: return "No valid frame was recorded."
    }
  }
}
final class MediaWriter: NSObject, SCStreamOutput, SCStreamDelegate,
  AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable
{
  let queue = DispatchQueue(label: "dev.vantashot.writer", qos: .userInitiated)
  let url: URL
  private let writer: AVAssetWriter
  private let video: AVAssetWriterInput
  private var systemAudio: AVAssetWriterInput?
  private var microphone: AVAssetWriterInput?
  private var timeline = RecordingTimeline()
  private var started = false, finishing = false
  private var firstTimestamp: Double?
  var microphoneClock: CMClock?
  /// Called on `queue` at most ~20×/s with a 0…1 microphone level.
  var onMicrophoneLevel: ((Float) -> Void)?
  private var lastLevelReport: Double = 0
  private var loggedFormat = false
  private static let logger = Logger(subsystem: "dev.vantashot.macos", category: "Recorder")
  private var microphoneSamples = 0
  var missingMicrophone: Bool { microphone != nil && microphoneSamples == 0 }
  private(set) var frameCount = 0
  private(set) var preview: CGImage?
  var onError: ((Error) -> Void)?
  init(url: URL, width: Int, height: Int, system: Bool, mic: Bool) throws {
    self.url = url
    writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    video = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [
          AVVideoAverageBitRateKey: max(1_000_000, width * height * 3)
        ],
      ])
    video.expectsMediaDataInRealTime = true
    super.init()
    guard writer.canAdd(video) else { throw RecordingError.setup("Could not set up the video track.") }
    writer.add(video)
    func audio(channels: Int) throws -> AVAssetWriterInput {
      let i = AVAssetWriterInput(
        mediaType: .audio,
        outputSettings: [
          AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
          AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: 128000,
        ])
      i.expectsMediaDataInRealTime = true
      guard writer.canAdd(i) else { throw RecordingError.setup("Could not set up the audio track.") }
      writer.add(i)
      return i
    }
    if system { systemAudio = try audio(channels: 2) }
    if mic { microphone = try audio(channels: 1) }
    guard writer.startWriting() else {
      throw writer.error ?? RecordingError.setup("Could not create the recording file.")
    }
  }
  func pause(_ paused: Bool) {
    queue.async {
      let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
      if paused { self.timeline.pause(at: now) } else { self.timeline.resume(at: now) }
    }
  }
  func stream(_ stream: SCStream, didStopWithError error: Error) { onError?(error) }
  func stream(
    _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    if type == .screen {
      if let attachments = CMSampleBufferGetSampleAttachmentsArray(
        sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
        let status = attachments.first?[.status] as? Int, status != SCFrameStatus.complete.rawValue
      {
        return
      }
      appendVideo(sampleBuffer)
    } else if type == .audio {
      appendAudio(sampleBuffer, microphone: false)
    }
  }
  func captureOutput(
    _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard microphone != nil, let clock = microphoneClock else { return }
    reportLevel(sampleBuffer)
    let converted = CMSyncConvertTime(
      sampleBuffer.presentationTimeStamp, from: clock, to: CMClockGetHostTimeClock())
    guard converted.isValid, let aligned = Self.retime(sampleBuffer, startingAt: converted) else {
      return
    }
    appendAudio(aligned, microphone: true)
  }
  private func reportLevel(_ sample: CMSampleBuffer) {
    guard let onMicrophoneLevel else { return }
    let now = CACurrentMediaTime()
    guard now - lastLevelReport >= 0.05 else { return }
    lastLevelReport = now
    if !loggedFormat, let asbd = sample.formatDescription?.audioStreamBasicDescription {
      loggedFormat = true
      Self.logger.info(
        "mic format id=\(asbd.mFormatID, privacy: .public) flags=\(asbd.mFormatFlags, privacy: .public) bits=\(asbd.mBitsPerChannel, privacy: .public) ch=\(asbd.mChannelsPerFrame, privacy: .public)"
      )
    }
    if let level = Self.microphoneLevel(from: sample) { onMicrophoneLevel(level) }
  }
  /// 0…1 meter value for a linear-PCM sample buffer (Float32 or Int16); nil for other formats.
  static func microphoneLevel(from sample: CMSampleBuffer) -> Float? {
    guard let desc = sample.formatDescription,
      let asbd = desc.audioStreamBasicDescription,
      asbd.mFormatID == kAudioFormatLinearPCM,
      let block = sample.dataBuffer
    else { return nil }
    var length = 0
    var pointer: UnsafeMutablePointer<Int8>?
    guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
      let pointer, length > 0
    else { return nil }
    let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
    let rms: Float
    if isFloat && asbd.mBitsPerChannel == 32 {
      let count = length / MemoryLayout<Float>.size
      rms = pointer.withMemoryRebound(to: Float.self, capacity: count) {
        AudioLevelMeter.rms(UnsafeBufferPointer(start: $0, count: count))
      }
    } else if !isFloat && asbd.mBitsPerChannel == 16 {
      let count = length / MemoryLayout<Int16>.size
      var acc: Float = 0
      pointer.withMemoryRebound(to: Int16.self, capacity: count) { p in
        for i in 0..<count {
          let v = Float(p[i]) / 32768
          acc += v * v
        }
      }
      rms = count > 0 ? (acc / Float(count)).squareRoot() : 0
    } else {
      return nil
    }
    return AudioLevelMeter.level(fromRMS: rms)
  }
  func appendAudio(_ sample: CMSampleBuffer, microphone isMicrophone: Bool) {
    guard let input = isMicrophone ? microphone : systemAudio else { return }
    if isMicrophone { microphoneSamples += 1 }
    append(sample, to: input, isVideo: false)
  }
  static func retime(_ sample: CMSampleBuffer, startingAt time: CMTime) -> CMSampleBuffer? {
    var count = 0
    guard
      CMSampleBufferGetSampleTimingInfoArray(
        sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count) == noErr, count > 0
    else { return nil }
    var timing = [CMSampleTimingInfo](
      repeating: CMSampleTimingInfo(
        duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid),
      count: count)
    guard
      CMSampleBufferGetSampleTimingInfoArray(
        sample, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count) == noErr
    else { return nil }
    let delta = sample.presentationTimeStamp - time
    for i in timing.indices {
      timing[i].presentationTimeStamp = timing[i].presentationTimeStamp - delta
      if timing[i].decodeTimeStamp.isValid {
        timing[i].decodeTimeStamp = timing[i].decodeTimeStamp - delta
      }
    }
    var result: CMSampleBuffer?
    guard
      CMSampleBufferCreateCopyWithNewTiming(
        allocator: kCFAllocatorDefault, sampleBuffer: sample, sampleTimingEntryCount: count,
        sampleTimingArray: &timing, sampleBufferOut: &result) == noErr
    else { return nil }
    return result
  }
  func appendVideo(_ sample: CMSampleBuffer) { append(sample, to: video, isVideo: true) }
  private func append(_ sample: CMSampleBuffer, to input: AVAssetWriterInput, isVideo: Bool) {
    guard !finishing, sample.isValid, !timeline.isPaused else { return }
    let stamp = sample.presentationTimeStamp.seconds
    if !started {
      guard isVideo else { return }
      writer.startSession(atSourceTime: .zero)
      started = true
      firstTimestamp = stamp
    }
    guard stamp >= (firstTimestamp ?? stamp), let time = timeline.presentationTime(stamp),
      input.isReadyForMoreMediaData
    else { return }
    var count = 0
    CMSampleBufferGetSampleTimingInfoArray(
      sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
    guard count > 0 else { return }
    var timings = [CMSampleTimingInfo](
      repeating: CMSampleTimingInfo(
        duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid),
      count: count)
    CMSampleBufferGetSampleTimingInfoArray(
      sample, entryCount: count, arrayToFill: &timings, entriesNeededOut: &count)
    let delta = sample.presentationTimeStamp - CMTime(seconds: time, preferredTimescale: 60000)
    for i in timings.indices {
      timings[i].presentationTimeStamp = timings[i].presentationTimeStamp - delta
      if timings[i].decodeTimeStamp.isValid {
        timings[i].decodeTimeStamp = timings[i].decodeTimeStamp - delta
      }
    }
    var adjusted: CMSampleBuffer?
    guard
      CMSampleBufferCreateCopyWithNewTiming(
        allocator: kCFAllocatorDefault, sampleBuffer: sample, sampleTimingEntryCount: count,
        sampleTimingArray: &timings, sampleBufferOut: &adjusted) == noErr, let adjusted
    else { return }
    if !input.append(adjusted) {
      if let error = writer.error { onError?(error) }
      return
    }
    if isVideo {
      frameCount += 1
      if preview == nil, let pixel = sample.imageBuffer {
        let ci = CIImage(cvPixelBuffer: pixel)
        preview = CIContext().createCGImage(ci, from: ci.extent)
      }
    }
  }
  func finish() async throws -> (CGImage, Double) {
    try await withCheckedThrowingContinuation { continuation in
      queue.async {
        guard !self.finishing else {
          continuation.resume(throwing: CancellationError())
          return
        }
        self.finishing = true
        guard self.started, let preview = self.preview else {
          self.writer.cancelWriting()
          continuation.resume(throwing: RecordingError.empty)
          return
        }
        let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let end = self.timeline.presentationTime(now) ?? max(0, now - (self.firstTimestamp ?? now))
        self.writer.endSession(atSourceTime: CMTime(seconds: end, preferredTimescale: 60000))
        self.video.markAsFinished()
        self.systemAudio?.markAsFinished()
        self.microphone?.markAsFinished()
        self.writer.finishWriting {
          if self.writer.status == .completed {
            continuation.resume(returning: (preview, end))
          } else {
            continuation.resume(
              throwing: self.writer.error ?? RecordingError.encoding("Could not finish the video file."))
          }
        }
      }
    }
  }
  func cancel(discardCompleted: Bool = true) {
    queue.async {
      if self.writer.status == .completed && !discardCompleted { return }
      self.finishing = true
      if self.writer.status == .writing || self.writer.status == .unknown {
        self.writer.cancelWriting()
      }
      if discardCompleted || self.writer.status != .completed {
        try? FileManager.default.removeItem(at: self.url)
      }
    }
  }
}
@MainActor public final class LiveScreenRecorderController: ObservableObject {
  public static let shared = LiveScreenRecorderController()
  private static let recorderLogger = Logger(subsystem: "dev.vantashot.macos", category: "Recorder")
  @Published public private(set) var isRecording = false
  @Published private(set) var isPaused = false
  @Published private(set) var isStarting = false
  private var audioObservers: [NSObjectProtocol] = []
  private var completedSource: MediaAsset?
  private var failureWarning: String?
  @Published private(set) var elapsedSeconds = 0
  @Published private(set) var microphoneLevel: Float = 0
  @Published private(set) var status = "Preparing…"
  public var onCancel: (() -> Void)?
  var onPauseChanged: ((Bool) -> Void)?
  private var writer: MediaWriter?
  private var stream: SCStream?
  private var microphoneSession: AVCaptureSession?
  // AVCaptureSession start/stop are serialized; sample callbacks are confined to MediaWriter.queue.
  private let microphoneQueue = DispatchQueue(label: "dev.vantashot.microphone")
  private func startMicrophone(_ session: AVCaptureSession) async {
    await withCheckedContinuation { c in
      microphoneQueue.async {
        session.startRunning()
        c.resume()
      }
    }
  }
  private func stopMicrophone(_ session: AVCaptureSession) async {
    await withCheckedContinuation { c in
      microphoneQueue.async {
        session.stopRunning()
        c.resume()
      }
    }
  }
  private var hud: NSPanel?
  private let regionFrame = RegionFrameWindow()
  private var recordedRegion: CGRect = .zero
  private var setupWindow: RecordingSetupWindow?
  private var timer: Timer?
  private var work: Task<Void, Never>?
  private var generation = UUID()
  private var completion: ((MediaAsset) -> Void)?
  private var format = "mp4"
  private var size = PixelSize(width: 0, height: 0)
  public func startRecording(
    rectInAppKit rect: CGRect, expectedTarget: DisplayCaptureTarget? = nil,
    onComplete: @escaping (MediaAsset) -> Void
  ) {
    guard !isRecording, !isStarting, setupWindow == nil else { return }
    recordedRegion = rect
    regionFrame.show(around: rect, style: .setup)
    let size = RecordingSetupView.size
    let visible =
      NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) })?
      .visibleFrame ?? NSScreen.main?.visibleFrame ?? rect
    let window = RecordingSetupWindow(
      contentRect: RecordingCapsuleLayout.frame(region: rect, visibleFrame: visible, size: size),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = true
    window.isMovableByWindowBackground = true
    window.level = .floating
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    window.onCancel = { [weak self] in self?.cancel() }
    window.contentView = NSHostingView(
      rootView: RecordingSetupView(
        region: rect,
        onStart: { [weak self] in
          guard let self, self.setupWindow != nil else { return }
          let format = AppSettings.shared.recordFormat
          self.setupWindow?.orderOut(nil)
          self.setupWindow = nil
          self.runCountdownThenRecord(
            rectInAppKit: rect, expectedTarget: expectedTarget, format: format,
            onComplete: onComplete)
        }, onCancel: { [weak self] in self?.cancel() }))
    setupWindow = window
    VantaPanelMotion.present(window, from: CGPoint(x: 0, y: -12))
    window.makeKey()
  }
  private func runCountdownThenRecord(
    rectInAppKit rect: CGRect, expectedTarget: DisplayCaptureTarget?, format: String,
    onComplete: @escaping (MediaAsset) -> Void
  ) {
    let steps = CountdownSequence.steps(from: AppSettings.shared.recordCountdownSeconds)
    guard !steps.isEmpty else {
      beginRecording(
        rectInAppKit: rect, expectedTarget: expectedTarget, format: format, onComplete: onComplete)
      return
    }
    generation = UUID()
    let id = generation
    isStarting = true
    status = "Recording starts in a moment…"
    work = Task { [self] in
      for step in steps {
        guard generation == id, !Task.isCancelled else { return }
        CountdownOverlay.shared.show(step: step, region: rect)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
      }
      guard generation == id, !Task.isCancelled else { return }
      CountdownOverlay.shared.hide()
      isStarting = false
      beginRecording(
        rectInAppKit: rect, expectedTarget: expectedTarget, format: format, onComplete: onComplete)
    }
  }
  private func beginRecording(
    rectInAppKit rect: CGRect, expectedTarget: DisplayCaptureTarget?, format: String,
    onComplete: @escaping (MediaAsset) -> Void
  ) {
    generation = UUID()
    completedSource = nil
    failureWarning = nil
    isStarting = true
    showControls()
    let id = generation
    completion = onComplete
    self.format = format
    elapsedSeconds = 0
    status = "Preparing…"
    isPaused = false
    work = Task { [self] in
      do {
        let mic = AppSettings.shared.microphone && format != "gif"
        let system = AppSettings.shared.systemAudio && format != "gif"
        if mic {
          guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw RecordingError.setup(
              "Microphone permission was not granted. Turn the microphone off to record the screen without it.")
          }
        }
        RecordingDecorations.shared.prepare(region: rect)
        if !RecordingDecorations.shared.windowIDs.isEmpty {
          // Freshly ordered-front windows take a moment to be reported on screen by the window server.
          try await Task.sleep(nanoseconds: 250_000_000)
        }
        let content = try await ScreenCaptureProvider.shareableContent()
        try Task.checkCancellation()
        guard generation == id else { return }
        let (_, config) = try ScreenCaptureProvider.configuration(
          rect: rect, content: content, expectedTarget: expectedTarget)
        guard
          let screen = NSScreen.screens.first(where: {
            $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY))
          }),
          let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            as? NSNumber,
          let display = content.displays.first(where: { $0.displayID == number.uint32Value })
        else { throw CaptureError.noDisplay }
        let own = content.applications.filter {
          $0.processID == ProcessInfo.processInfo.processIdentifier
        }
        let keptWindows = DesktopIconsCoverManager.shared.coverWindowIDs.union(
          RecordingDecorations.shared.windowIDs)
        let ownWindows = content.windows.filter {
          $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
        }
        let excepted = content.windows.filter { keptWindows.contains($0.windowID) }
        Self.recorderLogger.info(
          "filter: wanted=\(keptWindows.sorted().map(String.init).joined(separator: ","), privacy: .public) own=\(ownWindows.map { "\($0.windowID):\($0.isOnScreen)" }.joined(separator: ","), privacy: .public) excepted=\(excepted.count, privacy: .public)"
        )
        let filter = SCContentFilter(
          display: display, excludingApplications: own, exceptingWindows: excepted)
        config.width = max(2, config.width / 2 * 2)
        config.height = max(2, config.height / 2 * 2)
        size = PixelSize(width: config.width, height: config.height)
        config.showsCursor = AppSettings.shared.captureCursor
        config.minimumFrameInterval = CMTime(value: 1, timescale: format == "gif" ? 5 : 30)
        config.capturesAudio = system
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        config.queueDepth = 5
        try FileManager.default.createDirectory(
          at: AssetFiles.temporary, withIntermediateDirectories: true)
        let url = AssetFiles.temporary.appendingPathComponent("VantaShot-\(UUID()).mp4")
        let w = try MediaWriter(
          url: url, width: config.width, height: config.height, system: system, mic: mic)
        w.onMicrophoneLevel = { [weak self] level in
          Task { @MainActor in
            guard let self, self.generation == id else { return }
            self.microphoneLevel = level
          }
        }
        w.onError = { [weak self] error in
          Task { @MainActor in
            guard let self, self.generation == id else { return }
            self.fail(error)
          }
        }
        let s = SCStream(filter: filter, configuration: config, delegate: w)
        try s.addStreamOutput(w, type: .screen, sampleHandlerQueue: w.queue)
        if system { try s.addStreamOutput(w, type: .audio, sampleHandlerQueue: w.queue) }
        writer = w
        stream = s
        if mic {
          let session = AVCaptureSession()
          guard let device = AVCaptureDevice.default(for: .audio) else {
            throw RecordingError.setup("No microphone is available.")
          }
          let input = try AVCaptureDeviceInput(device: device)
          let output = AVCaptureAudioDataOutput()
          guard session.canAddInput(input), session.canAddOutput(output) else {
            throw RecordingError.setup("The microphone is unavailable.")
          }
          session.addInput(input)
          session.addOutput(output)
          output.setSampleBufferDelegate(w, queue: w.queue)
          microphoneSession = session
          for name in [
            AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification,
            AVCaptureSession.didStopRunningNotification,
          ] {
            audioObservers.append(
              NotificationCenter.default.addObserver(forName: name, object: session, queue: .main) {
                [weak self] notification in
                Task { @MainActor in
                  guard let self, self.generation == id else { return }
                  self.audioFailed(
                    "The microphone stopped or could not start. Recording stopped so the available part could be saved.")
                }
              })
          }
          audioObservers.append(
            NotificationCenter.default.addObserver(
              forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: .main
            ) { [weak self] _ in
              Task { @MainActor in
                guard let self, self.generation == id else { return }
                self.audioFailed("The microphone disconnected. Recording stopped so the available part could be saved.")
              }
            })
          await startMicrophone(session)
          guard session.isRunning, let clock = session.synchronizationClock else {
            throw RecordingError.setup("Could not start the microphone. Recording did not start.")
          }
          w.queue.sync { w.microphoneClock = clock }
          try Task.checkCancellation()
        }
        try await s.startCapture()
        guard generation == id, !Task.isCancelled else {
          try? await s.stopCapture()
          w.cancel()
          return
        }
        isStarting = false
        isRecording = true
        regionFrame.show(around: rect, style: .recording)
        status = "Recording \(format.uppercased())"
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
          Task { @MainActor in
            guard let self, self.isRecording, !self.isPaused else { return }
            self.elapsedSeconds += 1
          }
        }
      } catch {
        guard generation == id else { return }
        fail(error)
      }
    }
  }
  private func showControls() {
    hud?.orderOut(nil)
    let size = RecordingControlPillView.size
    let visible =
      NSScreen.screens.first(where: {
        $0.frame.contains(CGPoint(x: recordedRegion.midX, y: recordedRegion.midY))
      })?.visibleFrame ?? NSScreen.main?.visibleFrame ?? recordedRegion
    let p = NSPanel(
      contentRect: RecordingCapsuleLayout.frame(
        region: recordedRegion, visibleFrame: visible, size: size),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    p.isReleasedWhenClosed = false
    p.hidesOnDeactivate = false
    p.isOpaque = false
    p.backgroundColor = .clear
    p.hasShadow = true
    p.isMovableByWindowBackground = true
    p.level = .floating
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    p.contentView = NSHostingView(rootView: RecordingControlPillView(recorder: self))
    hud = p
    VantaPanelMotion.present(p, from: CGPoint(x: 0, y: 12))
  }
  func togglePause() {
    guard isRecording else { return }
    isPaused.toggle()
    writer?.pause(isPaused)
    onPauseChanged?(isPaused)
  }
  public func stopAndSaveGIF() {
    if isStarting || setupWindow != nil {
      cancel()
      return
    }
    guard isRecording, let writer, let stream else { return }
    if isPaused {
      isPaused = false
      writer.pause(false)
    }
    isRecording = false
    timer?.invalidate()
    timer = nil
    status = "Saving the file…"
    let id = generation
    let callback = completion
    let format = self.format
    let size = self.size
    work = Task { [self] in
      do {
        removeAudioObservers()
        try await stream.stopCapture()
        if let mic = microphoneSession { await stopMicrophone(mic) }
        let (preview, duration) = try await writer.finish()
        guard generation == id, !Task.isCancelled else { return }
        completedSource = MediaAsset(
          kind: .video, title: "Recoverable MP4 recording", fileURL: writer.url, pixelSize: size,
          duration: duration)
        if writer.queue.sync(execute: { writer.missingMicrophone }) {
          failureWarning = "No microphone data arrived. The file contains only the available part."
        }
        let png = try AssetFiles.makeImage(
          NSImage(cgImage: preview, size: NSSize(width: preview.width, height: preview.height)),
          title: "Preview"
        ).fileURL
        let output: URL
        if format == "gif" {
          output = try await GIFExportService.export(video: writer.url, duration: duration)
          try? FileManager.default.removeItem(at: writer.url)
        } else {
          output = try await AudioMixService.mixIfNeeded(writer.url)
          if output != writer.url { try? FileManager.default.removeItem(at: writer.url) }
        }
        guard generation == id, !Task.isCancelled else {
          try? FileManager.default.removeItem(at: output)
          try? FileManager.default.removeItem(at: png)
          return
        }
        let warning = failureWarning
        cleanup()
        completedSource = nil
        if let warning {
          ToastBannerHUD.shared.show(message: warning, icon: "exclamationmark.triangle")
        }

        completion = nil
        callback?(
          MediaAsset(
            kind: format == "gif" ? .animatedImage : .video,
            title: warning.map { "Recording — \($0)" } ?? "Recording \(format.uppercased())",
            fileURL: output, previewURL: png, pixelSize: size, duration: duration))
      } catch {
        guard generation == id else { return }
        fail(error)
      }
    }
  }
  public func cancel() {
    removeAudioObservers()
    generation = UUID()
    work?.cancel()
    if let s = stream { Task { try? await s.stopCapture() } }
    if let mic = microphoneSession { microphoneQueue.async { mic.stopRunning() } }
    writer?.cancel()
    cleanup()
    completion = nil
    onCancel?()
  }
  private func audioFailed(_ message: String) {
    failureWarning = message
    AssetFiles.showError(RecordingError.setup(message))
    if isRecording { stopAndSaveGIF() } else { cancel() }
  }
  private func removeAudioObservers() {
    for observer in audioObservers { NotificationCenter.default.removeObserver(observer) }
    audioObservers = []
  }
  private func fail(_ error: Error) {
    AssetFiles.showError(error)
    if var recovery = completedSource {
      recovery.title = "Recovered MP4 file — export could not be finished"
      writer?.cancel(discardCompleted: false)
      let callback = completion
      removeAudioObservers()
      cleanup()
      completedSource = nil
      completion = nil
      callback?(recovery)
    } else {
      cancel()
    }
  }
  private func cleanup() {
    CountdownOverlay.shared.hide()
    RecordingDecorations.shared.stop()
    regionFrame.hide()
    setupWindow?.orderOut(nil)
    setupWindow = nil
    timer?.invalidate()
    timer = nil
    hud?.orderOut(nil)
    hud = nil
    isRecording = false
    isStarting = false
    stream = nil
    writer = nil
    microphoneSession = nil
    isPaused = false
    microphoneLevel = 0
  }
}
private final class RecordingSetupWindow: NSPanel {
  var onCancel: (() -> Void)?
  override var canBecomeKey: Bool { true }
  override func close() { onCancel?() }
  override func cancelOperation(_ sender: Any?) { onCancel?() }
}
private struct RecordingSetupView: View {
  static let size = CGSize(width: 440, height: 232)
  @ObservedObject private var settings = AppSettings.shared
  let region: CGRect
  let onStart: () -> Void
  let onCancel: () -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Image(systemName: "record.circle").foregroundStyle(VantaTheme.Palette.danger)
        Text("Record Area").font(VantaTheme.Font.title)
        Spacer()
        Text("\(Int(region.width)) × \(Int(region.height)) pt")
          .font(VantaTheme.Font.number).foregroundStyle(VantaTheme.Palette.textSecondary)
      }
      HStack(spacing: 8) {
        VantaIconButton(
          title: "MP4 Video", icon: "film", isSelected: settings.recordFormat == "mp4", compact: true
        ) { settings.recordFormat = "mp4" }
        VantaIconButton(
          title: "Animated GIF", icon: "photo.stack", isSelected: settings.recordFormat == "gif",
          compact: true
        ) { settings.recordFormat = "gif" }
        Spacer()
        Stepper(
          settings.recordCountdownSeconds == 0
            ? "No countdown" : "\(settings.recordCountdownSeconds)s countdown",
          value: $settings.recordCountdownSeconds, in: 0...10
        ).font(VantaTheme.Font.label)
      }
      HStack(spacing: 16) {
        Toggle("System audio", isOn: $settings.systemAudio).disabled(settings.recordFormat == "gif")
        Toggle("Microphone", isOn: $settings.microphone).disabled(settings.recordFormat == "gif")
        Toggle("Pointer", isOn: $settings.captureCursor)
      }
      .toggleStyle(.switch).controlSize(.small).font(VantaTheme.Font.label)
      HStack(spacing: 16) {
        Toggle("Pointer highlight", isOn: $settings.highlightCursor)
        Toggle("Keystrokes", isOn: $settings.showKeystrokes)
        Spacer()
      }
      .toggleStyle(.switch).controlSize(.small).font(VantaTheme.Font.label)
      if settings.recordFormat == "gif" {
        Text("The GIF is saved without audio.").font(VantaTheme.Font.caption)
          .foregroundStyle(VantaTheme.Palette.textSecondary)
      }
      HStack {
        VantaIconButton(title: "Cancel", icon: "xmark", shortcut: "Esc", role: .destructive, compact: true, action: onCancel)
        Spacer()
        VantaIconButton(
          title: settings.recordFormat == "gif" ? "Start GIF Recording" : "Start Recording", icon: "record.circle.fill",
          shortcut: "⏎", role: .prominent, compact: true, action: onStart)
      }
    }
    .padding(16)
    .frame(width: Self.size.width, height: Self.size.height)
    .vantaGlassCard(radius: VantaTheme.Radius.large, shadow: false)
    .foregroundStyle(VantaTheme.Palette.text)
    .preferredColorScheme(.dark)
    .environment(\.layoutDirection, .leftToRight)
    .background(KeyEquivalentCatcher(onReturn: onStart, onEscape: onCancel))
  }
}
/// Routes ⏎ / Esc to the setup actions without relying on default-button chrome.
struct KeyEquivalentCatcher: NSViewRepresentable {
  let onReturn: () -> Void
  let onEscape: () -> Void
  func makeNSView(context: Context) -> KeyCatcherView {
    let v = KeyCatcherView()
    v.onReturn = onReturn
    v.onEscape = onEscape
    return v
  }
  func updateNSView(_ v: KeyCatcherView, context: Context) {
    v.onReturn = onReturn
    v.onEscape = onEscape
  }
  final class KeyCatcherView: NSView {
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?
    private var monitor: Any?
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
      guard window != nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
        guard let self, e.window === self.window else { return e }
        switch e.keyCode {
        case 36, 76:
          self.onReturn?()
          return nil
        case 53:
          self.onEscape?()
          return nil
        default: return e
        }
      }
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
  }
}
struct RecordingControlPillView: View {
  static let size = CGSize(width: 450, height: 50)
  @ObservedObject var recorder: LiveScreenRecorderController
  @ObservedObject private var settings = AppSettings.shared
  @State private var pulsing = false
  var body: some View {
    HStack(spacing: 10) {
      Circle()
        .fill(recorder.isPaused ? VantaTheme.Palette.warning : VantaTheme.Palette.danger)
        .frame(width: 10, height: 10)
        .scaleEffect(pulsing && recorder.isRecording && !recorder.isPaused ? 0.7 : 1)
        .animation(VantaTheme.Motion.pulse, value: pulsing)
        .onAppear { pulsing = true }
      Text(String(format: "%02d:%02d", recorder.elapsedSeconds / 60, recorder.elapsedSeconds % 60))
      .font(.system(size: 15, weight: .semibold, design: .monospaced))
      Text(recorder.isPaused ? "Paused" : recorder.status).font(VantaTheme.Font.caption)
        .foregroundStyle(VantaTheme.Palette.textSecondary).lineLimit(1).truncationMode(.tail)
        .layoutPriority(-1)
      if settings.microphone && settings.recordFormat != "gif" {
        MicrophoneLevelView(level: recorder.microphoneLevel)
          .help("Microphone level")
      }
      Spacer(minLength: 4)
      PillButton(icon: recorder.isPaused ? "play.fill" : "pause.fill", help: recorder.isPaused ? "Resume" : "Pause") {
        recorder.togglePause()
      }.disabled(!recorder.isRecording)
      Button {
        recorder.stopAndSaveGIF()
      } label: {
        HStack(spacing: 5) {
          Image(systemName: "stop.fill")
          Text("Stop and Save").font(VantaTheme.Font.label)
        }
        .fixedSize()
        .foregroundStyle(VantaTheme.Palette.accentText)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Capsule().fill(VantaTheme.Palette.accentGradient))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.45), lineWidth: 1))
        .shadow(color: VantaTheme.Palette.accent.opacity(0.30), radius: 8, y: 2)
      }
      .buttonStyle(.plain)
      .disabled(!recorder.isRecording && !recorder.isStarting)
      .help("Stop recording and save")
      PillButton(icon: "xmark", help: "Cancel recording (Esc)") { recorder.cancel() }
    }
    .padding(.horizontal, 14).padding(.vertical, 8)
    .frame(width: Self.size.width, height: Self.size.height)
    .vantaGlassCard(radius: Self.size.height / 2, shadow: false)
    .foregroundStyle(VantaTheme.Palette.text)
    .preferredColorScheme(.dark)
    .environment(\.layoutDirection, .leftToRight)
  }
}
struct MicrophoneLevelView: View {
  let level: Float
  private let bars = 5
  var body: some View {
    HStack(spacing: 2) {
      Image(systemName: "mic.fill").font(.system(size: 10))
        .foregroundStyle(level > 0.02 ? VantaTheme.Palette.accent : VantaTheme.Palette.textSecondary)
      let lit = AudioLevelMeter.litBars(level: level, count: bars)
      ForEach(0..<bars, id: \.self) { i in
        RoundedRectangle(cornerRadius: 1, style: .continuous)
          .fill(i < lit ? (i >= bars - 1 ? VantaTheme.Palette.danger : VantaTheme.Palette.success) : VantaTheme.Palette.fillHover)
          .frame(width: 3, height: 6 + CGFloat(i) * 2)
      }
    }
    .animation(.linear(duration: 0.05), value: level)
    .accessibilityLabel("Microphone level")
    .accessibilityValue("\(Int(level * 100)) percent")
  }
}
struct PillButton: View {
  let icon: String
  let help: String
  let action: () -> Void
  @State private var hovering = false
  var body: some View {
    Button(action: action) {
      Image(systemName: icon).font(.system(size: 12, weight: .semibold))
        .frame(width: 30, height: 30)
        .background(
          Circle().fill(
            hovering
              ? VantaTheme.Palette.surfaceHoverGradient
              : VantaTheme.Palette.surfaceGradient)
        )
        .overlay(
          Circle().strokeBorder(
            hovering
              ? AnyShapeStyle(VantaTheme.Palette.accent.opacity(0.55))
              : AnyShapeStyle(VantaTheme.Palette.surfaceRim),
            lineWidth: 1)
        )
        .scaleEffect(hovering ? 1.05 : 1)
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .animation(VantaTheme.Motion.fade, value: hovering)
    .help(help)
  }
}
enum GIFExportService {
  static func export(video: URL, duration: Double) async throws -> URL {
    try Task.checkCancellation()
    let worker = Task.detached(priority: .userInitiated) {
      let url = video.deletingLastPathComponent().appendingPathComponent("VantaShot-\(UUID()).gif")
      let asset = AVURLAsset(url: video)
      let generator = AVAssetImageGenerator(asset: asset)
      generator.appliesPreferredTrackTransform = true
      generator.maximumSize = CGSize(width: 1280, height: 1280)
      generator.requestedTimeToleranceBefore = .zero
      generator.requestedTimeToleranceAfter = .zero
      let count = max(1, Int(ceil(duration * 5)))
      guard
        let dest = CGImageDestinationCreateWithURL(
          url as CFURL, UTType.gif.identifier as CFString, count, nil)
      else { throw RecordingError.encoding("Could not create the GIF.") }
      var successful = false
      defer { if !successful { try? FileManager.default.removeItem(at: url) } }
      CGImageDestinationSetProperties(
        dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
      for i in 0..<count {
        try Task.checkCancellation()
        let cg = try generator.copyCGImage(
          at: CMTime(
            seconds: min(Double(i) / 5, max(0, duration - 0.001)), preferredTimescale: 60000),
          actualTime: nil)
        CGImageDestinationAddImage(
          dest, cg,
          [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]] as CFDictionary)
      }
      try Task.checkCancellation()
      guard CGImageDestinationFinalize(dest) else { throw RecordingError.encoding("Could not finish the GIF.") }
      successful = true
      return url
    }
    return try await withTaskCancellationHandler(
      operation: { try await worker.value }, onCancel: { worker.cancel() })
  }
}
