import AppKit
import SwiftUI
import VantaShotCore

@MainActor enum AssetFiles {
  static let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
    .first!.appendingPathComponent("VantaShot", isDirectory: true)
  static let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
    "VantaShotDrops", isDirectory: true)
  static func cleanupTemporary() {
    let fm = FileManager.default
    let protected = NSPasteboard.general.string(forType: .fileURL).flatMap { URL(string: $0) }?
      .standardizedFileURL
    guard
      let files = try? fm.contentsOfDirectory(
        at: temporary, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])
    else { return }
    for file in files where file.standardizedFileURL != protected {
      if let v = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]
      ), v.isRegularFile == true, let date = v.contentModificationDate,
        Date().timeIntervalSince(date) > 7 * 86400
      {
        try? fm.removeItem(at: file)
      }
    }
  }
  static func removeTransientOriginal(_ asset: MediaAsset, stored: MediaAsset) {
    let protected = NSPasteboard.general.string(forType: .fileURL).flatMap { URL(string: $0) }?
      .standardizedFileURL
    for (input, output) in [(asset.fileURL, stored.fileURL), (asset.previewURL, stored.previewURL)]
    {
      guard let input, let output, input.standardizedFileURL != output.standardizedFileURL,
        input.standardizedFileURL != protected,
        input.standardizedFileURL.path.hasPrefix(temporary.standardizedFileURL.path + "/")
      else { continue }
      try? FileManager.default.removeItem(at: input)
    }
  }
  static func png(_ image: NSImage) throws -> Data {
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
      let d = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    else { throw StorageError.invalidData }
    return d
  }
  static func makeImage(_ image: NSImage, title: String) throws -> MediaAsset {
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      throw StorageError.invalidData
    }
    let url = try MediaExportService().write(png(image), extension: "png", directory: temporary)
    return MediaAsset(
      kind: .stillImage, title: title, fileURL: url,
      pixelSize: PixelSize(width: cg.width, height: cg.height))
  }
  static func preview(_ asset: MediaAsset) -> NSImage? {
    NSImage(contentsOf: asset.previewURL ?? asset.fileURL)
  }
  @discardableResult static func copy(_ asset: MediaAsset) throws -> Bool {
    guard FileManager.default.fileExists(atPath: asset.fileURL.path) else {
      throw StorageError.missingFile
    }
    let clipboardFile = try MediaExportService().export(asset, to: temporary)
    let item: NSPasteboardItem
    if asset.kind == .stillImage, let image = preview(asset) {
      item = AppKitDraggableImageView.makeSinglePasteboardItem(for: image, fileURL: clipboardFile)
    } else {
      item = AppKitDraggableImageView.filePasteboardItem(clipboardFile)
    }
    let p = NSPasteboard.general
    p.clearContents()
    guard p.writeObjects([item]) else { throw StorageError.invalidData }
    ToastBannerHUD.shared.show(
      message: "Copied",
      subtitle: asset.kind == .stillImage ? "One image is ready to paste." : "The original recording is ready to paste."
    )
    return true
  }
  @discardableResult static func save(_ asset: MediaAsset) throws -> URL {
    let url: URL
    if asset.kind == .stillImage, AppSettings.shared.imageFormat == "jpg",
      let image = preview(asset),
      let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
      let jpeg = NSBitmapImageRep(cgImage: cg).representation(
        using: .jpeg, properties: [.compressionFactor: AppSettings.shared.jpegQuality])
    {
      url = try MediaExportService().write(
        jpeg, extension: "jpg", directory: AppSettings.shared.outputDirectory)
    } else {
      url = try MediaExportService().export(asset, to: AppSettings.shared.outputDirectory)
    }
    ToastBannerHUD.shared.show(message: "File saved", subtitle: url.lastPathComponent)
    return url
  }
  static func showError(_ error: Error) {
    if let capture = error as? CaptureError, capture == .permissionDenied {
      ToastBannerHUD.shared.show(
        message: "Screen Recording blocked this capture.",
        subtitle: "Turn VantaShot on in Screen & System Audio Recording. If it is already on, quit the app and open it once.",
        icon: "exclamationmark.triangle",
        duration: 6)
      return
    }
    ToastBannerHUD.shared.show(
      message: error.localizedDescription, icon: "exclamationmark.triangle")
  }
}
@MainActor public final class QuickAccessPopupController: ObservableObject {
  public static let shared = QuickAccessPopupController()
  static let cardSize = CGSize(width: 324, height: 268)
  private struct Card {
    let panel: NSPanel
    let asset: MediaAsset
  }
  private var cards: [Card] = []
  private(set) var lastCapturedAsset: MediaAsset?
  public var lastCapturedImage: NSImage? { lastCapturedAsset.flatMap { AssetFiles.preview($0) } }
  public var lastCapturedTitle: String { lastCapturedAsset?.title ?? "" }
  public var visibleCardCount: Int { cards.count }

