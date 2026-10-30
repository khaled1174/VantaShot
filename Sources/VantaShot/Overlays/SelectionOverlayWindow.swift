import AppKit
import SwiftUI
import os
import VantaShotCore

public final class KeyableFullscreenOverlayWindow: NSWindow {
  public override var canBecomeKey: Bool { true }
  public override var canBecomeMain: Bool { true }
}

@MainActor
public final class SelectionOverlayController: ObservableObject {
  public static let shared = SelectionOverlayController()
  @Published public var mode: CaptureMode = .allInOne {
    didSet {
      if mode != oldValue {
        selectedWindow = nil
        selectionRect = nil
        prefersWindow = false
      }
    }
  }
  @Published public var cursorLocation: CGPoint = .zero
  @Published public var selectionRect: CGRect?
  @Published public var isDragging = false
  @Published public var hoveredWindow: DetectedWindowInfo?
  @Published public var prefersWindow = false {
    didSet {
      if prefersWindow != oldValue {
        selectedWindow = nil
        selectionRect = nil
      }
    }
  }
  public var isWindowMode: Bool { mode == .window || prefersWindow }
  var lastCapturedTarget: DisplayCaptureTarget? {
    get {
      guard let data = UserDefaults.standard.data(forKey: "previousCaptureTarget.v1") else {
        return nil
      }
      return try? JSONDecoder().decode(DisplayCaptureTarget.self, from: data)
    }
    set {
      UserDefaults.standard.set(
        try? newValue.map { try JSONEncoder().encode($0) }, forKey: "previousCaptureTarget.v1")
    }
  }
  public private(set) var screenFrame: CGRect = .zero
  /// Window edges (in overlay-local coordinates) the selection snaps to while dragging.
  private(set) var snapEdges = SnapEdges(xs: [], ys: [])
  public static let snapThreshold: CGFloat = 6
  private var windowsList: [DetectedWindowInfo] = []
  private var overlayWindows: [NSWindow] = []
  private var pending: Task<Void, Never>?
  private var generation = UUID()
  private var selectedWindow: DetectedWindowInfo?
  private var activeDisplayTarget: DisplayCaptureTarget?
  public var isOverlayActive: Bool { !overlayWindows.isEmpty }
  public var onActionCompleted: ((CaptureResultAction) -> Void)?
  public var onCancelled: (() -> Void)?
  public enum CaptureResultAction {
    case quickAccess(NSImage, String)
    case openAnnotate(NSImage, String)
    case copyDirectly(NSImage)
    case saveDirectly(NSImage)
    case pinDirectly(NSImage)
    case ocrDirectly(NSImage)
    case startScrolling(DisplayCaptureTarget, NSImage)
    case startRecording(DisplayCaptureTarget)
  }
  public func present(initialMode: CaptureMode, onComplete: @escaping (CaptureResultAction) -> Void)
  {
    dismiss()
    onActionCompleted = onComplete
    mode = initialMode
    selectionRect = nil
    isDragging = false
    prefersWindow = false
    selectedWindow = nil
    guard let primary = NSScreen.screens.first else {
      onCancelled?()
      return
    }
    windowsList = ScreenCaptureService.visibleWindows(
      on: primary, excludingPID: ProcessInfo.processInfo.processIdentifier)
    screenFrame =
      (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? primary).frame
    activeDisplayTarget = try? ScreenCaptureProvider.target(for: screenFrame)
    refreshSnapEdges()
    if initialMode == .fullscreen {
      finishWithCurrentSelection()
      return
    }
    cursorLocation = CGPoint(
      x: NSEvent.mouseLocation.x - screenFrame.minX, y: NSEvent.mouseLocation.y - screenFrame.minY)
    for screen in NSScreen.screens {
      let w = KeyableFullscreenOverlayWindow(
        contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
      w.isReleasedWhenClosed = false
      w.level = .statusBar
      w.isOpaque = false
      w.backgroundColor = .clear
      w.hasShadow = false
      w.acceptsMouseMovedEvents = true
      w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      let v = NativeCaptureOverlayNSView(
        controller: self, frame: NSRect(origin: .zero, size: screen.frame.size))
      v.displayFrame = screen.frame
      v.displayVisibleFrame = screen.visibleFrame
      w.contentView = v
      overlayWindows.append(w)
      w.orderFrontRegardless()
      v.captureBackdrop()
      if screen.frame == screenFrame {
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(v)
      }
    }
    NSApp.activate(ignoringOtherApps: true)
  }
  public func activateDisplay(_ frame: CGRect) {
    if screenFrame != frame {
      screenFrame = frame
      activeDisplayTarget = try? ScreenCaptureProvider.target(for: frame)
      selectionRect = nil
      selectedWindow = nil
      refreshSnapEdges()
    }
    for w in overlayWindows { w.contentView?.needsDisplay = true }
  }
  private func hide() {
    for w in overlayWindows { w.orderOut(nil) }
    overlayWindows = []
  }
  public func dismiss() {
    pending?.cancel()
    pending = nil
    generation = UUID()
    hide()
  }
  public func cancelAndRestoreLauncher() {
    dismiss()
    onCancelled?()
  }
  private func refreshSnapEdges() {
    snapEdges = SnapEdges(windowFrames: windowsList.map(\.appKitFrame), screenFrame: screenFrame)
  }
  /// Pulls a drag point onto a nearby window edge unless the user holds ⌥ to drag freely.
  func snapped(_ point: CGPoint, flags: NSEvent.ModifierFlags) -> CGPoint {
    guard !flags.contains(.option) else { return point }
    return SelectionSnapper.snap(point, to: snapEdges, threshold: Self.snapThreshold)
  }
  public func updateHoveredWindow(at point: CGPoint) {
    let global = CGPoint(x: point.x + screenFrame.minX, y: point.y + screenFrame.minY)
    hoveredWindow = windowsList.first { $0.appKitFrame.contains(global) }
  }
  public func selectWindow() {
    guard let w = hoveredWindow else { return }
    selectedWindow = w
    selectionRect = w.appKitFrame.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
    if mode != .allInOne { finishWithCurrentSelection() }
  }
  public func finishWithCurrentSelection(preferredAction: String? = nil) {
    guard pending == nil else { return }
    let id = generation
    let active = mode
    let win = isWindowMode && mode != .fullscreen ? (selectedWindow ?? hoveredWindow) : nil
    let local = selectionRect
    let frame = screenFrame
    let callback = onActionCompleted
    var chosenTarget = activeDisplayTarget
    if let local { chosenTarget?.rect = local.offsetBy(dx: frame.minX, dy: frame.minY) }
    hide()
    pending = Task { @MainActor in
      do {
        try await Task.sleep(nanoseconds: 100_000_000)
        try Task.checkCancellation()
        let rect = local?.offsetBy(dx: frame.minX, dy: frame.minY)
        if active == .record || preferredAction == "record" {
          guard rect != nil else { throw CaptureError.emptyCapture }
          self.lastCapturedTarget = chosenTarget
          guard let chosenTarget else { throw CaptureError.noDisplay }
          callback?(.startRecording(chosenTarget))
          self.pending = nil
          return
        }
        let image: NSImage
        if let win {
          image = try await ScreenCaptureService.captureWindow(windowInfo: win)
        } else if active == .fullscreen {
          guard let chosenTarget else { throw CaptureError.noDisplay }
          image = try await ScreenCaptureProvider.capture(target: chosenTarget)
        } else {
          guard let rect, rect.width > 12, rect.height > 12 else { throw CaptureError.emptyCapture }
          guard let chosenTarget else { throw CaptureError.noDisplay }
          image = try await ScreenCaptureProvider.capture(target: chosenTarget)
          self.lastCapturedTarget = chosenTarget
        }
        guard !Task.isCancelled, self.generation == id else { return }
        ScreenCaptureService.playShutterSound()
        let label =
          win.map { "Window: \($0.ownerName)" }
          ?? "Capture \(image.size.width.formatted()) × \(image.size.height.formatted())"
        switch preferredAction {
        case "annotate": callback?(.openAnnotate(image, label))
        case "copy": callback?(.copyDirectly(image))
        case "save": callback?(.saveDirectly(image))
        case "pin": callback?(.pinDirectly(image))
        case "ocr": callback?(.ocrDirectly(image))
        case "scroll": if let chosenTarget { callback?(.startScrolling(chosenTarget, image)) }
        default:
          if active == .ocr {
            callback?(.ocrDirectly(image))
          } else if active == .scrolling, rect != nil {
            if let chosenTarget { callback?(.startScrolling(chosenTarget, image)) }
          } else {
            callback?(.quickAccess(image, label))
          }
        }
        self.pending = nil
      } catch {
        guard !Task.isCancelled, self.generation == id else { return }
        self.pending = nil
        AssetFiles.showError(error)
        self.onCancelled?()
      }
    }
  }
}

// MARK: - Live Transparent AppKit NSView (Never Paints Screen Black!)

final class NativeCaptureOverlayNSView: NSView {
  unowned let controller: SelectionOverlayController
  var displayFrame: CGRect = .zero
  var displayVisibleFrame: CGRect = .zero {
    didSet { updateHUDPlacement() }
  }
  static let dimAlpha: CGFloat = 0.42
  static let hudMargin: CGFloat = 24
  /// Snapshot of the screen beneath the overlay, used by the loupe.
  private var backdrop: CGImage?
  private var backdropTask: Task<Void, Never>?
  private static let logger = Logger(subsystem: "dev.vantashot.macos", category: "Overlay")
  private var hudBottomConstraint: NSLayoutConstraint?
  private var dragOrigin: CGPoint?
  private var originalRect: CGRect?
  private var resizeCorner: Int?
  private var moving = false
  private var hudHostingView: NSHostingView<OverlayBottomHUDView>?

