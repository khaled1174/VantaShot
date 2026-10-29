import CoreGraphics
import Foundation

public struct DisplayGeometry {
  public var appKitFrame: CGRect
  public var primaryTop: CGFloat
  public init(appKitFrame: CGRect, primaryTop: CGFloat) {
    self.appKitFrame = appKitFrame
    self.primaryTop = primaryTop
  }
  public func globalRect(local: CGRect) -> CGRect {
    local.offsetBy(dx: appKitFrame.minX, dy: appKitFrame.minY)
  }
  public func quartzRect(global: CGRect) -> CGRect {
    CGRect(x: global.minX, y: primaryTop - global.maxY, width: global.width, height: global.height)
  }
  public func displayLocalQuartz(global: CGRect) -> CGRect {
    let q = quartzRect(global: global)
    let d = quartzRect(global: appKitFrame)
    return q.offsetBy(dx: -d.minX, dy: -d.minY)
  }
}
