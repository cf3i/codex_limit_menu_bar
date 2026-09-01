import Foundation
import XCTest

@testable import CodexLimitMenuBar

final class UsageModelsTests: XCTestCase {
  func testCalculatesMostConstrainedAndWeeklyWindow() {
    let snapshot = UsageSnapshot(
      fetchedAt: Date(),
      buckets: [
        CodexRateLimitBucket(
          limitId: "codex",
          primary: CodexRateLimitWindow(
            usedPercent: 15,
            windowDurationMins: 300,
            resetsAt: nil
          ),
          secondary: CodexRateLimitWindow(
            usedPercent: 72,
            windowDurationMins: 10_080,
            resetsAt: nil
          )
        )
      ]
    )

    XCTAssertEqual(snapshot.mostConstrainedRemainingPercent, 28)
    XCTAssertEqual(snapshot.weeklyRemainingPercent, 28)
    XCTAssertEqual(snapshot.windows.map(\.title), ["5-hour limit", "Weekly limit"])
  }

  func testWeeklyMenuValuePrefersMainCodexBucket() {
    let snapshot = UsageSnapshot(
      fetchedAt: Date(),
      buckets: [
        CodexRateLimitBucket(
          limitId: "codex",
          primary: CodexRateLimitWindow(
            usedPercent: 54,
            windowDurationMins: 10_080,
            resetsAt: nil
          )
        ),
        CodexRateLimitBucket(
          limitId: "codex_bengalfox",
          limitName: "GPT-5.3-Codex-Spark",
          secondary: CodexRateLimitWindow(
            usedPercent: 5,
            windowDurationMins: 10_080,
            resetsAt: nil
          )
        ),
      ]
    )

    XCTAssertEqual(snapshot.weeklyRemainingPercent, 46)
  }

  func testUnknownWindowGetsReadableTitle() {
    let item = PresentedLimitWindow(
      id: "test",
      bucketId: "codex",
      bucketName: "Codex",
      kind: .primary,
      window: CodexRateLimitWindow(
        usedPercent: 0,
        windowDurationMins: 90,
        resetsAt: nil
      )
    )

    XCTAssertEqual(item.title, "90-minute limit")
  }
}
