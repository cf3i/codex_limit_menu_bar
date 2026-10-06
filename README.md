# Codex & Claude Limit Menu Bar

A lightweight native macOS menu bar app that shows how much of your Codex and Claude subscription limits remain.

The menu bar displays **Codex weekly remaining first, Claude five-hour remaining second**: `91% | 94%`. Open the panel for Codex's weekly limit and Claude's five-hour and weekly limits, reset times, update time, and usage dashboard. Codex's panel follows the windows actually returned by its account endpoint.

Codex uses the official App Server `account/rateLimits/read` endpoint. Claude uses the same internal `/api/oauth/usage` endpoint as Claude Code, with its existing subscription login. This Claude endpoint is not a documented public API and may change. Claude's access token is read into memory for the request and is never persisted or logged by this app.

## Features

- Codex weekly and Claude five-hour remaining percentages directly in the macOS menu bar
- Codex weekly usage and Claude five-hour/weekly usage, plus additional windows when returned
- Reset countdowns and exact reset-time tooltips
- Automatic refresh every five minutes, on wake, and when stale data is opened
- Automatic Claude access-token renewal through the installed Claude Code CLI
- Independent refresh buttons and usage dashboards for both accounts
- Separate caches and error states; one account's failure does not block the other
- Last-known readings are visibly marked, with the last successful update time
- Claude rate-limit responses trigger a cooldown and exponential backoff
- Optional launch at login
- Automatic Codex CLI discovery plus a manual executable picker

## Requirements

- macOS 13 or newer
- Swift 6.1 / Xcode 16 or newer to build
- A recent Codex CLI installation signed in with ChatGPT for Codex limits
- A recent Claude Code signed in with a Claude subscription for Claude limits (automatic renewal requires `--safe-mode` and the streaming `get_usage` protocol; verified with 2.1.289)

Either account can be used independently; an unavailable account shows `--` in its position.

Sign in to the accounts you want to display:

```bash
codex --version
codex login
claude auth login
```

## Download and install

Download the DMG and its SHA-256 checksum from [GitHub Releases](https://github.com/cf3i/codex_limit_menu_bar/releases/latest). Version 0.2.2 is built for Apple Silicon (`arm64`) and requires macOS 13 or newer.

Open the DMG, drag **Codex Limit.app** to **Applications**, then launch the app. The release is ad-hoc signed and has not been notarized; macOS may require approval before the first launch.

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

Create a compressed DMG and SHA-256 checksum for the build machine's architecture:

```bash
make dmg
```

Outputs are written to `dist/`. Generated bundles are ad-hoc signed. Developer ID signing and notarization are needed for a release trusted by Gatekeeper without first-launch approval.

## Development

```bash
swift build
swift test
```

Optional live checks against your signed-in accounts (credentials are not printed):

```bash
CODEX_LIMIT_LIVE_TEST=1 CLAUDE_LIMIT_LIVE_TEST=1 CLAUDE_RENEWAL_LIVE_TEST=1 swift test --filter testLive
```

Render app-only layout previews with sample data (no desktop capture):

```bash
CODEX_LIMIT_PREVIEW_DIR=/tmp swift test --filter testPanelIntrinsicSize
```

The project is a dependency-free Swift Package. The release script builds the executable, creates a standard `.app` bundle, marks it as a menu-bar-only app, and applies an ad-hoc signature.

## How it works

1. The app locates the local `codex` executable.
2. It starts `codex app-server` over its default JSONL standard-I/O transport.
3. It performs the required `initialize` / `initialized` handshake.
4. It requests `account/rateLimits/read` and converts `usedPercent` into the percentage remaining.
5. It closes the child process after each refresh. No background server or credential copy is retained.

Claude's usage request reads the `Claude Code-credentials` entry from macOS Keychain, or Claude Code's existing `.credentials.json` fallback. `CLAUDE_CONFIG_DIR` is respected, including its separate Keychain entry. Credentials are reread on every refresh so a new Claude Code login is picked up automatically.

When an access token expires or has less than a minute remaining, the app starts Claude Code, sends streaming `initialize` and `get_usage` control requests, waits for the usage response, and then rereads the saved credential. `skip_behaviors` disables transcript scanning; no user prompt or model request is sent. Initialization or a zero exit code alone is never treated as successful renewal. It runs in an empty temporary directory with customizations, tools, MCP servers, and session persistence disabled. Claude Code manages its own renewal locks and credential storage; this app never reads refresh-token values or writes login credentials. Concurrent renewal requests share one helper, which has a 60-second timeout. Telemetry and error reporting are disabled individually; the broad `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` flag is deliberately omitted because it blocks the usage request before OAuth renewal.

If Claude rejects a usage request, the app first checks whether another Claude Code process rotated the credential. It makes at most one recovery attempt and one usage retry. Renewal failures keep the last known reading and pause retries for five minutes. An access-token expiry alone does not mean you need to log in again.

Claude's second menu bar value uses the aggregate `five_hour` window. If that window is absent, it shows `--`; a weekly or model-specific limit is never substituted. Claude's weekly limit remains available in the expanded panel. Remaining percentages are `100 - utilization`, clamped to 0–100. Both accounts refresh independently every five minutes, on wake, and when the panel opens with stale data. Claude's cooldown also applies to manual refresh.

## Privacy

- No analytics
- No third-party dependencies
- No browser cookies
- No authentication tokens saved in app settings, files, or logs
- Codex account requests go through the locally installed Codex CLI
- Claude's access token is sent only to `https://api.anthropic.com/api/oauth/usage`; redirects are rejected, and cookies and HTTP caching are disabled
- Renewal is delegated to the installed Claude Code CLI and its own authentication endpoints; helper output is discarded and no conversation is submitted
- Cached snapshots contain only quota values, reset times, plan names, and their fetch time

## Troubleshooting

If the app cannot find Codex CLI, click **Choose Codex CLI…** in the error panel and select the `codex` executable. Common locations include:

- `~/.npm-global/bin/codex`
- `~/.local/bin/codex`
- `/opt/homebrew/bin/codex`
- `/usr/local/bin/codex`

If usage cannot be loaded, run `codex` in Terminal and use `/status` to confirm the same account is signed in.

For Claude, access-token renewal is automatic. If renewal fails or times out, open Claude Code and check `/usage`, then refresh this app after its retry cooldown. Sign in again only if Claude Code asks you to. If the CLI is missing or too old, install/update it. If Keychain access is unavailable, click Claude's Refresh button to allow the macOS access prompt. Background credential reads do not open access prompts. Rate-limit and renewal errors display the next allowed retry time and retain the last successful reading.

## References

- [Codex App Server](https://learn.chatgpt.com/docs/app-server)
- [Codex pricing and usage limits](https://learn.chatgpt.com/docs/pricing)
- [Claude Code authentication](https://code.claude.com/docs/en/authentication)
- [Claude Code usage](https://code.claude.com/docs/en/costs)

## License

MIT
