import Darwin
import Foundation

enum ClaudeUsageProcess {
  static let arguments = [
    "-p", "--input-format", "stream-json", "--output-format", "stream-json",
    "--verbose", "--no-session-persistence", "--safe-mode", "--setting-sources", "",
    "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}", "--tools", "",
  ]
  static let initializeMessage =
    "{\"type\":\"control_request\",\"request_id\":\"usage-initialize\",\"request\":{\"subtype\":\"initialize\"}}\n"

  static let usageMessage =
    "{\"type\":\"control_request\",\"request_id\":\"usage-read\",\"request\":{\"subtype\":\"get_usage\",\"skip_behaviors\":true}}\n"

  static func locate(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> URL? {
    let directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
      + ["\(home.path)/.local/bin", "\(home.path)/.npm-global/bin",
         "\(home.path)/.bun/bin", "/opt/homebrew/bin", "/usr/local/bin"]
    return directories.map { URL(fileURLWithPath: $0).appendingPathComponent("claude") }
      .first { FileManager.default.isExecutableFile(atPath: $0.path) }
  }

  static func environment(
    executable: URL, inherited: [String: String] = ProcessInfo.processInfo.environment
  ) -> [String: String] {
    // Keep the same login directory and network configuration, without allowing
    // an unrelated API key, provider, or SDK environment to select another login.
    let keys = ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "CLAUDE_CONFIG_DIR",
      "HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "NO_PROXY",
      "https_proxy", "http_proxy", "all_proxy", "no_proxy",
      "SSL_CERT_FILE", "NODE_EXTRA_CA_CERTS"]
    var result = inherited.filter { keys.contains($0.key) }
    result["HOME"] = result["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
    if let directory = result["CLAUDE_CONFIG_DIR"], !directory.isEmpty {
      result["CLAUDE_CONFIG_DIR"] = URL(fileURLWithPath:
        NSString(string: directory).expandingTildeInPath).standardizedFileURL.path
    }
    result["PATH"] = ([executable.deletingLastPathComponent().path,
      "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
      + (inherited["PATH"] ?? "").split(separator: ":").map(String.init)).joined(separator: ":")
    // The broad NONESSENTIAL switch blocks /api/oauth/usage before OAuth renewal.
    // Disable telemetry specifically, keeping authenticated usage reads available.
    result["DISABLE_TELEMETRY"] = "1"
    result["DISABLE_ERROR_REPORTING"] = "1"
    result["DISABLE_AUTOUPDATER"] = "1"
    return result
  }

  static func run(executable: URL, timeout: TimeInterval = 60) throws -> UsageSnapshot {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("codex-limit-usage-\(UUID().uuidString)", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    } catch { throw ClaudeUsageClientError.cliFailed }
    defer { try? FileManager.default.removeItem(at: directory) }

    let process = Process()
    let input = Pipe()
    let output = Pipe()
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    defer {
      try? input.fileHandleForWriting.close()
      if process.isRunning {
        process.terminate()
        if exited.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
          kill(process.processIdentifier, SIGKILL)
          _ = exited.wait(timeout: .now() + 1)
        }
      }
      try? input.fileHandleForReading.close()
      try? output.fileHandleForReading.close()
      try? output.fileHandleForWriting.close()
    }
    process.executableURL = executable
    process.arguments = arguments
    process.environment = environment(executable: executable)
    process.currentDirectoryURL = directory
    process.standardInput = input
    process.standardOutput = output
    // Parse only usage control responses; never persist raw output or errors.
    process.standardError = FileHandle.nullDevice
    do {
      // Both small messages fit in the pipe. Keep it open until get_usage replies:
      // EOF after initialize can end the CLI before background renewal runs.
      try input.fileHandleForWriting.write(contentsOf: Data((initializeMessage + usageMessage).utf8))
      try process.run()
      try output.fileHandleForWriting.close()
    } catch { throw ClaudeUsageClientError.cliFailed }

    let deadline = DispatchTime.now() + timeout
    var pending = Data()
    var bytes = [UInt8](repeating: 0, count: 16_384)
    var snapshot: UsageSnapshot?
    var ended = false
    while !ended {
      guard DispatchTime.now() < deadline else { throw ClaudeUsageClientError.cliTimedOut }
      var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor,
        events: Int16(POLLIN | POLLHUP), revents: 0)
      let ready = poll(&descriptor, 1, 100)
      if ready < 0 {
        if errno == EINTR { continue }
        throw ClaudeUsageClientError.cliFailed
      }
      if ready == 0 { continue }
      let count = Darwin.read(descriptor.fd, &bytes, bytes.count)
      if count == 0 { ended = true; break }
      guard count > 0 else {
        if errno == EINTR { continue }
        throw ClaudeUsageClientError.cliFailed
      }
      pending.append(contentsOf: bytes.prefix(count))
      guard pending.count <= 1_048_576 else { throw ClaudeUsageClientError.cliProtocolFailed }
      while let newline = pending.firstIndex(of: 0x0A) {
        let line = pending.prefix(upTo: newline)
        let message = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
        pending.removeSubrange(...newline)
        guard let message, message["type"] as? String == "control_response",
          let response = message["response"] as? [String: Any],
          let id = response["request_id"] as? String,
          ["usage-initialize", "usage-read"].contains(id)
        else { continue }
        guard response["subtype"] as? String == "success" else {
          throw ClaudeUsageClientError.cliProtocolFailed
        }
        if id == "usage-read", snapshot == nil {
          guard let payload = response["response"] as? [String: Any] else {
            throw ClaudeUsageClientError.cliProtocolFailed
          }
          if payload["rate_limits_available"] as? Bool == false {
            throw ClaudeUsageClientError.noRateLimits
          }
          guard let limits = payload["rate_limits"] as? [String: Any] else {
            throw ClaudeUsageClientError.usageUnavailable
          }
          // Decode quota fields only. Account details and other CLI output are discarded.
          snapshot = try ClaudeUsageClient.decodeResponse(JSONSerialization.data(withJSONObject: limits))
          try? input.fileHandleForWriting.close()
          // Drain remaining stdout while the child exits, avoiding a full-pipe deadlock.
        }
      }
    }
    try? input.fileHandleForWriting.close()
    guard exited.wait(timeout: deadline) == .success else {
      throw ClaudeUsageClientError.cliTimedOut
    }
    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
      throw ClaudeUsageClientError.cliFailed
    }
    guard let snapshot else { throw ClaudeUsageClientError.cliProtocolFailed }
    return snapshot
  }
}
