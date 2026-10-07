import Foundation

enum ClaudeUsageClientError: LocalizedError, Equatable {
  case claudeCLINotFound
  case cliFailed
  case cliTimedOut
  case cliProtocolFailed
  case invalidResponse
  case noRateLimits
  case usageUnavailable

  var errorDescription: String? {
    switch self {
    case .claudeCLINotFound:
      return "Claude Code was not found. Install it and sign in, then refresh."
    case .cliFailed:
      return "Claude Code could not read usage. Open Claude Code and check /usage, then refresh."
    case .cliTimedOut:
      return "Claude Code did not respond in time. Check your connection or open Claude Code."
    case .cliProtocolFailed:
      return "Claude Code did not complete the usage request. Update Claude Code, then refresh."
    case .invalidResponse:
      return "Claude Code returned an unreadable usage response."
    case .noRateLimits:
      return "No Claude subscription limits were returned. Open Claude Code and check /usage."
    case .usageUnavailable:
      return "Claude Code could not retrieve usage. It will retry automatically; check /usage in Claude Code if this continues."
    }
  }
}

protocol ClaudeUsageFetching: Sendable {
  func fetchRateLimits() async throws -> UsageSnapshot
}

// The official CLI owns all authentication and Keychain access. This app only
// receives quota values; it never reads, copies, or sends Claude credentials.
actor ClaudeUsageClient: ClaudeUsageFetching {
  static let shared = ClaudeUsageClient()
  private var pending: Task<UsageSnapshot, Error>?
  private let reader: @Sendable () async throws -> UsageSnapshot

  init(reader: @escaping @Sendable () async throws -> UsageSnapshot = {
    try await Task.detached(priority: .utility) {
      guard let executable = ClaudeUsageProcess.locate() else {
        throw ClaudeUsageClientError.claudeCLINotFound
      }
      return try ClaudeUsageProcess.run(executable: executable)
    }.value
  }) {
    self.reader = reader
  }

  func fetchRateLimits() async throws -> UsageSnapshot {
    if let pending { return try await pending.value }
    let reader = reader
    let task = Task { try await reader() }
    pending = task
    defer { pending = nil }
    return try await task.value
  }

  static func decodeResponse(_ data: Data) throws -> UsageSnapshot {
    do {
      return try JSONDecoder().decode(ClaudeUsageResponse.self, from: data).snapshot()
    } catch let error as ClaudeUsageClientError {
      throw error
    } catch {
      throw ClaudeUsageClientError.invalidResponse
    }
  }
}
