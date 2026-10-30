import Foundation

/// Decides how a privacy switch is requested.
/// Screen Recording, Accessibility, and Input Monitoring stay stale in the
/// running process, and asking again can turn a switch the user just enabled
/// back off. Ask the system once per launch, then only open Settings.
public struct SystemPermissionPrompt: Equatable, Sendable {
  public var didRequestThisLaunch = false
  public var didOpenSettings = false

  public init() {}

  public enum Step: Equatable, Sendable {
    case alreadyOn
    case requestOnce
    case openSettingsOnly
  }

  public func step(granted: Bool) -> Step {
    if granted { return .alreadyOn }
    return didRequestThisLaunch ? .openSettingsOnly : .requestOnce
  }

  /// The switch may already be on in System Settings while this process still
  /// sees it as off. macOS applies that grant on the next launch.
  public func needsRelaunch(granted: Bool) -> Bool {
    didOpenSettings && !granted
  }
}

/// Classifies ScreenCaptureKit failures that mean the user has not authorized capture.
public enum ScreenCaptureDenial {
  public static let streamErrorDomain = "com.apple.ScreenCaptureKit.SCStreamErrorDomain"
  /// `SCStreamErrorUserDeclined`.
  public static let userDeclinedCode = -3801

  public static func isUserDeclined(domain: String, code: Int) -> Bool {
    domain == streamErrorDomain && code == userDeclinedCode
  }

  public static func looksLikePermissionFailure(domain: String, code: Int, description: String)
    -> Bool
  {
    if isUserDeclined(domain: domain, code: code) { return true }
    let text = description.lowercased()
    return [
      "screen recording", "not authorized", "not authorised", "permission", "declined", "tcc",
    ].contains { text.contains($0) }
  }
}
