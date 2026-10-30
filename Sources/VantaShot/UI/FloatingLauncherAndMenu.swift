import AppKit
import SwiftUI
import VantaShotCore

// MARK: - Pin & Desktop Icons Helper Managers

@MainActor
public final class DesktopIconsCoverManager: ObservableObject {
  public static let shared = DesktopIconsCoverManager()
  @Published public var isHidden: Bool = false
  var coverWindowIDs: Set<CGWindowID> { Set(coverWindows.map { CGWindowID($0.windowNumber) }) }
  private var coverWindows: [NSWindow] = []
  private var refreshTimer: Timer?
  private var desktopSignature = ""

  public func toggle() {
    guard !LiveScreenRecorderController.shared.isRecording,
      !LiveScreenRecorderController.shared.isStarting
    else {
      ToastBannerHUD.shared.show(message: "Change icon hiding before you start recording, or after you stop.")
      return
    }
    isHidden ? showIcons() : hideIcons()
  }

  public func hideIcons() {
    guard !isHidden else { return }
    isHidden = true
    refreshCovers()
    desktopSignature = signature()
    refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self, self.isHidden else { return }
        if self.signature() != self.desktopSignature {
          self.refreshCovers()
          self.desktopSignature = self.signature()
        }

      }
    }
    ToastBannerHUD.shared.show(
      message: "Desktop icons are hidden",
      subtitle: "The desktop is clear and ready to capture.",
      icon: "eye.slash.fill"
    )
  }

  private func refreshCovers() {
    let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
    var next: [NSWindow] = []
    for screen in NSScreen.screens {
      let id = NSUserInterfaceItemIdentifier(
        "desktop-cover-\((screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0)"
      )
      let win =
        coverWindows.first { $0.identifier == id }
        ?? NSWindow(
          contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
      win.identifier = id
      win.isReleasedWhenClosed = false
      win.level = level
      win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
      win.ignoresMouseEvents = true
      win.isOpaque = true
      win.setFrame(screen.frame, display: false)
      win.contentView = DesktopWallpaperView(screen: screen)
      win.orderFrontRegardless()
      next.append(win)
    }
    for old in coverWindows where !next.contains(where: { $0 === old }) { old.orderOut(nil) }
    coverWindows = next
  }
  private func signature() -> String {
    NSScreen.screens.map {
      "\($0.frame):\(NSWorkspace.shared.desktopImageURL(for:$0)?.absoluteString ?? ""): \(NSWorkspace.shared.desktopImageOptions(for:$0)?.description ?? "")"
    }.joined(separator: "|")
  }
  public func showIcons() {
    refreshTimer?.invalidate()
    refreshTimer = nil
    for w in coverWindows {
      w.orderOut(nil)
    }
    coverWindows.removeAll()
    isHidden = false
    ToastBannerHUD.shared.show(
      message: "Desktop icons are visible",
      icon: "eye.fill"
    )
  }
}

final class DesktopWallpaperView: NSView {
  private let image: NSImage?
  private let options: [NSWorkspace.DesktopImageOptionKey: Any]
  init(screen: NSScreen) {
    image = NSWorkspace.shared.desktopImageURL(for: screen).flatMap { NSImage(contentsOf: $0) }
    options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
    super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
  }
  required init?(coder: NSCoder) { fatalError() }
  override func draw(_ dirtyRect: NSRect) {
    (options[.fillColor] as? NSColor ?? NSColor.black).setFill()
    bounds.fill()
    guard let image else { return }
    let scaling =
      (options[.imageScaling] as? NSNumber)?.uintValue
      ?? NSImageScaling.scaleProportionallyUpOrDown.rawValue
    var r = bounds
    if scaling != NSImageScaling.scaleAxesIndependently.rawValue {
      let clips = (options[.allowClipping] as? Bool) ?? true
      var factor =
        clips
        ? max(bounds.width / image.size.width, bounds.height / image.size.height)
        : min(bounds.width / image.size.width, bounds.height / image.size.height)
      if scaling == NSImageScaling.scaleNone.rawValue { factor = 1 }
      if scaling == NSImageScaling.scaleProportionallyDown.rawValue { factor = min(1, factor) }
      let size = NSSize(width: image.size.width * factor, height: image.size.height * factor)
      r = NSRect(
        x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width,
        height: size.height)
    }
    image.draw(in: r)
  }
}

@MainActor
public final class FloatingPinWindowManager {
  public static let shared = FloatingPinWindowManager()
  private var pinnedWindows: [UUID: NSPanel] = [:]

