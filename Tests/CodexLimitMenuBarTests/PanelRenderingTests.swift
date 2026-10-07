import AppKit
import Foundation
import SwiftUI
import XCTest

@testable import CodexLimitMenuBar

private struct PreviewCodexClient: CodexUsageFetching {
  let snapshot: UsageSnapshot
  func fetchRateLimits(executableURL: URL) async throws -> UsageSnapshot { snapshot }
}

private struct PreviewClaudeClient: ClaudeUsageFetching {
  let snapshot: UsageSnapshot
  let error: ClaudeUsageClientError?
  func fetchRateLimits() async throws -> UsageSnapshot {
    if let error { throw error }
    return snapshot
  }
}

@MainActor
final class PanelRenderingTests: XCTestCase {
  func testPanelIntrinsicSizeKeepsUsageVisible() async throws {
    let directory = ProcessInfo.processInfo.environment["CODEX_LIMIT_PREVIEW_DIR"]
    _ = NSApplication.shared
    let now = Date()
    func fixture(_ provider: String, primary: Double, secondary: Double) -> UsageSnapshot {
      UsageSnapshot(fetchedAt: now, buckets: [CodexRateLimitBucket(
        limitId: provider, limitName: provider.capitalized,
        primary: CodexRateLimitWindow(
          usedPercent: primary, windowDurationMins: 300,
          resetsAt: now.addingTimeInterval(3_600).timeIntervalSince1970
        ),
        secondary: CodexRateLimitWindow(
          usedPercent: secondary, windowDurationMins: 10_080,
          resetsAt: now.addingTimeInterval(172_800).timeIntervalSince1970
        ), planType: "pro"
      )])
    }
    // Match the current account's Codex shape: a weekly primary window only.
    let codex = UsageSnapshot(fetchedAt: now, buckets: [CodexRateLimitBucket(
      limitId: "codex",
      primary: CodexRateLimitWindow(
        usedPercent: 9, windowDurationMins: 10_080,
        resetsAt: now.addingTimeInterval(172_800).timeIntervalSince1970
      ), planType: "pro"
    )])
    let claude = fixture("claude", primary: 6, secondary: 19)
    for failed in [false, true] {
      let suite = "CodexLimitMenuBarPreview.\(UUID().uuidString)"
      let defaults = UserDefaults(suiteName: suite)!
      defer { defaults.removePersistentDomain(forName: suite) }
      defaults.set("/usr/bin/true", forKey: CodexLocator.userDefaultsKey)
      let store = UsageStore(
        client: PreviewCodexClient(snapshot: codex),
        claudeClient: PreviewClaudeClient(snapshot: claude, error: failed ? .cliFailed : nil),
        locator: CodexLocator(userDefaults: defaults), defaults: defaults, startAutomatically: false
      )
      await store.refresh()
      let controller = NSHostingController(rootView:
        StatusPanelView().environmentObject(store)
          .background(Color(nsColor: .windowBackgroundColor))
      )
      let view = controller.view
      let minimum = controller.sizeThatFits(in: CGSize(width: 370, height: 0))
      print("Panel minimum size (failed=\(failed)): \(minimum)")
      XCTAssertGreaterThan(minimum.height, 450, "A compact popover must not collapse usage")
      // MenuBarExtra uses the panel's natural size. Giving the test an arbitrary
      // height hides a collapsed ScrollView, so measure before setting its frame.
      let size = view.fittingSize
      print("Panel natural size (failed=\(failed)): \(size)")
      XCTAssertEqual(size.width, 370, accuracy: 1)
      XCTAssertGreaterThan(size.height, 450, "Usage must have a visible scroll viewport")
      XCTAssertLessThan(size.height, 700, "The panel must fit on a laptop display")
      view.frame = NSRect(origin: .zero, size: size)
      view.layoutSubtreeIfNeeded()
      guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
        return XCTFail("The panel could not be rendered")
      }
      view.cacheDisplay(in: view.bounds, to: bitmap)
      let image = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      let name = failed ? "panel-claude-renewal-failed.png" : "panel-healthy.png"
      if let directory {
        try image.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
      }
    }
  }
}
