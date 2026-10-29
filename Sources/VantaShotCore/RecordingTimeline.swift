import Foundation

public struct RecordingTimeline: Sendable {
  private var first: Double?
  private var pausedAt: Double?
  private var removed = 0.0
  public init() {}
  public var isPaused: Bool { pausedAt != nil }
  public mutating func pause(at time: Double) {
    guard pausedAt == nil else { return }
    pausedAt = time
  }
  public mutating func resume(at time: Double) {
    guard let start = pausedAt else { return }
    removed += max(0, time - start)
    pausedAt = nil
  }
  public mutating func presentationTime(_ input: Double) -> Double? {
    guard input.isFinite, !isPaused else { return nil }
    if first == nil { first = input }
    return max(0, input - first! - removed)
  }
}