  public func pinImage(_ image: NSImage, title: String) {
    let id = UUID()
    let visible =
      (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main)?
      .visibleFrame ?? NSRect(x: 100, y: 100, width: 1280, height: 800)
    let rect = PinnedImageLayout.frame(imageSize: image.size, visibleFrame: visible)
    let baseSize = rect.size

    let panel = NSPanel(
      contentRect: rect,
      styleMask: [.borderless, .nonactivatingPanel, .resizable],
      backing: .buffered,
      defer: false
    )
    panel.minSize = NSSize(
      width: PinnedImageLayout.minWidth, height: PinnedImageLayout.minWidth * rect.height / rect.width)
    panel.aspectRatio = rect.size
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    panel.level = .floating
    panel.isFloatingPanel = true
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.isMovableByWindowBackground = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

    let view = PinnedFloatingImageView(
      image: image,
      title: title,
      onOpacity: { [weak panel] alpha in
        panel?.alphaValue = alpha
      },
      onLock: { [weak panel] locked in
        panel?.isMovableByWindowBackground = !locked
        if locked {
          panel?.styleMask.remove(.resizable)
        } else {
          panel?.styleMask.insert(.resizable)
        }
      },
      onZoom: { [weak panel] scale in
        guard let panel else { return }
        let size = NSSize(width: baseSize.width * scale, height: baseSize.height * scale)
        var f = NSRect(
          x: panel.frame.maxX - size.width, y: panel.frame.maxY - size.height,
          width: size.width, height: size.height)
        f.origin.x = min(max(f.origin.x, visible.minX), visible.maxX - f.width)
        f.origin.y = min(max(f.origin.y, visible.minY), visible.maxY - f.height)
        NSAnimationContext.runAnimationGroup { ctx in
          ctx.duration = VantaTheme.Motion.fadeDuration
          panel.animator().setFrame(f, display: true)
        }
      },
      onCopy: {
        QuickAccessPopupController.copyImageToClipboard(image)
      },
      onEdit: {
        AnnotateWindowController.shared.open(with: image, title: title)
      },
      onClose: { [weak self] in
        guard let p = self?.pinnedWindows[id] else { return }
        VantaPanelMotion.dismiss(p) {
          p.close()
          self?.pinnedWindows.removeValue(forKey: id)
        }
      }
    )
    let host = NSHostingView(rootView: view)
    host.sizingOptions = []  // the toolbar must never widen the panel past the screen edge
    panel.contentView = host
    panel.setFrame(rect, display: false)
    pinnedWindows[id] = panel
    VantaPanelMotion.present(panel, from: CGPoint(x: 0, y: 14))

    ToastBannerHUD.shared.show(
      message: "The image is pinned to the screen",
      subtitle: "Hover to show the tools, and double-click to open it in the editor.",
      icon: "pin.fill"
    )
  }
}

struct PinnedFloatingImageView: View {
  let image: NSImage
  let title: String
  let onOpacity: (Double) -> Void
  let onLock: (Bool) -> Void
  let onZoom: (Double) -> Void
  let onCopy: () -> Void
  let onEdit: () -> Void
  let onClose: () -> Void

  @State private var hovering = false
  @State private var locked = false
  @State private var zoom = 1.0
  @State private var opacity: Double = 1.0

