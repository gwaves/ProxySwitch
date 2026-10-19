# ProxySwitch

A macOS menu bar app for managing proxy configurations. Toggle system and terminal proxies with one click, switch between saved profiles, and monitor proxy health in real time.

---

## ProxySwitch

一款 macOS 菜单栏代理管理工具。一键切换系统代理与终端代理，在多个代理配置间快速切换，并实时监控代理连通状态。

---

## Features / 功能

- **System Proxy Toggle** — Enable/disable macOS HTTP/HTTPS/SOCKS proxy via `networksetup` for all active network services.
- **Terminal Proxy Toggle** — Write/remove marked proxy env blocks (`http_proxy`, `https_proxy`, `ALL_PROXY`, `no_proxy`) in your shell config file (default `~/.zshrc`).
- **Profile Management** — Add, edit, and delete proxy configurations. Click a row to activate a profile. Right-click for edit/delete.
- **Health Check with Latency** — On launch, all profiles are checked automatically. Each row shows its TCP handshake latency (color-coded: green < 100 ms, orange < 300 ms, red ≥ 300 ms). The active profile is also monitored periodically.
- **Menu Bar Icon** — Globe icon with green tint (connected) or red badge (unreachable). Left-click opens popover, right-click shows context menu with bulk actions.
- **Settings Window** — Launch at login, show in Dock, health check interval, custom shell config path.

---

- **系统代理开关** — 通过 `networksetup` 为所有活跃网络服务启用/关闭 HTTP/HTTPS/SOCKS 代理。
- **终端代理开关** — 在 Shell 配置文件（默认 `~/.zshrc`）中写入或移除标记代理环境变量块（`http_proxy`、`https_proxy`、`ALL_PROXY`、`no_proxy`）。
- **配置管理** — 添加、编辑、删除代理配置。点击行激活配置，右键菜单可编辑/删除。
- **健康检测与延迟显示** — 启动时自动检测所有配置的连通性，每行显示 TCP 握手延迟（颜色编码：绿色 < 100ms，橙色 < 300ms，红色 ≥ 300ms）。活跃配置还会被周期性监测。
- **菜单栏图标** — 地球图标，连接正常时绿色，不可达时红色标记。左键打开弹出面板，右键显示上下文菜单（批量操作等）。
- **设置窗口** — 开机自启、Dock 图标、检测间隔、自定义 Shell 配置路径。

---

## Requirements / 系统要求

- macOS 13.0 (Ventura) or later / 或更高版本
- Xcode 15+ with Swift 5.9+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- Python 3 + Pillow (only for regenerating icons / 仅用于重新生成图标)

---

## Build / 构建

```bash
# Generate Xcode project / 生成 Xcode 工程
xcodegen generate

# Build Release / 构建 Release 版本
xcodebuild -project ProxySwitch.xcodeproj \
  -scheme ProxySwitch \
  -configuration Release \
  -derivedDataPath build \
  clean build
```

The built app is at: `build/Build/Products/Release/ProxySwitch.app`

构建产物位于：`build/Build/Products/Release/ProxySwitch.app`

---

## Project Structure / 项目结构

```
ProxySwitch/
├── ProxySwitchApp.swift        # App entry, AppDelegate (status bar + popover + settings window)
├── Models/
│   ├── AppState.swift          # Central @MainActor observable state
│   └── ProxyProfile.swift      # Proxy profile model (Codable)
├── Services/
│   ├── ProfileStore.swift      # JSON persistence in ~/Library/Application Support/
│   ├── ProxyHealthChecker.swift # TCP connectivity check (NWConnection, generation-based)
│   ├── SystemProxyManager.swift # macOS system proxy via networksetup
│   └── TerminalProxyManager.swift # Shell config file marker blocks
├── Views/
│   ├── PopoverView.swift       # Main popover (header, toggles, profile list, add button)
│   ├── ProfileRow.swift        # Single profile row with health indicator
│   ├── ProfileEditView.swift   # Add/edit profile sheet
│   └── SettingsView.swift      # Multi-tab settings window
├── Assets.xcassets/            # App icon + menu bar icons
├── Info.plist                  # LSUIElement=true (no Dock icon by default)
project.yml                     # XcodeGen project definition
generate_icon.py                # App icon generator (Pillow)
generate_menubar_icon.py        # Menu bar icon generator (Pillow)
```

---

## How It Works / 工作原理

### System Proxy / 系统代理

Uses `/usr/sbin/networksetup` to set/unset HTTP, HTTPS, and SOCKS proxy on every active network service. Bypass domains are also configured.

调用 `/usr/sbin/networksetup` 为每个活跃网络服务设置/取消 HTTP、HTTPS 和 SOCKS 代理，同时配置例外域名。

### Terminal Proxy / 终端代理

Writes a marker-delimited block to the shell config file:

在 Shell 配置文件中写入标记分隔的代理块：

```bash
# >>> ProxySwitch >>>
export http_proxy="http://127.0.0.1:7890"
export https_proxy="http://127.0.0.1:7890"
export ALL_PROXY="socks5://127.0.0.1:7891"
export no_proxy="localhost,127.0.0.1,*.local"
# <<< ProxySwitch <<<
```

On disable, the entire block is removed. On re-enable, the old block is replaced — edits are idempotent.

关闭时整个块被移除，重新开启时旧块被替换——操作是幂等的。

### Health Check / 健康检测

Uses Apple's `Network` framework (`NWConnection` TCP) to measure connection latency, followed by a HEAD request through the proxy. Turning off automatic checks cancels pending work; changing the interval takes effect immediately. Manual checks remain available. Full scans after an active proxy failure are limited to once per minute (or the configured interval, if longer).

使用 `NWConnection` 测量 TCP 连接延迟，再通过代理发送 HEAD 请求。自动检测开关和间隔即时生效，关闭时取消在途任务，仍可手动检测。活动代理失败后，对其他配置的全量复查最多每分钟一次（检测间隔更长时按该间隔）。

### Traffic Monitoring / 流量监控

Traffic sampling uses a single numeric-address `nettop` snapshot with only byte counters. Samples never overlap, and output is drained while the process runs. Refresh is every 15 seconds in the background and every 3 seconds while the menu is open. Disable **显示代理流量** in General settings to stop traffic sampling entirely. No traffic timer runs when proxies or traffic monitoring are off.

流量采样使用 `nettop` 单次快照，禁用反向 DNS，仅收集字节计数，采样不重叠并及时读取输出。后台每 15 秒更新，打开菜单时每 3 秒更新。关闭通用设置中的「显示代理流量」后完全停止流量采样；代理全部关闭时也不运行流量定时器。

### Regression Checks / 回归检查

Run `Tests/run.sh` on macOS with the Swift command line tools. It checks CSV parsing, pipe draining, sample overlap, cancellation, target changes, and live health settings without changing system proxy or shell settings.

---

## License / 许可

MIT
