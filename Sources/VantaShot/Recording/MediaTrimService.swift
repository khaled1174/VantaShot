import AVKit
import AppKit
import SwiftUI
import VantaShotCore

@MainActor final class MediaTrimService {
  static let shared = MediaTrimService()
  private var windows: [NSWindow] = []
  func show(_ asset: MediaAsset) {
    let w = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    w.isReleasedWhenClosed = false
    w.title = "معاينة وقص التسجيل"
    w.contentView = NSHostingView(rootView: MediaTrimView(asset: asset))
    w.center()
    w.makeKeyAndOrderFront(nil)
    windows.append(w)
  }
  static func trim(_ asset: MediaAsset, start: Double, end: Double) async throws -> MediaAsset {
    let source = AVURLAsset(url: asset.fileURL)
    let duration = try await source.load(.duration).seconds
    guard start >= 0, end > start, end <= duration + 0.05,
      let export = AVAssetExportSession(
        asset: source, presetName: AVAssetExportPresetHighestQuality)
    else { throw StorageError.invalidData }
    let out = AssetFiles.temporary.appendingPathComponent("VantaShot-\(UUID()).mp4")
    export.outputURL = out
    export.outputFileType = .mp4
    export.timeRange = CMTimeRange(
      start: CMTime(seconds: start, preferredTimescale: 600),
      end: CMTime(seconds: end, preferredTimescale: 600))
    await withCheckedContinuation { c in export.exportAsynchronously { c.resume() } }
    guard export.status == .completed else { throw export.error ?? StorageError.invalidData }
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: out))
    generator.appliesPreferredTrackTransform = true
    let image = try generator.copyCGImage(at: .zero, actualTime: nil)
    let preview = try AssetFiles.makeImage(
      NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)),
      title: "معاينة القص"
    ).fileURL
    return MediaAsset(
      kind: .video, title: "تسجيل مقصوص", fileURL: out, previewURL: preview,
      pixelSize: asset.pixelSize, duration: end - start)
  }
}
struct MediaTrimView: View {
  let asset: MediaAsset
  @State private var player: AVPlayer?
  @State private var start = 0.0
  @State private var end = 1.0
  @State private var busy = false
  @State private var error: String?
  var body: some View {
    VStack(spacing: 14) {
      VideoPlayer(player: player).frame(minHeight: 300)
      HStack {
        Text("من (ث)")
        TextField("البداية", value: $start, format: .number).frame(width: 70)
        Text("إلى (ث)")
        TextField("النهاية", value: $end, format: .number).frame(width: 70)
        Button("حفظ نسخة مقصوصة") {
          busy = true
          Task {
            do {
              let result = try await MediaTrimService.trim(asset, start: start, end: end)
              CleanWorkflowCoordinator.shared.addExternalAsset(result)
              error = nil
            } catch { self.error = error.localizedDescription }
            busy = false
          }
        }.disabled(busy)
      }
      if busy { ProgressView("جارٍ التصدير…") }
      if let error { Text(error).foregroundStyle(.red) }
    }.frame(minWidth: 600, minHeight: 420).padding(16).onAppear {
      player = AVPlayer(url: asset.fileURL)
      end = asset.duration ?? 1
    }.onDisappear { player?.pause() }.environment(\.layoutDirection, .rightToLeft)
  }
}