  var body: some View {
    ZStack(alignment: .top) {
      Image(nsImage: image)
        .resizable()
        .scaledToFit()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onEdit() }
      toolbar
        .opacity(hovering ? 1 : 0)
        .offset(y: hovering ? 0 : -8)
        .allowsHitTesting(hovering)
    }
    .background(Color.black.opacity(0.25))
    .clipShape(RoundedRectangle(cornerRadius: VantaTheme.Radius.medium, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: VantaTheme.Radius.medium, style: .continuous)
        .strokeBorder(
          hovering
            ? AnyShapeStyle(VantaTheme.Palette.accent.opacity(0.95))
            : AnyShapeStyle(VantaTheme.Palette.specularRim),
          lineWidth: 1.5)
    )
    .animation(VantaTheme.Motion.fade, value: hovering)
    .onHover { hovering = $0 }
    .foregroundStyle(VantaTheme.Palette.text)
    .preferredColorScheme(.dark)
    .environment(\.layoutDirection, .leftToRight)
  }

  private var toolbar: some View {
    ViewThatFits(in: .horizontal) {
      toolbarRow(full: true)
      toolbarRow(full: false)
    }
    .padding(7)
    .vantaGlassCard(radius: VantaTheme.Radius.medium, shadow: false)
    .padding(8)
  }

  private func toolbarRow(full: Bool) -> some View {
    HStack(spacing: 6) {
      PillButton(icon: "xmark", help: "Close", action: onClose)
      HStack(spacing: 4) {
        Image(systemName: "pin.fill").font(.system(size: 10))
          .foregroundStyle(VantaTheme.Palette.accent)
        Text("\(title)")
          .font(VantaTheme.Font.label).lineLimit(1).truncationMode(.middle)
      }
      .layoutPriority(1)
      Spacer(minLength: 6)
      if full {
        Slider(value: $opacity, in: 0.25...1.0)
          .frame(width: 64).controlSize(.mini)
          .onChange(of: opacity) { onOpacity($0) }
          .help("Opacity")
        PillButton(icon: "minus.magnifyingglass", help: "Zoom Out") {
          zoom = max(0.5, zoom - 0.25)
          onZoom(zoom)
        }
        PillButton(icon: "plus.magnifyingglass", help: "Zoom In") {
          zoom = min(2.0, zoom + 0.25)
          onZoom(zoom)
        }
      }
      PillButton(icon: locked ? "lock.fill" : "lock.open", help: locked ? "Unlock" : "Lock Position") {
        locked.toggle()
        onLock(locked)
      }
      PillButton(icon: "doc.on.doc", help: "Copy", action: onCopy)
      if full {
        PillButton(icon: "pencil.and.outline", help: "Open in the Editor", action: onEdit)
      }
      ZStack {
        PillButton(icon: "hand.draw", help: "Drag the image to another app") {}
        NativeToolbarDragPill { image }
      }
      .frame(width: 30, height: 30)
    }
  }
}

