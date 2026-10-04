import Foundation
import XCTest

@testable import CodexLimitMenuBar

private actor MockCodexClient: CodexUsageFetching {
  var result: Result<UsageSnapshot, Error>
  init(_ result: Result<UsageSnapshot, Error>) { self.result = result }
  func setResult(_ result: Result<UsageSnapshot, Error>) { self.result = result }
  func fetchRateLimits(executableURL: URL) async throws -> UsageSnapshot { try result.get() }
}

private actor MockClaudeClient: ClaudeUsageFetching {
  var result: Result<UsageSnapshot, Error>
  private(set) var calls = 0
  init(_ result: Result<UsageSnapshot, Error>) { self.result = result }
  func setResult(_ result: Result<UsageSnapshot, Error>) { self.result = result }
  func fetchRateLimits(allowKeychainInteraction: Bool) async throws -> UsageSnapshot {
    calls += 1
    return try result.get()
  }
}

private actor SuspendedCodexClient: CodexUsageFetching {
  private var pending: CheckedContinuation<UsageSnapshot, Error>?
  private var waiter: CheckedContinuation<Void, Never>?
  func fetchRateLimits(executableURL: URL) async throws -> UsageSnapshot {
    try await withCheckedThrowingContinuation { continuation in
      pending = continuation
      waiter?.resume()
      waiter = nil
    }
  }
  func waitUntilRequested() async {
    if pending != nil { return }
    await withCheckedContinuation { waiter = $0 }
  }
  func finish(_ snapshot: UsageSnapshot) { pending?.resume(returning: snapshot); pending = nil }
}

@MainActor
final class UsageStoreTests: XCTestCase {
  private var defaults: UserDefaults!
  private var suite: String!
  private var clock = Date(timeIntervalSince1970: 1_791_072_000)

