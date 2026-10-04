import Foundation
import XCTest

@testable import CodexLimitMenuBar

final class ClaudeUsageClientTests: XCTestCase {
  private let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

  private func response(_ status: Int = 200, headers: [String: String] = [:]) -> HTTPURLResponse {
    HTTPURLResponse(url: endpoint, statusCode: status, httpVersion: nil, headerFields: headers)!
  }

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
    let snapshot = try ClaudeUsageClient.decodeResponse(data, response: response(), planType: "pro")
    XCTAssertEqual(snapshot.claudeWeeklyRemainingPercent, 81)
    XCTAssertEqual(snapshot.claudeFiveHourRemainingPercent, 94)
    XCTAssertEqual(snapshot.windows.first?.window.remainingPercent, 94)
    XCTAssertEqual(snapshot.windows.map(\.title), ["5-hour limit", "Weekly limit"])
    XCTAssertNotNil(snapshot.windows.first?.window.resetDate)
    XCTAssertEqual(snapshot.planType, "pro")
  }

  func testMissingAggregateWeeklyDoesNotUseModelSpecificWeekly() throws {
    let data = Data(#"""
      {
        "five_hour": {"utilization": 20, "resets_at": null},
        "seven_day": null,
        "seven_day_sonnet": {"utilization": 52, "resets_at": "2026-10-06T21:00:00Z"}
      }
      """#.utf8)
    let snapshot = try ClaudeUsageClient.decodeResponse(data, response: response())
    XCTAssertNil(snapshot.claudeWeeklyRemainingPercent)
    XCTAssertEqual(snapshot.claudeFiveHourRemainingPercent, 80)
    XCTAssertEqual(snapshot.windows.count, 2)
    XCTAssertEqual(snapshot.windows.last?.bucketName, "Claude Sonnet")
    XCTAssertEqual(snapshot.windows.last?.window.remainingPercent, 48)
  }

  func testHandlesSingleWindowAndClampsRemaining() throws {
    for (used, expected) in [(-10, 100), (110, 0)] {
      let data = Data("{\"seven_day\":{\"utilization\":\(used),\"resets_at\":null}}".utf8)
      let snapshot = try ClaudeUsageClient.decodeResponse(data, response: response())
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
        Data(json.utf8), response: response()
      )) { XCTAssertEqual($0 as? ClaudeUsageClientError, expected) }
    }
  }

  func testAuthenticationAndServerErrorsDoNotExposeResponseBody() {
    for (status, expected) in [(401, ClaudeUsageClientError.unauthorized),
      (403, .unauthorized), (503, .httpError(503))]
    {
      XCTAssertThrowsError(try ClaudeUsageClient.decodeResponse(
        Data("sensitive server detail".utf8), response: response(status)
      )) {
        XCTAssertEqual($0 as? ClaudeUsageClientError, expected)
        XCTAssertFalse($0.localizedDescription.contains("sensitive"))
      }
    }
  }

  func testHonorsRateLimitRetryAfter() {
    XCTAssertThrowsError(try ClaudeUsageClient.decodeResponse(
      Data(), response: response(429, headers: ["Retry-After": "900"])
    )) { XCTAssertEqual($0 as? ClaudeUsageClientError, .rateLimited(retryAfter: 900)) }
    let now = Date(timeIntervalSince1970: 1_791_072_000)
    XCTAssertEqual(ClaudeUsageClient.retryDelay("0", now: now), 300)
    XCTAssertEqual(ClaudeUsageClient.retryDelay("invalid", now: now), 300)
    XCTAssertEqual(ClaudeUsageClient.retryDelay("inf", now: now), 300)
    let date = DateFormatter()
    date.locale = Locale(identifier: "en_US_POSIX")
    date.timeZone = TimeZone(secondsFromGMT: 0)
    date.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    XCTAssertEqual(
      ClaudeUsageClient.retryDelay(date.string(from: now.addingTimeInterval(1_200)), now: now), 1_200
    )
  }

  func testReadsOnlyAccessCredentialAndConvertsMillisecondExpiration() throws {
    let data = Data(#"""
      {"claudeAiOauth": {
        "accessToken": "fixture-access-token", "refreshToken": "ignored",
        "expiresAt": 1791072000000, "subscriptionType": "pro"
      }}
      """#.utf8)
    let login = try ClaudeCredentialReader.decode(data)
    XCTAssertEqual(login.accessToken, "fixture-access-token")
    XCTAssertEqual(login.expiresAt, Date(timeIntervalSince1970: 1_791_072_000))
    XCTAssertEqual(login.planType, "pro")
  }

  func testRejectsMissingOrMalformedCredentials() {
    for json in ["{}", "bad JSON", #"{"claudeAiOauth":{"accessToken":""}}"#,
      #"{"claudeAiOauth":{"accessToken":"bad\ntoken"}}"#]
    {
      XCTAssertThrowsError(try ClaudeCredentialReader.decode(Data(json.utf8))) {
        XCTAssertEqual($0 as? ClaudeUsageClientError, .invalidCredentials)
      }
    }
  }

  func testCustomClaudeDirectoryUsesSeparateKeychainService() {
    let directory = URL(fileURLWithPath: "/tmp/claude-custom")
    XCTAssertEqual(
      ClaudeCredentialReader.keychainService(configDirectory: directory, isCustom: false),
      "Claude Code-credentials"
    )
    let custom = ClaudeCredentialReader.keychainService(configDirectory: directory, isCustom: true)
    XCTAssertTrue(custom.hasPrefix("Claude Code-credentials-"))
    XCTAssertNotEqual(custom, ClaudeCredentialReader.keychainService(
      configDirectory: URL(fileURLWithPath: "/tmp/claude-other"), isCustom: true
    ))
  }

  func testExpiredCredentialFailsBeforeMakingNetworkRequest() async {
    struct ExpiredReader: ClaudeCredentialReading {
      func read(allowInteraction: Bool) throws -> ClaudeCredentials {
        ClaudeCredentials(accessToken: "fixture", expiresAt: .distantPast, planType: nil)
      }
    }
    do {
      _ = try await ClaudeUsageClient(credentials: ExpiredReader()).fetchRateLimits()
      XCTFail("Expired credentials must not be sent")
    } catch {
      XCTAssertEqual(error as? ClaudeUsageClientError, .credentialsExpired)
    }
  }

  func testLiveClaudeRateLimitsWhenEnabled() async throws {
    guard ProcessInfo.processInfo.environment["CLAUDE_LIMIT_LIVE_TEST"] == "1" else {
      throw XCTSkip("Set CLAUDE_LIMIT_LIVE_TEST=1 to query the signed-in Claude account.")
    }
    let snapshot = try await ClaudeUsageClient().fetchRateLimits()
    XCTAssertFalse(snapshot.windows.isEmpty)
    XCTAssertNotNil(snapshot.claudeWeeklyRemainingPercent)
    print("Claude weekly remaining: \(snapshot.claudeWeeklyRemainingPercent ?? -1)%")
  }
}
