import AppKit
import SwiftUI

// MARK: - Design tokens (single source of truth for every floating surface)

enum VantaTheme {
  enum Radius {
    static let small: CGFloat = 10
    static let medium: CGFloat = 14
    static let large: CGFloat = 20
  }
  enum Palette {
    static let accent = Color(red: 0.16, green: 0.85, blue: 0.98)
    static let accentDeep = Color(red: 0.06, green: 0.58, blue: 0.88)
    static let accentText = Color(red: 0.02, green: 0.09, blue: 0.14)
    static let success = Color(red: 0.18, green: 0.88, blue: 0.62)
    static let danger = Color(red: 1.0, green: 0.33, blue: 0.33)
    static let warning = Color(red: 1.0, green: 0.72, blue: 0.25)
    static let stroke = Color.white.opacity(0.18)
    static let strokeStrong = Color.white.opacity(0.32)
    static let fillSubtle = Color.white.opacity(0.07)
    static let fillHover = Color.white.opacity(0.14)
    static let text = Color.white
    static let textSecondary = Color.white.opacity(0.68)

    static let accentGradient = LinearGradient(
      colors: [
        Color(red: 0.26, green: 0.90, blue: 1.0),
        Color(red: 0.10, green: 0.72, blue: 0.94),
      ],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )

    static let windowTintGradient = LinearGradient(
      stops: [
        .init(color: Color(red: 0.06, green: 0.09, blue: 0.16).opacity(0.68), location: 0.0),
        .init(color: Color(red: 0.04, green: 0.06, blue: 0.11).opacity(0.76), location: 0.55),
        .init(color: Color(red: 0.03, green: 0.04, blue: 0.08).opacity(0.84), location: 1.0),
      ],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )

    static let specularRim = LinearGradient(
      stops: [
        .init(color: Color.white.opacity(0.36), location: 0.0),
        .init(color: Color.white.opacity(0.13), location: 0.45),
        .init(color: Color(red: 0.16, green: 0.85, blue: 0.98).opacity(0.20), location: 1.0),
      ],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )

    static let surfaceRim = LinearGradient(
      stops: [
        .init(color: Color.white.opacity(0.24), location: 0.0),
        .init(color: Color.white.opacity(0.08), location: 0.5),
        .init(color: Color.white.opacity(0.04), location: 1.0),
      ],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )

    static let surfaceGradient = LinearGradient(
      colors: [
        Color.white.opacity(0.10),
        Color.white.opacity(0.04),
      ],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )

    static let surfaceHoverGradient = LinearGradient(
      colors: [
        Color.white.opacity(0.16),
        Color.white.opacity(0.07),
      ],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
  }
  enum Font {
    static let body = SwiftUI.Font.system(size: 13, weight: .regular)
    static let label = SwiftUI.Font.system(size: 11, weight: .medium)
    static let title = SwiftUI.Font.system(size: 15, weight: .semibold)
    static let caption = SwiftUI.Font.system(size: 10.5, weight: .medium)
    static let number = SwiftUI.Font.system(size: 11.5, weight: .semibold, design: .monospaced)
  }
  enum Motion {
    static let spring = Animation.spring(response: 0.35, dampingFraction: 0.8)
    static let fade = Animation.easeOut(duration: 0.15)
    static let fadeDuration: TimeInterval = 0.15
    static let springDuration: TimeInterval = 0.35
    static let pulse = Animation.easeInOut(duration: 1.4).repeatForever(autoreverses: true)
  }
  enum Shadow {
    static let radius: CGFloat = 24
    static let y: CGFloat = 10
    static let opacity: Double = 0.45
  }
}

// MARK: - Glass material

/// A real AppKit `NSVisualEffectView` so floating panels blur whatever sits behind them,
/// exactly like native macOS HUDs and popovers.
struct VantaGlassMaterial: NSViewRepresentable {
  var material: NSVisualEffectView.Material = .hudWindow
  var cornerRadius: CGFloat = VantaTheme.Radius.large

