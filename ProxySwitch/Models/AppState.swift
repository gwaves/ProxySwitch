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

    /// Current real-time traffic speed through the active proxy (bytes/second).
    /// `nil` when no proxy is active or traffic cannot be measured.
    @Published var trafficSpeed: Double?

    /// Per-profile health map. Populated on startup and on add/edit.
    @Published var profileHealths: [UUID: ProxyHealth] = [:]

    @Published var showSettings: Bool = false

    // MARK: Computed

    var activeProfile: ProxyProfile? {
        profiles.first { $0.id == activeProfileId }
    }

    /// SF Symbol name for the menu bar icon. Always a valid symbol: state is
    /// conveyed by `menuBarIconColor` instead of variant glyphs, because invalid
    /// symbol names (e.g. "globe.badge") resolve to nil and make the status item
    /// image disappear — the menu bar icon looks like it "auto-hides".
    var menuBarIconName: String {
        "globe"
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
    /// Real-time traffic monitor for the active proxy port.
    private var trafficMonitor: ProxyTrafficMonitor?
    private var cancellables = Set<AnyCancellable>()
    private var oneShotChecks: [UUID: HealthCheckOperation] = [:]
    private var lastAllProfilesCheck: TimeInterval?
    private var monitoringSettings: MonitoringSettings?

    private struct MonitoringSettings: Equatable {
        let healthEnabled: Bool
        let healthInterval: Double
        let trafficEnabled: Bool

        init() {
            let defaults = UserDefaults.standard
            healthEnabled = defaults.object(forKey: "healthCheckEnabled") as? Bool ?? true
            let interval = defaults.double(forKey: "healthCheckInterval")
            healthInterval = interval.isFinite && interval >= 10 ? interval : 30
            trafficEnabled = defaults.object(forKey: "trafficMonitoringEnabled") as? Bool ?? true
        }
    }

    // MARK: Auto-disable / auto-re-enable tracking

    /// `true` if the last proxy disable was triggered automatically because every profile was unreachable.
    private var wasAutoDisabled = false
    /// Which proxy channels were enabled before the automatic disable, so we can restore them on recovery.
    private var autoDisabledSystemProxy = false
    private var autoDisabledTerminalProxy = false

    // MARK: Init

    init() {
        loadState()
        setupTrafficMonitor()
        applyMonitoringSettings()
        observeProfileHealths()
        observeProxyHealthForAutoReenable()
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyMonitoringSettings() }
            .store(in: &cancellables)
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
    private func applyMonitoringSettings() {
        let settings = MonitoringSettings()
        let previous = monitoringSettings
        guard previous != settings else { return }
        monitoringSettings = settings
        if previous?.healthEnabled != settings.healthEnabled || previous?.healthInterval != settings.healthInterval {
            healthChecker?.stop()
            healthChecker = nil
            for check in oneShotChecks.values { check.cancel() }
            oneShotChecks.removeAll()
            lastAllProfilesCheck = nil
            if settings.healthEnabled {
                setupHealthChecker(interval: settings.healthInterval)
                for profile in profiles where profile.id != activeProfileId {
                    checkProfileHealth(profile)
                }
            } else {
                proxyHealth = .unknown
                profileHealths = [:]
            }
        }
        if previous?.trafficEnabled != settings.trafficEnabled {
            updateTrafficMonitorTarget()
        }
    }

    private func setupHealthChecker(interval: Double) {
        healthChecker = ProxyHealthChecker(interval: interval)
        healthChecker?.onStatusChange = { [weak self] health in
            self?.proxyHealth = health
            if let activeId = self?.activeProfileId {
                self?.profileHealths[activeId] = health
            }
            if case .unreachable = health {
                self?.checkAllProfiles()
            }
        }
        healthChecker?.updateTarget(profile: activeProfile)
    }

    // MARK: Traffic Monitor

    /// Sets up the real-time traffic monitor for the active proxy port.
    private func setupTrafficMonitor() {
        trafficMonitor = ProxyTrafficMonitor(interval: 15)
        trafficMonitor?.onSpeedUpdate = { [weak self] speed in
            self?.trafficSpeed = speed
        }
    }

    /// Starts or stops traffic monitoring based on whether any proxy is enabled.
    private func updateTrafficMonitorTarget() {
        let anyProxyEnabled = systemProxyEnabled || terminalProxyEnabled
        let trafficEnabled = UserDefaults.standard.object(forKey: "trafficMonitoringEnabled") as? Bool ?? true
        if trafficEnabled, anyProxyEnabled, let profile = activeProfile {
            trafficMonitor?.updateTarget(profile: profile)
        } else {
            trafficMonitor?.updateTarget(profile: nil)
            trafficSpeed = nil
        }
    }

    func setPopoverVisible(_ visible: Bool) {
        trafficMonitor?.setInterval(visible ? 3 : 15)
    }

    // MARK: Auto Disable

    /// Monitors `profileHealths` and disables all proxies when every configured proxy is unreachable.
    private func observeProfileHealths() {
        $profileHealths
            .sink { [weak self] _ in
                self?.evaluateAutoDisable()
            }
            .store(in: &cancellables)
    }

    private func evaluateAutoDisable() {
        guard UserDefaults.standard.bool(forKey: "autoDisableWhenAllUnreachable") else { return }
        guard !profiles.isEmpty else { return }
        guard systemProxyEnabled || terminalProxyEnabled else { return }

        let allUnreachable = profiles.allSatisfy { profile in
            if let health = profileHealths[profile.id] {
                return health == .unreachable
            }
            return false
        }

        if allUnreachable {
            autoDisabledSystemProxy = systemProxyEnabled
            autoDisabledTerminalProxy = terminalProxyEnabled
            wasAutoDisabled = true
            disableAll(isAutomatic: true)
        }
    }

    // MARK: Auto Re-enable

    /// Watches the active profile's health and re-enables proxies that were automatically disabled
    /// once connectivity is restored.
    private func observeProxyHealthForAutoReenable() {
        $proxyHealth
            .sink { [weak self] health in
                self?.evaluateAutoReenable(health: health)
            }
            .store(in: &cancellables)
    }

    private func evaluateAutoReenable(health: ProxyHealth) {
        guard wasAutoDisabled else { return }
        guard case .reachable(_, let functional) = health, functional else { return }
        guard activeProfile != nil else { return }

        if autoDisabledSystemProxy && !systemProxyEnabled {
            setSystemProxy(true)
        }
        if autoDisabledTerminalProxy && !terminalProxyEnabled {
            setTerminalProxy(true)
        }

        wasAutoDisabled = false
        autoDisabledSystemProxy = false
        autoDisabledTerminalProxy = false
    }

    /// Clears auto-disable tracking so a subsequent manual user action does not trigger auto-re-enable.
    private func clearAutoDisableTracking() {
        wasAutoDisabled = false
        autoDisabledSystemProxy = false
        autoDisabledTerminalProxy = false
    }

    // MARK: Profile Activation

    /// Switches the active profile and applies it to any enabled proxy channels.
    func activateProfile(_ profile: ProxyProfile) {
        clearAutoDisableTracking()
        oneShotChecks.removeValue(forKey: profile.id)?.cancel()
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
        // Update traffic monitor target as well.
        updateTrafficMonitorTarget()
    }

    // MARK: Batch Health Check

    /// Checks connectivity for every saved profile (used on launch and on demand).
    func checkAllProfiles() {
        // Repeated failures must not fan out into a full scan every cycle.
        let now = ProcessInfo.processInfo.systemUptime
        let minimumInterval = max(60, monitoringSettings?.healthInterval ?? 30)
        if let lastAllProfilesCheck, now - lastAllProfilesCheck < minimumInterval { return }
        lastAllProfilesCheck = now
        for profile in profiles where profile.id != activeProfileId {
            checkProfileHealth(profile)
        }
    }

    /// Checks a single profile's connectivity by sending an HTTP request through it.
    private func checkProfileHealth(_ profile: ProxyProfile) {
        let id = profile.id
        guard oneShotChecks[id] == nil else { return }
        profileHealths[id] = .checking

        let testUrl = UserDefaults.standard.string(forKey: "proxyTestUrl") ?? "https://www.google.com"

        oneShotChecks[id] = ProxyHealthChecker.checkOnce(profile: profile, testUrl: testUrl) { [weak self] health in
            self?.oneShotChecks.removeValue(forKey: id)
            self?.profileHealths[id] = health
            if id == self?.activeProfileId {
                self?.proxyHealth = health
            }
        }
    }

    /// Re-checks a single profile's connectivity (triggered from context menu).
    func recheckProfile(_ profile: ProxyProfile) {
        checkProfileHealth(profile)
    }

    // MARK: Proxy Toggles

    /// Enables or disables the macOS system proxy (HTTP/HTTPS/SOCKS) via `networksetup`.
    func setSystemProxy(_ enabled: Bool, isAutomatic: Bool = false) {
        if !isAutomatic {
            clearAutoDisableTracking()
        }
        systemProxyEnabled = enabled
        updateTrafficMonitorTarget()
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
    func setTerminalProxy(_ enabled: Bool, isAutomatic: Bool = false) {
        if !isAutomatic {
            clearAutoDisableTracking()
        }
        terminalProxyEnabled = enabled
        updateTrafficMonitorTarget()
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
        clearAutoDisableTracking()
        setSystemProxy(true)
        setTerminalProxy(true)
    }

    func disableAll(isAutomatic: Bool = false) {
        if !isAutomatic {
            clearAutoDisableTracking()
        }
        setSystemProxy(false, isAutomatic: isAutomatic)
        setTerminalProxy(false, isAutomatic: isAutomatic)
    }

    // MARK: Profile CRUD

    func addProfile(_ profile: ProxyProfile) {
        profiles.append(profile)
        // Auto-activate the first profile so toggles have something to act on.
        if profiles.count == 1 {
            activateProfile(profile)
        }
        if activeProfileId != profile.id || healthChecker == nil {
            checkProfileHealth(profile)
        }
    }

    func updateProfile(_ profile: ProxyProfile) {
        oneShotChecks.removeValue(forKey: profile.id)?.cancel()
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        }
        // Re-apply if the active profile was edited.
        if activeProfileId == profile.id {
            activateProfile(profile)
        }
        if activeProfileId != profile.id || healthChecker == nil {
            checkProfileHealth(profile)
        }
    }

    func deleteProfile(_ profile: ProxyProfile) {
        oneShotChecks.removeValue(forKey: profile.id)?.cancel()
        profiles.removeAll { $0.id == profile.id }
        profileHealths.removeValue(forKey: profile.id)
        // Fall back to the first remaining profile.
        if activeProfileId == profile.id {
            activeProfileId = profiles.first?.id
            healthChecker?.updateTarget(profile: activeProfile)
            updateTrafficMonitorTarget()
        }
    }
}
