import Foundation

enum ClaudeUsageClientError: LocalizedError, Equatable {
  case credentialsNotFound
  case credentialsExpired
  case keychainAccessDenied
  case invalidCredentials
  case invalidResponse
  case noRateLimits
  case unauthorized
  case rateLimited(retryAfter: TimeInterval)
  case httpError(Int)
  case requestTimedOut
  case networkUnavailable

  var errorDescription: String? {
    switch self {
    case .credentialsNotFound:
      return "Claude Code login was not found. Open Claude Code and sign in, then refresh."
    case .credentialsExpired:
      return "Claude Code login has expired. Open Claude Code to renew it, then refresh."
    case .keychainAccessDenied:
      return "Claude login access is unavailable. Click Refresh to allow access, or unlock your Keychain."
    case .invalidCredentials:
      return "Claude Code login could not be read. Sign in to Claude Code again, then refresh."
    case .invalidResponse:
      return "Claude returned an unreadable usage response."
    case .noRateLimits:
      return "No Claude subscription limits were returned for this account."
    case .unauthorized:
      return "Claude login was not accepted. Open Claude Code and sign in again, then refresh."
    case .rateLimited:
      return "Claude usage requests are temporarily limited. Refresh will resume automatically."
    case .httpError(let status):
      return "Claude usage is unavailable (HTTP \(status))."
    case .requestTimedOut:
      return "Claude did not respond in time."
    case .networkUnavailable:
      return "Could not connect to Claude. Check your internet connection."
    }
  }
}

protocol ClaudeUsageFetching: Sendable {
  func fetchRateLimits(allowKeychainInteraction: Bool) async throws -> UsageSnapshot
}

private final class ClaudeSessionDelegate: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    // This endpoint is fixed. Never forward credentials to a redirect target.
    completionHandler(nil)
  }
}

final class ClaudeUsageClient: ClaudeUsageFetching {
  private let credentials: any ClaudeCredentialReading
  private let session: URLSession
  private let now: @Sendable () -> Date

  init(
    credentials: any ClaudeCredentialReading = ClaudeCredentialReader(),
    session: URLSession? = nil,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.credentials = credentials
    self.now = now
    if let session {
      self.session = session
    } else {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.httpShouldSetCookies = false
      configuration.urlCache = nil
      configuration.timeoutIntervalForRequest = 15
      configuration.timeoutIntervalForResource = 20
      self.session = URLSession(
        configuration: configuration, delegate: ClaudeSessionDelegate(), delegateQueue: nil
      )
    }
  }

  func fetchRateLimits(allowKeychainInteraction: Bool = false) async throws -> UsageSnapshot {
    let reader = credentials
    let login = try await Task.detached(priority: .utility) {
      try reader.read(allowInteraction: allowKeychainInteraction)
    }.value
    if let expiration = login.expiresAt, expiration <= now() {
      throw ClaudeUsageClientError.credentialsExpired
    }

    var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue("Bearer \(login.accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("CodexLimitMenuBar/0.2.0", forHTTPHeaderField: "User-Agent")

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch let error as URLError {
      if error.code == .cancelled { throw CancellationError() }
      throw error.code == .timedOut
        ? ClaudeUsageClientError.requestTimedOut : ClaudeUsageClientError.networkUnavailable
    } catch {
      throw ClaudeUsageClientError.networkUnavailable
    }
    guard let http = response as? HTTPURLResponse else {
      throw ClaudeUsageClientError.invalidResponse
    }
    return try Self.decodeResponse(
      data, response: http, planType: login.planType, fetchedAt: now()
    )
  }

  static func decodeResponse(
    _ data: Data, response: HTTPURLResponse, planType: String? = nil,
    fetchedAt: Date = Date()
  ) throws -> UsageSnapshot {
    switch response.statusCode {
    case 200:
      let usage: ClaudeUsageResponse
      do {
        usage = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
      } catch {
        throw ClaudeUsageClientError.invalidResponse
      }
      return try usage.snapshot(planType: planType, fetchedAt: fetchedAt)
    case 401, 403:
      throw ClaudeUsageClientError.unauthorized
    case 429:
      throw ClaudeUsageClientError.rateLimited(retryAfter: retryDelay(
        response.value(forHTTPHeaderField: "Retry-After"), now: fetchedAt
      ))
    default:
      // Response bodies can contain account details; never surface or log them.
      throw ClaudeUsageClientError.httpError(response.statusCode)
    }
  }

  static func retryDelay(_ header: String?, now: Date) -> TimeInterval {
    if let header, let seconds = Double(header), seconds.isFinite {
      return max(300, seconds)
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    if let header, let date = formatter.date(from: header) {
      return max(300, date.timeIntervalSince(now))
    }
    return 300
  }
}
