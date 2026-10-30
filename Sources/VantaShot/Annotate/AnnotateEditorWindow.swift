import AppKit
import CoreImage
import SwiftUI
import UniformTypeIdentifiers
import VantaShotCore
import VantaShotRendering

@MainActor
public final class AnnotateWindowController: ObservableObject {
  public static let shared = AnnotateWindowController()
  public static let projectContentType =
    UTType(importedAs: "dev.vantashot.project", conformingTo: .json)
  private var window: NSWindow?
  private var source: CGImage?
  private var history = DocumentHistory(AnnotationDocument(size: PixelSize(width: 1, height: 1)))
  private let renderer = DocumentRenderer()
  private var isSyncingSelection = false
  @Published public private(set) var document = AnnotationDocument(
    size: PixelSize(width: 1, height: 1))
  @Published public var documentTitle = "Edit Capture"
  @Published public var selectedTool: AnnotationTool = .arrow
  @Published public var selectedID: UUID?
  @Published public var showBackgroundBar = true
  @Published public var activeColor: Color = .red {
    didSet { if !isSyncingSelection, selectedID != nil { updateSelection() } }
  }
  @Published public var strokeWidth: CGFloat = 5 {
    didSet { if !isSyncingSelection, selectedID != nil { updateSelection() } }
  }
  @Published var fontFamily = "Helvetica" {
    didSet { if !isSyncingSelection, selectedID != nil { updateSelection() } }
  }
  @Published public var fontSize: CGFloat = 32 {
    didSet { if !isSyncingSelection, selectedID != nil { updateSelection() } }
  }
  @Published public var customText = "Note" {
    didSet { if !isSyncingSelection, selectedID != nil { updateSelection() } }
  }
  @Published public var doubleArrow = false {
    didSet { if !isSyncingSelection, selectedID != nil { updateSelection() } }
  }
  @Published public private(set) var preview: NSImage?
  @Published public private(set) var errorMessage: String?
  public var canUndo: Bool { history.canUndo }
  public var canRedo: Bool { history.canRedo }
  public var baseImage: NSImage {
    source.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
      ?? NSImage()
  }
  public func open(with image: NSImage, title: String) {
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      report(RenderError.missingImage)
      return
    }
    source = cg
    documentTitle = title
    document = AnnotationDocument(size: PixelSize(width: cg.width, height: cg.height))
    history = DocumentHistory(document)
    selectedID = nil
    refresh()
    showWindow()
  }
  private func showWindow() {
    if window == nil {
      let w = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1200, height: 780),
        styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered,
        defer: false)
      w.isReleasedWhenClosed = false
      w.minSize = NSSize(width: 960, height: 650)
      VantaWindowGlass.configure(w)
      w.center()
      w.contentView = NSHostingView(rootView: AnnotateEditorRootView(controller: self))
      window = w
    }
    window?.title = documentTitle
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
  public func commit(_ d: AnnotationDocument) {
    history.apply(d)
    document = history.current
    refresh()
  }
  public func previewDocument(_ d: AnnotationDocument) {
    document = d
    refresh()
  }
  public func undo() {
    history.undo()
    document = history.current
    selectedID = nil
    refresh()
  }
  public func redo() {
    history.redo()
    document = history.current
    selectedID = nil
    refresh()
  }
  public func clearAll() {
    var d = document
    d.objects = []
    d.nextCounter = 1
    commit(d)
    selectedID = nil
  }
  public func deleteSelection() {
    guard let id = selectedID else { return }
    var d = document
    d.objects.removeAll { $0.id == id }
    commit(d)
    selectedID = nil
  }
  public func updateSelection() {
    guard let i = document.objects.firstIndex(where: { $0.id == selectedID }) else { return }
    var d = document
    d.objects[i].color = rgba
    d.objects[i].lineWidth = strokeWidth
    d.objects[i].fontSize = fontSize
    d.objects[i].fontFamily = fontFamily
    d.objects[i].text = customText
    d.objects[i].doubleArrow = doubleArrow
    commit(d)
  }
  public func select(_ id: UUID?) {
    selectedID = id
    if let o = document.objects.first(where: { $0.id == id }) {
      isSyncingSelection = true
      defer { isSyncingSelection = false }
      activeColor = Color(
        red: o.color.red, green: o.color.green, blue: o.color.blue, opacity: o.color.alpha)
      strokeWidth = o.lineWidth
      fontSize = o.fontSize
      fontFamily = o.fontFamily ?? "Helvetica"
      customText = o.text
      doubleArrow = o.doubleArrow
    }
  }
  var rgba: RGBA {
    let c = NSColor(activeColor).usingColorSpace(.deviceRGB) ?? .red
    return RGBA(c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
  }
  public func newObject(points: [CGPoint]) -> AnnotationObject {
    var o = AnnotationObject(
      tool: selectedTool, points: points, color: rgba, lineWidth: strokeWidth, text: customText,
      fontSize: fontSize, stepIndex: document.nextCounter)
    o.doubleArrow = doubleArrow
    o.fontFamily = fontFamily
    return o
  }
  func renderedBounds(_ o: AnnotationObject) -> CGRect {
    o.tool == .text ? renderer.textBounds(o) : o.bounds
  }
  public func hitTest(_ p: CGPoint, tolerance: CGFloat) -> UUID? {
    document.objects.reversed().first { renderer.hitTest(p, object: $0, tolerance: tolerance) }?.id
  }
  public func renderFinalImage() throws -> NSImage {
    guard let source else { throw RenderError.missingImage }
    let cg = try renderer.render(document: document, source: source)
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
  }
  public func renderedForDrag() -> NSImage? {
    do { return try renderFinalImage() } catch {
      report(error)
      return nil
    }
  }
  public func copy() {
    do { QuickAccessPopupController.copyImageToClipboard(try renderFinalImage()) } catch {
      report(error)
    }
  }
  public func save() {
    do { _ = QuickAccessPopupController.saveImageToDesktop(try renderFinalImage()) } catch {
      report(error)
    }
  }
  private func refresh() {
    do {
      preview = try renderFinalImage()
      errorMessage = nil
    } catch {
      preview = nil
      errorMessage = error.localizedDescription
    }
  }
  private func report(_ error: Error) {
    errorMessage = error.localizedDescription
    ToastBannerHUD.shared.show(
      message: error.localizedDescription, icon: "exclamationmark.triangle")
  }
  public func saveProject() {
    guard let source else { return }
    let p = NSSavePanel()
    p.allowedContentTypes = [
      UTType(filenameExtension: "vantashot") ?? Self.projectContentType
    ]
    p.nameFieldStringValue = "Document.vantashot"
    p.canCreateDirectories = true
    guard p.runModal() == .OK, let url = p.url else { return }
    do {
      let data = NSMutableData()
      guard
        let dst = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
      else { throw RenderError.allocationFailed }
      CGImageDestinationAddImage(dst, source, nil)
      guard CGImageDestinationFinalize(dst) else { throw RenderError.allocationFailed }
      try DocumentStore.save(document: document, sourcePNG: data as Data, to: url)
    } catch { report(error) }
  }
  public func openProject(_ url: URL) {
    do {
      let p = try DocumentStore.load(from: url)
      guard let s = CGImageSourceCreateWithData(p.sourcePNG as CFData, nil),
        let cg = CGImageSourceCreateImageAtIndex(s, 0, nil)
      else { throw RenderError.missingImage }
      source = cg
      document = p.document
      history = DocumentHistory(document)
      documentTitle = url.lastPathComponent
      selectedID = nil
      refresh()
      showWindow()
    } catch { report(error) }
  }
  func useWallpaper() {
    guard let screen = NSScreen.main, let url = NSWorkspace.shared.desktopImageURL(for: screen),
      let image = NSImage(contentsOf: url)
    else {
      report(RenderError.missingImage)
      return
    }
    do {
      var d = document
      d.background.enabled = true
      d.background.wallpaperPNG = try AssetFiles.png(image)
      commit(d)
    } catch { report(error) }
  }
  func useImageColors() {
    guard let source else { return }
    let ci = CIImage(cgImage: source).applyingFilter(
      "CIAreaAverage",
      parameters: [
        kCIInputExtentKey: CIVector(
          cgRect: CGRect(x: 0, y: 0, width: source.width, height: source.height))
      ])
    var bytes = [UInt8](repeating: 0, count: 4)
    CIContext().render(
      ci, toBitmap: &bytes, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
      format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
    var d = document
    d.background.wallpaperPNG = nil
    d.background.enabled = true
    let r = Double(bytes[0]) / 255
    let g = Double(bytes[1]) / 255
    let b = Double(bytes[2]) / 255
    d.background.first = RGBA(r, g, b)
    d.background.second = RGBA(min(1, r + 0.25), min(1, g + 0.2), min(1, b + 0.3))
    commit(d)
  }
  public func insertImage() {
    let p = NSOpenPanel()
    p.allowedContentTypes = [.image]
    guard p.runModal() == .OK, let u = p.url else { return }
    do {
      var o = AnnotationObject(
        tool: .image,
        points: [
          CGPoint(x: document.cropRect.minX + 20, y: document.cropRect.minY + 20),
          CGPoint(x: document.cropRect.minX + 220, y: document.cropRect.minY + 170),
        ])
      o.imageData = try Data(contentsOf: u)
      var d = document
      d.objects.append(o)
      commit(d)
      select(o.id)
      selectedTool = .select
    } catch { report(error) }
  }
}

struct AnnotateEditorRootView: View {
  @ObservedObject var controller: AnnotateWindowController
  @State private var showBackground = false
  private static let swatches: [Color] = [
    .red, .orange, .yellow, .green, VantaTheme.Palette.accent, .blue, .purple, .white, .black,
  ]
  private static let fontFamilies: [String] = {
    let preferred = ["Helvetica", "Helvetica Neue", "Arial", "Avenir Next", "Menlo", "Georgia"]
    let all = NSFontManager.shared.availableFontFamilies
    return preferred.filter(all.contains) + all.filter { !preferred.contains($0) }
  }()

  var body: some View {
    VStack(spacing: 0) {
      topBar
      Divider().overlay(Color.white.opacity(0.10))
      HStack(spacing: 0) {
        toolsColumn
        Divider().overlay(Color.white.opacity(0.08))
        EditorCanvas(controller: controller)
          .background(Color.black.opacity(0.28))
          .clipped()
        Divider().overlay(Color.white.opacity(0.08))
        inspector.frame(width: 244)
      }
      Divider().overlay(Color.white.opacity(0.10))
      statusBar
    }
    .background(WindowKeyCatcher(handler: handleKey))
    .vantaWindowBackground()
    .foregroundStyle(VantaTheme.Palette.text)
    .preferredColorScheme(.dark)
    .environment(\.layoutDirection, .leftToRight)
    .onAppear { showBackground = controller.document.background.enabled }
  }

  private func handleKey(_ e: NSEvent) -> Bool {
    let cmd = e.modifierFlags.contains(.command)
    let shift = e.modifierFlags.contains(.shift)
    if cmd {
      switch e.charactersIgnoringModifiers?.lowercased() {
      case "c":
        controller.copy()
        return true
      case "s":
        controller.save()
        return true
      case "z":
        shift ? controller.redo() : controller.undo()
        return true
      default:
        return false
      }
    }
    switch e.keyCode {
    case 51, 117:
      guard controller.selectedID != nil else { return false }
      controller.deleteSelection()
      return true
    case 53:
      guard controller.selectedID != nil else { return false }
      controller.select(nil)
      return true
    default:
      return false
    }
  }

  private var topBar: some View {
    HStack(spacing: 8) {
      Text("\(controller.documentTitle)").font(VantaTheme.Font.title).lineLimit(1)
        .truncationMode(.middle).frame(maxWidth: 260, alignment: .leading)
      Spacer()
      PillButton(icon: "arrow.uturn.backward", help: "Undo ⌘Z", action: controller.undo)
        .disabled(!controller.canUndo).opacity(controller.canUndo ? 1 : 0.4)
      PillButton(icon: "arrow.uturn.forward", help: "Redo ⇧⌘Z", action: controller.redo)
        .disabled(!controller.canRedo).opacity(controller.canRedo ? 1 : 0.4)
      PillButton(icon: "trash", help: "Delete the selected item ⌫", action: controller.deleteSelection)
        .disabled(controller.selectedID == nil).opacity(controller.selectedID == nil ? 0.4 : 1)
      PillButton(icon: "eraser", help: "Clear all annotations", action: controller.clearAll)
      Menu {
        Button("Save Editable Project…", action: controller.saveProject)
        Button("Open Project…") {
          let p = NSOpenPanel()
          if let extType = UTType(filenameExtension: "vantashot") {
            p.allowedContentTypes = [extType]
          }
          if p.runModal() == .OK, let u = p.url { controller.openProject(u) }
        }
      } label: {
        Image(systemName: "doc").font(.system(size: 12, weight: .semibold)).frame(width: 30, height: 30)
      }
      .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 30, height: 30)
      .background(Circle().fill(VantaTheme.Palette.fillSubtle))
      .overlay(Circle().strokeBorder(VantaTheme.Palette.stroke, lineWidth: 1))
      .help("Document")
      Divider().frame(height: 22)
      VantaIconButton(title: "Save", icon: "square.and.arrow.down", shortcut: "⌘S", compact: true, action: controller.save)
      VantaIconButton(title: "Copy", icon: "doc.on.doc", shortcut: "⌘C", role: .prominent, compact: true, action: controller.copy)
      ZStack {
        VantaIconButton(title: "Drag", icon: "hand.draw", compact: true) {}
        NativeToolbarDragPill { controller.renderedForDrag() }
      }
      .frame(width: 64, height: 46)
      .help("Drag the finished image to any app")
    }
    .padding(.horizontal, 14).padding(.top, 30).padding(.bottom, 10)
    .background(
      LinearGradient(
        colors: [Color.white.opacity(0.07), Color.white.opacity(0.02)],
        startPoint: .top,
        endPoint: .bottom
      )
    )
  }

  private var toolsColumn: some View {
    VStack(spacing: 6) {
      LazyVGrid(columns: [GridItem(.fixed(38), spacing: 6), GridItem(.fixed(38), spacing: 6)], spacing: 6) {
        ForEach(AnnotationTool.allCases, id: \.self) { t in
          ToolButton(tool: t, isSelected: controller.selectedTool == t) {
            if t == .image { controller.insertImage() } else { controller.selectedTool = t }
          }
        }
      }
      Spacer()
    }
    .padding(10).frame(width: 104)
    .background(Color.white.opacity(0.03))
  }

  private var statusBar: some View {
    HStack {
      Text(
        controller.errorMessage
          ?? "\(Int(controller.document.cropRect.width)) × \(Int(controller.document.cropRect.height)) px • \(controller.selectedTool.title)"
      ).font(VantaTheme.Font.caption).foregroundStyle(VantaTheme.Palette.textSecondary)
      Spacer()
      Text("⌘Z Undo • ⇧⌘Z Redo • Esc clears the selection").font(VantaTheme.Font.caption)
        .foregroundStyle(VantaTheme.Palette.textSecondary)
    }
    .padding(.horizontal, 14).padding(.vertical, 8)
    .background(Color.black.opacity(0.18))
  }

  private var inspector: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        let sections = InspectorSections.for(controller.selectedTool)
        HStack(spacing: 6) {
          Image(systemName: controller.selectedTool.icon).foregroundStyle(VantaTheme.Palette.accent)
          Text(controller.selectedTool.title).font(VantaTheme.Font.title)
          Spacer()
        }
        if sections.isEmpty {
          Text(hint(for: controller.selectedTool)).font(VantaTheme.Font.caption)
            .foregroundStyle(VantaTheme.Palette.textSecondary)
        }
        if sections.contains(.color) {
          colorSection
            .padding(10)
            .vantaSurfaceCard(radius: VantaTheme.Radius.small)
        }
        if sections.contains(.stroke) {
          sliderRow("Thickness", value: $controller.strokeWidth, range: 1...32)
            .padding(10)
            .vantaSurfaceCard(radius: VantaTheme.Radius.small)
        }
        if sections.contains(.text) {
          textSection
            .padding(10)
            .vantaSurfaceCard(radius: VantaTheme.Radius.small)
        }
        if sections.contains(.arrowStyle) {
          Toggle("Arrow on both ends", isOn: $controller.doubleArrow).toggleStyle(.switch).controlSize(.small)
            .padding(10)
            .vantaSurfaceCard(radius: VantaTheme.Radius.small)
        }
        if controller.selectedID != nil && !sections.isEmpty {
          VantaIconButton(title: "Apply to Selection", icon: "checkmark", compact: true, action: controller.updateSelection)
        }
        backgroundSection
          .padding(10)
          .vantaSurfaceCard(radius: VantaTheme.Radius.small)
      }
      .padding(12)
    }
    .background(Color.white.opacity(0.035))
  }

  private var colorSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Color").font(VantaTheme.Font.label).foregroundStyle(VantaTheme.Palette.textSecondary)
      HStack(spacing: 6) {
        ForEach(Array(Self.swatches.enumerated()), id: \.offset) { _, c in
          Button { controller.activeColor = c } label: {
            Circle().fill(c).frame(width: 18, height: 18)
              .overlay(Circle().strokeBorder(Color.white.opacity(0.5), lineWidth: 1))
          }.buttonStyle(.plain)
        }
        ColorPicker("", selection: $controller.activeColor).labelsHidden().frame(width: 24)
      }
    }
  }

  private var textSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Text").font(VantaTheme.Font.label).foregroundStyle(VantaTheme.Palette.textSecondary)
      TextField("Text", text: $controller.customText).textFieldStyle(.roundedBorder)
      Picker("Font", selection: $controller.fontFamily) {
        ForEach(Self.fontFamilies, id: \.self) { Text($0).tag($0) }
      }.labelsHidden()
      sliderRow("Text size", value: $controller.fontSize, range: 12...120)
    }
  }

  private var backgroundSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Toggle(isOn: background(\.enabled)) {
        Text("Background").font(VantaTheme.Font.title)
      }.toggleStyle(.switch).controlSize(.small)
      if controller.document.background.enabled {
        Text("Templates").font(VantaTheme.Font.label).foregroundStyle(VantaTheme.Palette.textSecondary)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
          ForEach(BackgroundTemplate.all) { t in
            Button {
              var d = controller.document
              d.background.wallpaperPNG = nil
              d.background.first = t.first
              d.background.second = t.second
              controller.commit(d)
            } label: {
              RoundedRectangle(cornerRadius: 7, style: .continuous).fill(t.gradient)
                .frame(height: 30)
                .overlay(
                  RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(
                      isCurrent(t) ? VantaTheme.Palette.text : VantaTheme.Palette.stroke,
                      lineWidth: isCurrent(t) ? 2 : 1))
            }.buttonStyle(.plain).help(t.name)
          }
        }
        HStack(spacing: 6) {
          VantaIconButton(title: "Desktop", icon: "desktopcomputer", compact: true, action: controller.useWallpaper)
          VantaIconButton(title: "Image Colors", icon: "eyedropper", compact: true, action: controller.useImageColors)
        }
        VantaIconButton(
          title: "Mac Window Frame", icon: "macwindow",
          isSelected: controller.document.background.frame == .macWindow, compact: true
        ) {
          var d = controller.document
          d.background.frame = d.background.frame == .macWindow ? .none : .macWindow
          controller.commit(d)
        }
        .help("Adds a title bar with the three window buttons above the capture")
        HStack {
          ColorPicker("Start", selection: backgroundColor(true))
          ColorPicker("End", selection: backgroundColor(false))
        }.font(VantaTheme.Font.label)
        sliderRow("Padding", value: background(\.padding), range: 0...200)
        sliderRow("Corners", value: background(\.cornerRadius), range: 0...80)
        sliderRow("Shadow", value: background(\.shadowRadius), range: 0...80)
      }
    }
  }

  private func isCurrent(_ t: BackgroundTemplate) -> Bool {
    controller.document.background.wallpaperPNG == nil
      && controller.document.background.first == t.first
      && controller.document.background.second == t.second
  }

  private func hint(for tool: AnnotationTool) -> String {
    switch tool {
    case .select: return "Click an item to move it, or resize it from its corners."
    case .crop: return "Drag on the image to choose the crop."
    case .pixelate, .redact: return "Drag over the area you want to hide."
    case .spotlight: return "Drag to choose the area that stays lit."
    case .image: return "Choose an image to insert, then move it with the Move tool."
    default: return ""
    }
  }

  private func sliderRow(_ title: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(title).font(VantaTheme.Font.label).foregroundStyle(VantaTheme.Palette.textSecondary)
        Spacer()
        Text("\(Int(value.wrappedValue))").font(VantaTheme.Font.number)
      }
      Slider(value: value, in: range).controlSize(.small)
    }
  }

  private func background<T>(_ key: WritableKeyPath<DocumentBackground, T>) -> Binding<T> {
    Binding(
      get: { controller.document.background[keyPath: key] },
      set: { v in
        var d = controller.document
        d.background[keyPath: key] = v
        controller.commit(d)
      })
  }
  private func backgroundColor(_ first: Bool) -> Binding<Color> {
    Binding(
      get: {
        let c = first ? controller.document.background.first : controller.document.background.second
        return Color(red: c.red, green: c.green, blue: c.blue)
      },
      set: { v in
        let c = NSColor(v).usingColorSpace(.deviceRGB)!
        var d = controller.document
        let rgba = RGBA(c.redComponent, c.greenComponent, c.blueComponent)
        if first { d.background.first = rgba } else { d.background.second = rgba }
        controller.commit(d)
      })
  }
}

