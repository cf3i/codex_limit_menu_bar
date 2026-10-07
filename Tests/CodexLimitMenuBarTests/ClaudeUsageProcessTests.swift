import Darwin
import Foundation
import XCTest
@testable import CodexLimitMenuBar

final class ClaudeUsageProcessTests: XCTestCase {
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
      echo '{"type":"control_response","response":{"request_id":"usage-initialize","subtype":"success"}}'
      IFS= read -r usage
      printf '%s\\n' "$usage" >> '\(dir.path)/input'
      sleep 0.2
      echo '{"type":"control_response","response":{"request_id":"usage-read","subtype":"success","response":{"rate_limits":{"five_hour":{"utilization":12},"seven_day":{"utilization":34}}}}}'
      cat > /dev/null
      printf '%s\\n' "$@" > '\(dir.path)/arguments'
      pwd > '\(dir.path)/cwd'
      head -c 131072 /dev/zero >&2
      """
    }) { dir, executable in
      let snapshot = try ClaudeUsageProcess.run(executable: executable, timeout: 5)
      XCTAssertEqual(snapshot.claudeFiveHourRemainingPercent, 88)
      XCTAssertEqual(snapshot.claudeWeeklyRemainingPercent, 66)
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
      XCTAssertEqual(args, ClaudeUsageProcess.arguments.joined(separator: "\n") + "\n")
      XCTAssertTrue(args.contains("--safe-mode\n"))
      XCTAssertTrue(args.contains("--tools\n\n"))
      XCTAssertTrue(args.contains("--no-session-persistence\n"))
      let cwd = try String(contentsOf: dir.appendingPathComponent("cwd"), encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      XCTAssertFalse(FileManager.default.fileExists(atPath: cwd))
      XCTAssertEqual(ClaudeUsageProcess.locate(environment: ["PATH": dir.path]), executable)
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
      XCTAssertThrowsError(try ClaudeUsageProcess.run(executable: executable, timeout: 2)) {
        XCTAssertEqual($0 as? ClaudeUsageClientError, .cliTimedOut)
      }
      XCTAssertLessThan(Date().timeIntervalSince(start), 6)
      let pid = try XCTUnwrap(Int32(String(contentsOf: dir.appendingPathComponent("pid"), encoding: .utf8)))
      XCTAssertEqual(kill(pid, 0), -1)
      XCTAssertEqual(errno, ESRCH)
    }
  }

  func testImmediateCLIErrorIsSanitizedAndDoesNotBreakInputPipe() throws {
    try fixture({ _ in "echo 'private credential detail' >&2\nexit 2\n" }) { _, executable in
      XCTAssertThrowsError(try ClaudeUsageProcess.run(executable: executable, timeout: 5)) {
        XCTAssertEqual($0 as? ClaudeUsageClientError, .cliFailed)
        XCTAssertFalse($0.localizedDescription.contains("private credential detail"))
      }
    }
  }

  func testExitZeroAfterInitializationIsNotUsageSuccess() throws {
    try fixture({ _ in
      "echo '{\"type\":\"control_response\",\"response\":{\"request_id\":\"usage-initialize\",\"subtype\":\"success\"}}'\nexit 0\n"
    }) { _, executable in
      XCTAssertThrowsError(try ClaudeUsageProcess.run(executable: executable, timeout: 5)) {
        XCTAssertEqual($0 as? ClaudeUsageClientError, .cliProtocolFailed)
      }
    }
  }

  func testUnsupportedUsageProtocolDoesNotExposeRawError() throws {
    try fixture({ _ in
      "echo '{\"type\":\"control_response\",\"response\":{\"request_id\":\"usage-read\",\"subtype\":\"error\",\"error\":\"private detail\"}}'\nexit 0\n"
    }) { _, executable in
      XCTAssertThrowsError(try ClaudeUsageProcess.run(executable: executable, timeout: 5)) {
        XCTAssertEqual($0 as? ClaudeUsageClientError, .cliProtocolFailed)
        XCTAssertFalse($0.localizedDescription.contains("private detail"))
      }
    }
  }

  func testMissingUsageDoesNotPretendInitializationSucceeded() throws {
    for (payload, expected) in [
      (#"{"rate_limits_available":true,"rate_limits":null}"#, ClaudeUsageClientError.usageUnavailable),
      (#"{"rate_limits_available":false,"rate_limits":null}"#, .noRateLimits),
      (#"{"rate_limits":{}}"#, .noRateLimits),
      (#"{"rate_limits":{"five_hour":{"utilization":"bad"}}}"#, .invalidResponse),
    ] {
      try fixture({ _ in
        "echo '{\"type\":\"control_response\",\"response\":{\"request_id\":\"usage-read\",\"subtype\":\"success\",\"response\":\(payload)}}'\nexit 0\n"
      }) { _, executable in
        XCTAssertThrowsError(try ClaudeUsageProcess.run(executable: executable, timeout: 5)) {
          XCTAssertEqual($0 as? ClaudeUsageClientError, expected)
        }
      }
    }
  }

  func testUsageSuccessStillDrainsOutputAndRequiresCleanExit() throws {
    for exitCode in [0, 2] {
      try fixture({ _ in
        """
        echo '{"type":"control_response","response":{"request_id":"unrelated","subtype":"error","error":"private detail"}}'
        echo '{"type":"control_response","response":{"request_id":"usage-read","subtype":"success","response":{"rate_limits":{"five_hour":{"utilization":12}}}}}'
        cat > /dev/null
        i=0
        while [ "$i" -lt 5000 ]; do echo '{"type":"ignored","detail":"private output"}'; i=$((i + 1)); done
        exit \(exitCode)
        """
      }) { _, executable in
        if exitCode == 0 {
          let result = try ClaudeUsageProcess.run(executable: executable, timeout: 5)
          XCTAssertEqual(result.claudeFiveHourRemainingPercent, 88)
        } else {
          XCTAssertThrowsError(try ClaudeUsageProcess.run(executable: executable, timeout: 5)) {
            XCTAssertEqual($0 as? ClaudeUsageClientError, .cliFailed)
          }
        }
      }
    }
  }

  func testEnvironmentUsesSameLoginWithoutProviderOverrides() {
    let env = ClaudeUsageProcess.environment(executable: URL(fileURLWithPath: "/test/claude"),
      inherited: ["CLAUDE_CONFIG_DIR": "/custom/claude", "HTTPS_PROXY": "http://localhost:1234",
        "ANTHROPIC_API_KEY": "fixture", "CLAUDE_CODE_OAUTH_TOKEN": "fixture",
        "ANTHROPIC_BASE_URL": "https://example.com", "CLAUDE_CODE_SIMPLE": "1",
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"])
    XCTAssertEqual(env["CLAUDE_CONFIG_DIR"], "/custom/claude")
    XCTAssertEqual(env["HTTPS_PROXY"], "http://localhost:1234")
    for key in ["ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_BASE_URL",
      "CLAUDE_CODE_SIMPLE", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] {
      XCTAssertNil(env[key])
    }
    XCTAssertEqual(env["DISABLE_TELEMETRY"], "1")
    XCTAssertEqual(env["DISABLE_ERROR_REPORTING"], "1")
  }
}