  init(controller: SelectionOverlayController, frame: NSRect) {
    self.controller = controller
    super.init(frame: frame)
    self.wantsLayer = true
    self.layer?.backgroundColor = NSColor.clear.cgColor

    let hud = NSHostingView(rootView: OverlayBottomHUDView(controller: controller))
    hud.translatesAutoresizingMaskIntoConstraints = false
    addSubview(hud)
    let bottom = hud.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.hudMargin)
    NSLayoutConstraint.activate([hud.centerXAnchor.constraint(equalTo: centerXAnchor), bottom])
    self.hudBottomConstraint = bottom
    self.hudHostingView = hud
  }

  private func updateHUDPlacement() {
    hudBottomConstraint?.constant = -OverlayLayout.hudBottomInset(
      screenFrame: displayFrame, visibleFrame: displayVisibleFrame, margin: Self.hudMargin)
  }

  /// Grabs what is on screen beneath this overlay (the provider's filter excludes our own
  /// windows) so the loupe can magnify pixels around the cursor. Silently skipped on failure.
  func captureBackdrop() {
    let frame = displayFrame
    backdropTask?.cancel()
    backdropTask = Task { @MainActor [weak self] in
      do {
        let target = try ScreenCaptureProvider.target(for: frame)
        let image = try await ScreenCaptureProvider.capture(target: target)
        guard !Task.isCancelled, let self, self.displayFrame == frame else { return }
        self.backdrop = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        Self.logger.info(
          "loupe backdrop ready \(self.backdrop?.width ?? 0)x\(self.backdrop?.height ?? 0)")
        self.needsDisplay = true
      } catch {
        Self.logger.error("loupe backdrop failed: \(error.localizedDescription)")
      }
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override var isOpaque: Bool { false }
  override var acceptsFirstResponder: Bool { true }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for area in trackingAreas {
      removeTrackingArea(area)
    }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(area)
  }

  override func keyDown(with event: NSEvent) {
    switch event.keyCode {
    case 53:  // ESC
      controller.cancelAndRestoreLauncher()
    case 49:  // Space toggles Window / Area
      controller.prefersWindow.toggle()
      controller.selectionRect = nil
      needsDisplay = true
    case 0:  // A
      controller.mode = .area
      needsDisplay = true
    case 13:  // W
      controller.mode = .window
      needsDisplay = true
    case 3:  // F
      controller.mode = .fullscreen
      controller.finishWithCurrentSelection()
    case 1:  // S
      controller.mode = .scrolling
      needsDisplay = true
    case 31:  // O
      controller.mode = .ocr
      needsDisplay = true
    case 15:  // R
      controller.mode = .record
      needsDisplay = true
    case 36:  // Return / Enter
      controller.finishWithCurrentSelection()
    default:
      break
    }
  }

  override func mouseMoved(with event: NSEvent) {
    let pt = convert(event.locationInWindow, from: nil)
    controller.activateDisplay(displayFrame)
    controller.cursorLocation = pt
    if controller.isWindowMode {
      controller.updateHoveredWindow(at: pt)
    }
    needsDisplay = true
  }

  override func mouseDown(with event: NSEvent) {
    let pt = convert(event.locationInWindow, from: nil)
    controller.activateDisplay(displayFrame)
    if controller.isWindowMode {
      controller.updateHoveredWindow(at: pt)
      controller.selectWindow()
      return
    }
    dragOrigin = pt
    moving = false
    resizeCorner = nil
    originalRect = controller.selectionRect
    if let r = originalRect {
      let corners = [
        CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.maxY),
        CGPoint(x: r.maxX, y: r.maxY),
      ]
      resizeCorner = corners.firstIndex { hypot($0.x - pt.x, $0.y - pt.y) < 12 }
      moving = resizeCorner == nil && r.contains(pt)
    }
    controller.isDragging = true
    if !moving && resizeCorner == nil {
      let start = controller.snapped(pt, flags: event.modifierFlags)
      dragOrigin = start
      controller.selectionRect = CGRect(origin: start, size: .zero)
    }
    needsDisplay = true
  }

