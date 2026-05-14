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

Uses Apple's `Network` framework (`NWConnection` TCP) to test proxy reachability. A generation counter ensures stale in-flight checks are silently discarded when a new check starts or the target changes. Latency is measured from connection start to the `.ready` state.

使用 Apple `Network` 框架（`NWConnection` TCP）检测代理连通性。代计数器确保当新检测开始或目标变更时，过期的在途检测被静默丢弃。延迟从连接开始到 `.ready` 状态计算。

---

## License / 许可

MIT
