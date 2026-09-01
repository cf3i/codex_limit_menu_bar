import Foundation

struct CodexRateLimitWindow: Codable, Equatable, Sendable {
  let usedPercent: Double
  let windowDurationMins: Int?
  let resetsAt: Double?

  var remainingPercent: Double {
    min(100, max(0, 100 - usedPercent))
  }

  var resetDate: Date? {
    guard let resetsAt else { return nil }
    return Date(timeIntervalSince1970: resetsAt)
  }
}

struct CodexRateLimitBucket: Codable, Equatable, Sendable {
  let limitId: String
  let limitName: String?
  let primary: CodexRateLimitWindow?
  let secondary: CodexRateLimitWindow?
  let rateLimitReachedType: String?
  let planType: String?

  init(
    limitId: String,
    limitName: String? = nil,
    primary: CodexRateLimitWindow? = nil,
    secondary: CodexRateLimitWindow? = nil,
    rateLimitReachedType: String? = nil,
    planType: String? = nil
  ) {
    self.limitId = limitId
    self.limitName = limitName
    self.primary = primary
    self.secondary = secondary
    self.rateLimitReachedType = rateLimitReachedType
    self.planType = planType
  }
}

struct RateLimitResetCredits: Codable, Equatable, Sendable {
  let availableCount: Int
}

struct RateLimitReadResult: Codable, Equatable, Sendable {
  let rateLimits: CodexRateLimitBucket?
  let rateLimitsByLimitId: [String: CodexRateLimitBucket]?
  let rateLimitResetCredits: RateLimitResetCredits?

  var normalizedBuckets: [CodexRateLimitBucket] {
    if let byId = rateLimitsByLimitId, !byId.isEmpty {
      return byId.values.sorted { lhs, rhs in
        if lhs.limitId == "codex" { return true }
        if rhs.limitId == "codex" { return false }
        return lhs.limitId.localizedCaseInsensitiveCompare(rhs.limitId) == .orderedAscending
      }
    }
    return rateLimits.map { [$0] } ?? []
  }
}

struct UsageSnapshot: Codable, Equatable, Sendable {
  let fetchedAt: Date
  let buckets: [CodexRateLimitBucket]
  let resetCreditsAvailable: Int?

  init(result: RateLimitReadResult, fetchedAt: Date = Date()) {
    self.fetchedAt = fetchedAt
    self.buckets = result.normalizedBuckets
    self.resetCreditsAvailable = result.rateLimitResetCredits?.availableCount
  }

  init(
    fetchedAt: Date,
    buckets: [CodexRateLimitBucket],
    resetCreditsAvailable: Int? = nil
  ) {
    self.fetchedAt = fetchedAt
    self.buckets = buckets
    self.resetCreditsAvailable = resetCreditsAvailable
  }

  var planType: String? {
    buckets.compactMap(\.planType).first
  }

  var windows: [PresentedLimitWindow] {
    buckets.flatMap { bucket in
      var values: [PresentedLimitWindow] = []
      if let primary = bucket.primary {
        values.append(
          PresentedLimitWindow(
            id: "\(bucket.limitId)-primary",
            bucketId: bucket.limitId,
            bucketName: bucket.displayName,
            kind: .primary,
            window: primary
          )
        )
      }
      if let secondary = bucket.secondary {
        values.append(
          PresentedLimitWindow(
            id: "\(bucket.limitId)-secondary",
            bucketId: bucket.limitId,
            bucketName: bucket.displayName,
            kind: .secondary,
            window: secondary
          )
        )
      }
      return values
    }
  }

  var mostConstrainedRemainingPercent: Double? {
    windows.map(\.window.remainingPercent).min()
  }

  var weeklyRemainingPercent: Double? {
    let weeklyDuration = 7 * 24 * 60

    if let codexWeekly = windows.first(where: {
      $0.bucketId == "codex" && $0.window.windowDurationMins == weeklyDuration
    }) {
      return codexWeekly.window.remainingPercent
    }

    return windows.first(where: {
      $0.window.windowDurationMins == weeklyDuration
    })?.window.remainingPercent
  }
}

extension CodexRateLimitBucket {
  var displayName: String {
    let trimmed = limitName?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let trimmed, !trimmed.isEmpty, trimmed != limitId {
      return trimmed
    }
    if limitId == "codex" {
      return "Codex"
    }
    return limitId.replacingOccurrences(of: "_", with: " ").capitalized
  }
}

struct PresentedLimitWindow: Identifiable, Equatable, Sendable {
  enum Kind: String, Equatable, Sendable {
    case primary
    case secondary
  }

  let id: String
  let bucketId: String
  let bucketName: String
  let kind: Kind
  let window: CodexRateLimitWindow

  var title: String {
    guard let minutes = window.windowDurationMins else {
      return kind == .primary ? "Primary limit" : "Secondary limit"
    }

    switch minutes {
    case 300:
      return "5-hour limit"
    case 1_440:
      return "Daily limit"
    case 10_080:
      return "Weekly limit"
    default:
      if minutes.isMultiple(of: 1_440) {
        let days = minutes / 1_440
        return "\(days)-day limit"
      }
      if minutes.isMultiple(of: 60) {
        let hours = minutes / 60
        return "\(hours)-hour limit"
      }
      return "\(minutes)-minute limit"
    }
  }
}
