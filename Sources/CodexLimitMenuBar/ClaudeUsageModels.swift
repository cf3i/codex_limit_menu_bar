import Foundation

struct ClaudeRateLimitWindow: Decodable, Equatable, Sendable {
  let utilization: Double
  let resetsAt: Date?

  private enum CodingKeys: String, CodingKey {
    case utilization
    case resetsAt = "resets_at"
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    utilization = try values.decode(Double.self, forKey: .utilization)
    guard utilization.isFinite else {
      throw ClaudeUsageClientError.invalidResponse
    }
    if let text = try values.decodeIfPresent(String.self, forKey: .resetsAt) {
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      if let date = formatter.date(from: text) {
        resetsAt = date
      } else {
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: text) else {
          throw ClaudeUsageClientError.invalidResponse
        }
        resetsAt = date
      }
    } else {
      resetsAt = nil
    }
  }

  func limitWindow(duration: Int) -> CodexRateLimitWindow {
    CodexRateLimitWindow(
      usedPercent: utilization,
      windowDurationMins: duration,
      resetsAt: resetsAt?.timeIntervalSince1970
    )
  }
}

struct ClaudeUsageResponse: Decodable, Sendable {
  let fiveHour: ClaudeRateLimitWindow?
  let sevenDay: ClaudeRateLimitWindow?
  let modelWindows: [String: ClaudeRateLimitWindow]

  private struct Key: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: Key.self)
    fiveHour = try values.decodeIfPresent(
      ClaudeRateLimitWindow.self, forKey: Key(stringValue: "five_hour")
    )
    sevenDay = try values.decodeIfPresent(
      ClaudeRateLimitWindow.self, forKey: Key(stringValue: "seven_day")
    )
    var models: [String: ClaudeRateLimitWindow] = [:]
    for key in values.allKeys where key.stringValue.hasPrefix("seven_day_") {
      // Statistics such as seven_day_breakdown share this prefix but are not
      // limit windows. Only objects carrying utilization belong in the panel.
      guard let fields = try? values.nestedContainer(keyedBy: Key.self, forKey: key),
        fields.contains(Key(stringValue: "utilization"))
      else { continue }
      if let window = try values.decodeIfPresent(ClaudeRateLimitWindow.self, forKey: key) {
        models[key.stringValue] = window
      }
    }
    modelWindows = models
  }

  func snapshot(planType: String? = nil, fetchedAt: Date = Date()) throws -> UsageSnapshot {
    var buckets: [CodexRateLimitBucket] = []
    if fiveHour != nil || sevenDay != nil {
      buckets.append(CodexRateLimitBucket(
        limitId: "claude", limitName: "Claude",
        primary: fiveHour?.limitWindow(duration: 300),
        secondary: sevenDay?.limitWindow(duration: 10_080),
        planType: planType
      ))
    }
    for (key, window) in modelWindows.sorted(by: { $0.key < $1.key }) {
      let name = key.replacingOccurrences(of: "seven_day_", with: "")
        .replacingOccurrences(of: "_", with: " ").capitalized
      buckets.append(CodexRateLimitBucket(
        limitId: "claude-\(key)", limitName: "Claude \(name)",
        secondary: window.limitWindow(duration: 10_080), planType: planType
      ))
    }
    guard !buckets.isEmpty else { throw ClaudeUsageClientError.noRateLimits }
    return UsageSnapshot(fetchedAt: fetchedAt, buckets: buckets)
  }
}

extension UsageSnapshot {
  // Select aggregate windows explicitly, without substituting another window.
  var claudeFiveHourRemainingPercent: Double? {
    guard let window = buckets.first(where: { $0.limitId == "claude" })?.primary,
      window.windowDurationMins == 300
    else { return nil }
    return window.remainingPercent
  }

  var claudeWeeklyRemainingPercent: Double? {
    buckets.first(where: { $0.limitId == "claude" })?.secondary?.remainingPercent
  }
}
