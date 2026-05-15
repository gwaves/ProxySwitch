import SwiftUI
import Combine

// MARK: - Health Status

/// Represents the connectivity state of a proxy endpoint.
/// `.reachable(ms:, functional:)` carries the TCP connection latency to the proxy
/// and whether the test URL is reachable through it.
enum ProxyHealth: Equatable {
    case unknown
    case checking
    case reachable(ms: Int, functional: Bool)
    case unreachable
}

// MARK: - App State

/// Central observable state for the entire app.
/// Marked `@MainActor` so all `@Published` mutations happen on the main thread.
class AppState: ObservableObject {
    static let shared = AppState()

    // MARK: Published State

    /// Saved proxy configurations. Persisted via `ProfileStore` on every mutation.
    @Published var profiles: [ProxyProfile] = [] {
        didSet { ProfileStore.shared.save(profiles) }
    }
    @Published var activeProfileId: UUID? {
        didSet { UserDefaults.standard.set(activeProfileId?.uuidString, forKey: "activeProfileId") }
    }
    @Published var systemProxyEnabled: Bool = false {
        didSet { UserDefaults.standard.set(systemProxyEnabled, forKey: "systemProxyEnabled") }
    }
    @Published var terminalProxyEnabled: Bool = false {
        didSet { UserDefaults.standard.set(terminalProxyEnabled, forKey: "terminalProxyEnabled") }
    }

    /// Health of the *active* profile (drives the menu bar icon).
    @Published var proxyHealth: ProxyHealth = .unknown

    /// Per-profile health map. Populated on startup and on add/edit.
    @Published var profileHealths: [UUID: ProxyHealth] = [:]

    @Published var showSettings: Bool = false

    // MARK: Computed

    var activeProfile: ProxyProfile? {
        profiles.first { $0.id == activeProfileId }
    }

    /// SF Symbol name for the menu bar icon.
    var menuBarIconName: String {
        if case .unreachable = proxyHealth { return "globe.badge" }
        if case .reachable(_, functional: false) = proxyHealth { return "globe.badge" }
        return "globe"
    }

    /// Tint color for the menu bar icon. `nil` means the system default.
    var menuBarIconColor: NSColor? {
        switch proxyHealth {
        case .unknown, .checking:
            return nil
        case .reachable(_, let functional):
            guard functional else { return NSColor.systemOrange }
            return systemProxyEnabled || terminalProxyEnabled
                ? NSColor.systemGreen : nil
        case .unreachable:
            return NSColor.systemRed
        }
    }

    // MARK: Private

    private let systemProxyManager = SystemProxyManager()
    private let terminalProxyManager = TerminalProxyManager()
    /// Periodic checker for the active profile only.
    private var healthChecker: ProxyHealthChecker?
    private var cancellables = Set<AnyCancellable>()

    // MARK: Init

    init() {
        loadState()
        setupHealthChecker()
        // Check all profiles on launch so each row shows its health immediately.
        checkAllProfiles()
    }

    // MARK: State Restoration

    private func loadState() {
        profiles = ProfileStore.shared.load()
        systemProxyEnabled = UserDefaults.standard.bool(forKey: "systemProxyEnabled")
        terminalProxyEnabled = UserDefaults.standard.bool(forKey: "terminalProxyEnabled")

        if let idString = UserDefaults.standard.string(forKey: "activeProfileId"),
           let uuid = UUID(uuidString: idString) {
            activeProfileId = uuid
        }
    }

    // MARK: Periodic Health Checker

    /// Sets up the timer-based checker that monitors the *active* profile.
    private func setupHealthChecker() {
        let interval = UserDefaults.standard.double(forKey: "healthCheckInterval")
        healthChecker = ProxyHealthChecker(interval: interval > 0 ? interval : 30)
        healthChecker?.onStatusChange = { [weak self] health in
            Task { @MainActor in
                self?.proxyHealth = health
            }
        }
    }

    // MARK: Profile Activation

    /// Switches the active profile and applies it to any enabled proxy channels.
    func activateProfile(_ profile: ProxyProfile) {
        activeProfileId = profile.id

        // Snapshot the toggles before dispatching to a background thread.
        let sysEnabled = systemProxyEnabled
        let termEnabled = terminalProxyEnabled

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            if sysEnabled {
                self.systemProxyManager.enable(proxy: profile)
            }
            if termEnabled {
                self.terminalProxyManager.enable(proxy: profile)
            }
        }

        // Point the periodic checker at the new target.
        healthChecker?.updateTarget(profile: profile)
    }

    // MARK: Batch Health Check

    /// Checks connectivity for every saved profile (used on launch and on demand).
    func checkAllProfiles() {
        for profile in profiles {
            checkProfileHealth(profile)
        }
    }

    /// Checks a single profile's connectivity by sending an HTTP request through it.
    private func checkProfileHealth(_ profile: ProxyProfile) {
        let id = profile.id
        profileHealths[id] = .checking

        let testUrl = UserDefaults.standard.string(forKey: "proxyTestUrl") ?? "https://www.google.com"

        ProxyHealthChecker.checkOnce(profile: profile, testUrl: testUrl) { [weak self] health in
            Task { @MainActor in
                self?.profileHealths[id] = health
                // Keep the active-profile health in sync for the menu bar icon.
                if id == self?.activeProfileId {
                    self?.proxyHealth = health
                }
            }
        }
    }

    /// Re-checks a single profile's connectivity (triggered from context menu).
    func recheckProfile(_ profile: ProxyProfile) {
        checkProfileHealth(profile)
    }

    // MARK: Proxy Toggles

    /// Enables or disables the macOS system proxy (HTTP/HTTPS/SOCKS) via `networksetup`.
    func setSystemProxy(_ enabled: Bool) {
        systemProxyEnabled = enabled
        guard let profile = activeProfile else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            if enabled {
                self.systemProxyManager.enable(proxy: profile)
            } else {
                self.systemProxyManager.disable()
            }
        }
    }

    /// Enables or disables terminal proxy env vars in the shell config file.
    func setTerminalProxy(_ enabled: Bool) {
        terminalProxyEnabled = enabled
        guard let profile = activeProfile else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            if enabled {
                self.terminalProxyManager.enable(proxy: profile)
            } else {
                self.terminalProxyManager.disable()
            }
        }
    }

    func enableAll() {
        setSystemProxy(true)
        setTerminalProxy(true)
    }

    func disableAll() {
        setSystemProxy(false)
        setTerminalProxy(false)
    }

    // MARK: Profile CRUD

    func addProfile(_ profile: ProxyProfile) {
        profiles.append(profile)
        // Auto-activate the first profile so toggles have something to act on.
        if profiles.count == 1 {
            activateProfile(profile)
        }
        checkProfileHealth(profile)
    }

    func updateProfile(_ profile: ProxyProfile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        }
        // Re-apply if the active profile was edited.
        if activeProfileId == profile.id {
            activateProfile(profile)
        }
        checkProfileHealth(profile)
    }

    func deleteProfile(_ profile: ProxyProfile) {
        profiles.removeAll { $0.id == profile.id }
        profileHealths.removeValue(forKey: profile.id)
        // Fall back to the first remaining profile.
        if activeProfileId == profile.id {
            activeProfileId = profiles.first?.id
        }
    }
}
