import AppKit
import SwiftUI

struct StatusPanelView: View {
  @EnvironmentObject private var store: UsageStore

  private let dashboardURL = URL(string: "https://chatgpt.com/codex/settings/usage")!

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      header

      Divider()

      usageContent

      if let error = store.errorMessage {
        errorBanner(error)
      }

      Divider()

      controls
    }
    .padding(16)
    .frame(width: 350)
    .task {
      await store.refreshIfStale()
    }
  }

  private var header: some View {
    HStack(spacing: 10) {
      Image(systemName: "gauge.with.dots.needle.67percent")
        .font(.system(size: 24, weight: .semibold))
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(.tint)

      VStack(alignment: .leading, spacing: 2) {
        Text("Codex Limit")
          .font(.headline)
        Text(headerSubtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer()

      Button {
        Task { await store.refresh() }
      } label: {
        if store.isRefreshing {
          ProgressView()
            .controlSize(.small)
        } else {
          Image(systemName: "arrow.clockwise")
        }
      }
      .buttonStyle(.borderless)
      .help("Refresh now")
      .disabled(store.isRefreshing)
    }
  }

  @ViewBuilder
  private var usageContent: some View {
    if let snapshot = store.snapshot, !snapshot.windows.isEmpty {
      VStack(alignment: .leading, spacing: 13) {
        ForEach(Array(snapshot.windows.enumerated()), id: \.element.id) { index, item in
          if index > 0 {
            Divider()
          }
          LimitWindowView(item: item)
        }

        if let resets = snapshot.resetCreditsAvailable {
          Label(
            "\(resets) earned reset\(resets == 1 ? "" : "s") available",
            systemImage: "arrow.counterclockwise.circle"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }
    } else if store.isRefreshing {
      HStack(spacing: 10) {
        ProgressView()
        Text("Loading Codex usage…")
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .center)
      .padding(.vertical, 20)
    } else {
      VStack(spacing: 8) {
        Image(systemName: "gauge.with.dots.needle.50percent")
          .font(.system(size: 28))
          .foregroundStyle(.secondary)
        Text("No usage data")
          .font(.headline)
        Text("Refresh after signing in to Codex CLI.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 14)
    }
  }

  private func errorBanner(_ message: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(message, systemImage: "exclamationmark.triangle.fill")
        .font(.caption)
        .foregroundStyle(.orange)
        .fixedSize(horizontal: false, vertical: true)

      if store.codexExecutableURL == nil {
        Button("Choose Codex CLI…") {
          store.chooseCodexExecutable()
        }
        .controlSize(.small)
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
  }

  private var controls: some View {
    VStack(alignment: .leading, spacing: 10) {
      Toggle(
        "Launch at Login",
        isOn: Binding(
          get: { store.launchAtLoginEnabled },
          set: { store.setLaunchAtLogin($0) }
        )
      )
      .toggleStyle(.switch)
      .controlSize(.small)

      if let error = store.launchAtLoginError {
        Text(error)
          .font(.caption2)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack {
        Button("Usage Dashboard") {
          NSWorkspace.shared.open(dashboardURL)
        }

        Spacer()

        Button("Quit") {
          NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
      }
      .controlSize(.small)
    }
  }

  private var headerSubtitle: String {
    guard let snapshot = store.snapshot else {
      return store.isRefreshing ? "Refreshing…" : "Waiting for usage data"
    }

    let relative = RelativeDateTimeFormatter()
    relative.unitsStyle = .abbreviated
    let updated = relative.localizedString(for: snapshot.fetchedAt, relativeTo: Date())
    if let plan = snapshot.planType, !plan.isEmpty {
      return "\(plan.capitalized) · Updated \(updated)"
    }
    return "Updated \(updated)"
  }
}

private struct LimitWindowView: View {
  let item: PresentedLimitWindow

  private var remaining: Double {
    item.window.remainingPercent
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 1) {
          Text(item.title)
            .font(.subheadline.weight(.medium))
          if item.bucketName != "Codex" {
            Text(item.bucketName)
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }

        Spacer()

        Text("\(Int(remaining.rounded()))% left")
          .font(.system(.title3, design: .rounded, weight: .semibold))
          .foregroundStyle(statusColor)
      }

      ProgressView(value: remaining, total: 100)
        .tint(statusColor)

      HStack {
        Text("\(Int(item.window.usedPercent.rounded()))% used")
        Spacer()
        if let resetDate = item.window.resetDate {
          Text(resetText(for: resetDate))
            .help(absoluteResetText(for: resetDate))
        }
      }
      .font(.caption2)
      .foregroundStyle(.secondary)
    }
  }

  private var statusColor: Color {
    switch remaining {
    case 50...:
      return .green
    case 20..<50:
      return .orange
    default:
      return .red
    }
  }

  private func resetText(for date: Date) -> String {
    if date <= Date() {
      return "Reset pending"
    }
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
