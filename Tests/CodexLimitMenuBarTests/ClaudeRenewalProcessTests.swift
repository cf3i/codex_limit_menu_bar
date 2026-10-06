import Darwin
import Foundation
import XCTest
@testable import CodexLimitMenuBar

final class ClaudeRenewalProcessTests: XCTestCase {
  private func fixture(_ body: (URL) -> String, test: (URL, URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("renewal-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("claude")
    try ("#!/bin/sh\n" + body(directory)).write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    try test(directory, executable)
  }

  func testHelperWaitsForUsageKeepsInputOpenAndAllowsUsageTraffic() throws {
    try fixture({ dir in
      """
      test -z "$CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC" || exit 4
      test "$DISABLE_TELEMETRY" = 1 || exit 5
      test "$DISABLE_ERROR_REPORTING" = 1 || exit 6
      IFS= read -r init
      printf '%s\\n' "$init" > '\(dir.path)/input'
      echo '{"type":"control_response","response":{"request_id":"usage-auth-renewal","subtype":"success"}}'
      IFS= read -r usage
      printf '%s\\n' "$usage" >> '\(dir.path)/input'
      sleep 0.2
      echo '{"type":"control_response","response":{"request_id":"usage-auth-check","subtype":"success","response":{"rate_limits":{}}}}'
      cat > /dev/null
      printf '%s\\n' "$@" > '\(dir.path)/arguments'
      pwd > '\(dir.path)/cwd'
      head -c 131072 /dev/zero >&2
      """
    }) { dir, executable in
      try ClaudeRenewalProcess.run(executable: executable, timeout: 5)
      let input = try String(contentsOf: dir.appendingPathComponent("input"), encoding: .utf8)
      let lines = input.split(separator: "\n")
      XCTAssertEqual(lines.count, 2)
      var subtypes: [String] = []
      for line in lines {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "control_request")
        let request = try XCTUnwrap(object["request"] as? [String: Any])
        subtypes.append(try XCTUnwrap(request["subtype"] as? String))
        if request["subtype"] as? String == "get_usage" {
          XCTAssertEqual(request["skip_behaviors"] as? Bool, true)
        }
      }
      XCTAssertEqual(subtypes, ["initialize", "get_usage"])
      let args = try String(contentsOf: dir.appendingPathComponent("arguments"), encoding: .utf8)
      XCTAssertEqual(args, ClaudeRenewalProcess.arguments.joined(separator: "\n") + "\n")
      XCTAssertTrue(args.contains("--safe-mode\n"))
      XCTAssertTrue(args.contains("--tools\n\n"))
      XCTAssertTrue(args.contains("--no-session-persistence\n"))
      let cwd = try String(contentsOf: dir.appendingPathComponent("cwd"), encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      XCTAssertFalse(FileManager.default.fileExists(atPath: cwd))
      XCTAssertEqual(ClaudeRenewalProcess.locate(environment: ["PATH": dir.path]), executable)
    }
  }

  func testTimeoutKillsAnUnresponsiveHelper() throws {
    try fixture({ dir in
      """
      trap '' TERM
      printf '%s' "$$" > '\(dir.path)/pid'
      while :; do :; done
      """
    }) { dir, executable in
      let start = Date()
      XCTAssertThrowsError(try ClaudeRenewalProcess.run(executable: executable, timeout: 2)) {
        XCTAssertEqual($0 as? ClaudeUsageClientError, .renewalTimedOut)
      }
      XCTAssertLessThan(Date().timeIntervalSince(start), 6)
      let pid = try XCTUnwrap(Int32(String(contentsOf: dir.appendingPathComponent("pid"), encoding: .utf8)))
      XCTAssertEqual(kill(pid, 0), -1)
      XCTAssertEqual(errno, ESRCH)
    }
  }

  func testImmediateCLIErrorIsSanitizedAndDoesNotBreakInputPipe() throws {
    try fixture({ _ in "echo 'private credential detail' >&2\nexit 2\n" }) { _, executable in
      XCTAssertThrowsError(try ClaudeRenewalProcess.run(executable: executable, timeout: 5)) {
        XCTAssertEqual($0 as? ClaudeUsageClientError, .renewalFailed)
        XCTAssertFalse($0.localizedDescription.contains("private credential detail"))
      }
    }
  }

  func testExitZeroAfterInitializationIsNotRenewalSuccess() throws {
    try fixture({ _ in
      "echo '{\"type\":\"control_response\",\"response\":{\"request_id\":\"usage-auth-renewal\",\"subtype\":\"success\"}}'\nexit 0\n"
    }) { _, executable in
      XCTAssertThrowsError(try ClaudeRenewalProcess.run(executable: executable, timeout: 5)) {
        XCTAssertEqual($0 as? ClaudeUsageClientError, .renewalProtocolFailed)
      }
    }
  }

  func testUnsupportedUsageProtocolDoesNotExposeRawError() throws {
    try fixture({ _ in
      "echo '{\"type\":\"control_response\",\"response\":{\"request_id\":\"usage-auth-check\",\"subtype\":\"error\",\"error\":\"private detail\"}}'\nexit 0\n"
    }) { _, executable in
      XCTAssertThrowsError(try ClaudeRenewalProcess.run(executable: executable, timeout: 5)) {
        XCTAssertEqual($0 as? ClaudeUsageClientError, .renewalProtocolFailed)
        XCTAssertFalse($0.localizedDescription.contains("private detail"))
      }
    }
  }

  func testLiveRenewalProtocolWhenEnabled() async throws {
    guard ProcessInfo.processInfo.environment["CLAUDE_RENEWAL_LIVE_TEST"] == "1" else {
      throw XCTSkip("Set CLAUDE_RENEWAL_LIVE_TEST=1 to verify the real CLI renewal protocol.")
    }
    // Exercise the actual Swift runner, including its production environment,
    // across separate CLI lifetimes. Never submit a user prompt or model request.
    for _ in 0..<2 {
      try await ClaudeCLICredentialRenewer.shared.renew()
      let snapshot = try await ClaudeUsageClient().fetchRateLimits()
      XCTAssertNotNil(snapshot.claudeFiveHourRemainingPercent)
    }
  }
}
