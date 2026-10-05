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

  func testHelperSendsOnlyInitializationDisablesToolsAndCleansWorkingDirectory() throws {
    try fixture({ dir in
      """
      cat > '\(dir.path)/input'
      printf '%s\\n' "$@" > '\(dir.path)/arguments'
      pwd > '\(dir.path)/cwd'
      head -c 131072 /dev/zero >&2
      """
    }) { dir, executable in
      try ClaudeRenewalProcess.run(executable: executable, timeout: 5)
      let input = try String(contentsOf: dir.appendingPathComponent("input"), encoding: .utf8)
      XCTAssertEqual(input.split(separator: "\n").count, 1)
      let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
      XCTAssertEqual(object["type"] as? String, "control_request")
      XCTAssertEqual((object["request"] as? [String: String])?["subtype"], "initialize")
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
}
