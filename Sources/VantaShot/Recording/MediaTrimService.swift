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
      styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered,
      defer: false)
    w.isReleasedWhenClosed = false
    w.title = "Preview and Trim Recording"
    VantaWindowGlass.configure(w)
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
      title: "Trim preview"
    ).fileURL
    return MediaAsset(
      kind: .video, title: "Trimmed recording", fileURL: out, previewURL: preview,
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
      HStack {
        Label(asset.title, systemImage: "scissors")
          .font(VantaTheme.Font.title)
          .lineLimit(1)
        Spacer()
        if let duration = asset.duration {
          Text("\(String(format: "%.1f", duration)) s")
            .font(VantaTheme.Font.number)
            .foregroundStyle(VantaTheme.Palette.textSecondary)
        }
      }
      VideoPlayer(player: player)
        .frame(minHeight: 300)
        .clipShape(RoundedRectangle(cornerRadius: VantaTheme.Radius.medium, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: VantaTheme.Radius.medium, style: .continuous)
            .strokeBorder(VantaTheme.Palette.surfaceRim, lineWidth: 1)
        )
      HStack(spacing: 12) {
        HStack(spacing: 6) {
          Text("From (s)").font(VantaTheme.Font.label)
            .foregroundStyle(VantaTheme.Palette.textSecondary)
          TextField("Start", value: $start, format: .number)
            .textFieldStyle(.roundedBorder)
            .frame(width: 76)
        }
        HStack(spacing: 6) {
          Text("To (s)").font(VantaTheme.Font.label)
            .foregroundStyle(VantaTheme.Palette.textSecondary)
          TextField("End", value: $end, format: .number)
            .textFieldStyle(.roundedBorder)
            .frame(width: 76)
        }
        Spacer()
        if busy {
          ProgressView().controlSize(.small)
        }
        VantaIconButton(
          title: "Save Trimmed Copy",
          icon: "scissors",
          role: .prominent,
          compact: true
        ) {
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
      .padding(12)
      .vantaSurfaceCard(radius: VantaTheme.Radius.medium)
      if let error {
        Text(error).font(VantaTheme.Font.caption).foregroundStyle(VantaTheme.Palette.danger)
      }
    }
    .frame(minWidth: 600, minHeight: 420)
    .padding(18)
    .padding(.top, 16)
    .vantaWindowBackground()
    .foregroundStyle(VantaTheme.Palette.text)
    .preferredColorScheme(.dark)
    .onAppear {
      player = AVPlayer(url: asset.fileURL)
      end = asset.duration ?? 1
    }
    .onDisappear { player?.pause() }
    .environment(\.layoutDirection, .leftToRight)
  }
}
