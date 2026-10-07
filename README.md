# Codex & Claude Limit Menu Bar

A lightweight native macOS menu bar app that shows how much of your Codex and Claude subscription limits remain.

The menu bar displays **Codex weekly remaining first, Claude five-hour remaining second**: `91% | 94%`. Open the panel for Codex's weekly limit and Claude's five-hour and weekly limits, reset times, update time, and usage dashboard. Codex's panel follows the windows actually returned by its account endpoint.

Codex uses the official App Server `account/rateLimits/read` endpoint. Claude usage is requested through the installed Claude Code CLI using its streaming `get_usage` control request. This Claude protocol is internal and may change. Claude Code owns authentication and token renewal; this app never reads Claude login credentials or accesses Keychain directly.

## Features

- Codex weekly and Claude five-hour remaining percentages directly in the macOS menu bar
- Codex weekly usage and Claude five-hour/weekly usage, plus additional windows when returned
- Reset countdowns and exact reset-time tooltips
- Automatic refresh every five minutes, on wake, and when stale data is opened
- Automatic Claude access-token renewal through the installed Claude Code CLI
- Independent refresh buttons and usage dashboards for both accounts
- Separate caches and error states; one account's failure does not block the other
- Last-known readings are visibly marked, with the last successful update time
- Claude failures retain the last reading and trigger a cooldown with exponential backoff
- Optional launch at login
- Automatic Codex CLI discovery plus a manual executable picker

## Requirements

- macOS 13 or newer
- Swift 6.1 / Xcode 16 or newer to build
- A recent Codex CLI installation signed in with ChatGPT for Codex limits
- A recent Claude Code signed in with a Claude subscription for Claude limits (usage reads require `--safe-mode` and the streaming `get_usage` protocol; verified with 2.1.289)

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
CODEX_LIMIT_LIVE_TEST=1 CLAUDE_LIMIT_LIVE_TEST=1 swift test --filter testLive
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

For every Claude refresh, the app locates `claude`, starts it in an empty temporary directory, and sends streaming `initialize` and `get_usage` control requests. It keeps stdin open until a valid usage response arrives, then waits for the process to exit. `skip_behaviors` disables transcript scanning; no user prompt or model request is sent. Customizations, tools, MCP servers, session persistence, telemetry, error reporting, and auto-updating are disabled. The broad `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` flag is deliberately omitted because it blocks usage reads. `CLAUDE_CONFIG_DIR` and network proxy settings are respected.

The app decodes only quota windows from the response. Claude Code handles its own login, Keychain access, credential storage, and renewal. The menu-bar process no longer calls Keychain APIs or reads `.credentials.json`, so rebuilding its ad-hoc signature does not require granting it access to Claude credentials. Existing Keychain permissions are not changed. Ordinary refresh buttons use the same CLI path as automatic refresh.

Concurrent requests share one helper, with a 60-second timeout and forced cleanup of an unresponsive process. Initialization, a zero exit code, or a null `rate_limits` response alone is never treated as successful usage retrieval. The CLI does not expose HTTP errors or `Retry-After` through this response, so any failed read preserves the cache and backs off from five minutes to a maximum of one hour. A successful read resets the backoff.

Claude's second menu bar value uses the aggregate `five_hour` window. If that window is absent, it shows `--`; a weekly or model-specific limit is never substituted. Claude's weekly limit remains available in the expanded panel. Remaining percentages are `100 - utilization`, clamped to 0–100. Both accounts refresh independently every five minutes, on wake, and when the panel opens with stale data. Claude's cooldown also applies to manual refresh.

## Privacy

- No analytics
- No third-party dependencies
- No browser cookies
- No authentication tokens saved in app settings, files, or logs
- Codex account requests go through the locally installed Codex CLI
- Claude requests and renewal go through the locally installed Claude Code CLI; this app receives no authentication tokens and does not read Keychain or credential files
- Only quota fields from helper output are decoded; other output is discarded and no conversation is submitted
- Cached snapshots contain only quota values, reset times, plan names, and their fetch time

## Troubleshooting

If the app cannot find Codex CLI, click **Choose Codex CLI…** in the error panel and select the `codex` executable. Common locations include:

- `~/.npm-global/bin/codex`
- `~/.local/bin/codex`
- `/opt/homebrew/bin/codex`
- `/usr/local/bin/codex`

If usage cannot be loaded, run `codex` in Terminal and use `/status` to confirm the same account is signed in.

For Claude, login and access-token renewal are handled by Claude Code. If usage fails or times out, open Claude Code and check `/usage`, then refresh this app after its retry cooldown. Sign in again only if Claude Code asks you to. If the CLI is missing or too old, install/update it. The menu-bar app no longer requests access to `Claude Code-credentials`; if an old version is still showing that prompt, quit it and launch the updated app from Applications. The official CLI may still require its own normal login or Keychain approval. Failures display the next allowed retry time and retain the last successful reading.

## References

- [Codex App Server](https://learn.chatgpt.com/docs/app-server)
- [Codex pricing and usage limits](https://learn.chatgpt.com/docs/pricing)
- [Claude Code authentication](https://code.claude.com/docs/en/authentication)
- [Claude Code usage](https://code.claude.com/docs/en/costs)

## License

MIT