  override func setUp() {
    super.setUp()
    suite = "CodexLimitMenuBarTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suite)!
    defaults.set("/usr/bin/true", forKey: CodexLocator.userDefaultsKey)
    clock = Date(timeIntervalSince1970: 1_791_072_000)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suite)
    defaults = nil
    super.tearDown()
  }

  private func snapshot(_ provider: String, used: Double) -> UsageSnapshot {
    UsageSnapshot(fetchedAt: clock, buckets: [CodexRateLimitBucket(
      limitId: provider,
      primary: provider == "claude"
        ? CodexRateLimitWindow(usedPercent: used, windowDurationMins: 300, resetsAt: nil) : nil,
      secondary: CodexRateLimitWindow(
        usedPercent: provider == "claude" ? 65 : used,
        windowDurationMins: 10_080, resetsAt: nil
      )
    )])
  }

  private func store(
    codex: any CodexUsageFetching, claude: any ClaudeUsageFetching
  ) -> UsageStore {
    UsageStore(
      client: codex, claudeClient: claude,
      locator: CodexLocator(userDefaults: defaults), defaults: defaults,
      startAutomatically: false, now: { self.clock }
    )
  }

  func testMenuUsesCodexWeeklyAndClaudeFiveHourWithIndependentCaches() async {
    let codex = MockCodexClient(.success(snapshot("codex", used: 61)))
    let claude = MockClaudeClient(.success(snapshot("claude", used: 19)))
    let usage = store(codex: codex, claude: claude)
    XCTAssertEqual(usage.menuBarText, "-- | --")
    await usage.refresh()
    XCTAssertEqual(usage.menuBarText, "39% | 81%")
    XCTAssertEqual(usage.claudeSnapshot?.claudeWeeklyRemainingPercent, 35)
    XCTAssertTrue(usage.menuBarHelp.contains("Codex weekly remaining"))
    XCTAssertTrue(usage.menuBarHelp.contains("Claude 5-hour remaining"))
    XCTAssertFalse(usage.codexShowsLastKnownData)
    XCTAssertFalse(usage.claudeShowsLastKnownData)
    let restored = store(codex: codex, claude: claude)
    XCTAssertEqual(restored.menuBarText, "39% | 81%")
    XCTAssertTrue(restored.codexShowsLastKnownData)
    XCTAssertTrue(restored.claudeShowsLastKnownData)
    XCTAssertTrue(restored.menuBarHelp.contains("last known"))
  }

  func testMissingClaudeFiveHourDoesNotSubstituteWeekly() async {
    let codex = MockCodexClient(.success(snapshot("codex", used: 61)))
    let weeklyOnly = UsageSnapshot(fetchedAt: clock, buckets: [CodexRateLimitBucket(
      limitId: "claude",
      secondary: CodexRateLimitWindow(usedPercent: 19, windowDurationMins: 10_080, resetsAt: nil)
    )])
    let claude = MockClaudeClient(.success(weeklyOnly))
    let usage = store(codex: codex, claude: claude)
    await usage.refresh()
    XCTAssertEqual(usage.menuBarText, "39% | --")
    XCTAssertEqual(usage.claudeSnapshot?.claudeWeeklyRemainingPercent, 81)
  }

  func testClaudeLoginFailureDoesNotBlockCodexAndRecovers() async {
    let codex = MockCodexClient(.success(snapshot("codex", used: 61)))
    let claude = MockClaudeClient(.failure(ClaudeUsageClientError.credentialsExpired))
    let usage = store(codex: codex, claude: claude)
    await usage.refresh()
    XCTAssertEqual(usage.menuBarText, "39% | --")
    XCTAssertNil(usage.errorMessage)
    XCTAssertNotNil(usage.claudeErrorMessage)
    await claude.setResult(.success(snapshot("claude", used: 19)))
    await usage.refreshClaude()
    XCTAssertEqual(usage.menuBarText, "39% | 81%")
    XCTAssertNil(usage.claudeErrorMessage)
  }

  func testCodexFailureKeepsItsCacheWhileClaudeUpdates() async {
    let codex = MockCodexClient(.success(snapshot("codex", used: 61)))
    let claude = MockClaudeClient(.success(snapshot("claude", used: 19)))
    let usage = store(codex: codex, claude: claude)
    await usage.refresh()
    await codex.setResult(.failure(AppServerClientError.requestTimedOut))
    await claude.setResult(.success(snapshot("claude", used: 30)))
    await usage.refresh()
    XCTAssertEqual(usage.menuBarText, "39% | 70%")
    XCTAssertTrue(usage.codexShowsLastKnownData)
    XCTAssertFalse(usage.claudeShowsLastKnownData)
    XCTAssertNotNil(usage.errorMessage)
    XCTAssertNil(usage.claudeErrorMessage)
  }

  func testClaudeFailureKeepsItsCacheWhileCodexUpdates() async {
    let codex = MockCodexClient(.success(snapshot("codex", used: 61)))
    let claude = MockClaudeClient(.success(snapshot("claude", used: 19)))
    let usage = store(codex: codex, claude: claude)
    await usage.refresh()
    await codex.setResult(.success(snapshot("codex", used: 70)))
    await claude.setResult(.failure(ClaudeUsageClientError.networkUnavailable))
    await usage.refresh()
    XCTAssertEqual(usage.menuBarText, "30% | 81%")
    XCTAssertFalse(usage.codexShowsLastKnownData)
    XCTAssertTrue(usage.claudeShowsLastKnownData)
    XCTAssertEqual(usage.menuBarSymbol, "exclamationmark.triangle")
  }

  func testClaudeRefreshCompletesWhileCodexIsStillWaiting() async {
    let codex = SuspendedCodexClient()
    let claude = MockClaudeClient(.success(snapshot("claude", used: 19)))
    let usage = store(codex: codex, claude: claude)
    let request = Task { await usage.refreshCodex() }
    await codex.waitUntilRequested()
    await usage.refreshClaude()
    XCTAssertEqual(usage.menuBarText, "… | 81%")
    XCTAssertTrue(usage.isCodexRefreshing)
    XCTAssertFalse(usage.isClaudeRefreshing)
    await codex.finish(snapshot("codex", used: 61))
    await request.value
    XCTAssertEqual(usage.menuBarText, "39% | 81%")
  }

  func testRateLimitCooldownBlocksManualRequestsAndBacksOff() async {
    let codex = MockCodexClient(.success(snapshot("codex", used: 61)))
    let claude = MockClaudeClient(.failure(ClaudeUsageClientError.rateLimited(retryAfter: 900)))
    let usage = store(codex: codex, claude: claude)
    await usage.refresh()
    XCTAssertEqual(usage.claudeNextRetryAt, clock.addingTimeInterval(900))
    await usage.refresh()
    await usage.refreshIfStale()
    let initialCalls = await claude.calls
    XCTAssertEqual(initialCalls, 1)
    XCTAssertEqual(usage.codexMenuBarText, "39%")
    clock = clock.addingTimeInterval(900)
    await claude.setResult(.failure(ClaudeUsageClientError.rateLimited(retryAfter: 300)))
    await usage.refreshClaude()
    XCTAssertEqual(usage.claudeNextRetryAt, clock.addingTimeInterval(600))
    clock = clock.addingTimeInterval(600)
    await claude.setResult(.success(snapshot("claude", used: 19)))
    await usage.refreshClaude()
    XCTAssertNil(usage.claudeNextRetryAt)
    XCTAssertNil(usage.claudeErrorMessage)
  }
}
