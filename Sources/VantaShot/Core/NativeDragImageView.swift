import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Native AppKit Drag-and-Drop Image View (Works in Finder, Browsers, Chat Apps, Notes, Everywhere!)

public final class AppKitDraggableImageView: NSView, NSDraggingSource {
  public var imageToDrag: NSImage? {
    didSet { needsDisplay = true }
  }
  public var fileURLToDrag: URL?
  public var renderImageProvider: (() -> NSImage?)?
  public var onSingleClick: (() -> Void)?
  public var onDoubleClick: (() -> Void)?
  public var onDragCompleted: (() -> Void)?
  public var showsThumbnail: Bool = true

  private var mouseDownPoint: CGPoint?
  private var didStartDrag: Bool = false

  public override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    self.wantsLayer = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  public override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    true
  }

  public override func resetCursorRects() {
    addCursorRect(bounds, cursor: .openHand)
  }

  public override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard showsThumbnail, let img = imageToDrag else { return }

    let bgPath = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
    NSColor.black.withAlphaComponent(0.35).setFill()
    bgPath.fill()

    // Aspect-fit rect inside bounds
    let insetBounds = bounds.insetBy(dx: 4, dy: 4)
    let imgRatio = img.size.width / max(1, img.size.height)
    let boxRatio = insetBounds.width / max(1, insetBounds.height)

    var drawRect = insetBounds
    if imgRatio > boxRatio {
      let h = insetBounds.width / imgRatio
      drawRect = NSRect(
        x: insetBounds.minX, y: insetBounds.midY - h / 2, width: insetBounds.width, height: h)
    } else {
      let w = insetBounds.height * imgRatio
      drawRect = NSRect(
        x: insetBounds.midX - w / 2, y: insetBounds.minY, width: w, height: insetBounds.height)
    }

    NSGraphicsContext.saveGraphicsState()
    let clip = NSBezierPath(roundedRect: drawRect, xRadius: 6, yRadius: 6)
    clip.addClip()
    img.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()
  }

  public override func mouseDown(with event: NSEvent) {
    mouseDownPoint = convert(event.locationInWindow, from: nil)
    didStartDrag = false

  }

  public override func mouseDragged(with event: NSEvent) {
    guard !didStartDrag, let start = mouseDownPoint else { return }
    let cur = convert(event.locationInWindow, from: nil)
    let dist = hypot(cur.x - start.x, cur.y - start.y)
    guard dist >= 3.0 else { return }

    let finalImage = renderImageProvider?() ?? imageToDrag
    guard let img = finalImage else { return }

    didStartDrag = true
    startSystemDragSession(with: img, event: event)
  }

  public override func mouseUp(with event: NSEvent) {

    defer {
      mouseDownPoint = nil
      didStartDrag = false
    }
    if !didStartDrag {
      if event.clickCount >= 2 {
        onDoubleClick?()
      } else {
        onSingleClick?()
      }
    }
  }

  private func startSystemDragSession(with image: NSImage, event: NSEvent) {
    guard
      let fileURL = fileURLToDrag.flatMap({ Self.writeTempDropFile(forFile: $0) })
        ?? (fileURLToDrag == nil ? Self.writeTempDropFile(for: image) : nil)
    else { return }

    // ONE single NSPasteboardItem with multiple representations (.fileURL + .png + .tiff) = 1 file!
    let pbItem =
      fileURLToDrag == nil
      ? Self.makeSinglePasteboardItem(for: image, fileURL: fileURL)
      : Self.filePasteboardItem(fileURL)
    let dragItem = NSDraggingItem(pasteboardWriter: pbItem)

    // Thumbnail preview size during drag
    let maxPreviewDim: CGFloat = 180
    let ratio = image.size.width / max(1, image.size.height)
    let prevW = ratio >= 1 ? maxPreviewDim : maxPreviewDim * ratio
    let prevH = ratio >= 1 ? maxPreviewDim / ratio : maxPreviewDim
    let previewImage = NSImage(size: NSSize(width: prevW, height: prevH))
    previewImage.lockFocus()
    image.draw(in: NSRect(x: 0, y: 0, width: prevW, height: prevH))
    previewImage.unlockFocus()

    let clickPt = convert(event.locationInWindow, from: nil)
    let dragFrame = NSRect(
      x: clickPt.x - prevW / 2,
      y: clickPt.y - prevH / 2,
      width: prevW,
      height: prevH
    )
    dragItem.setDraggingFrame(dragFrame, contents: previewImage)

    let session = beginDraggingSession(with: [dragItem], event: event, source: self)
    session.animatesToStartingPositionsOnCancelOrFail = true
  }

  public static func filePasteboardItem(_ url: URL) -> NSPasteboardItem {
    let item = NSPasteboardItem()
    item.setString(url.absoluteString, forType: .fileURL)
    return item
  }

  public static func makeSinglePasteboardItem(for image: NSImage, fileURL: URL?) -> NSPasteboardItem
  {
    let pbItem = NSPasteboardItem()
    if let fileURL {
      pbItem.setString(fileURL.absoluteString, forType: .fileURL)
    }
    if let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff)
    {
      if let pngData = rep.representation(using: .png, properties: [:]) {
        pbItem.setData(pngData, forType: .png)
      }
      pbItem.setData(tiff, forType: .tiff)
    }
    return pbItem
  }

  private static func writeTempDropFile(forFile input: URL) -> URL? {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
      "VantaShotDrops", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let out = directory.appendingPathComponent("VantaShot-\(UUID()).\(input.pathExtension)")
      try FileManager.default.copyItem(at: input, to: out)
      return out
    } catch {
      AssetFiles.showError(error)
      return nil
    }
  }
  public static func writeTempDropFile(for image: NSImage) -> URL? {
    guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
    else {
      return nil
    }
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("VantaShotDrops", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let fileURL = dir.appendingPathComponent("VantaShot-\(UUID().uuidString).png")
    do {
      try png.write(to: fileURL, options: .atomic)
      return fileURL
    } catch {
      return nil
    }
  }

  // MARK: - NSDraggingSource

  public func draggingSession(
    _ session: NSDraggingSession,
    sourceOperationMaskFor context: NSDraggingContext
  ) -> NSDragOperation {
    return [.copy]
  }

  public func draggingSession(
    _ session: NSDraggingSession,
    endedAt screenPoint: NSPoint,
    operation: NSDragOperation
  ) {

    if operation != [] {
      onDragCompleted?()
    }
  }
}