  override func mouseDragged(with event: NSEvent) {
    guard let start = dragOrigin else { return }
    let pt = convert(event.locationInWindow, from: nil)
    controller.cursorLocation = pt
    if moving, let r = originalRect {
      let x = min(max(0, r.minX + pt.x - start.x), bounds.width - r.width)
      let y = min(max(0, r.minY + pt.y - start.y), bounds.height - r.height)
      controller.selectionRect = CGRect(x: x, y: y, width: r.width, height: r.height)
      needsDisplay = true
      return
    }
    var anchor = start
    if let corner = resizeCorner, let r = originalRect {
      anchor = CGPoint(x: corner % 2 == 0 ? r.maxX : r.minX, y: corner < 2 ? r.maxY : r.minY)
    }
    let limitedPoint = controller.snapped(
      CGPoint(x: min(bounds.width, max(0, pt.x)), y: min(bounds.height, max(0, pt.y))),
      flags: event.modifierFlags)
    let anchorPoint = anchor
    let rect = CGRect(
      x: min(anchorPoint.x, limitedPoint.x),
      y: min(anchorPoint.y, limitedPoint.y),
      width: abs(limitedPoint.x - anchorPoint.x),
      height: abs(limitedPoint.y - anchorPoint.y)
    )
    controller.selectionRect = rect
    needsDisplay = true
  }

