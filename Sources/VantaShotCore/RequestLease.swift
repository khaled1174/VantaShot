import Foundation

/// Cancellation is checked at publication boundaries, including synchronous store commits.
public final class RequestLease: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  public init() {}
  public func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }
  public var isValid: Bool {
    lock.lock()
    defer { lock.unlock() }
    return !cancelled
  }
  public func check() throws { guard isValid else { throw CancellationError() } }
}
public struct DisplayCaptureTarget: Codable, Equatable, Sendable {
  public var displayID: UInt32
  public var displayFrame: CGRect
  public var rect: CGRect
  public init(displayID: UInt32, displayFrame: CGRect, rect: CGRect) {
    self.displayID = displayID
    self.displayFrame = displayFrame
    self.rect = rect
  }
  public func validate(displays: [UInt32: CGRect]) throws {
    guard displays[displayID] == displayFrame, displayFrame.contains(rect), rect.width > 0,
      rect.height > 0
    else { throw StorageError.invalidData }
  }
}