struct ToolButton: View {
  let tool: AnnotationTool
  let isSelected: Bool
  let action: () -> Void
  @State private var hovering = false
  var body: some View {
    Button(action: action) {
      Image(systemName: tool.icon).font(.system(size: 14, weight: .semibold))
        .frame(width: 38, height: 34)
        .foregroundStyle(isSelected ? VantaTheme.Palette.accentText : VantaTheme.Palette.text)
        .background(
          RoundedRectangle(cornerRadius: VantaTheme.Radius.small, style: .continuous)
            .fill(
              isSelected
                ? AnyShapeStyle(VantaTheme.Palette.accentGradient)
                : AnyShapeStyle(
                  hovering
                    ? VantaTheme.Palette.surfaceHoverGradient
                    : VantaTheme.Palette.surfaceGradient))
        )
        .overlay(
          RoundedRectangle(cornerRadius: VantaTheme.Radius.small, style: .continuous)
            .strokeBorder(
              isSelected
                ? AnyShapeStyle(Color.white.opacity(0.45))
                : AnyShapeStyle(VantaTheme.Palette.surfaceRim),
              lineWidth: 1)
        )
        .shadow(
          color: isSelected ? VantaTheme.Palette.accent.opacity(0.28) : .clear, radius: 8, y: 2)
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .animation(VantaTheme.Motion.fade, value: hovering)
    .help(tool.title)
  }
}
struct EditorCanvas: NSViewRepresentable {
  @ObservedObject var controller: AnnotateWindowController
  func makeNSView(context: Context) -> EditorCanvasView { EditorCanvasView(controller: controller) }
  func updateNSView(_ view: EditorCanvasView, context: Context) { view.needsDisplay = true }
}
final class EditorCanvasView: NSView {
  let controller: AnnotateWindowController
  private var startingDocument: AnnotationDocument?
  private var origin: CGPoint?
  private var points: [CGPoint] = []
  private var resizing = false
  private var fixedCorner: CGPoint = .zero
  init(controller: AnnotateWindowController) {
    self.controller = controller
    super.init(frame: .zero)
  }
  required init?(coder: NSCoder) { fatalError() }
  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  var transform: DocumentTransform {
    return DocumentTransform(sourceRect: controller.document.renderedSourceRect, viewport: bounds.size)
  }
  override func draw(_ dirtyRect: NSRect) {
    guard let image = controller.preview else { return }
    let t = transform
    image.draw(
      in: t.imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
      hints: nil)
    if let id = controller.selectedID,
      let o = controller.document.objects.first(where: { $0.id == id })
    {
      let rendered = controller.renderedBounds(o)
      let a = t.documentToView(rendered.origin)
      let b = t.documentToView(CGPoint(x: rendered.maxX, y: rendered.maxY))
      NSColor.cyan.setStroke()
      let path = NSBezierPath(
        rect: CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y).insetBy(dx: -4, dy: -4))
      path.lineWidth = 1
      path.stroke()
      for p in [a, CGPoint(x: b.x, y: a.y), CGPoint(x: a.x, y: b.y), b] {
        NSColor.cyan.setFill()
        NSBezierPath(ovalIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)).fill()
      }

    }
    if controller.selectedTool == .crop, let a = origin, let b = points.last {
      let x = t.documentToView(a)
      let y = t.documentToView(b)
      NSColor.cyan.setStroke()
      NSBezierPath(
        rect: CGRect(
          x: min(x.x, y.x), y: min(x.y, y.y), width: abs(x.x - y.x), height: abs(x.y - y.y))
      ).stroke()
    }
  }
  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    guard let p = transform.viewToDocument(convert(event.locationInWindow, from: nil)),
      controller.document.cropRect.contains(p)
    else { return }
    startingDocument = controller.document
    origin = p
    points = [p]
    resizing = false
    if controller.selectedTool == .select {
      if let o = controller.document.objects.first(where: { $0.id == controller.selectedID }) {
        let r = controller.renderedBounds(o)
        let corners = [
          r.origin, CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.maxY),
          CGPoint(x: r.maxX, y: r.maxY),
        ]
        if let index = corners.firstIndex(where: {
          hypot($0.x - p.x, $0.y - p.y) < 10 / transform.scale
        }) {
          resizing = true
          fixedCorner = corners[3 - index]
          return
        }
      }
      controller.select(controller.hitTest(p, tolerance: 7 / transform.scale))
    }
  }
  override func mouseDragged(with event: NSEvent) {
    guard let a = origin, var d = startingDocument,
      let p = transform.viewToDocument(convert(event.locationInWindow, from: nil))
    else { return }
    if controller.selectedTool == .select {
      if let i = d.objects.firstIndex(where: { $0.id == controller.selectedID }) {
        if resizing {
          let q = fixedCorner
          let r = CGRect(
            x: min(p.x, q.x), y: min(p.y, q.y), width: max(2, abs(p.x - q.x)),
            height: max(2, abs(p.y - q.y)))
          d.objects[i].resize(to: r, from: controller.renderedBounds(d.objects[i]))
        } else {
          d.objects[i].translate(by: CGSize(width: p.x - a.x, height: p.y - a.y))
        }
        controller.previewDocument(d)
      }
    } else if controller.selectedTool == .crop {
      points = [a, p]
      needsDisplay = true
    } else {
      if [.freehand, .highlighter].contains(controller.selectedTool) {
        points.append(p)
      } else {
        points = [a, p]
      }
      d.objects.append(controller.newObject(points: points))
      controller.previewDocument(d)
    }
  }
  override func mouseUp(with event: NSEvent) {
    defer {
      origin = nil
      startingDocument = nil
      points = []
      needsDisplay = true
    }
    guard let a = origin, var d = startingDocument else { return }
    if controller.selectedTool == .select {
      controller.commit(controller.document)
      return
    }
    if controller.selectedTool == .crop {
      if let b = points.last {
        let r = CGRect(
          x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)
        ).integral.intersection(d.cropRect)
        if r.width >= 2 && r.height >= 2 {
          d.cropRect = r
          controller.commit(d)
        }
      }
      return
    }
    let final = points.count > 1 ? points : [a, CGPoint(x: a.x + 1, y: a.y + 1)]
    let o = controller.newObject(points: final)
    if controller.selectedTool == .text && o.text.isEmpty { return }
    if controller.selectedTool == .counter { d.nextCounter += 1 }
    if [.rectangle, .filledRect, .pixelate, .redact, .ellipse, .spotlight].contains(o.tool)
      && o.bounds.width < 2
    {
      return
    }
    d.objects.append(o)
    controller.commit(d)
  }
  override func keyDown(with event: NSEvent) {
    if event.modifierFlags.contains(.command) {
      switch event.charactersIgnoringModifiers?.lowercased() {
      case "c": controller.copy()
      case "s": controller.save()
      case "z": event.modifierFlags.contains(.shift) ? controller.redo() : controller.undo()
      default: super.keyDown(with: event)
      }
    } else if event.keyCode == 51 {
      controller.deleteSelection()
    } else if event.keyCode == 53 {
      controller.select(nil)
    } else {
      super.keyDown(with: event)
    }
  }
}
