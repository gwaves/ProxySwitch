import Foundation

// MARK: - Proxy Health Checker

/// Tests proxy availability by making an HTTP request through the proxy
/// to a configurable test URL. Uses URLSession with proxy configuration
/// and a generation counter to invalidate stale in-flight checks.
class ProxyHealthChecker {
    private var timer: Timer?
    private var targetProfile: ProxyProfile?
    private var checkGeneration: UInt64 = 0
    private var currentTask: URLSessionDataTask?
    private var timeoutWork: DispatchWorkItem?

    var onStatusChange: ((ProxyHealth) -> Void)?

    init(interval: Double = 30) {
        startChecking(interval: interval)
    }

    deinit {
        timer?.invalidate()
        currentTask?.cancel()
        timeoutWork?.cancel()
    }

    /// Updates the target profile and triggers an immediate check.
    func updateTarget(profile: ProxyProfile) {
        targetProfile = profile
        checkNow()
    }

    // MARK: One-shot Check (Static)

    /// Tests proxy availability by sending a HEAD request through the proxy
    /// to the given test URL. Any HTTP response (even non-200) means the proxy
    /// forwarded the request successfully.
    static func checkOnce(profile: ProxyProfile, testUrl: String, callback: @escaping (ProxyHealth) -> Void) {
        guard let url = URL(string: testUrl) else {
            callback(.unreachable)
            return
        }

        let startTime = CFAbsoluteTimeGetCurrent()
        let config = URLSessionConfiguration.ephemeral.copy() as! URLSessionConfiguration
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        Self.configureProxy(config: config, profile: profile)

        let session = URLSession(configuration: config)
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"

        let task = session.dataTask(with: request) { _, response, error in
            let elapsed = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
            if error != nil {
                callback(.unreachable)
            } else if response is HTTPURLResponse {
                // Any HTTP response means the proxy is functional
                callback(.reachable(ms: elapsed))
            } else {
                callback(.unreachable)
            }
            session.invalidateAndCancel()
        }
        task.resume()
    }

    // MARK: Periodic Checking

    private func startChecking(interval: Double) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.checkNow()
        }
    }

    // MARK: Single Check Cycle

    /// Runs one proxy availability check. Increments `checkGeneration` so any
    /// in-flight handler from a previous check is silently discarded.
    private func checkNow() {
        guard let profile = targetProfile else { return }

        checkGeneration &+= 1
        let generation = checkGeneration

        currentTask?.cancel()
        currentTask = nil
        timeoutWork?.cancel()
        timeoutWork = nil

        onStatusChange?(.checking)

        let testUrl = UserDefaults.standard.string(forKey: "proxyTestUrl") ?? "https://www.google.com"

        guard let url = URL(string: testUrl) else {
            onStatusChange?(.unreachable)
            return
        }

        let startTime = CFAbsoluteTimeGetCurrent()
        let config = URLSessionConfiguration.ephemeral.copy() as! URLSessionConfiguration
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        Self.configureProxy(config: config, profile: profile)

        let session = URLSession(configuration: config)
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"

        let task = session.dataTask(with: request) { [weak self] _, response, error in
            guard let self else { return }
            guard generation == self.checkGeneration else { return }

            let elapsed = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
            if error != nil {
                self.onStatusChange?(.unreachable)
            } else if response is HTTPURLResponse {
                self.onStatusChange?(.reachable(ms: elapsed))
            } else {
                self.onStatusChange?(.unreachable)
            }
            session.invalidateAndCancel()
        }
        currentTask = task
        task.resume()

        // 10-second hard timeout (beyond URLSession's own timeout)
        let work = DispatchWorkItem { [weak self] in
            guard let self, generation == self.checkGeneration else { return }
            self.currentTask?.cancel()
            self.onStatusChange?(.unreachable)
        }
        timeoutWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10, execute: work)
    }

    // MARK: Proxy Configuration

    /// Configures URLSession proxy settings based on the profile type.
    private static func configureProxy(config: URLSessionConfiguration, profile: ProxyProfile) {
        switch profile.type {
        case .http:
            config.connectionProxyDictionary = [
                kCFStreamPropertyHTTPProxyHost as String: profile.host,
                kCFStreamPropertyHTTPProxyPort as String: profile.httpPort,
                kCFStreamPropertyHTTPSProxyHost as String: profile.host,
                kCFStreamPropertyHTTPSProxyPort as String: profile.httpPort,
            ]
        case .socks5:
            let port = profile.socksPort ?? profile.httpPort
            config.connectionProxyDictionary = [
                kCFStreamPropertySOCKSProxyHost as String: profile.host,
                kCFStreamPropertySOCKSProxyPort as String: port,
                kCFStreamPropertySOCKSVersion as String: 5,
            ]
        }
    }
}
