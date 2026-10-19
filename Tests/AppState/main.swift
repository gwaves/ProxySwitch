import Foundation

// Isolate state tests from the real configuration, shell and system proxies.
let first = ProxyProfile(name: "first", type: .http, host: "127.0.0.1", httpPort: -1, bypass: [])
let second = ProxyProfile(name: "second", type: .http, host: "127.0.0.1", httpPort: -1, bypass: [])
final class ProfileStore {
    static let shared = ProfileStore()
    func load() -> [ProxyProfile] { [first, second] }
    func save(_ profiles: [ProxyProfile]) {}
}
final class SystemProxyManager {
    func enable(proxy: ProxyProfile) { fatalError("Must not change system proxy") }
    func disable() { fatalError("Must not change system proxy") }
}
final class TerminalProxyManager {
    func enable(proxy: ProxyProfile) { fatalError("Must not edit shell configuration") }
    func disable() { fatalError("Must not edit shell configuration") }
}
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}
func spin() { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
let defaults = UserDefaults.standard
// Override only this test process's settings. No real app preferences are read.
var settings: [String: Any] = [
    "activeProfileId": first.id.uuidString,
    "systemProxyEnabled": false,
    "terminalProxyEnabled": false,
    "trafficMonitoringEnabled": false,
    "healthCheckEnabled": false,
    "healthCheckInterval": 10.0,
    "autoDisableWhenAllUnreachable": false
]
func applySettings() {
    defaults.setVolatileDomain(settings, forName: UserDefaults.argumentDomain)
    NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
    spin()
}
applySettings()
defer { defaults.removePersistentDomain(forName: ProcessInfo.processInfo.processName) }
let state = AppState()
spin()
expect(state.proxyHealth == .unknown && state.profileHealths.isEmpty, "Disabled health checks must remain idle at startup")
settings["healthCheckEnabled"] = true
applySettings()
expect(state.proxyHealth == .unreachable, "Enabling checks must immediately check the restored active profile")
expect(state.profileHealths[second.id] == .unreachable, "Enabling checks must populate the other profile statuses")
settings["healthCheckEnabled"] = false
applySettings()
expect(state.proxyHealth == .unknown && state.profileHealths.isEmpty, "Disabling checks must clear pending status")
state.recheckProfile(first)
spin()
expect(state.proxyHealth == .unreachable, "Manual health checks must still work when automatic checks are off")
settings["healthCheckEnabled"] = true
settings["healthCheckInterval"] = 120.0
applySettings()
expect(state.proxyHealth == .unreachable, "Changing the interval must restart checking immediately")
state.deleteProfile(first)
spin()
expect(state.activeProfileId == second.id && state.proxyHealth == .unreachable, "Removing the active profile must retarget the checker")
settings["healthCheckEnabled"] = false
applySettings()
print("PASS: health settings apply live; restored target; manual checks; target deletion")