  override func mouseUp(with event: NSEvent) {
    controller.isDragging = false
    dragOrigin = nil
    guard let rect = controller.selectionRect, rect.width > 14, rect.height > 14 else {
      controller.selectionRect = nil
      needsDisplay = true
      return
    }

    if controller.mode != .allInOne {
      controller.finishWithCurrentSelection()
    } else {
      needsDisplay = true
    }
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }

    // 1. Subtle transparent dim over screen (live desktop & windows remain 100% visible underneath!)
    ctx.saveGState()
    ctx.setFillColor(NSColor.black.withAlphaComponent(Self.dimAlpha).cgColor)
    ctx.fill(bounds)

    guard displayFrame == controller.screenFrame else {
      ctx.restoreGState()
      return
    }
    // 2. Cut out the active Window or Selection Rect so it is 100% crystal clear
    if controller.isWindowMode, let winInfo = controller.hoveredWindow {
      let winRect = winInfo.appKitFrame.offsetBy(dx: -displayFrame.minX, dy: -displayFrame.minY)
      ctx.setBlendMode(.clear)
      ctx.fill(winRect)
      ctx.setBlendMode(.normal)

      let path = NSBezierPath(roundedRect: winRect, xRadius: 10, yRadius: 10)
      NSColor(calibratedRed: 0.14, green: 0.82, blue: 0.98, alpha: 1.0).setStroke()
      path.lineWidth = 3.0
      path.stroke()

      drawPillLabel(
        text:
          "\(winInfo.ownerName)  —  \(Int(winRect.width))×\(Int(winRect.height))  (click to capture)",
        at: CGPoint(x: winRect.midX, y: max(90, winRect.minY - 22))
      )
    } else if let sel = controller.selectionRect, sel.width > 4, sel.height > 4 {
      ctx.setBlendMode(.clear)
      ctx.fill(sel)
      ctx.setBlendMode(.normal)

      let borderPath = NSBezierPath(rect: sel)
      NSColor(calibratedRed: 0.14, green: 0.82, blue: 0.98, alpha: 1.0).setStroke()
      borderPath.lineWidth = 2.0
      borderPath.stroke()

      // Corner Resize Handles
      let corners = [
        CGPoint(x: sel.minX, y: sel.minY),
        CGPoint(x: sel.maxX, y: sel.minY),
        CGPoint(x: sel.minX, y: sel.maxY),
        CGPoint(x: sel.maxX, y: sel.maxY),
      ]
      for c in corners {
        let handle = NSRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: handle).fill()
        NSColor(calibratedRed: 0.14, green: 0.82, blue: 0.98, alpha: 1.0).setStroke()
        NSBezierPath(ovalIn: handle).stroke()
      }