// MARK: - SwiftUI Representable for Thumbnail Drag View

public struct NativeDraggableThumbnail: NSViewRepresentable {
  public let image: NSImage
  public var fileURL: URL?
  public var onSingleClick: (() -> Void)?
  public var onDoubleClick: (() -> Void)?
  public var onDragCompleted: (() -> Void)?

  public init(
    image: NSImage,
    fileURL: URL? = nil,
    onSingleClick: (() -> Void)? = nil,
    onDoubleClick: (() -> Void)? = nil,
    onDragCompleted: (() -> Void)? = nil
  ) {
    self.image = image
    self.fileURL = fileURL
    self.onSingleClick = onSingleClick
    self.onDoubleClick = onDoubleClick
    self.onDragCompleted = onDragCompleted
  }

  public func makeNSView(context: Context) -> AppKitDraggableImageView {
    let v = AppKitDraggableImageView()
    v.showsThumbnail = true
    v.imageToDrag = image
    v.fileURLToDrag = fileURL
    v.onSingleClick = onSingleClick
    v.onDoubleClick = onDoubleClick
    v.onDragCompleted = onDragCompleted
    return v
  }

  public func updateNSView(_ nsView: AppKitDraggableImageView, context: Context) {
    nsView.imageToDrag = image
    nsView.fileURLToDrag = fileURL
    nsView.onSingleClick = onSingleClick
    nsView.onDoubleClick = onDoubleClick
    nsView.onDragCompleted = onDragCompleted
  }
}

// MARK: - SwiftUI Representable for Toolbar "Drag Image" Button (Like CleanShot's ANDragButton)

public struct NativeToolbarDragPill: NSViewRepresentable {
  public let renderImage: () -> NSImage?

  public init(renderImage: @escaping () -> NSImage?) {
    self.renderImage = renderImage
  }

  public func makeNSView(context: Context) -> AppKitDraggableImageView {
    let v = AppKitDraggableImageView()
    v.showsThumbnail = false
    v.renderImageProvider = renderImage
    return v
  }

  public func updateNSView(_ nsView: AppKitDraggableImageView, context: Context) {
    nsView.renderImageProvider = renderImage
  }
}
