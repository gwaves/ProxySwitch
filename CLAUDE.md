# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

ProxySwitch is a Swift/SwiftUI menu-bar macOS app for toggling system and terminal proxy settings from one place. It targets macOS 13.0+ and uses XcodeGen to generate the Xcode project.

## Common commands

Generate the Xcode project (do this after pulling or after editing `project.yml`):

```bash
xcodegen generate
```

Build a release binary:

```bash
xcodebuild -project ProxySwitch.xcodeproj \
  -scheme ProxySwitch \
  -configuration Release \
  -derivedDataPath build \
  clean build
```

The built app is at `build/Build/Products/Release/ProxySwitch.app`.

There are currently no unit/UI tests in the repo. Testing is manual: build and run the app from Xcode or open the built `.app`.

Regenerate icons (requires Python 3 + Pillow):

```bash
pip install Pillow
python generate_icon.py
python generate_menubar_icon.py
```

## Architecture

### App lifecycle and UI hosting

- `ProxySwitchApp.swift` is the `@main` entry point. Its `body` returns an empty `Settings` scene; the real UI is hosted in `AppDelegate`.
- `AppDelegate` owns the `NSStatusBar` item, the `NSPopover` containing `PopoverView`, and the manually managed settings `NSWindow` (containing `SettingsView`). It also observes `AppState` to update the menu-bar icon and traffic speed title.
- The settings window is manually created instead of using `showSettingsWindow:` because `.accessory` activation-policy apps cannot reliably trigger the SwiftUI Settings scene.
- `Info.plist` sets `LSUIElement` to `true`, so the app does not show in the Dock by default. The "在 Dock 显示图标" toggle switches the activation policy to `.regular` at runtime.

### State management

- `AppState` is a `@MainActor` `ObservableObject` singleton and the single source of truth.
- Published state is persisted through a mix of `UserDefaults` (`@AppStorage` mirrors the same keys) and `ProfileStore` (JSON in `~/Library/Application Support/ProxySwitch/config.json`).
- Mutating `AppState.profiles` triggers `ProfileStore.save()` automatically via `didSet`.

### Services

- `SystemProxyManager` wraps `/usr/sbin/networksetup`. It discovers non-disabled network services and applies HTTP/HTTPS/SOCKS proxy settings to all of them. Calls are dispatched to a background queue from `AppState`.
- `TerminalProxyManager` reads/writes a marker-delimited block in the shell config file (default `~/.zshrc`, overridable via the `shellConfigPath` setting). Edits are idempotent: the old block is removed before the new one is appended.
- `ProxyHealthChecker` performs two-phase health checks: (1) TCP connect latency via `NWConnection`, then (2) a HEAD request through the proxy to the configured test URL. It uses a generation counter to discard stale in-flight results when the target profile or interval changes.
- `ProxyTrafficMonitor` runs `/usr/bin/nettop -L 2 -x` on a timer, parses CSV output, and sums bytes for connections matching the active proxy host:port to compute real-time bytes/second.

### Health-check flow

- On launch, `AppState.checkAllProfiles()` checks every saved profile once.
- A periodic `ProxyHealthChecker` instance monitors only the *active* profile and updates `AppState.proxyHealth` (which drives the menu-bar icon color).
- Per-profile health is stored in `AppState.profileHealths` so each row in the list shows its own status.
- If the active profile becomes unreachable, `AppState` re-checks all profiles.
- When "所有代理不可用时自动关闭代理" is enabled and every configured profile is unreachable, `AppState.evaluateAutoDisable()` calls `disableAll(isAutomatic: true)` and records which channels were on. Once the active profile becomes reachable and functional again, `AppState.evaluateAutoReenable()` re-enables those recorded channels. Manual toggles clear this tracking so a user-initiated disable is never undone automatically.

### Important concurrency notes

- All `@Published` state mutations happen on the main actor (inside `AppState`).
- `SystemProxyManager`, `TerminalProxyManager`, `ProxyHealthChecker.checkOnce`, and `ProxyTrafficMonitor` all do their work on background queues and call back onto the main actor before updating `AppState`.
- When adding features that mutate UI state from background work, route the result through `Task { @MainActor in ... }` or an equivalent `DispatchQueue.main.async` block.

### XcodeGen configuration

- `project.yml` is the source of truth for the Xcode project. `ProxySwitch.xcodeproj` is generated and ignored in `.gitignore`; do not hand-edit the `.pbxproj` file.
- The generated project uses the existing `ProxySwitch/Info.plist` (`GENERATE_INFOPLIST_FILE: false`).

## Settings/defaults keys

These `UserDefaults` keys are used across the app and should be kept in sync with `SettingsView`:

- `launchAtLogin` — registered via `SMAppService`.
- `activeProfileId` — UUID string of the currently active profile.
- `systemProxyEnabled`, `terminalProxyEnabled` — current toggle states.
- `healthCheckEnabled`, `healthCheckInterval` — periodic health check settings.
- `proxyTestUrl` — URL used for the functional HEAD request (default `https://www.google.com`).
- `autoDisableWhenAllUnreachable` — disables all proxies when every profile is unreachable.
- `shellConfigPath` — custom path for the terminal proxy block; empty means `~/.zshrc`.