  func makeNSView(context: Context) -> NSVisualEffectView {
    let v = NSVisualEffectView()
    v.blendingMode = .behindWindow
    v.state = .active
    v.wantsLayer = true
    v.layer?.masksToBounds = true
    update(v)
    return v
  }
  func updateNSView(_ v: NSVisualEffectView, context: Context) { update(v) }
  private func update(_ v: NSVisualEffectView) {
    v.material = material
    v.layer?.cornerRadius = cornerRadius
    v.layer?.cornerCurve = .continuous
  }
}

struct VantaGlassCardModifier: ViewModifier {
  var radius: CGFloat
  var material: NSVisualEffectView.Material
  var tint: Color
  var shadow: Bool
  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    content
      .background(
        ZStack {
          VantaGlassMaterial(material: material, cornerRadius: radius)
          shape.fill(tint)
          shape.fill(
            LinearGradient(
              colors: [Color.white.opacity(0.08), Color.clear, Color.black.opacity(0.14)],
              startPoint: .top,
              endPoint: .bottom
            )
          )
        }
      )
      .overlay(
        shape.strokeBorder(VantaTheme.Palette.specularRim, lineWidth: 1)
      )
      .clipShape(shape)
      .shadow(
        color: .black.opacity(shadow ? VantaTheme.Shadow.opacity : 0),
        radius: shadow ? VantaTheme.Shadow.radius : 0, y: shadow ? VantaTheme.Shadow.y : 0)
  }
}

struct VantaSurfaceCardModifier: ViewModifier {
  var radius: CGFloat
  var isSelected: Bool
  var isHovering: Bool
  var shadow: Bool

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    content
      .background(
        ZStack {
          shape.fill(
            isSelected
              ? AnyShapeStyle(
                LinearGradient(
                  colors: [
                    VantaTheme.Palette.accent.opacity(0.18),
                    VantaTheme.Palette.accent.opacity(0.07),
                  ],
                  startPoint: .topLeading,
                  endPoint: .bottomTrailing
                ))
              : AnyShapeStyle(
                isHovering
                  ? VantaTheme.Palette.surfaceHoverGradient
                  : VantaTheme.Palette.surfaceGradient)
          )
        }
      )
      .overlay(
        shape.strokeBorder(
          isSelected
            ? AnyShapeStyle(VantaTheme.Palette.accent)
            : isHovering
              ? AnyShapeStyle(
                LinearGradient(
                  colors: [
                    VantaTheme.Palette.accent.opacity(0.65),
                    Color.white.opacity(0.18),
                  ],
                  startPoint: .topLeading,
                  endPoint: .bottomTrailing
                ))
              : AnyShapeStyle(VantaTheme.Palette.surfaceRim),
          lineWidth: isSelected ? 1.5 : 1
        )
      )
      .clipShape(shape)
      .shadow(
        color: isSelected
          ? VantaTheme.Palette.accent.opacity(0.18)
          : .black.opacity(shadow ? 0.25 : 0),
        radius: shadow || isSelected ? 12 : 0,
        y: shadow || isSelected ? 4 : 0
      )
  }
}

struct VantaWindowBackgroundModifier: ViewModifier {
  var material: NSVisualEffectView.Material
  func body(content: Content) -> some View {
    content
      .background(
        ZStack {
          VantaGlassMaterial(material: material, cornerRadius: 0)
          VantaTheme.Palette.windowTintGradient
          RadialGradient(
            colors: [
              VantaTheme.Palette.accent.opacity(0.09),
              Color.clear,
            ],
            center: .topLeading,
            startRadius: 10,
            endRadius: 420
          )
        }
        .ignoresSafeArea()
      )
  }
}

@MainActor enum VantaWindowGlass {
  /// Configures an `NSWindow` so its content view's behind-window blur shines through cleanly.
  static func configure(_ window: NSWindow) {
    window.isReleasedWhenClosed = false
    window.isOpaque = false
    window.backgroundColor = .clear
    window.titlebarAppearsTransparent = true
    if !window.styleMask.contains(.fullSizeContentView) {
      window.styleMask.insert(.fullSizeContentView)
    }
    window.appearance = NSAppearance(named: .darkAqua)
    window.hasShadow = true
  }
}

