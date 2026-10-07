import AppKit
import Combine
import Foundation
import ServiceManagement

@MainActor
final class UsageStore: ObservableObject {
  enum RefreshState: Equatable {
    case idle
    case refreshing
    case failed(String)
  }

  @Published private(set) var snapshot: UsageSnapshot?
  @Published private(set) var refreshState: RefreshState = .idle
  @Published private(set) var claudeSnapshot: UsageSnapshot?
  @Published private(set) var claudeRefreshState: RefreshState = .idle
  @Published private(set) var claudeNextRetryAt: Date?
  @Published private(set) var codexExecutableURL: URL?
  @Published private(set) var launchAtLoginEnabled = false
  @Published private(set) var launchAtLoginError: String?

  private static let cacheKey = "cachedUsageSnapshot"
  private static let claudeCacheKey = "cachedClaudeUsageSnapshot"
  private static let refreshInterval: TimeInterval = 5 * 60
  private static let staleAfter: TimeInterval = 60

  private let client: any CodexUsageFetching
  private let claudeClient: any ClaudeUsageFetching
  private let locator: CodexLocator
  private let defaults: UserDefaults
  private let now: () -> Date
  private var claudeFailures = 0
  private var codexLoadedThisSession = false
  private var claudeLoadedThisSession = false
  private var refreshTimer: Timer?
  private var wakeObserver: NSObjectProtocol?

  init(
    client: any CodexUsageFetching = AppServerClient(),
    claudeClient: any ClaudeUsageFetching = ClaudeUsageClient.shared,
    locator: CodexLocator = CodexLocator(),
    defaults: UserDefaults = .standard,
    startAutomatically: Bool = true,
    now: @escaping () -> Date = Date.init
  ) {
    self.client = client
    self.claudeClient = claudeClient
    self.locator = locator
    self.defaults = defaults
    self.now = now
    self.snapshot = Self.loadCachedSnapshot(key: Self.cacheKey, defaults: defaults)
    self.claudeSnapshot = Self.loadCachedSnapshot(key: Self.claudeCacheKey, defaults: defaults)
    self.codexExecutableURL = locator.locate()
    self.launchAtLoginEnabled = SMAppService.mainApp.status == .enabled

    if startAutomatically {
      scheduleRefreshTimer()
      observeWakeFromSleep()

      Task { [weak self] in
        await self?.refresh()
      }
    }
  }

  deinit {
    refreshTimer?.invalidate()
    if let wakeObserver {
      NotificationCenter.default.removeObserver(wakeObserver)
    }
  }

  var isRefreshing: Bool {
    isCodexRefreshing || isClaudeRefreshing
  }

  var isCodexRefreshing: Bool { refreshState == .refreshing }
  var isClaudeRefreshing: Bool { claudeRefreshState == .refreshing }

  var canRefreshClaude: Bool {
    !isClaudeRefreshing && (claudeNextRetryAt.map { $0 <= now() } ?? true)
  }

  var errorMessage: String? {
    guard case .failed(let message) = refreshState else { return nil }
    return message
  }

  var claudeErrorMessage: String? {
    guard case .failed(let message) = claudeRefreshState else { return nil }
    return message
  }

  var codexShowsLastKnownData: Bool {
    snapshot != nil && (!codexLoadedThisSession || errorMessage != nil || isOld(snapshot))
  }

  var claudeShowsLastKnownData: Bool {
    claudeSnapshot != nil
      && (!claudeLoadedThisSession || claudeErrorMessage != nil || isOld(claudeSnapshot))
  }

  var menuBarText: String {
    "\(codexMenuBarText) | \(claudeMenuBarText)"
  }

  var codexMenuBarText: String {
    menuValue(snapshot?.weeklyRemainingPercent, refreshing: isCodexRefreshing)
  }

  var claudeMenuBarText: String {
    menuValue(claudeSnapshot?.claudeFiveHourRemainingPercent, refreshing: isClaudeRefreshing)
  }

  var menuBarHelp: String {
    let codexNote = codexShowsLastKnownData ? " (last known)" : ""
    let claudeNote = claudeShowsLastKnownData ? " (last known)" : ""
    var lines = [
      "Codex weekly remaining: \(codexMenuBarText)\(codexNote)",
      "Claude 5-hour remaining: \(claudeMenuBarText)\(claudeNote)",
    ]
    if let errorMessage { lines.append("Codex: \(errorMessage)") }
    if let claudeErrorMessage { lines.append("Claude: \(claudeErrorMessage)") }
    return lines.joined(separator: "\n")
  }

