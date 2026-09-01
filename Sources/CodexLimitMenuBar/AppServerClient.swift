import Foundation

enum AppServerClientError: LocalizedError, Equatable {
  case launchFailed(String)
  case requestTimedOut
  case connectionClosed(String?)
  case invalidResponse
  case rpcError(code: Int?, message: String)
  case noRateLimits

  var errorDescription: String? {
    switch self {
    case .launchFailed(let details):
      return "Could not start Codex CLI: \(details)"
    case .requestTimedOut:
      return "Codex did not respond in time."
    case .connectionClosed(let details):
      if let details, !details.isEmpty {
        return "Codex App Server closed the connection: \(details)"
      }
      return "Codex App Server closed the connection."
    case .invalidResponse:
      return "Codex returned an unreadable response."
    case .rpcError(_, let message):
      if message.localizedCaseInsensitiveContains("not logged in")
        || message.localizedCaseInsensitiveContains("unauthorized")
      {
        return "Codex CLI is not signed in. Run `codex login` first."
      }
      return message
    case .noRateLimits:
      return "No Codex rate-limit windows were returned for this account."
    }
  }
}

private struct RPCErrorPayload: Decodable {
  let code: Int?
  let message: String
}

private struct RPCResponse<Result: Decodable>: Decodable {
  let id: Int?
  let result: Result?
  let error: RPCErrorPayload?
}

final class AppServerClient {
  private let timeout: TimeInterval

  init(timeout: TimeInterval = 15) {
    self.timeout = timeout
  }

  func fetchRateLimits(executableURL: URL) async throws -> UsageSnapshot {
    let timeout = timeout
    return try await Task.detached(priority: .utility) {
      let result = try Self.fetchRateLimitsSynchronously(
        executableURL: executableURL,
        timeout: timeout
      )
      guard !result.normalizedBuckets.isEmpty else {
        throw AppServerClientError.noRateLimits
      }
      return UsageSnapshot(result: result)
    }.value
  }

  static func decodeRateLimitResponse(_ data: Data) throws -> RateLimitReadResult {
    let response: RPCResponse<RateLimitReadResult>
    do {
      response = try JSONDecoder().decode(RPCResponse<RateLimitReadResult>.self, from: data)
    } catch {
      throw AppServerClientError.invalidResponse
    }

    if let error = response.error {
      throw AppServerClientError.rpcError(code: error.code, message: error.message)
    }
    guard let result = response.result else {
      throw AppServerClientError.invalidResponse
    }
    return result
  }

  private static func fetchRateLimitsSynchronously(
    executableURL: URL,
    timeout: TimeInterval
  ) throws -> RateLimitReadResult {
    let process = Process()
    let standardInput = Pipe()
    let standardOutput = Pipe()
    let standardError = Pipe()

    process.executableURL = executableURL
    process.arguments = ["app-server"]
    process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
    process.standardInput = standardInput
    process.standardOutput = standardOutput
    process.standardError = standardError
    process.environment = processEnvironment(executableURL: executableURL)

    do {
      try process.run()
    } catch {
      throw AppServerClientError.launchFailed(error.localizedDescription)
    }

    let timeoutState = TimeoutState()
    let timeoutWork = DispatchWorkItem {
      timeoutState.markTimedOut()
      if process.isRunning {
        process.terminate()
      }
    }
    DispatchQueue.global(qos: .utility).asyncAfter(
      deadline: .now() + timeout,
      execute: timeoutWork
    )

    defer {
      timeoutWork.cancel()
      try? standardInput.fileHandleForWriting.close()
      if process.isRunning {
        process.terminate()
      }
    }

    do {
      try sendHandshakeAndRequest(to: standardInput.fileHandleForWriting)
    } catch {
      throw AppServerClientError.connectionClosed(error.localizedDescription)
    }

    var buffer = Data()

    while true {
      let chunk = standardOutput.fileHandleForReading.availableData
      if chunk.isEmpty {
        if timeoutState.didTimeOut {
          throw AppServerClientError.requestTimedOut
        }
        let details = readAvailableStderr(from: standardError)
        throw AppServerClientError.connectionClosed(details)
      }

      buffer.append(chunk)
      while let newline = buffer.firstIndex(of: 0x0A) {
        let line = buffer[..<newline]
        buffer.removeSubrange(...newline)

        guard !line.isEmpty, responseID(in: line) == 2 else { continue }
        return try decodeRateLimitResponse(Data(line))
      }
    }
  }

  private static func sendHandshakeAndRequest(to handle: FileHandle) throws {
    let messages: [[String: Any]] = [
      [
        "method": "initialize",
        "id": 1,
        "params": [
          "clientInfo": [
            "name": "codex_limit_menu_bar",
            "title": "Codex Limit Menu Bar",
            "version": Bundle.main.object(
              forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "dev",
          ]
        ],
      ],
      [
        "method": "initialized",
        "params": [:],
      ],
      [
        "method": "account/rateLimits/read",
        "id": 2,
      ],
    ]

    for message in messages {
      var data = try JSONSerialization.data(withJSONObject: message, options: [])
      data.append(0x0A)
      try handle.write(contentsOf: data)
    }
  }

  private static func responseID(in data: Data.SubSequence) -> Int? {
    guard
      let object = try? JSONSerialization.jsonObject(with: Data(data)) as? [String: Any],
      let id = object["id"] as? NSNumber
    else {
      return nil
    }
    return id.intValue
  }

  private static func readAvailableStderr(from pipe: Pipe) -> String? {
    let data = pipe.fileHandleForReading.availableData
    guard !data.isEmpty else { return nil }
    return String(data: data, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func processEnvironment(executableURL: URL) -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    let currentPath = environment["PATH"] ?? ""
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let extraPaths = [
      executableURL.deletingLastPathComponent().path,
      "/opt/homebrew/bin",
      "/usr/local/bin",
      "\(home)/.local/bin",
      "\(home)/.npm-global/bin",
      "/usr/bin",
      "/bin",
    ]
    let combined = (extraPaths + currentPath.split(separator: ":").map(String.init))
      .reduce(into: [String]()) { result, path in
        if !path.isEmpty, !result.contains(path) {
          result.append(path)
        }
      }
    environment["PATH"] = combined.joined(separator: ":")
    return environment
  }
}

private final class TimeoutState {
  private let lock = NSLock()
  private var value = false

  var didTimeOut: Bool {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func markTimedOut() {
    lock.lock()
    value = true
    lock.unlock()
  }
}