      drawPillLabel(
        text: "\(Int(sel.width)) × \(Int(sel.height)) pt",
        at: CGPoint(x: sel.midX, y: min(bounds.height - 40, sel.maxY + 20))
      )
    }
    ctx.restoreGState()

    // 3. Draw Crosshair Lines & Coordinate Badge at Cursor
    let cursor = controller.cursorLocation
    if !controller.isWindowMode {
      ctx.saveGState()
      ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.45).cgColor)
      ctx.setLineWidth(1.0)
      ctx.move(to: CGPoint(x: cursor.x, y: 0))
      ctx.addLine(to: CGPoint(x: cursor.x, y: bounds.height))
      ctx.move(to: CGPoint(x: 0, y: cursor.y))
      ctx.addLine(to: CGPoint(x: bounds.width, y: cursor.y))
      ctx.strokePath()

      ctx.restoreGState()
      drawLoupe(in: ctx, around: cursor)
    }
  }

  // MARK: Loupe (pixel magnifier that follows the cursor)

  static let loupeDiameter: CGFloat = 128
  static let loupeSourceSide: CGFloat = 32

  private func drawLoupe(in ctx: CGContext, around cursor: CGPoint) {
    let d = Self.loupeDiameter
    let gap: CGFloat = 22
    var center = CGPoint(x: cursor.x + gap + d / 2, y: cursor.y + gap + d / 2)
    if center.x + d / 2 > bounds.width - 8 { center.x = cursor.x - gap - d / 2 }
    if center.y + d / 2 > bounds.height - 8 { center.y = cursor.y - gap - d / 2 }
    let circle = CGRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d)

    ctx.saveGState()
    ctx.addEllipse(in: circle)
    ctx.clip()
    ctx.setFillColor(NSColor(calibratedRed: 0.05, green: 0.07, blue: 0.12, alpha: 1).cgColor)
    ctx.fill(circle)
    if let backdrop {
      let scale = CGFloat(backdrop.width) / max(1, bounds.width)
      let side = Self.loupeSourceSide
      let crop = CGRect(
        x: (cursor.x - side / 2) * scale, y: (bounds.height - cursor.y - side / 2) * scale,
        width: side * scale, height: side * scale)
      if let piece = backdrop.cropping(to: crop) {
        ctx.interpolationQuality = .none
        // Keep the magnified block anchored on the cursor even when the crop was clipped at an edge.
        let drawn = CGRect(
          x: circle.minX + (crop.minX / scale - (cursor.x - side / 2)) * (d / side),
          y: circle.minY + ((bounds.height - cursor.y + side / 2) - (crop.maxY / scale)) * (d / side),
          width: CGFloat(piece.width) / scale * (d / side),
          height: CGFloat(piece.height) / scale * (d / side))
        ctx.draw(piece, in: drawn)
      }
    }
    // Center crosshair: one magnified pixel-cell wide
    let cell = d / Self.loupeSourceSide
    ctx.setStrokeColor(NSColor(calibratedRed: 0.16, green: 0.85, blue: 0.98, alpha: 0.9).cgColor)
    ctx.setLineWidth(1)
    ctx.stroke(CGRect(x: center.x - cell / 2, y: center.y - cell / 2, width: cell, height: cell))
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor)
    ctx.move(to: CGPoint(x: circle.minX, y: center.y))
    ctx.addLine(to: CGPoint(x: center.x - cell / 2, y: center.y))
    ctx.move(to: CGPoint(x: center.x + cell / 2, y: center.y))
    ctx.addLine(to: CGPoint(x: circle.maxX, y: center.y))
    ctx.move(to: CGPoint(x: center.x, y: circle.minY))
    ctx.addLine(to: CGPoint(x: center.x, y: center.y - cell / 2))
    ctx.move(to: CGPoint(x: center.x, y: center.y + cell / 2))
    ctx.addLine(to: CGPoint(x: center.x, y: circle.maxY))
    ctx.strokePath()
    ctx.restoreGState()

    // Ring
    ctx.saveGState()
    ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.55).cgColor)
    ctx.setLineWidth(4)
    ctx.strokeEllipse(in: circle.insetBy(dx: -1, dy: -1))
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
    ctx.setLineWidth(2)
    ctx.strokeEllipse(in: circle)
    ctx.restoreGState()

    let label: String
    if let sel = controller.selectionRect, controller.isDragging, sel.width > 0 {
      label = "\(Int(sel.width)) × \(Int(sel.height))"
    } else {
      label = "X \(Int(cursor.x))   Y \(Int(cursor.y))"
    }
    drawPillLabel(text: label, at: CGPoint(x: center.x, y: circle.minY - 16))
  }

  private func drawPillLabel(text: String, at center: CGPoint) {
    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .bold),
      .foregroundColor: NSColor.white,
    ]
    let str = NSString(string: text)
    let size = str.size(withAttributes: attrs)
    let pillRect = NSRect(
      x: center.x - (size.width + 20) / 2,
      y: center.y - (size.height + 10) / 2,
      width: size.width + 20,
      height: size.height + 10
    )
    let path = NSBezierPath(
      roundedRect: pillRect, xRadius: pillRect.height / 2, yRadius: pillRect.height / 2)
    NSColor(calibratedRed: 0.07, green: 0.09, blue: 0.14, alpha: 0.92).setFill()
    path.fill()
    NSColor.white.withAlphaComponent(0.22).setStroke()
    path.lineWidth = 1
    path.stroke()
    str.draw(at: NSPoint(x: pillRect.minX + 10, y: pillRect.minY + 5), withAttributes: attrs)
  }
}