  var menuBarSymbol: String {
    if errorMessage != nil || claudeErrorMessage != nil
      || codexShowsLastKnownData || claudeShowsLastKnownData
    {
      return "exclamationmark.triangle"
    }
    let percentages = [snapshot?.weeklyRemainingPercent, claudeSnapshot?.claudeFiveHourRemainingPercent]
      .compactMap { $0 }
    guard let percent = percentages.min() else {
      return "gauge.with.dots.needle.50percent"
    }
    switch percent {
    case 50...:
      return "gauge.with.dots.needle.67percent"
    case 20..<50:
      return "gauge.with.dots.needle.50percent"
    default:
      return "gauge.with.dots.needle.33percent"
    }
  }

  func refreshIfStale() async {
    async let codex: Void = refreshCodexIfStale()
    async let claude: Void = refreshClaudeIfStale()
    _ = await (codex, claude)
  }

  func refresh() async {
    async let codex: Void = refreshCodex()
    async let claude: Void = refreshClaude()
    _ = await (codex, claude)
  }

  func refreshCodex() async {
    guard !isCodexRefreshing else { return }
    refreshState = .refreshing

    let executable = locator.locate()
    codexExecutableURL = executable
    guard let executable else {
      refreshState = .failed(
        "Codex CLI was not found. Install it or choose its executable below."
      )
      return
    }

    do {
      let newSnapshot = try await client.fetchRateLimits(executableURL: executable)
      snapshot = newSnapshot
      codexLoadedThisSession = true
      Self.cache(newSnapshot, key: Self.cacheKey, defaults: defaults)
      refreshState = .idle
    } catch {
      refreshState = .failed(error.localizedDescription)
    }
  }

  func refreshClaude() async {
    guard canRefreshClaude else { return }
    claudeRefreshState = .refreshing
    do {
      let newSnapshot = try await claudeClient.fetchRateLimits()
      claudeSnapshot = newSnapshot
      claudeLoadedThisSession = true
      Self.cache(newSnapshot, key: Self.claudeCacheKey, defaults: defaults)
      claudeNextRetryAt = nil
      claudeFailures = 0
      claudeRefreshState = .idle
    } catch {
      // The CLI does not expose HTTP status/Retry-After when usage is unavailable.
      // Back off on every failure, including missing usage and login problems.
      claudeFailures += 1
      let backoff = min(3_600, Self.refreshInterval * pow(2, Double(min(claudeFailures - 1, 4))))
      claudeNextRetryAt = now().addingTimeInterval(backoff)
      claudeRefreshState = .failed(error.localizedDescription)
    }
  }

  private func refreshCodexIfStale() async {
    if needsRefresh(snapshot) { await refreshCodex() }
  }

  private func refreshClaudeIfStale() async {
    if needsRefresh(claudeSnapshot) { await refreshClaude() }
  }

  private func needsRefresh(_ value: UsageSnapshot?) -> Bool {
    value.map { now().timeIntervalSince($0.fetchedAt) >= Self.staleAfter } ?? true
  }

  private func isOld(_ value: UsageSnapshot?) -> Bool {
    value.map { now().timeIntervalSince($0.fetchedAt) >= 2 * Self.refreshInterval } ?? false
  }

  private func menuValue(_ percent: Double?, refreshing: Bool) -> String {
    guard let percent else { return refreshing ? "…" : "--" }
    return "\(Int(percent.rounded()))%"
  }

  func chooseCodexExecutable() {
    let panel = NSOpenPanel()
    panel.title = "Choose the Codex CLI executable"
    panel.message = "Select the `codex` executable installed on this Mac."
    panel.prompt = "Choose"
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.resolvesAliases = true

    guard panel.runModal() == .OK, let url = panel.url else { return }
    guard FileManager.default.isExecutableFile(atPath: url.path) else {
      refreshState = .failed("The selected file is not executable.")
      return
    }

    locator.saveUserSelectedPath(url.path)
    codexExecutableURL = url
    Task { [weak self] in
      await self?.refreshCodex()
    }
  }

  func setLaunchAtLogin(_ enabled: Bool) {
    launchAtLoginError = nil
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
      launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    } catch {
      launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
      launchAtLoginError = error.localizedDescription
    }
  }

  private func scheduleRefreshTimer() {
    let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in
        await self?.refresh()
      }
    }
    timer.tolerance = 20
    RunLoop.main.add(timer, forMode: .common)
    refreshTimer = timer
  }

  private func observeWakeFromSleep() {
    wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        await self?.refresh()
      }
    }
  }

  private static func cache(_ snapshot: UsageSnapshot, key: String, defaults: UserDefaults) {
    guard let data = try? JSONEncoder().encode(snapshot) else { return }
    defaults.set(data, forKey: key)
  }

  private static func loadCachedSnapshot(key: String, defaults: UserDefaults) -> UsageSnapshot? {
    guard let data = defaults.data(forKey: key) else { return nil }
    return try? JSONDecoder().decode(UsageSnapshot.self, from: data)
  }
}