  func present(asset: MediaAsset) {
    lastCapturedAsset = asset
    if let existing = cards.first(where: { $0.asset.id == asset.id }) {
      remove(existing.panel, animated: false)
    }
    showAfterCapture()
    guard
      let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
        ?? NSScreen.main
    else { return }
    // Keep earlier cards. Drop the oldest only when the screen has no room left;
    // it stays in History.
    let capacity = QuickAccessCardLayout.capacity(
      cardSize: Self.cardSize, visibleFrame: screen.visibleFrame)
    while cards.count >= capacity, let oldest = cards.first {
      remove(oldest.panel, animated: true)
    }
    let frame = QuickAccessCardLayout.frame(
      index: cards.count, cardSize: Self.cardSize, visibleFrame: screen.visibleFrame)
    let p = NSPanel(
      contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)
    p.isReleasedWhenClosed = false
    p.hidesOnDeactivate = false
    p.level = .floating
    p.isOpaque = false
    p.backgroundColor = .clear
    p.hasShadow = true
    p.acceptsMouseMovedEvents = true
    p.isMovableByWindowBackground = false
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    p.contentView = NSHostingView(
      rootView: QuickAccessCardView(
        asset: asset,
        onClose: { [weak self, weak p] in
          guard let p else { return }
          self?.close(p)
        }))
    cards.append(Card(panel: p, asset: asset))
    VantaPanelMotion.present(p, from: CGPoint(x: -(Self.cardSize.width + 40), y: 0))
  }

  /// Closes every visible card and records them as closed in the history store.
  public func dismiss() {
    for card in cards { close(card.panel) }
  }
  /// Moves the cards out of the way while the user picks the next area. They stay
  /// in the list and come back with `showAfterCapture()`.
  public func hideForCapture() {
    for card in cards { card.panel.orderOut(nil) }
  }
  public func showAfterCapture() {
    for card in cards where !card.panel.isVisible { card.panel.orderFrontRegardless() }
  }
  private func close(_ panel: NSPanel) {
    guard let card = cards.first(where: { $0.panel === panel }) else { return }
    CleanWorkflowCoordinator.shared.markClosed(card.asset.id)
    remove(panel, animated: true)
  }
  private func remove(_ panel: NSPanel, animated: Bool) {
    cards.removeAll { $0.panel === panel }
    if animated {
      VantaPanelMotion.dismiss(panel) { panel.orderOut(nil) }
    } else {
      panel.orderOut(nil)
    }
    reflow()
  }
  private func reflow() {
    for (index, card) in cards.enumerated() {
      let screen = card.panel.screen ?? NSScreen.main
      guard let visible = screen?.visibleFrame else { continue }
      let target = QuickAccessCardLayout.frame(
        index: index, cardSize: Self.cardSize, visibleFrame: visible)
      guard card.panel.frame != target else { continue }
      NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = VantaTheme.Motion.springDuration
        card.panel.animator().setFrame(target, display: true)
      }
    }
  }
  @discardableResult public static func copyImageToClipboard(_ image: NSImage) -> Bool {
    do {
      let a = try AssetFiles.makeImage(image, title: "Image")
      return try AssetFiles.copy(a)
    } catch {
      AssetFiles.showError(error)
      return false
    }
  }
  @discardableResult public static func saveImageToDesktop(_ image: NSImage) -> URL? {
    do { return try AssetFiles.save(AssetFiles.makeImage(image, title: "Image")) } catch {
      AssetFiles.showError(error)
      return nil
    }
  }
}

