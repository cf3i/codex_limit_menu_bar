import AppKit
import SwiftUI

struct StatusPanelView: View {
  @EnvironmentObject private var store: UsageStore

  var body: some View {
    TimelineView(.periodic(from: .now, by: 30)) { _ in
      VStack(alignment: .leading, spacing: 14) {
        header
        Divider()
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            UsageProviderSection(
              name: "Codex", snapshot: store.snapshot,
              isRefreshing: store.isCodexRefreshing,
              showsLastKnownData: store.codexShowsLastKnownData,
              errorMessage: store.errorMessage,
              dashboardURL: URL(string: "https://chatgpt.com/codex/settings/usage")!,
              canRefresh: !store.isCodexRefreshing,
              onRefresh: { Task { await store.refreshCodex() } },
              chooseExecutable: store.codexExecutableURL == nil
                ? { store.chooseCodexExecutable() } : nil
            )
            Divider()
            UsageProviderSection(
              name: "Claude", snapshot: store.claudeSnapshot,
              isRefreshing: store.isClaudeRefreshing,
              showsLastKnownData: store.claudeShowsLastKnownData,
              errorMessage: store.claudeErrorMessage,
              nextRetryAt: store.claudeNextRetryAt,
              dashboardURL: URL(string: "https://claude.ai/settings/usage")!,
              canRefresh: store.canRefreshClaude,
              onRefresh: {
                Task { await store.refreshClaude(allowKeychainInteraction: true) }
              }
            )
          }
          .padding(.trailing, 2)
        }
        // MenuBarExtra can propose the panel's minimum size. A maximum alone
        // lets ScrollView collapse to zero; give the viewport a definite height.
        .frame(height: 400)
        Divider()
        controls
      }
      .padding(16)
      .frame(width: 370)
    }
    .task { await store.refreshIfStale() }
  }

  private var header: some View {
    HStack(spacing: 10) {
      Image(systemName: "gauge.with.dots.needle.67percent")
        .font(.system(size: 24, weight: .semibold))
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(.tint)
      VStack(alignment: .leading, spacing: 2) {
        Text("Codex & Claude").font(.headline)
        Text("Codex weekly · Claude 5h remaining")
          .font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      Button {
        Task { await store.refresh(allowClaudeKeychainInteraction: true) }
      } label: {
        if store.isRefreshing {
          ProgressView().controlSize(.small)
        } else {
          Image(systemName: "arrow.clockwise")
        }
      }
      .buttonStyle(.borderless)
      .help("Refresh both accounts")
      .disabled(store.isRefreshing)
    }
  }

  private var controls: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Toggle(
          "Launch at Login",
          isOn: Binding(
            get: { store.launchAtLoginEnabled },
            set: { store.setLaunchAtLogin($0) }
          )
        )
        .toggleStyle(.switch)
        Spacer()
        Button("Quit") { NSApplication.shared.terminate(nil) }
          .keyboardShortcut("q")
      }
      .controlSize(.small)
      if let error = store.launchAtLoginError {
        Text(error).font(.caption2).foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

private struct UsageProviderSection: View {
  let name: String
  let snapshot: UsageSnapshot?
  let isRefreshing: Bool
  let showsLastKnownData: Bool
  let errorMessage: String?
  var nextRetryAt: Date? = nil
  let dashboardURL: URL
  let canRefresh: Bool
  let onRefresh: () -> Void
  var chooseExecutable: (() -> Void)? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 3) {
          Text(name).font(.headline)
          Text(subtitle).font(.caption2)
            .foregroundStyle(showsLastKnownData ? Color.orange : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer()
        Button("Usage") { NSWorkspace.shared.open(dashboardURL) }
          .buttonStyle(.borderless).font(.caption)
          .help("Open \(name) usage dashboard")
        Button(action: onRefresh) {
          if isRefreshing {
            ProgressView().controlSize(.mini)
          } else {
            Image(systemName: "arrow.clockwise")
          }
        }
        .buttonStyle(.borderless)
        .help("Refresh \(name)")
        .disabled(!canRefresh)
      }

      if let snapshot, !snapshot.windows.isEmpty {
        ForEach(snapshot.windows) { item in
          LimitWindowView(item: item, providerName: name)
        }
        if let resets = snapshot.resetCreditsAvailable {
          Label(
            "\(resets) earned reset\(resets == 1 ? "" : "s") available",
            systemImage: "arrow.counterclockwise.circle"
          )
          .font(.caption).foregroundStyle(.secondary)
        }
      } else if isRefreshing {
        HStack(spacing: 10) {
          ProgressView().controlSize(.small)
          Text("Loading \(name) usage…").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
      } else {
        Text("No usage data. Sign in to \(name) CLI, then refresh.")
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      if let errorMessage {
        VStack(alignment: .leading, spacing: 8) {
          Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
            .font(.caption).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
          if let nextRetryAt, nextRetryAt > Date() {
            Text("Retry after \(nextRetryAt.formatted(date: .omitted, time: .shortened))")
              .font(.caption2).foregroundStyle(.secondary)
          }
          if let chooseExecutable {
            Button("Choose Codex CLI…", action: chooseExecutable).controlSize(.small)
          }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
      }
    }
  }

  private var subtitle: String {
    guard let snapshot else {
      return isRefreshing ? "Refreshing…" : "Waiting for usage data"
    }
    let relative = RelativeDateTimeFormatter()
    relative.unitsStyle = .abbreviated
    let updated = Date().timeIntervalSince(snapshot.fetchedAt) < 60
      ? "just now" : relative.localizedString(for: snapshot.fetchedAt, relativeTo: Date())
    let prefix = showsLastKnownData ? "Last known · Checked" : "Updated"
    let plan = snapshot.planType.map { "\($0.capitalized) · " } ?? ""
    return "\(plan)\(prefix) \(updated)"
  }
}

private struct LimitWindowView: View {
  let item: PresentedLimitWindow
  let providerName: String

  private var remaining: Double { item.window.remainingPercent }

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 1) {
          Text(item.title).font(.subheadline.weight(.medium))
          if item.bucketName != providerName {
            Text(item.bucketName).font(.caption2).foregroundStyle(.secondary)
          }
        }
        Spacer()
        Text("\(Int(remaining.rounded()))% left")
          .font(.system(.title3, design: .rounded, weight: .semibold))
          .foregroundStyle(statusColor)
      }
      ProgressView(value: remaining, total: 100).tint(statusColor)
      HStack {
        Text("\(Int(item.window.usedPercent.rounded()))% used")
        Spacer()
        if let resetDate = item.window.resetDate {
          Text(resetText(for: resetDate)).help(absoluteResetText(for: resetDate))
        }
      }
      .font(.caption2).foregroundStyle(.secondary)
    }
  }

  private var statusColor: Color {
    switch remaining {
    case 50...: return .green
    case 20..<50: return .orange
    default: return .red
    }
  }

  private func resetText(for date: Date) -> String {
    if date <= Date() { return "Reset pending" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return "Resets \(formatter.localizedString(for: date, relativeTo: Date()))"
  }

  private func absoluteResetText(for date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return "Resets \(formatter.string(from: date))"
  }
}
