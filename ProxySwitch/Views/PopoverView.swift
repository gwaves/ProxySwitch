import SwiftUI

// MARK: - Popover View

/// Main popover content displayed when clicking the menu bar icon.
/// Layout: header → system/terminal toggles → profile list → add button.
struct PopoverView: View {
    @EnvironmentObject var appState: AppState
    @State private var showAddProfile = false
    @State private var editingProfile: ProxyProfile?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            trafficSection
            toggleSection
            Divider()
            profileList
            Divider()
            addProfileButton
        }
        .frame(width: 280)
        .sheet(isPresented: $showAddProfile) {
            ProfileEditView(mode: .add) { profile in
                appState.addProfile(profile)
            }
        }
        .sheet(item: $editingProfile) { profile in
            ProfileEditView(mode: .edit(profile)) { updated in
                appState.updateProfile(updated)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("ProxySwitch")
                .font(.headline)
            Spacer()
            Button {
                NotificationCenter.default.post(name: .openSettings, object: nil)
            } label: {
                Image(systemName: "gearshape")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Traffic Section

    @ViewBuilder
    private var trafficSection: some View {
        let anyProxyEnabled = appState.systemProxyEnabled || appState.terminalProxyEnabled
        if anyProxyEnabled {
            HStack {
                Image(systemName: "arrow.down.arrow.up")
                    .foregroundColor(.secondary)
                    .font(.caption)
                if let speed = appState.trafficSpeed, speed > 0 {
                    Text(speed.trafficFullString)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.primary)
                } else {
                    Text("暂无流量")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }

    // MARK: Toggle Section

    private var toggleSection: some View {
        VStack(spacing: 8) {
            HStack {
                Label("系统代理", systemImage: "network")
                    .font(.subheadline)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { appState.systemProxyEnabled },
                    set: { appState.setSystemProxy($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            HStack {
                Label("终端代理", systemImage: "terminal")
                    .font(.subheadline)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { appState.terminalProxyEnabled },
                    set: { appState.setTerminalProxy($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Profile List

    private var profileList: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                if appState.profiles.isEmpty {
                    emptyState
                } else {
                    ForEach(appState.profiles) { profile in
                        ProfileRow(
                            profile: profile,
                            isActive: appState.activeProfileId == profile.id,
                            health: appState.profileHealths[profile.id] ?? .unknown
                        ) {
                            appState.activateProfile(profile)
                        }
                        .contextMenu {
                            Button("测速") { appState.recheckProfile(profile) }
                            Divider()
                            Button("编辑") { editingProfile = profile }
                            Divider()
                            Button("删除", role: .destructive) { appState.deleteProfile(profile) }
                        }
                    }
                }
            }
        }
        .frame(maxHeight: 240)
        .padding(.vertical, 6)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "globe.badge.plus")
                .font(.title2)
                .foregroundColor(.secondary)
            Text("暂无代理配置")
                .font(.caption)
                .foregroundColor(.secondary)
            Text("点击下方按钮添加")
                .font(.caption2)
                .foregroundColor(.secondary.opacity(0.6))
        }
        .padding(.vertical, 30)
    }

    // MARK: Add Button

    private var addProfileButton: some View {
        Button {
            showAddProfile = true
        } label: {
            Label("添加代理配置", systemImage: "plus")
                .font(.subheadline)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted to request the settings window to open.
    static let openSettings = Notification.Name("openSettings")
}