struct QuickAccessCardView: View {
  let asset: MediaAsset
  let onClose: () -> Void

  private var kindLabel: String {
    switch asset.kind {
    case .video: return "MP4"
    case .animatedImage: return "GIF"
    default: return "PNG"
    }
  }
  private var kindIcon: String {
    switch asset.kind {
    case .video: return "film"
    case .animatedImage: return "photo.stack"
    default: return "photo"
    }
  }

  var body: some View {
    VStack(spacing: 10) {
      HStack(spacing: 8) {
        Image(systemName: kindIcon).font(.system(size: 12, weight: .semibold))
          .foregroundStyle(VantaTheme.Palette.accent)
        Text(asset.title).font(VantaTheme.Font.label).lineLimit(1)
        Spacer()
        Text("\(asset.pixelSize.width) × \(asset.pixelSize.height) • \(kindLabel)")
          .font(VantaTheme.Font.number).foregroundStyle(VantaTheme.Palette.textSecondary)
        Button(action: onClose) {
          Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
            .frame(width: 20, height: 20)
            .background(Circle().fill(VantaTheme.Palette.fillSubtle))
        }.buttonStyle(.plain).help("Close")
      }
      Group {
        if let image = AssetFiles.preview(asset) {
          NativeDraggableThumbnail(
            image: image, fileURL: asset.kind == .stillImage ? nil : asset.fileURL,
            onDoubleClick: open, onDragCompleted: onClose)
        } else {
          Label("Preview unavailable", systemImage: "film")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(VantaTheme.Palette.fillSubtle)
        }
      }
      .frame(height: 138)
      .clipShape(RoundedRectangle(cornerRadius: VantaTheme.Radius.small, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: VantaTheme.Radius.small, style: .continuous)
          .strokeBorder(VantaTheme.Palette.stroke, lineWidth: 1))
      HStack(spacing: 4) {
        VantaIconButton(title: "Copy", icon: "doc.on.doc", role: .prominent, compact: true) {
          do {
            try AssetFiles.copy(asset)
            onClose()
          } catch { AssetFiles.showError(error) }
        }
        VantaIconButton(title: "Save", icon: "square.and.arrow.down", compact: true) {
          do {
            try AssetFiles.save(asset)
            onClose()
          } catch { AssetFiles.showError(error) }
        }
        VantaIconButton(
          title: asset.kind == .stillImage ? "Edit" : "Play",
          icon: asset.kind == .stillImage ? "pencil.and.outline" : "play.fill", compact: true,
          action: open)
        if asset.kind == .stillImage {
          VantaIconButton(title: "Pin", icon: "pin", compact: true) {
            if let i = AssetFiles.preview(asset) {
              FloatingPinWindowManager.shared.pinImage(i, title: asset.title)
            }
          }
          VantaIconButton(title: "Text", icon: "text.viewfinder", compact: true) {
            if let i = AssetFiles.preview(asset) { OCRService.extractAndCopyText(from: i) }
          }
        } else if asset.kind == .video {
          VantaIconButton(title: "Trim", icon: "scissors", compact: true) {
            MediaTrimService.shared.show(asset)
          }
        }
        if !CleanWorkflowCoordinator.shared.history.contains(where: { $0.id == asset.id }) {
          VantaIconButton(title: "To History", icon: "arrow.clockwise", compact: true) {
            CleanWorkflowCoordinator.shared.addExternalAsset(asset)
          }
        }
      }
    }
    .padding(14)
    .frame(
      width: QuickAccessPopupController.cardSize.width,
      height: QuickAccessPopupController.cardSize.height)
    .vantaGlassCard(radius: VantaTheme.Radius.large, shadow: false)
    .foregroundStyle(VantaTheme.Palette.text)
    .preferredColorScheme(.dark)
    .environment(\.layoutDirection, .leftToRight)
  }

  private func open() {
    guard FileManager.default.fileExists(atPath: asset.fileURL.path) else {
      AssetFiles.showError(StorageError.missingFile)
      return
    }
    if asset.kind == .stillImage, let i = AssetFiles.preview(asset) {
      AnnotateWindowController.shared.open(with: i, title: asset.title)
    } else {
      NSWorkspace.shared.open(asset.fileURL)
    }
  }
}