@MainActor public final class CleanWorkflowCoordinator: ObservableObject {
  public static let shared = CleanWorkflowCoordinator()
  @Published public private(set) var history: [MediaAsset] = []
  @Published private(set) var trashedHistory: [MediaAsset] = []
  private var currentLease = RequestLease()
  @Published private(set) var session = CaptureSession()
  public weak var mainLauncherWindow: NSWindow?
  private var historyWindow: NSWindow?
  private var pending: Task<Void, Never>?
  private let store: HistoryStore
  public var isBusy: Bool { session.state != .idle || OCRService.isRunning }
  public init(historyRoot: URL? = nil) {
    store = HistoryStore(
      rootURL: historyRoot ?? AssetFiles.root, retentionLimit: AppSettings.shared.historyLimit)
    Task { await loadHistory() }
  }
  private func loadHistory() async {
    do {
      let manifest = try await store.load()
      let deleted = Set(manifest.deletedItemIDs ?? [])
      history = manifest.entries.filter { !deleted.contains($0.id) }
      trashedHistory = manifest.entries.filter { deleted.contains($0.id) }
      if let warning = manifest.warning {
        ToastBannerHUD.shared.show(message: warning, icon: "exclamationmark.triangle")
      }
    } catch { AssetFiles.showError(error) }
  }
  public func showLauncherWindow() {
    guard let w = mainLauncherWindow else { return }
    if w.isMiniaturized { w.deminiaturize(nil) }
    w.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
  public func executeMode(_ mode: CaptureMode) { CommandRouter.shared.perform(mode.command) }
  public func capturePreviousArea() { CommandRouter.shared.perform(.previousArea) }
  public func startSelfTimerCapture(seconds: Int) { CommandRouter.shared.perform(.selfTimer) }
  public func openFromClipboard() { CommandRouter.shared.perform(.clipboard) }
  public func openAnnotateDirectly() { CommandRouter.shared.perform(.annotate) }
  public func openHistoryWindow() { CommandRouter.shared.perform(.history) }
  public func restoreRecentlyClosed() { CommandRouter.shared.perform(.restore) }
  func perform(_ command: AppCommand) {
    if command == .recordToggle, session.state == .recording || session.state == .pausedRecording {
      LiveScreenRecorderController.shared.stopAndSaveGIF()
      return
    }
    switch command {
    case .showLauncher: showLauncherWindow()
    case .hideIcons: DesktopIconsCoverManager.shared.toggle()
    case .history: showHistory()
    case .clipboard:
      if let images = NSPasteboard.general.readObjects(forClasses: [NSImage.self], options: nil)
        as? [NSImage], let i = images.first
      {
        AnnotateWindowController.shared.open(with: i, title: "Clipboard Image")
      } else {
        ToastBannerHUD.shared.show(message: "There is no image on the clipboard.")
      }
    case .restore:
      Task {
        do {
          if let a = try await store.restoreLastClosed() ?? history.first {
            QuickAccessPopupController.shared.present(asset: a)
          } else {
            ToastBannerHUD.shared.show(message: "There is no capture to restore.")
          }
        } catch { AssetFiles.showError(error) }
      }
    case .annotate:
      if let a = history.first(where: { $0.kind == .stillImage }), let i = AssetFiles.preview(a) {
        AnnotateWindowController.shared.open(with: i, title: a.title)
      } else {
        begin(.fullscreen, annotate: true)
      }
    case .previousArea: begin(.area, previous: true)
    case .selfTimer: begin(.fullscreen, countdown: AppSettings.shared.timerSeconds)
    default:
      if let mode = CaptureMode.allCases.first(where: { $0.command == command }) { begin(mode) }
    }
  }
  private func begin(
    _ mode: CaptureMode, previous: Bool = false, countdown: Int = 0, annotate: Bool = false
  ) {
    OCRService.cancel()
    guard !isBusy else {
      ToastBannerHUD.shared.show(message: "Finish or cancel the current action first.")
      return
    }
    currentLease.cancel()
    currentLease = RequestLease()
    let fixedDisplayTarget = try? ScreenCaptureProvider.target()
    pending?.cancel()
    let id = session.begin(countdown > 0 ? .countdown : .selecting)
    mainLauncherWindow?.orderOut(nil)
    QuickAccessPopupController.shared.hideForCapture()
    ToastBannerHUD.shared.hide()
    pending = Task { @MainActor [self] in
      do {
        try await Task.sleep(nanoseconds: 160_000_000)
        for i in CountdownSequence.steps(from: countdown) {
          guard session.id == id else { return }
          CountdownOverlay.shared.show(step: i, region: nil)
          try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        CountdownOverlay.shared.hide()
        if countdown > 0 { try await Task.sleep(nanoseconds: 180_000_000) }
        ToastBannerHUD.shared.hide()
        try Task.checkCancellation()
        guard session.id == id else { return }
        if previous {
          guard let target = SelectionOverlayController.shared.lastCapturedTarget else {
            throw CaptureError.emptyCapture
          }
          let image = try await ScreenCaptureProvider.capture(target: target)
          guard session.id == id else { return }
          handle(.quickAccess(image, "Previous Area"), id: id)
        } else if countdown > 0 {
          guard let fixedDisplayTarget else { throw CaptureError.noDisplay }
          let image = try await ScreenCaptureProvider.capture(target: fixedDisplayTarget)
          guard session.id == id else { return }
          handle(.quickAccess(image, "Timer Capture"), id: id)
        } else {
          SelectionOverlayController.shared.onCancelled = { [weak self] in self?.finish(id) }
          SelectionOverlayController.shared.present(initialMode: mode) { [weak self] r in
            guard let self, self.session.id == id else { return }
            if annotate, case .quickAccess(let image, let title) = r {
              self.handle(.openAnnotate(image, title), id: id)
            } else {
              self.handle(r, id: id)
            }
          }
        }
      } catch {
        guard !Task.isCancelled, session.id == id else { return }
        AssetFiles.showError(error)
        finish(id)
      }
    }
  }
  func cancelCurrent() {
    currentLease.cancel()
    OCRService.cancel()
    pending?.cancel()
    pending = nil
    SelectionOverlayController.shared.dismiss()
    CountdownOverlay.shared.hide()
    LiveScrollingCaptureController.shared.cancel()
    LiveScreenRecorderController.shared.cancel()
    session.cancel()
    ToastBannerHUD.shared.hide()
    QuickAccessPopupController.shared.showAfterCapture()
    showLauncherWindow()
  }
  private func finish(_ id: UUID) {
    guard session.finish(id) else { return }
    pending = nil
    QuickAccessPopupController.shared.showAfterCapture()
    showLauncherWindow()
  }
  private func handle(_ result: SelectionOverlayController.CaptureResultAction, id: UUID) {
    guard session.id == id else { return }
    switch result {
    case .startScrolling(let r, let i):
      session.transition(.scrolling, id: id)
      LiveScrollingCaptureController.shared.onCancel = { [weak self] in self?.finish(id) }
      LiveScrollingCaptureController.shared.start(rectInAppKit: r.rect, initialImage: i, target: r)
      {
        [weak self] image in self?.handle(.quickAccess(image, "Scrolling Capture"), id: id)
      }
    case .startRecording(let r):
      session.transition(.recording, id: id)
      LiveScreenRecorderController.shared.onCancel = { [weak self] in self?.finish(id) }
      LiveScreenRecorderController.shared.onPauseChanged = { [weak self] paused in
        self?.session.transition(paused ? .pausedRecording : .recording, id: id)
      }
      LiveScreenRecorderController.shared.startRecording(rectInAppKit: r.rect, expectedTarget: r) {
        [weak self] asset in
        guard let self, self.session.id == id else { return }
        self.accept(asset, id: id)
      }
    default:
      let image: NSImage
      let title: String
      switch result {
      case .quickAccess(let i, let t), .openAnnotate(let i, let t):
        image = i
        title = t
      case .copyDirectly(let i):
        image = i
        title = "Copied"
      case .saveDirectly(let i):
        image = i
        title = "Saved"
      case .pinDirectly(let i):
        image = i
        title = "Pinned Capture"
      case .ocrDirectly(let i):
        image = i
        title = "Extract Text"
      default: return
      }
      do {
        let asset = try AssetFiles.makeImage(image, title: title)
        accept(asset, id: id) { storedAsset in
          switch result {
          case .openAnnotate: AnnotateWindowController.shared.open(with: image, title: title)
          case .copyDirectly:
            do { try AssetFiles.copy(storedAsset) } catch { AssetFiles.showError(error) }
          case .saveDirectly:
            do { try AssetFiles.save(storedAsset) } catch { AssetFiles.showError(error) }
          case .pinDirectly: FloatingPinWindowManager.shared.pinImage(image, title: title)
          case .ocrDirectly: OCRService.extractAndCopyText(from: image)
          default: QuickAccessPopupController.shared.present(asset: storedAsset)
          }
        }
      } catch {
        AssetFiles.showError(error)
        finish(id)
      }
    }
  }
  private func accept(_ asset: MediaAsset, id: UUID, action: ((MediaAsset) -> Void)? = nil) {
    session.transition(.exporting, id: id)
    let lease = currentLease
    pending = Task {
      do {
        try lease.check()
        await store.updateRetentionLimit(AppSettings.shared.historyLimit)
        try await store.insert(asset, lease: lease)
        try lease.check()
        await loadHistory()
        guard session.id == id, lease.isValid else { return }
        let stored = history.first { $0.id == asset.id } ?? asset
        finish(id)
        if let action {
          action(stored)
        } else {
          QuickAccessPopupController.shared.present(asset: stored)
        }
        AssetFiles.removeTransientOriginal(asset, stored: stored)
      } catch {
        guard lease.isValid, session.id == id else { return }
        AssetFiles.showError(error)
        finish(id)
        QuickAccessPopupController.shared.present(asset: asset)
      }
    }
  }
  func trash(_ asset: MediaAsset) { trash([asset]) }
  func trash(_ assets: [MediaAsset]) {
    guard !assets.isEmpty else { return }
    Task {
      do {
        try await store.moveToTrash(assets.map(\.id))
        await loadHistory()
      } catch { AssetFiles.showError(error) }
    }
  }
  /// Asks first, then deletes the trashed files from disk for good.
  func confirmEmptyTrash() {
    let count = trashedHistory.count
    guard count > 0 else { return }
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Permanently delete \(count) \(count == 1 ? "item" : "items")?"
    alert.informativeText = "The files are removed from this Mac. You can't undo this."
    alert.addButton(withTitle: "Delete")
    alert.addButton(withTitle: "Cancel")
    alert.buttons.first?.hasDestructiveAction = true
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    Task {
      do {
        let removed = try await store.emptyTrash()
        await loadHistory()
        ToastBannerHUD.shared.show(
          message: "Deleted \(removed) \(removed == 1 ? "item" : "items") from this Mac", icon: "trash")
      } catch { AssetFiles.showError(error) }
    }
  }
  func restoreTrash(_ asset: MediaAsset) {
    Task {
      do {
        try await store.restoreFromTrash(asset.id)
        await loadHistory()
      } catch { AssetFiles.showError(error) }
    }
  }
  func addExternalAsset(_ asset: MediaAsset) {
    Task {
      do {
        await store.updateRetentionLimit(AppSettings.shared.historyLimit)
        try await store.insert(asset)
        await loadHistory()
        QuickAccessPopupController.shared.present(
          asset: history.first { $0.id == asset.id } ?? asset)
      } catch {
        AssetFiles.showError(error)
        QuickAccessPopupController.shared.present(asset: asset)
      }
    }
  }
  func markClosed(_ id: UUID) {
    Task { do { try await store.markClosed(id) } catch { AssetFiles.showError(error) } }
  }
  private func showHistory() {
    if historyWindow == nil {
      let w = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
        styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered,
        defer: false)
      w.isReleasedWhenClosed = false
      w.minSize = NSSize(width: 680, height: 460)
      w.title = "VantaShot History"
      VantaWindowGlass.configure(w)
      let host = QuickLookHostView(frame: NSRect(x: 0, y: 0, width: 900, height: 620))
      host.autoresizingMask = [.width, .height]
      let hosting = NSHostingView(rootView: CaptureHistoryWindowView(coordinator: self))
      hosting.frame = host.bounds
      hosting.autoresizingMask = [.width, .height]
      host.addSubview(hosting)
      w.contentView = host
      HistoryQuickLook.shared.host = host
      w.center()
      historyWindow = w
    }
    historyWindow?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
}
@MainActor final class CommandRouter {
  static let shared = CommandRouter()
  func perform(_ command: AppCommand) { CleanWorkflowCoordinator.shared.perform(command) }
}
extension CaptureMode {
  var command: AppCommand {
    switch self {
    case .allInOne: return .allInOne
    case .area: return .area
    case .fullscreen: return .fullscreen
    case .window: return .window
    case .scrolling: return .scrolling
    case .ocr: return .ocr
    case .record: return .recordToggle
    }
  }
}
struct CaptureHistoryWindowView: View {
  @ObservedObject var coordinator: CleanWorkflowCoordinator
  @State private var filter = HistoryFilter()
  @State private var selection = HistorySelectionModel()
  static let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US")
    f.dateStyle = .medium
    f.timeStyle = .short
    return f
  }()
  private var items: [MediaAsset] { filter.apply(to: coordinator.history) }
  private var selectedAssets: [MediaAsset] { items.filter { selection.contains($0.id) } }
  private var selectedURLs: [URL] { selectedAssets.map(\.fileURL) }

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      if selection.isSelecting || !selection.isEmpty { selectionBar }
      if items.isEmpty {
        emptyState
      } else {
        ScrollView {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 228), spacing: 14)], spacing: 14) {
            ForEach(items) { a in
              HistoryCard(
                asset: a, dateText: Self.dateFormatter.string(from: a.date),
                isSelected: selection.contains(a.id),
                showsCheckbox: selection.isSelecting,
                dragURLs: { selection.contains(a.id) ? selectedURLs : [a.fileURL] },
                onClick: { command, shift in
                  selection.click(a.id, in: items.map(\.id), command: command, shift: shift)
                  HistoryQuickLook.shared.update(urls: selectedURLs)
                }
              ) {
                open(a)
              } onCopy: {
                do { try AssetFiles.copy(a) } catch { AssetFiles.showError(error) }
              } onCard: {
                QuickAccessPopupController.shared.present(asset: a)
              } onTrash: {
                coordinator.trash(a)
              }
            }
          }
          .padding(16)
        }
        .contentShape(Rectangle())
        .onTapGesture { if !selection.isSelecting { selection.clear() } }
      }
    }
    .background(WindowKeyCatcher(handler: handleKey))
    .onChange(of: coordinator.history) { _ in selection.prune(keeping: items.map(\.id)) }
    .onChange(of: filter) { _ in selection.prune(keeping: items.map(\.id)) }
    .vantaWindowBackground()
    .foregroundStyle(VantaTheme.Palette.text)
    .preferredColorScheme(.dark)
    .environment(\.layoutDirection, .leftToRight)
    .frame(minWidth: 660, minHeight: 420)
  }

  private var toolbar: some View {
    HStack(spacing: 12) {
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass").foregroundStyle(VantaTheme.Palette.textSecondary)
        TextField("Search by title or type", text: $filter.query).textFieldStyle(.plain)
        if !filter.query.isEmpty {
          Button { filter.query = "" } label: { Image(systemName: "xmark.circle.fill") }
            .buttonStyle(.plain).foregroundStyle(VantaTheme.Palette.textSecondary)
        }
      }
      .padding(.horizontal, 10).padding(.vertical, 6)
      .vantaSurfaceCard(radius: VantaTheme.Radius.small)
      .frame(maxWidth: 300)
      Picker("", selection: $filter.kind) {
        Text("All").tag(MediaKind?.none)
        Text("Image").tag(MediaKind?.some(.stillImage))
        Text("GIF").tag(MediaKind?.some(.animatedImage))
        Text("Video").tag(MediaKind?.some(.video))
      }.pickerStyle(.segmented).frame(width: 260)
      Spacer()
      Text("\(items.count) \(items.count == 1 ? "item" : "items")").font(VantaTheme.Font.caption)
        .foregroundStyle(VantaTheme.Palette.textSecondary)
      VantaIconButton(title: "Select All", icon: "checkmark.circle.fill", shortcut: "⌘A", compact: true) {
        selectAll()
      }
      .disabled(items.isEmpty)
      VantaIconButton(
        title: selection.isSelecting ? "Done" : "Select",
        icon: selection.isSelecting ? "xmark.circle" : "checkmark.circle",
        role: selection.isSelecting ? .prominent : .neutral, compact: true
      ) {
        if selection.isSelecting { selection.endSelecting() } else { selection.isSelecting = true }
        HistoryQuickLook.shared.update(urls: selectedURLs)
      }
      .disabled(items.isEmpty && !selection.isSelecting)
      if !coordinator.trashedHistory.isEmpty {
        Menu {
          ForEach(coordinator.trashedHistory) { a in
            Button(a.title) { coordinator.restoreTrash(a) }
          }
          Divider()
          Button("Empty Trash…", role: .destructive) { coordinator.confirmEmptyTrash() }
        } label: {
          Label("Restore (\(coordinator.trashedHistory.count))", systemImage: "trash.slash")
        }
        .menuStyle(.borderlessButton).fixedSize()
      }
    }
    .padding(.horizontal, 16).padding(.top, 34).padding(.bottom, 10)
  }

  private var selectionBar: some View {
    HStack(spacing: 8) {
      Text(
        selection.isEmpty
          ? "Click items to select them" : "\(selection.ids.count) of \(items.count) selected"
      ).font(VantaTheme.Font.label)
      Spacer()
      VantaIconButton(title: "Preview", icon: "eye", shortcut: "␣", compact: true) {
        HistoryQuickLook.shared.toggle(urls: selectedURLs)
      }
      VantaIconButton(title: "Copy", icon: "doc.on.doc", shortcut: "⌘C", compact: true) { copySelection() }
      VantaIconButton(title: "Save", icon: "square.and.arrow.down", compact: true) { saveSelection() }
      VantaIconButton(title: "Delete", icon: "trash", shortcut: "⌫", role: .destructive, compact: true) {
        trashSelection()
      }
      .disabled(selection.isEmpty)
      PillButton(icon: "xmark", help: "Clear Selection (Esc)") { selection.endSelecting() }
    }
    .padding(.horizontal, 14).padding(.vertical, 8)
    .vantaSurfaceCard(radius: VantaTheme.Radius.medium, isSelected: true)
    .padding(.horizontal, 16).padding(.bottom, 6)
    .transition(.move(edge: .top).combined(with: .opacity))
  }

  private func handleKey(_ e: NSEvent) -> Bool {
    let cmd = e.modifierFlags.contains(.command)
    switch (e.keyCode, cmd) {
    case (49, false):  // space
      guard !selection.isEmpty else { return false }
      HistoryQuickLook.shared.toggle(urls: selectedURLs)
      return true
    case (0, true):  // ⌘A
      selectAll()
      return true
    case (8, true):  // ⌘C
      guard !selection.isEmpty else { return false }
      copySelection()
      return true
    case (51, _), (117, _):  // delete / forward delete
      guard !selection.isEmpty else { return false }
      trashSelection()
      return true
    case (53, false):  // esc
      guard selection.isSelecting || !selection.isEmpty else { return false }
      selection.endSelecting()
      return true
    default: return false
    }
  }

  private func copySelection() {
    let urls = selectedURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
    guard !urls.isEmpty else { return }
    if urls.count == 1, let a = selectedAssets.first {
      do { try AssetFiles.copy(a) } catch { AssetFiles.showError(error) }
      return
    }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.writeObjects(urls as [NSURL])
    ToastBannerHUD.shared.show(message: "Copied \(urls.count) \(urls.count == 1 ? "file" : "files") to the clipboard", icon: "doc.on.doc")
  }
  private func saveSelection() {
    var saved = 0
    for a in selectedAssets {
      do {
        try AssetFiles.save(a)
        saved += 1
      } catch { AssetFiles.showError(error) }
    }
    if saved > 0 {
      ToastBannerHUD.shared.show(
        message: "Saved \(saved) \(saved == 1 ? "item" : "items")", subtitle: AppSettings.shared.outputPath,
        icon: "square.and.arrow.down")
    }
  }
  private func selectAll() {
    selection.selectAll(items.map(\.id))
    HistoryQuickLook.shared.update(urls: selectedURLs)
  }
  private func trashSelection() {
    let assets = selectedAssets
    guard !assets.isEmpty else { return }
    coordinator.trash(assets)
    selection.endSelecting()
    ToastBannerHUD.shared.show(
      message: "Moved \(assets.count) \(assets.count == 1 ? "item" : "items") to Trash",
      subtitle: "Use Restore to bring them back, or Empty Trash to delete the files.", icon: "trash")
  }

  private var emptyState: some View {
    VStack(spacing: 10) {
      Image(systemName: coordinator.history.isEmpty ? "camera.viewfinder" : "magnifyingglass")
        .font(.system(size: 34, weight: .light)).foregroundStyle(VantaTheme.Palette.textSecondary)
      Text(coordinator.history.isEmpty ? "No saved captures yet" : "No matching results")
        .font(VantaTheme.Font.title)
      Text(coordinator.history.isEmpty ? "Everything you capture shows up here." : "Try another word, or clear the filter.")
        .font(VantaTheme.Font.body).foregroundStyle(VantaTheme.Palette.textSecondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func open(_ a: MediaAsset) {
    guard FileManager.default.fileExists(atPath: a.fileURL.path) else {
      AssetFiles.showError(StorageError.missingFile)
      return
    }
    if a.kind == .stillImage, let i = AssetFiles.preview(a) {
      AnnotateWindowController.shared.open(with: i, title: a.title)
    } else {
      NSWorkspace.shared.open(a.fileURL)
    }
  }
}

struct HistoryCard: View {
  let asset: MediaAsset
  let dateText: String
  var isSelected = false
  var showsCheckbox = false
  var dragURLs: () -> [URL] = { [] }
  var onClick: (_ command: Bool, _ shift: Bool) -> Void = { _, _ in }
  let onOpen: () -> Void
  let onCopy: () -> Void
  let onCard: () -> Void
  let onTrash: () -> Void
  @State private var hovering = false
  private var missing: Bool { !FileManager.default.fileExists(atPath: asset.fileURL.path) }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ZStack(alignment: .bottomLeading) {
        Color.black.opacity(0.3)
          .frame(height: 138)
          .overlay {
            if let i = AssetFiles.preview(asset) {
              Image(nsImage: i).resizable().aspectRatio(contentMode: .fill)
            } else {
              Image(systemName: asset.kind.icon).font(.system(size: 28))
                .foregroundStyle(VantaTheme.Palette.textSecondary)
            }
          }
          .clipped()
          .overlay(HistoryDragSurface(dragURLs: dragURLs, onClick: onClick, onDoubleClick: onOpen))
        HStack(spacing: 4) {
          Image(systemName: asset.kind.icon).font(.system(size: 9, weight: .bold))
          Text(asset.kind.friendlyName).font(.system(size: 10, weight: .bold))
          if let d = asset.duration, d > 0 {
            Text(String(format: "%d:%02d", Int(d) / 60, Int(d) % 60))
              .font(VantaTheme.Font.number)
          }
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(Color.black.opacity(0.6)))
        .padding(6)
        .allowsHitTesting(false)
      }
      .overlay(alignment: .topTrailing) {
        if showsCheckbox {
          Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(isSelected ? VantaTheme.Palette.accent : Color.white.opacity(0.85))
            .background(Circle().fill(Color.black.opacity(0.45)).padding(1))
            .padding(8)
            .allowsHitTesting(false)
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: VantaTheme.Radius.small, style: .continuous))
      HStack {
        Text(asset.title).font(VantaTheme.Font.body).lineLimit(1)
        Spacer(minLength: 4)
        HStack(spacing: 4) {
          PillButton(icon: "pencil.and.outline", help: "Open", action: onOpen)
          PillButton(icon: "doc.on.doc", help: "Copy", action: onCopy)
          PillButton(icon: "rectangle.on.rectangle", help: "Quick access card", action: onCard)
          PillButton(icon: "trash", help: "Delete", action: onTrash)
        }
        .scaleEffect(0.8)
        .opacity(hovering ? 1 : 0)
        .frame(height: 24)
      }
      HStack {
        Text(dateText).font(VantaTheme.Font.caption).foregroundStyle(VantaTheme.Palette.textSecondary)
        Spacer()
        Text("\(asset.pixelSize.width) × \(asset.pixelSize.height)")
          .font(VantaTheme.Font.number).foregroundStyle(VantaTheme.Palette.textSecondary)
      }
      if missing {
        Label("File unavailable", systemImage: "exclamationmark.triangle")
          .font(VantaTheme.Font.caption).foregroundStyle(VantaTheme.Palette.warning)
      }
    }
    .padding(10)
    .vantaSurfaceCard(
      radius: VantaTheme.Radius.medium,
      isSelected: isSelected,
      isHovering: hovering,
      shadow: true
    )
    .scaleEffect(hovering ? 1.012 : 1)
    .animation(VantaTheme.Motion.fade, value: hovering)
    .animation(VantaTheme.Motion.fade, value: isSelected)
    .onHover { hovering = $0 }
  }
}