extension View {
  /// Standard floating surface: blurred glass + specular hairline border + soft shadow.
  func vantaGlassCard(
    radius: CGFloat = VantaTheme.Radius.large,
    material: NSVisualEffectView.Material = .hudWindow,
    tint: Color = Color(red: 0.05, green: 0.07, blue: 0.12).opacity(0.55),
    shadow: Bool = true
  ) -> some View {
    modifier(VantaGlassCardModifier(radius: radius, material: material, tint: tint, shadow: shadow))
  }
  /// Inner layered glass surface used for cards, tiles, and sections inside a glass window.
  func vantaSurfaceCard(
    radius: CGFloat = VantaTheme.Radius.medium,
    isSelected: Bool = false,
    isHovering: Bool = false,
    shadow: Bool = false
  ) -> some View {
    modifier(
      VantaSurfaceCardModifier(
        radius: radius, isSelected: isSelected, isHovering: isHovering, shadow: shadow))
  }
  /// Root behind-window frosted glass background for application windows.
  func vantaWindowBackground(material: NSVisualEffectView.Material = .hudWindow) -> some View {
    modifier(VantaWindowBackgroundModifier(material: material))
  }
  /// Dark text/number badge used inside overlays (size labels, coordinates).
  func vantaBadge() -> some View {
    self
      .font(VantaTheme.Font.number)
      .foregroundStyle(VantaTheme.Palette.text)
      .padding(.horizontal, 10).padding(.vertical, 5)
      .background(Capsule().fill(Color(red: 0.05, green: 0.07, blue: 0.12).opacity(0.9)))
      .overlay(Capsule().strokeBorder(VantaTheme.Palette.specularRim, lineWidth: 1))
  }
}

// MARK: - Buttons

/// Icon-over-label button used in HUDs and cards. One `prominent` button per surface.
struct VantaIconButton: View {
  enum Role { case neutral, prominent, destructive }
  let title: String
  let icon: String
  var shortcut: String? = nil
  var role: Role = .neutral
  var isSelected = false
  var compact = false
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      VStack(spacing: 4) {
        Image(systemName: icon)
          .font(.system(size: compact ? 14 : 16, weight: .semibold))
          .frame(height: compact ? 16 : 18)
        HStack(spacing: 3) {
          Text(title).font(VantaTheme.Font.label)
          if let shortcut {
            Text(shortcut).font(.system(size: 9, weight: .semibold, design: .monospaced))
              .opacity(0.65)
          }
        }
        .lineLimit(1).fixedSize()
      }
      .foregroundStyle(foreground)
      .padding(.horizontal, compact ? 10 : 12)
      .padding(.vertical, compact ? 6 : 8)
      .frame(minWidth: compact ? 52 : 64)
      .background(
        RoundedRectangle(cornerRadius: VantaTheme.Radius.small, style: .continuous).fill(fill)
      )
      .overlay(
        RoundedRectangle(cornerRadius: VantaTheme.Radius.small, style: .continuous)
          .strokeBorder(border, lineWidth: 1)
      )
      .shadow(color: glowColor, radius: hovering || role == .prominent || isSelected ? 10 : 0, y: 3)
      .scaleEffect(hovering ? 1.03 : 1)
      .animation(VantaTheme.Motion.fade, value: hovering)
      .animation(VantaTheme.Motion.fade, value: isSelected)
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .help(shortcut.map { "\(title) (\($0))" } ?? title)
  }

  private var foreground: Color {
    switch role {
    case .prominent: return VantaTheme.Palette.accentText
    case .destructive: return VantaTheme.Palette.danger
    case .neutral: return isSelected ? VantaTheme.Palette.accentText : VantaTheme.Palette.text
    }
  }
  private var fill: AnyShapeStyle {
    switch role {
    case .prominent:
      return AnyShapeStyle(VantaTheme.Palette.accentGradient)
    case .destructive:
      return AnyShapeStyle(
        LinearGradient(
          colors: [
            VantaTheme.Palette.danger.opacity(hovering ? 0.28 : 0.16),
            VantaTheme.Palette.danger.opacity(hovering ? 0.16 : 0.08),
          ],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        ))
    case .neutral:
      if isSelected { return AnyShapeStyle(VantaTheme.Palette.accentGradient) }
      return AnyShapeStyle(
        hovering ? VantaTheme.Palette.surfaceHoverGradient : VantaTheme.Palette.surfaceGradient)
    }
  }
  private var border: AnyShapeStyle {
    switch role {
    case .prominent:
      return AnyShapeStyle(
        LinearGradient(
          colors: [Color.white.opacity(0.55), VantaTheme.Palette.accent.opacity(0.85)],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        ))
    case .destructive:
      return AnyShapeStyle(
        LinearGradient(
          colors: [
            VantaTheme.Palette.danger.opacity(hovering ? 0.65 : 0.45),
            VantaTheme.Palette.danger.opacity(0.20),
          ],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        ))
    case .neutral:
      if isSelected {
        return AnyShapeStyle(
          LinearGradient(
            colors: [Color.white.opacity(0.5), VantaTheme.Palette.accent],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          ))
      }
      return AnyShapeStyle(
        hovering
          ? LinearGradient(
            colors: [VantaTheme.Palette.accent.opacity(0.55), Color.white.opacity(0.16)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
          : VantaTheme.Palette.surfaceRim
      )
    }
  }
  private var glowColor: Color {
    switch role {
    case .prominent: return VantaTheme.Palette.accent.opacity(hovering ? 0.42 : 0.25)
    case .destructive: return VantaTheme.Palette.danger.opacity(hovering ? 0.25 : 0)
    case .neutral:
      if isSelected { return VantaTheme.Palette.accent.opacity(0.28) }
      return hovering ? VantaTheme.Palette.accent.opacity(0.14) : .clear
    }
  }
}

// MARK: - Panel animation helpers (AppKit level, works for every NSPanel we float)

enum VantaPanelMotion {
  /// Slides the panel in from `offset` while fading from 0 to 1.
  @MainActor static func present(_ panel: NSWindow, from offset: CGPoint) {
    let final = panel.frame
    panel.setFrame(final.offsetBy(dx: offset.x, dy: offset.y), display: false)
    panel.alphaValue = 0
    panel.orderFrontRegardless()
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = VantaTheme.Motion.springDuration
      ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.05)
      panel.animator().setFrame(final, display: true)
      panel.animator().alphaValue = 1
    }
  }
  /// Fades the panel out, then runs `completion` (typically `orderOut`/`close`).
  @MainActor static func dismiss(_ panel: NSWindow, completion: @escaping @MainActor () -> Void) {
    NSAnimationContext.runAnimationGroup(
      { ctx in
        ctx.duration = VantaTheme.Motion.fadeDuration
        panel.animator().alphaValue = 0
      },
      completionHandler: {
        MainActor.assumeIsolated { completion() }
      })
  }
}

