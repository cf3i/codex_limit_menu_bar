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
  @Published private(set) var codexExecutableURL: URL?
  @Published private(set) var launchAtLoginEnabled = false
  @Published private(set) var launchAtLoginError: String?

  private static let cacheKey = "cachedUsageSnapshot"
  private static let refreshInterval: TimeInterval = 5 * 60
  private static let staleAfter: TimeInterval = 60

  private let client: AppServerClient
  private let locator: CodexLocator
  private var refreshTimer: Timer?
  private var wakeObserver: NSObjectProtocol?

  init(client: AppServerClient = AppServerClient(), locator: CodexLocator = CodexLocator()) {
    self.client = client
    self.locator = locator
    self.snapshot = Self.loadCachedSnapshot()
    self.codexExecutableURL = locator.locate()
    self.launchAtLoginEnabled = SMAppService.mainApp.status == .enabled

    scheduleRefreshTimer()
    observeWakeFromSleep()

    Task { [weak self] in
      await self?.refresh()
    }
  }

  deinit {
    refreshTimer?.invalidate()
    if let wakeObserver {
      NotificationCenter.default.removeObserver(wakeObserver)
    }
  }

  var isRefreshing: Bool {
    refreshState == .refreshing
  }

  var errorMessage: String? {
    guard case .failed(let message) = refreshState else { return nil }
    return message
  }

  var menuBarText: String {
    guard let percent = snapshot?.weeklyRemainingPercent else {
      return isRefreshing ? "…" : "--"
    }
    return "\(Int(percent.rounded()))%"
  }

  var menuBarSymbol: String {
    guard let percent = snapshot?.weeklyRemainingPercent else {
      return errorMessage == nil ? "gauge.with.dots.needle.50percent" : "exclamationmark.triangle"
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
    guard let fetchedAt = snapshot?.fetchedAt else {
      await refresh()
      return
    }
    if Date().timeIntervalSince(fetchedAt) >= Self.staleAfter {
      await refresh()
    }
  }

  func refresh() async {
    guard !isRefreshing else { return }
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
      Self.cache(newSnapshot)
      refreshState = .idle
    } catch {
      refreshState = .failed(error.localizedDescription)
    }
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
      await self?.refresh()
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

  private static func cache(_ snapshot: UsageSnapshot) {
    guard let data = try? JSONEncoder().encode(snapshot) else { return }
    UserDefaults.standard.set(data, forKey: cacheKey)
  }

  private static func loadCachedSnapshot() -> UsageSnapshot? {
    guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return nil }
    return try? JSONDecoder().decode(UsageSnapshot.self, from: data)
  }
}
