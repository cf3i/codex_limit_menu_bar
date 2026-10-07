import Foundation
import XCTest

@testable import CodexLimitMenuBar

final class ClaudeUsageClientTests: XCTestCase {
  func testDecodesActualUsageShapeWithFractionalResetDates() throws {
    let data = Data(#"""
      {
        "five_hour": {"utilization": 6.0, "resets_at": "2026-10-04T17:00:00.332735+00:00"},
        "seven_day": {"utilization": 19.0, "resets_at": "2026-10-06T21:00:00.332760+00:00"},
        "seven_day_opus": null,
        "seven_day_breakdown": {"by_model": []},
        "seven_day_future_metadata": ["ignored"],
        "limits": [],
        "extra_usage": {"is_enabled": false, "utilization": null}
      }
      """#.utf8)
    let snapshot = try ClaudeUsageClient.decodeResponse(data)
    XCTAssertEqual(snapshot.claudeWeeklyRemainingPercent, 81)
    XCTAssertEqual(snapshot.claudeFiveHourRemainingPercent, 94)
    XCTAssertEqual(snapshot.windows.first?.window.remainingPercent, 94)
    XCTAssertEqual(snapshot.windows.map(\.title), ["5-hour limit", "Weekly limit"])
    XCTAssertNotNil(snapshot.windows.first?.window.resetDate)
    XCTAssertNil(snapshot.planType)
  }

  func testMissingAggregateWeeklyDoesNotUseModelSpecificWeekly() throws {
    let data = Data(#"""
      {
        "five_hour": {"utilization": 20, "resets_at": null},
        "seven_day": null,
        "seven_day_sonnet": {"utilization": 52, "resets_at": "2026-10-06T21:00:00Z"}
      }
      """#.utf8)
    let snapshot = try ClaudeUsageClient.decodeResponse(data)
    XCTAssertNil(snapshot.claudeWeeklyRemainingPercent)
    XCTAssertEqual(snapshot.claudeFiveHourRemainingPercent, 80)
    XCTAssertEqual(snapshot.windows.count, 2)
    XCTAssertEqual(snapshot.windows.last?.bucketName, "Claude Sonnet")
    XCTAssertEqual(snapshot.windows.last?.window.remainingPercent, 48)
  }

  func testHandlesSingleWindowAndClampsRemaining() throws {
    for (used, expected) in [(-10, 100), (110, 0)] {
      let data = Data("{\"seven_day\":{\"utilization\":\(used),\"resets_at\":null}}".utf8)
      let snapshot = try ClaudeUsageClient.decodeResponse(data)
      XCTAssertEqual(snapshot.claudeWeeklyRemainingPercent, Double(expected))
    }
  }

  func testRejectsEmptyAndMalformedUsage() {
    for (json, expected) in [
      ("{}", ClaudeUsageClientError.noRateLimits),
      (#"{"seven_day":{"utilization":"nineteen"}}"#, .invalidResponse),
      (#"{"seven_day":{"utilization":19,"resets_at":"bad date"}}"#, .invalidResponse),
      ("not JSON", .invalidResponse),
    ] {
      XCTAssertThrowsError(try ClaudeUsageClient.decodeResponse(
        Data(json.utf8)
      )) { XCTAssertEqual($0 as? ClaudeUsageClientError, expected) }
    }
  }

  func testConcurrentRefreshesShareCLIAndNextRefreshStartsAgain() async throws {
    let reader = CountingUsageReader()
    let client = ClaudeUsageClient(reader: { try await reader.read() })
    try await withThrowingTaskGroup(of: UsageSnapshot.self) { group in
      for _ in 0..<8 { group.addTask { try await client.fetchRateLimits() } }
      for try await snapshot in group {
        XCTAssertEqual(snapshot.claudeFiveHourRemainingPercent, 80)
      }
    }
    let firstCalls = await reader.calls
    XCTAssertEqual(firstCalls, 1)
    _ = try await client.fetchRateLimits()
    let secondCalls = await reader.calls
    XCTAssertEqual(secondCalls, 2)
  }

  func testFailedCLIRequestCanRetryOnNextRefresh() async throws {
    let reader = CountingUsageReader(failFirst: true)
    let client = ClaudeUsageClient(reader: { try await reader.read() })
    do { _ = try await client.fetchRateLimits(); XCTFail("Expected CLI failure") }
    catch { XCTAssertEqual(error as? ClaudeUsageClientError, .cliFailed) }
    let snapshot = try await client.fetchRateLimits()
    XCTAssertEqual(snapshot.claudeFiveHourRemainingPercent, 80)
    let calls = await reader.calls
    XCTAssertEqual(calls, 2)
  }

  func testLiveClaudeRateLimitsWhenEnabled() async throws {
    guard ProcessInfo.processInfo.environment["CLAUDE_LIMIT_LIVE_TEST"] == "1" else {
      throw XCTSkip("Set CLAUDE_LIMIT_LIVE_TEST=1 to query the signed-in Claude account.")
    }
    let client = ClaudeUsageClient()
    for _ in 0..<2 {
      let snapshot = try await client.fetchRateLimits()
      XCTAssertFalse(snapshot.windows.isEmpty)
      XCTAssertNotNil(snapshot.claudeFiveHourRemainingPercent)
      print("Claude 5-hour remaining: \(snapshot.claudeFiveHourRemainingPercent ?? -1)%")
    }
  }
}

private actor CountingUsageReader {
  private(set) var calls = 0
  let failFirst: Bool
  init(failFirst: Bool = false) { self.failFirst = failFirst }
  func read() async throws -> UsageSnapshot {
    calls += 1
    if failFirst && calls == 1 { throw ClaudeUsageClientError.cliFailed }
    try await Task.sleep(nanoseconds: 100_000_000)
    return try ClaudeUsageClient.decodeResponse(Data(#"{"five_hour":{"utilization":20}}"#.utf8))
  }
}
