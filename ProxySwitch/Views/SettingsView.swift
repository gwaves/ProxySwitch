import SwiftUI
import ServiceManagement

// MARK: - Settings View

/// Multi-tab settings window with General, Proxy Check, and Terminal tabs.
/// Uses `@AppStorage` for persistence so changes are saved automatically.
struct SettingsView: View {
    @AppStorage("showInDock") private var showInDock = false
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("healthCheckEnabled") private var healthCheckEnabled = true
    @AppStorage("healthCheckInterval") private var healthCheckInterval = 30.0
    @AppStorage("proxyTestUrl") private var proxyTestUrl = "https://www.google.com"
    @AppStorage("autoDisableWhenAllUnreachable") private var autoDisableWhenAllUnreachable = false
    @AppStorage("shellConfigPath") private var shellConfigPath = ""

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("通用", systemImage: "gearshape") }

            proxyTab
                .tabItem { Label("代理检测", systemImage: "heart.circle") }

            terminalTab
                .tabItem { Label("终端", systemImage: "terminal") }
        }
        .frame(width: 450, height: 350)
    }

    // MARK: General Tab

    private var generalTab: some View {
        Form {
            Toggle("开机自启", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { newValue in
                    setLaunchAtLogin(newValue)
                }

            Toggle("在 Dock 显示图标", isOn: $showInDock)
                .onChange(of: showInDock) { newValue in
                    if newValue {
                        NSApp.setActivationPolicy(.regular)
                    } else {
                        NSApp.setActivationPolicy(.accessory)
                    }
                }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: Proxy Check Tab

    private var proxyTab: some View {
        Form {
            Toggle("自动检测代理可用性", isOn: $healthCheckEnabled)

            if healthCheckEnabled {
                Picker("检测间隔", selection: $healthCheckInterval) {
                    Text("10 秒").tag(10.0)
                    Text("30 秒").tag(30.0)
                    Text("60 秒").tag(60.0)
                    Text("120 秒").tag(120.0)
                }

                Toggle("所有代理不可用时自动关闭代理", isOn: $autoDisableWhenAllUnreachable)
            }

            TextField("测试目标 URL", text: $proxyTestUrl, prompt: Text("https://www.google.com"))
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: Terminal Tab

    private var terminalTab: some View {
        Form {
            TextField("Shell 配置文件路径", text: $shellConfigPath, prompt: Text("~/.zshrc"))

            if shellConfigPath.isEmpty {
                Text("默认路径: ~/.zshrc")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: Launch at Login

    /// Registers/unregisters the app as a login item via ServiceManagement.
    private func setLaunchAtLogin(_ enabled: Bool) {
        if enabled {
            try? SMAppService.mainApp.register()
        } else {
            try? SMAppService.mainApp.unregister()
        }
    }
}
