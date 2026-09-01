import Foundation
import XCTest

@testable import CodexLimitMenuBar

final class AppServerClientTests: XCTestCase {
  func testLiveCodexRateLimitsWhenEnabled() async throws {
    guard ProcessInfo.processInfo.environment["CODEX_LIMIT_LIVE_TEST"] == "1" else {
      throw XCTSkip("Set CODEX_LIMIT_LIVE_TEST=1 to query the signed-in Codex account.")
    }
    guard let executable = CodexLocator().locate() else {
      XCTFail("Codex CLI was not found")
      return
    }

    let snapshot = try await AppServerClient(timeout: 20)
      .fetchRateLimits(executableURL: executable)

    XCTAssertFalse(snapshot.buckets.isEmpty)
    XCTAssertFalse(snapshot.windows.isEmpty)
    XCTAssertNotNil(snapshot.weeklyRemainingPercent)
  }

  func testDecodesMultipleRateLimitBuckets() throws {
    let json = #"""
      {
        "id": 2,
        "result": {
          "rateLimits": {
            "limitId": "codex",
            "limitName": null,
            "primary": { "usedPercent": 25, "windowDurationMins": 300, "resetsAt": 1730947200 },
            "secondary": null,
            "rateLimitReachedType": null
          },
          "rateLimitsByLimitId": {
            "codex_other": {
              "limitId": "codex_other",
              "limitName": "Other Codex",
              "primary": { "usedPercent": 42.5, "windowDurationMins": 60, "resetsAt": 1730950800 },
              "secondary": null,
              "rateLimitReachedType": null
            },
            "codex": {
              "limitId": "codex",
              "limitName": null,
              "primary": { "usedPercent": 25, "windowDurationMins": 300, "resetsAt": 1730947200 },
              "secondary": { "usedPercent": 60, "windowDurationMins": 10080, "resetsAt": 1731552000 },
              "rateLimitReachedType": null,
              "planType": "plus"
            }
          },
          "rateLimitResetCredits": { "availableCount": 2, "credits": [] }
        }
      }
      """#

    let result = try AppServerClient.decodeRateLimitResponse(Data(json.utf8))

    XCTAssertEqual(result.normalizedBuckets.map(\.limitId), ["codex", "codex_other"])
    XCTAssertEqual(result.normalizedBuckets[0].primary?.remainingPercent, 75)
    XCTAssertEqual(result.normalizedBuckets[0].secondary?.remainingPercent, 40)
    XCTAssertEqual(result.rateLimitResetCredits?.availableCount, 2)
  }

  func testFallsBackToLegacySingleBucket() throws {
    let json = #"""
      {
        "id": 2,
        "result": {
          "rateLimits": {
            "limitId": "codex",
            "primary": { "usedPercent": 80, "windowDurationMins": 300, "resetsAt": 1730947200 },
            "secondary": null
          },
          "rateLimitsByLimitId": null,
          "rateLimitResetCredits": null
        }
      }
      """#

    let result = try AppServerClient.decodeRateLimitResponse(Data(json.utf8))

    XCTAssertEqual(result.normalizedBuckets.count, 1)
    XCTAssertEqual(result.normalizedBuckets[0].primary?.remainingPercent, 20)
  }

  func testSurfacesRPCError() {
    let json = #"{"id":2,"error":{"code":-32000,"message":"Not logged in"}}"#

    XCTAssertThrowsError(
      try AppServerClient.decodeRateLimitResponse(Data(json.utf8))
    ) { error in
      XCTAssertEqual(
        error as? AppServerClientError,
        .rpcError(code: -32000, message: "Not logged in")
      )
    }
  }

  func testRemainingPercentIsClamped() {
    XCTAssertEqual(
      CodexRateLimitWindow(usedPercent: -10, windowDurationMins: nil, resetsAt: nil)
        .remainingPercent,
      100
    )
    XCTAssertEqual(
      CodexRateLimitWindow(usedPercent: 110, windowDurationMins: nil, resetsAt: nil)
        .remainingPercent,
      0
    )
  }
}
