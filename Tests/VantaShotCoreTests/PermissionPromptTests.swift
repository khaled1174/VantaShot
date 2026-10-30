import XCTest

@testable import VantaShotCore

final class PermissionPromptTests: XCTestCase {
  func testAsksTheSystemOnceThenOnlyOpensSettings() {
    var prompt = SystemPermissionPrompt()
    XCTAssertEqual(prompt.step(granted: true), .alreadyOn)
    XCTAssertEqual(prompt.step(granted: false), .requestOnce)
    prompt.didRequestThisLaunch = true
    XCTAssertEqual(prompt.step(granted: false), .openSettingsOnly)
    XCTAssertFalse(prompt.needsRelaunch(granted: false))
    prompt.didOpenSettings = true
    XCTAssertTrue(prompt.needsRelaunch(granted: false))
    XCTAssertFalse(prompt.needsRelaunch(granted: true))
  }

  func testUserDeclinedScreenCaptureIsAPermissionFailure() {
    XCTAssertTrue(
      ScreenCaptureDenial.isUserDeclined(
        domain: ScreenCaptureDenial.streamErrorDomain, code: ScreenCaptureDenial.userDeclinedCode))
    XCTAssertFalse(
      ScreenCaptureDenial.isUserDeclined(
        domain: ScreenCaptureDenial.streamErrorDomain, code: -3802))
    XCTAssertTrue(
      ScreenCaptureDenial.looksLikePermissionFailure(
        domain: "other", code: 1, description: "The user declined screen recording"))
    XCTAssertFalse(
      ScreenCaptureDenial.looksLikePermissionFailure(
        domain: "other", code: 1, description: "The selected display is not available."))
  }
}
