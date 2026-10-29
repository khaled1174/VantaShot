import AppKit
import Quartz
import SwiftUI
import VantaShotCore

// MARK: - Click / multi-file drag surface for history cards

/// Transparent AppKit view over a card's thumbnail. Reports clicks with modifiers, double clicks,
/// and starts a real multi-item file drag (every selected asset) once the mouse moves.
struct HistoryDragSurface: NSViewRepresentable {
  var dragURLs: () -> [URL]
  var onClick: (_ command: Bool, _ shift: Bool) -> Void
  var onDoubleClick: () -> Void

  func makeNSView(context: Context) -> HistoryDragSurfaceView {
    let v = HistoryDragSurfaceView()
    update(v)
    return v
  }
  func updateNSView(_ v: HistoryDragSurfaceView, context: Context) { update(v) }
  private func update(_ v: HistoryDragSurfaceView) {
    v.dragURLs = dragURLs
    v.onClick = onClick
    v.onDoubleClick = onDoubleClick
  }
}

final class HistoryDragSurfaceView: NSView, NSDraggingSource {
  var dragURLs: (() -> [URL])?
  var onClick: ((Bool, Bool) -> Void)?
  var onDoubleClick: (() -> Void)?
  private var downPoint: CGPoint?
  private var dragging = false

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseDown(with event: NSEvent) {
    downPoint = convert(event.locationInWindow, from: nil)
    dragging = false
    if event.clickCount == 1 {
      // Select immediately so a drag that follows carries the whole selection.
      onClick?(event.modifierFlags.contains(.command), event.modifierFlags.contains(.shift))
    }
  }
  override func mouseDragged(with event: NSEvent) {
    guard !dragging, let start = downPoint else { return }
    let p = convert(event.locationInWindow, from: nil)
    guard hypot(p.x - start.x, p.y - start.y) >= 4 else { return }
    let urls = (dragURLs?() ?? []).filter { FileManager.default.fileExists(atPath: $0.path) }
    guard !urls.isEmpty else { return }
    dragging = true
    var items: [NSDraggingItem] = []
    let maxPreview: CGFloat = 160
    for (i, url) in urls.prefix(12).enumerated() {
      let item = NSDraggingItem(pasteboardWriter: url as NSURL)
      let image = NSImage(contentsOf: url) ?? NSWorkspace.shared.icon(forFile: url.path)
      let ratio = image.size.width / max(1, image.size.height)
      let w = ratio >= 1 ? maxPreview : maxPreview * ratio
      let h = ratio >= 1 ? maxPreview / ratio : maxPreview
      let offset = CGFloat(i) * 6
      item.setDraggingFrame(
        CGRect(x: p.x - w / 2 + offset, y: p.y - h / 2 - offset, width: w, height: h), contents: image)
      items.append(item)
    }
    let session = beginDraggingSession(with: items, event: event, source: self)
    session.animatesToStartingPositionsOnCancelOrFail = true
    session.draggingFormation = urls.count > 1 ? .stack : .none
  }
  override func mouseUp(with event: NSEvent) {
    defer {
      downPoint = nil
      dragging = false
    }
    guard !dragging else { return }
    if event.clickCount >= 2 { onDoubleClick?() }
  }
  func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
    [.copy]
  }
}

// MARK: - Quick Look host (responder-chain owner for QLPreviewPanel)

/// Window content view that owns the Quick Look panel for whatever `urls` currently holds.
final class QuickLookHostView: NSView, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
  var urls: [URL] = [] {
    didSet {
      guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(),
        panel.isVisible, panel.dataSource === self
      else { return }
      panel.reloadData()
    }
  }
  override var acceptsFirstResponder: Bool { true }
  override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
  override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
    panel.dataSource = self
    panel.delegate = self
  }
  override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
    panel.dataSource = nil
    panel.delegate = nil
  }
  func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }
  func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
    urls[index] as NSURL
  }
  func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
    // Space closes the panel again, like Finder.
    if event.type == .keyDown, event.keyCode == 49 {
      panel.orderOut(nil)
      return true
    }
    return false
  }

  func toggle() {
    guard let panel = QLPreviewPanel.shared() else { return }
    if panel.isVisible {
      panel.orderOut(nil)
    } else {
      window?.makeFirstResponder(self)
      panel.makeKeyAndOrderFront(nil)
    }
  }
}

@MainActor final class HistoryQuickLook {
  static let shared = HistoryQuickLook()
  weak var host: QuickLookHostView?
  func update(urls: [URL]) { host?.urls = urls }
  func toggle(urls: [URL]) {
    host?.urls = urls
    host?.toggle()
  }
}

// MARK: - Keyboard shortcuts scoped to one window

struct WindowKeyCatcher: NSViewRepresentable {
  /// Return true when the key was consumed.
  var handler: (NSEvent) -> Bool
  func makeNSView(context: Context) -> KeyView {
    let v = KeyView()
    v.handler = handler
    return v
  }
  func updateNSView(_ v: KeyView, context: Context) { v.handler = handler }
  final class KeyView: NSView {
    var handler: ((NSEvent) -> Bool)?
    private var monitor: Any?
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
      guard window != nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
        guard let self, e.window === self.window else { return e }
        if let first = self.window?.firstResponder, first is NSTextView { return e }
        return (self.handler?(e) ?? false) ? nil : e
      }
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
  }
}