// MARK: - Pure layout helpers (unit tested)

enum OverlayLayout {
  /// Distance from the bottom of a full-screen overlay to the HUD so it never covers the Dock.
  static func hudBottomInset(screenFrame: CGRect, visibleFrame: CGRect, margin: CGFloat) -> CGFloat
  {
    let dock = max(0, visibleFrame.minY - screenFrame.minY)
    return dock + margin
  }
}

struct SnapEdges: Equatable {
  var xs: [CGFloat]
  var ys: [CGFloat]
  init(xs: [CGFloat], ys: [CGFloat]) {
    self.xs = xs
    self.ys = ys
  }
  /// Edges of on-screen windows translated into the overlay's local coordinates.
  init(windowFrames: [CGRect], screenFrame: CGRect) {
    var xs: [CGFloat] = []
    var ys: [CGFloat] = []
    for f in windowFrames {
      let local = f.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
      xs += [local.minX, local.maxX]
      ys += [local.minY, local.maxY]
    }
    self.xs = xs
    self.ys = ys
  }
}

enum SelectionSnapper {
  static func snap(_ point: CGPoint, to edges: SnapEdges, threshold: CGFloat) -> CGPoint {
    func nearest(_ v: CGFloat, in candidates: [CGFloat]) -> CGFloat {
      guard let best = candidates.min(by: { abs($0 - v) < abs($1 - v) }), abs(best - v) <= threshold
      else { return v }
      return best
    }
    return CGPoint(x: nearest(point.x, in: edges.xs), y: nearest(point.y, in: edges.ys))
  }
}

enum QuickAccessCardLayout {
  static let margin: CGFloat = 20
  static let gap: CGFloat = 12
  /// Cards stack upward from the bottom-leading corner, then continue in the next column.
  static func frame(index: Int, cardSize: CGSize, visibleFrame: CGRect) -> CGRect {
    let rows = rowsPerColumn(cardSize: cardSize, visibleFrame: visibleFrame)
    let column = index / rows
    let row = index % rows
    return CGRect(
      x: visibleFrame.minX + margin + CGFloat(column) * (cardSize.width + gap),
      y: visibleFrame.minY + margin + CGFloat(row) * (cardSize.height + gap),
      width: cardSize.width, height: cardSize.height)
  }
  /// How many cards fit on the screen without overlapping. Always at least one.
  static func capacity(cardSize: CGSize, visibleFrame: CGRect) -> Int {
    let columns = Int((visibleFrame.width - 2 * margin + gap) / (cardSize.width + gap))
    return rowsPerColumn(cardSize: cardSize, visibleFrame: visibleFrame) * max(1, columns)
  }
  private static func rowsPerColumn(cardSize: CGSize, visibleFrame: CGRect) -> Int {
    max(1, Int((visibleFrame.height - 2 * margin + gap) / (cardSize.height + gap)))
  }
}
