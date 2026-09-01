# Codex Limit Menu Bar

A lightweight native macOS menu bar app that shows how much of your Codex usage limits remain.

The app reads the official Codex App Server `account/rateLimits/read` endpoint. It does not scrape the ChatGPT website and it does not copy or store your authentication token.

## Features

- Main Codex weekly remaining percentage directly in the macOS menu bar
- All rate-limit windows returned by Codex, including five-hour and weekly windows
- Reset countdowns and exact reset-time tooltips
- Automatic refresh every five minutes, on wake, and when stale data is opened
- Manual refresh and a shortcut to the official usage dashboard
- Last successful result is cached for offline/error states
- Optional launch at login
- Automatic Codex CLI discovery plus a manual executable picker

## Requirements

- macOS 13 or newer
- Swift 6.1 / Xcode 16 or newer to build
- A recent Codex CLI installation signed in with ChatGPT

Confirm that Codex is installed and authenticated:

```bash
codex --version
codex login
```

## Build and run

Create a release app bundle:

```bash
make app
open "dist/Codex Limit.app"
```

For launch-at-login support, move the app to `/Applications` first:

```bash
cp -R "dist/Codex Limit.app" /Applications/
```

The generated bundle is ad-hoc signed for local use. Public distribution requires signing with an Apple Developer ID and notarization.

## Development

```bash
swift build
swift test
```

The project is a dependency-free Swift Package. The release script builds the executable, creates a standard `.app` bundle, marks it as a menu-bar-only app, and applies an ad-hoc signature.

## How it works

1. The app locates the local `codex` executable.
2. It starts `codex app-server` over its default JSONL standard-I/O transport.
3. It performs the required `initialize` / `initialized` handshake.
4. It requests `account/rateLimits/read` and converts `usedPercent` into the percentage remaining.
5. It closes the child process after each refresh. No background server or credential copy is retained.

The menu bar shows the remaining percentage for the main Codex weekly window. Open the panel to inspect every available window, including model-specific limits.

## Privacy

- No analytics
- No third-party dependencies
- No browser cookies
- No copied authentication tokens
- No account data is sent anywhere except through the locally installed Codex CLI

## Troubleshooting

If the app cannot find Codex CLI, click **Choose Codex CLI…** in the error panel and select the `codex` executable. Common locations include:

- `~/.npm-global/bin/codex`
- `~/.local/bin/codex`
- `/opt/homebrew/bin/codex`
- `/usr/local/bin/codex`

If usage cannot be loaded, run `codex` in Terminal and use `/status` to confirm the same account is signed in.

## References

- [Codex App Server](https://learn.chatgpt.com/docs/app-server)
- [Codex pricing and usage limits](https://learn.chatgpt.com/docs/pricing)

## License

MIT
