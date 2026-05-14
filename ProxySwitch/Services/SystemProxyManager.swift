import Foundation

// MARK: - System Proxy Manager

/// Controls macOS system proxy settings via the `networksetup` CLI tool.
/// Applies changes to all active (non-disabled) network services.
class SystemProxyManager {
    private let networkSetup = "/usr/sbin/networksetup"

    // MARK: Active Services

    /// Returns the list of network service names that are not disabled.
    /// Disabled services are prefixed with `*` in the `networksetup` output.
    func activeNetworkServices() -> [String] {
        let result = runProcess(networkSetup, arguments: ["-listallnetworkservices"])
        guard result.success else { return [] }

        return result.output
            .split(separator: "\n")
            .dropFirst() // Header line: "An asterisk (*) denotes..."
            .filter { !$0.hasPrefix("*") }
            .map(String.init)
    }

    // MARK: Enable / Disable

    /// Sets proxy env vars on all active network services based on the profile type.
    func enable(proxy: ProxyProfile) {
        let services = activeNetworkServices()
        for service in services {
            switch proxy.type {
            case .http:
                runProcess(networkSetup, arguments: ["-setwebproxy", service, proxy.host, String(proxy.httpPort)])
                runProcess(networkSetup, arguments: ["-setsecurewebproxy", service, proxy.host, String(proxy.httpPort)])
                runProcess(networkSetup, arguments: ["-setwebproxystate", service, "on"])
                runProcess(networkSetup, arguments: ["-setsecurewebproxystate", service, "on"])
            case .socks5:
                // Fall back to httpPort when socksPort is not set.
                let port = proxy.socksPort ?? proxy.httpPort
                runProcess(networkSetup, arguments: ["-setsocksfirewallproxy", service, proxy.host, String(port)])
                runProcess(networkSetup, arguments: ["-setsocksfirewallproxystate", service, "on"])
            }

            if !proxy.bypass.isEmpty {
                let bypassString = proxy.bypass.joined(separator: ", ")
                runProcess(networkSetup, arguments: ["-setproxybypassdomain", service, bypassString])
            }
        }
    }

    /// Disables all proxy types (HTTP, HTTPS, SOCKS) on every active service.
    func disable() {
        let services = activeNetworkServices()
        for service in services {
            runProcess(networkSetup, arguments: ["-setwebproxystate", service, "off"])
            runProcess(networkSetup, arguments: ["-setsecurewebproxystate", service, "off"])
            runProcess(networkSetup, arguments: ["-setsocksfirewallproxystate", service, "off"])
        }
    }

    // MARK: Read Current State

    /// Reads the enabled/disabled state for each proxy type on the first active service.
    func currentProxyState() -> (http: Bool, https: Bool, socks: Bool) {
        let services = activeNetworkServices()
        guard let service = services.first else { return (false, false, false) }

        let httpEnabled = isProxyEnabled(service: service, type: "webproxy")
        let httpsEnabled = isProxyEnabled(service: service, type: "securewebproxy")
        let socksEnabled = isProxyEnabled(service: service, type: "socksfirewallproxy")

        return (httpEnabled, httpsEnabled, socksEnabled)
    }

    /// Parses `networksetup -get<type>` output for "Enabled: Yes".
    private func isProxyEnabled(service: String, type: String) -> Bool {
        let result = runProcess(networkSetup, arguments: ["-get\(type)", service])
        return result.output.contains("Enabled: Yes")
    }

    // MARK: Process Runner

    @discardableResult
    private func runProcess(_ executable: String, arguments: [String]) -> (success: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return (process.terminationStatus == 0, output)
        } catch {
            return (false, error.localizedDescription)
        }
    }
}