// MARK: - Bottom Floating Smart Capture HUD Bar

extension CaptureMode {
  /// Short label that fits the HUD; the full `rawValue` stays for menus and commands.
  var hudTitle: String {
    switch self {
    case .allInOne: return "Smart"
    case .area: return "Area"
    case .window: return "Window"
    case .fullscreen: return "Screen"
    case .scrolling: return "Scroll"
    case .ocr: return "Text"
    case .record: return "Record"
    }
  }
  var hudShortcut: String? { self == .allInOne ? nil : shortcutKey }
}

struct OverlayBottomHUDView: View {
  @ObservedObject var controller: SelectionOverlayController

  private var actionsVisible: Bool {
    guard controller.mode == .allInOne, let sel = controller.selectionRect else { return false }
    return sel.width > 14 && sel.height > 14 && !controller.isDragging
  }

  var body: some View {
    VStack(spacing: 10) {
      if actionsVisible {
        HStack(spacing: 4) {
          VantaIconButton(
            title: "Capture", icon: "checkmark", shortcut: "⏎", role: .prominent, compact: true
          ) {
            controller.finishWithCurrentSelection()
          }
          Divider().frame(height: 26).padding(.horizontal, 2)
          VantaIconButton(title: "Edit", icon: "pencil.and.outline", compact: true) {
            controller.finishWithCurrentSelection(preferredAction: "annotate")
          }
          VantaIconButton(title: "Copy", icon: "doc.on.doc", compact: true) {
            controller.finishWithCurrentSelection(preferredAction: "copy")
          }
          VantaIconButton(title: "Save", icon: "square.and.arrow.down", compact: true) {
            controller.finishWithCurrentSelection(preferredAction: "save")
          }
          VantaIconButton(title: "Pin", icon: "pin", compact: true) {
            controller.finishWithCurrentSelection(preferredAction: "pin")
          }
          VantaIconButton(title: "Text", icon: "text.viewfinder", compact: true) {
            controller.finishWithCurrentSelection(preferredAction: "ocr")
          }
          VantaIconButton(title: "Scroll", icon: "arrow.up.and.down.text.horizontal", compact: true)
          {
            controller.finishWithCurrentSelection(preferredAction: "scroll")
          }
          VantaIconButton(title: "Record", icon: "record.circle", compact: true) {
            controller.finishWithCurrentSelection(preferredAction: "record")
          }
        }
        .padding(6)
        .vantaGlassCard(radius: VantaTheme.Radius.medium)
        .transition(.move(edge: .bottom).combined(with: .opacity))
      }

      HStack(spacing: 4) {
        ForEach(CaptureMode.allCases) { m in
          VantaIconButton(
            title: m.hudTitle, icon: m.icon, shortcut: m.hudShortcut, isSelected: controller.mode == m
          ) {
            if m == .fullscreen {
              controller.mode = .fullscreen
              controller.finishWithCurrentSelection()
            } else {
              controller.mode = m
            }
          }
        }
        Divider().frame(height: 30).padding(.horizontal, 4)
        VantaIconButton(title: "Cancel", icon: "xmark", shortcut: "Esc", role: .destructive) {
          controller.cancelAndRestoreLauncher()
        }
      }
      .padding(6)
      .vantaGlassCard(radius: VantaTheme.Radius.large)
    }
    .padding(VantaTheme.Shadow.radius + VantaTheme.Shadow.y)
    .animation(VantaTheme.Motion.spring, value: actionsVisible)
    .environment(\.layoutDirection, .leftToRight)
  }
}
