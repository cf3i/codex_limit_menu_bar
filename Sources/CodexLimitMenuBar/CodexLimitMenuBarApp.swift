import AppKit
import SwiftUI

@main
struct CodexLimitMenuBarApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var store = UsageStore()

  var body: some Scene {
    MenuBarExtra {
      StatusPanelView()
        .environmentObject(store)
    } label: {
      HStack(spacing: 3) {
        Image(systemName: store.menuBarSymbol)
        Text(store.menuBarText)
          .monospacedDigit()
      }
      .accessibilityLabel("Codex weekly limit: \(store.menuBarText) remaining")
    }
    .menuBarExtraStyle(.window)
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApplication.shared.setActivationPolicy(.accessory)
  }
}
