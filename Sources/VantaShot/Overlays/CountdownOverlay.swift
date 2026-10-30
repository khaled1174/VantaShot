import AppKit
import SwiftUI

// MARK: - 3-2-1 countdown badge shown over the region (or the mouse screen) before timed captures.

@MainActor final class CountdownOverlay {
  static let shared = CountdownOverlay()
  static let size = CGSize(width: 180, height: 200)
  private var panel: NSPanel?
  private let model = CountdownModel()

  func show(step: Int, region: CGRect?) {
    let screen =
      region.flatMap { r in NSScreen.screens.first { $0.frame.contains(CGPoint(x: r.midX, y: r.midY)) } }
      ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    let anchor = region ?? screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 800, height: 600)
    let frame = CGRect(
      x: anchor.midX - Self.size.width / 2, y: anchor.midY - Self.size.height / 2,
      width: Self.size.width, height: Self.size.height)
    if panel == nil {
      let p = NSPanel(
        contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
        defer: false)
      p.isReleasedWhenClosed = false
      p.isOpaque = false
      p.backgroundColor = .clear
      p.hasShadow = false
      p.ignoresMouseEvents = true
      p.level = .screenSaver
      p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
      p.contentView = NSHostingView(rootView: CountdownBadgeView(model: model))
      panel = p
    }
    panel?.setFrame(frame, display: true)
    model.number = step
    if panel?.isVisible != true {
      panel?.alphaValue = 1
      panel?.orderFrontRegardless()
    }
  }

  func hide() {
    guard let p = panel, p.isVisible else { return }
    VantaPanelMotion.dismiss(p) { p.orderOut(nil) }
  }
}

@MainActor final class CountdownModel: ObservableObject {
  @Published var number = 3
}

struct CountdownBadgeView: View {
  @ObservedObject var model: CountdownModel
  @State private var pop = false

  var body: some View {
    VStack(spacing: 12) {
      ZStack {
        Circle().fill(Color.black.opacity(0.35))
        Circle().strokeBorder(VantaTheme.Palette.stroke, lineWidth: 1)
        Circle()
          .trim(from: 0, to: 1)
          .stroke(VantaTheme.Palette.accent.opacity(0.8), style: StrokeStyle(lineWidth: 4, lineCap: .round))
          .padding(6)
          .rotationEffect(.degrees(-90))
        Text("\(model.number)")
          .font(.system(size: 72, weight: .bold, design: .rounded))
          .foregroundStyle(VantaTheme.Palette.text)
          .scaleEffect(pop ? 1 : 0.6)
          .opacity(pop ? 1 : 0)
          .id(model.number)
      }
      .frame(width: 132, height: 132)
      .background(VantaGlassMaterial(material: .hudWindow, cornerRadius: 66))
      .clipShape(Circle())
      .shadow(color: .black.opacity(VantaTheme.Shadow.opacity), radius: 18, y: 8)
      Text("Esc to cancel")
        .font(VantaTheme.Font.caption)
        .foregroundStyle(VantaTheme.Palette.text)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Capsule().fill(Color.black.opacity(0.55)))
    }
    .frame(width: CountdownOverlay.size.width, height: CountdownOverlay.size.height)
    .onAppear { withAnimation(VantaTheme.Motion.spring) { pop = true } }
    .onChange(of: model.number) { _ in
      pop = false
      withAnimation(VantaTheme.Motion.spring) { pop = true }
    }
    .environment(\.layoutDirection, .leftToRight)
  }
}

// MARK: - Thin frame drawn around a region while it is being set up / recorded / scrolled.

@MainActor final class RegionFrameWindow {
  enum Style { case setup, recording, scrolling }
  private var window: NSWindow?
  private let model = RegionFrameModel()

  func show(around rect: CGRect, style: Style) {
    let frame = rect.insetBy(dx: -4, dy: -4)
    if window == nil {
      let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
      w.isReleasedWhenClosed = false
      w.isOpaque = false
      w.backgroundColor = .clear
      w.hasShadow = false
      w.ignoresMouseEvents = true
      w.level = .screenSaver
      w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
      w.contentView = NSHostingView(rootView: RegionFrameView(model: model))
      window = w
    }
    window?.setFrame(frame, display: true)
    model.style = style
    window?.orderFrontRegardless()
  }

  func hide() {
    window?.orderOut(nil)
  }
}

@MainActor final class RegionFrameModel: ObservableObject {
  @Published var style: RegionFrameWindow.Style = .setup
}

struct RegionFrameView: View {
  @ObservedObject var model: RegionFrameModel
  @State private var pulsing = false
  private var color: Color {
    switch model.style {
    case .setup: return VantaTheme.Palette.accent
    case .recording: return VantaTheme.Palette.danger
    case .scrolling: return VantaTheme.Palette.accent
    }
  }
  var body: some View {
    RoundedRectangle(cornerRadius: 6, style: .continuous)
      .strokeBorder(color.opacity(model.style == .recording && pulsing ? 0.55 : 0.95), lineWidth: 2)
      .padding(2)
      .animation(model.style == .recording ? VantaTheme.Motion.pulse : VantaTheme.Motion.fade, value: pulsing)
      .onAppear { pulsing = true }
  }
}
