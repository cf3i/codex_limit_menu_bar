import Darwin
import Foundation

protocol ClaudeCredentialRenewing: Sendable {
  func renew() async throws
}

// Claude Code owns refresh-token rotation, locking, and credential persistence.
// Initialize its SDK transport without ever submitting a user/model message.
actor ClaudeCLICredentialRenewer: ClaudeCredentialRenewing {
  static let shared = ClaudeCLICredentialRenewer()
  private var pending: Task<Void, Error>?

  func renew() async throws {
    if let pending { return try await pending.value }
    let task = Task.detached(priority: .utility) {
      guard let executable = ClaudeRenewalProcess.locate() else {
        throw ClaudeUsageClientError.claudeCLINotFound
      }
      try ClaudeRenewalProcess.run(executable: executable)
    }
    pending = task
    defer { pending = nil }
    try await task.value
  }
}

enum ClaudeRenewalProcess {
  static let arguments = [
    "-p", "--input-format", "stream-json", "--output-format", "stream-json",
    "--verbose", "--no-session-persistence", "--safe-mode", "--setting-sources", "",
    "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}", "--tools", "",
  ]
  static let initializeMessage =
    "{\"type\":\"control_request\",\"request_id\":\"usage-auth-renewal\",\"request\":{\"subtype\":\"initialize\"}}\n"

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
    result["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
    result["DISABLE_AUTOUPDATER"] = "1"
    return result
  }

  static func run(executable: URL, timeout: TimeInterval = 60) throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("codex-limit-renew-\(UUID().uuidString)", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    } catch { throw ClaudeUsageClientError.renewalFailed }
    defer { try? FileManager.default.removeItem(at: directory) }

    let process = Process()
    let input = Pipe()
    defer {
      try? input.fileHandleForWriting.close()
      try? input.fileHandleForReading.close()
    }
    process.executableURL = executable
    process.arguments = arguments
    process.environment = environment(executable: executable)
    process.currentDirectoryURL = directory
    process.standardInput = input
    // CLI diagnostics may contain account details. Neither retain nor log them.
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    do {
      // The single message fits in the pipe; write before launch to avoid SIGPIPE
      // if an incompatible CLI exits immediately. EOF ends initialization.
      try input.fileHandleForWriting.write(contentsOf: Data(initializeMessage.utf8))
      try input.fileHandleForWriting.close()
      try process.run()
    } catch { throw ClaudeUsageClientError.renewalFailed }
    if exited.wait(timeout: .now() + timeout) == .timedOut {
      if process.isRunning { process.terminate() }
      if exited.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
        kill(process.processIdentifier, SIGKILL)
        _ = exited.wait(timeout: .now() + 1)
      }
      throw ClaudeUsageClientError.renewalTimedOut
    }
    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
      throw ClaudeUsageClientError.renewalFailed
    }
  }
}
