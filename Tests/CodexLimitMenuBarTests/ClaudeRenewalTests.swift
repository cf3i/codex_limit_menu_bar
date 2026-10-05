import Foundation
import XCTest
@testable import CodexLimitMenuBar

private final class RenewalCredentials: ClaudeCredentialReading, @unchecked Sendable {
  private let lock = NSLock()
  private var value: ClaudeCredentials
  init(_ value: ClaudeCredentials) { self.value = value }
  func read(allowInteraction: Bool) throws -> ClaudeCredentials {
    lock.lock(); defer { lock.unlock() }; return value
  }
  func set(_ value: ClaudeCredentials) {
    lock.lock(); defer { lock.unlock() }; self.value = value
  }
}

private actor FixtureRenewer: ClaudeCredentialRenewing {
  private(set) var calls = 0
  let action: @Sendable () throws -> Void
  init(_ action: @escaping @Sendable () throws -> Void = {}) { self.action = action }
  func renew() async throws { calls += 1; try action() }
}

private final class UsageResponseProtocol: URLProtocol {
  private static let lock = NSLock()
  private static var handlers: [String: (URLRequest) -> (Int, String)] = [:]
  static func register(_ id: String, _ handler: @escaping (URLRequest) -> (Int, String)) {
    lock.lock(); defer { lock.unlock() }; handlers[id] = handler
  }
  static func remove(_ id: String) {
    lock.lock(); defer { lock.unlock() }; handlers.removeValue(forKey: id)
  }
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    Self.lock.lock()
    let handler = Self.handlers[request.value(forHTTPHeaderField: "X-Fixture-ID") ?? ""]
    Self.lock.unlock()
    guard let handler else { XCTFail("Missing fixture"); return }
    let (status, body) = handler(request)
    client?.urlProtocol(self, didReceive: HTTPURLResponse(
      url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
    )!, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

final class ClaudeRenewalTests: XCTestCase {
  private var fixtures: [String] = []
  private let goodBody = #"{"five_hour":{"utilization":20,"resets_at":null}}"#
  private func login(_ token: String, expired: Bool = false) -> ClaudeCredentials {
    ClaudeCredentials(accessToken: token,
      expiresAt: expired ? .distantPast : .distantFuture, planType: "pro")
  }
  private func session(_ handler: @escaping (URLRequest) -> (Int, String)) -> URLSession {
    let id = UUID().uuidString
    fixtures.append(id)
    UsageResponseProtocol.register(id, handler)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [UsageResponseProtocol.self]
    configuration.httpAdditionalHeaders = ["X-Fixture-ID": id]
    return URLSession(configuration: configuration)
  }
  override func tearDown() {
    fixtures.forEach(UsageResponseProtocol.remove)
    super.tearDown()
  }

  func testExpiredTokenRenewsBeforeRequestAndUsesNewCredential() async throws {
    let reader = RenewalCredentials(login("old", expired: true))
    let fresh = login("fresh")
    let renewer = FixtureRenewer { reader.set(fresh) }
    let network = session { request in
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fresh")
      return (200, self.goodBody)
    }
    let value = try await ClaudeUsageClient(credentials: reader, renewer: renewer,
      session: network).fetchRateLimits()
    XCTAssertEqual(value.claudeFiveHourRemainingPercent, 80)
    let calls = await renewer.calls
    XCTAssertEqual(calls, 1)
  }

  func testHealthyCredentialDoesNotStartCLI() async throws {
    let renewer = FixtureRenewer { XCTFail("Healthy token should not need renewal") }
    let client = ClaudeUsageClient(credentials: RenewalCredentials(login("fresh")),
      renewer: renewer, session: session { _ in (200, self.goodBody) })
    _ = try await client.fetchRateLimits()
    let calls = await renewer.calls
    XCTAssertEqual(calls, 0)
  }

  func testRejectedTokenAdoptsConcurrentRotationWithoutStartingCLI() async throws {
    let reader = RenewalCredentials(login("old"))
    let fresh = login("fresh")
    let renewer = FixtureRenewer { XCTFail("The official CLI already rotated the token") }
    var requests = 0
    let client = ClaudeUsageClient(credentials: reader, renewer: renewer,
      session: session { request in
        requests += 1
        if requests == 1 { reader.set(fresh); return (401, "private error body") }
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fresh")
        return (200, self.goodBody)
      })
    _ = try await client.fetchRateLimits()
    XCTAssertEqual(requests, 2)
    let calls = await renewer.calls
    XCTAssertEqual(calls, 0)
  }

  func testRejectedTokenRunsOneRenewalAndRetriesOnce() async throws {
    let reader = RenewalCredentials(login("old"))
    let fresh = login("fresh")
    let renewer = FixtureRenewer { reader.set(fresh) }
    var requests = 0
    let client = ClaudeUsageClient(credentials: reader, renewer: renewer,
      session: session { request in
        requests += 1
        if requests == 1 { return (401, "") }
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fresh")
        return (200, self.goodBody)
      })
    _ = try await client.fetchRateLimits()
    XCTAssertEqual(requests, 2)
    let calls = await renewer.calls
    XCTAssertEqual(calls, 1)
  }

  func testRejectionAfterRenewalDoesNotLoopOrExposeBody() async {
    let reader = RenewalCredentials(login("old", expired: true))
    let fresh = login("fresh")
    let renewer = FixtureRenewer { reader.set(fresh) }
    var requests = 0
    let client = ClaudeUsageClient(credentials: reader, renewer: renewer,
      session: session { _ in requests += 1; return (401, "private server detail") })
    do { _ = try await client.fetchRateLimits(); XCTFail("Expected rejection") }
    catch {
      XCTAssertEqual(error as? ClaudeUsageClientError, .unauthorized)
      XCTAssertFalse(error.localizedDescription.contains("private server detail"))
    }
    XCTAssertEqual(requests, 1)
    let calls = await renewer.calls
    XCTAssertEqual(calls, 1)
  }

  func testCLIExitSuccessWithoutFreshCredentialIsNotRenewalSuccess() async {
    let client = ClaudeUsageClient(credentials: RenewalCredentials(login("old", expired: true)),
      renewer: FixtureRenewer(), session: session { _ in
        XCTFail("Expired tokens must never be sent"); return (500, "")
      })
    do { _ = try await client.fetchRateLimits(); XCTFail("Expected renewal failure") }
    catch { XCTAssertEqual(error as? ClaudeUsageClientError, .renewalFailed) }
  }

  func testHelperFailureCanAdoptCredentialRenewedByAnotherProcess() async throws {
    let reader = RenewalCredentials(login("old", expired: true))
    let fresh = login("fresh")
    let renewer = FixtureRenewer {
      reader.set(fresh)
      throw ClaudeUsageClientError.renewalTimedOut
    }
    _ = try await ClaudeUsageClient(credentials: reader, renewer: renewer,
      session: session { _ in (200, self.goodBody) }).fetchRateLimits()
  }

  func testRateLimitDoesNotTriggerCredentialRenewal() async {
    let renewer = FixtureRenewer { XCTFail("Usage rate limits are not authentication failures") }
    let client = ClaudeUsageClient(credentials: RenewalCredentials(login("fresh")),
      renewer: renewer, session: session { _ in (429, "") })
    do { _ = try await client.fetchRateLimits(); XCTFail("Expected cooldown") }
    catch { XCTAssertEqual(error as? ClaudeUsageClientError, .rateLimited(retryAfter: 300)) }
  }

  func testRenewalEnvironmentUsesSameLoginWithoutProviderOverrides() {
    let env = ClaudeRenewalProcess.environment(executable: URL(fileURLWithPath: "/test/claude"),
      inherited: ["CLAUDE_CONFIG_DIR": "/custom/claude", "HTTPS_PROXY": "http://localhost:1234",
        "ANTHROPIC_API_KEY": "fixture", "CLAUDE_CODE_OAUTH_TOKEN": "fixture",
        "ANTHROPIC_BASE_URL": "https://example.com", "CLAUDE_CODE_SIMPLE": "1"])
    XCTAssertEqual(env["CLAUDE_CONFIG_DIR"], "/custom/claude")
    XCTAssertEqual(env["HTTPS_PROXY"], "http://localhost:1234")
    XCTAssertNil(env["ANTHROPIC_API_KEY"])
    XCTAssertNil(env["CLAUDE_CODE_OAUTH_TOKEN"])
    XCTAssertNil(env["ANTHROPIC_BASE_URL"])
    XCTAssertNil(env["CLAUDE_CODE_SIMPLE"])
  }
}
