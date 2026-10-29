import AppKit
import XCTest

@testable import VantaShot

final class DesignSystemTests: XCTestCase {
  func testRadiusScaleIsOrdered() {
    XCTAssertLessThan(VantaTheme.Radius.small, VantaTheme.Radius.medium)
    XCTAssertLessThan(VantaTheme.Radius.medium, VantaTheme.Radius.large)
  }

  func testHUDSitsAboveDockWhenDockIsAtBottom() {
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let visible = CGRect(x: 0, y: 70, width: 1512, height: 880)
    let inset = OverlayLayout.hudBottomInset(screenFrame: screen, visibleFrame: visible, margin: 24)
    XCTAssertEqual(inset, 94)
  }

  func testHUDUsesPlainMarginWhenDockIsHiddenOrOnSide() {
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let visible = CGRect(x: 80, y: 0, width: 1432, height: 950)
    let inset = OverlayLayout.hudBottomInset(screenFrame: screen, visibleFrame: visible, margin: 24)
    XCTAssertEqual(inset, 24)
  }

  func testSnapPullsPointToNearestWindowEdgeWithinThreshold() {
    let edges = SnapEdges(xs: [100, 400], ys: [50, 300])
    let snapped = SelectionSnapper.snap(CGPoint(x: 104, y: 296), to: edges, threshold: 6)
    XCTAssertEqual(snapped, CGPoint(x: 100, y: 300))
  }

  func testSnapLeavesPointAloneBeyondThreshold() {
    let edges = SnapEdges(xs: [100], ys: [50])
    let point = CGPoint(x: 110, y: 70)
    XCTAssertEqual(SelectionSnapper.snap(point, to: edges, threshold: 6), point)
  }

  func testSnapPrefersClosestEdgeWhenSeveralQualify() {
    let edges = SnapEdges(xs: [100, 103], ys: [])
    XCTAssertEqual(SelectionSnapper.snap(CGPoint(x: 102, y: 0), to: edges, threshold: 6).x, 103)
  }

  func testSnapEdgesComeFromWindowFramesInLocalCoordinates() {
    let frames = [CGRect(x: 1000, y: 500, width: 200, height: 100)]
    let edges = SnapEdges(windowFrames: frames, screenFrame: CGRect(x: 1000, y: 400, width: 800, height: 600))
    XCTAssertEqual(edges.xs, [0, 200])
    XCTAssertEqual(edges.ys, [100, 200])
  }

  func testQuickAccessCardsStackUpwardFromBottomLeading() {
    let visible = CGRect(x: 0, y: 70, width: 1512, height: 880)
    let size = CGSize(width: 320, height: 250)
    let first = QuickAccessCardLayout.frame(index: 0, cardSize: size, visibleFrame: visible)
    let second = QuickAccessCardLayout.frame(index: 1, cardSize: size, visibleFrame: visible)
    XCTAssertEqual(first.origin, CGPoint(x: 20, y: 90))
    XCTAssertEqual(second.origin.x, 20)
    XCTAssertEqual(second.minY, first.maxY + QuickAccessCardLayout.gap)
  }

  func testQuickAccessAutoDismissIsDisabledAtZero() {
    XCTAssertNil(QuickAccessCardLayout.autoDismissDuration(settingSeconds: 0))
    XCTAssertEqual(QuickAccessCardLayout.autoDismissDuration(settingSeconds: 8), 8)
  }
}
