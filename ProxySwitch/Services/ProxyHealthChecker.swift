import Foundation
import Network

// MARK: - Proxy Health Checker

/// Measures two aspects of proxy health:
/// 1. TCP handshake latency to the proxy host:port (the "ms" value).
/// 2. Whether an HTTP request through the proxy reaches the test URL ("functional").
/// Uses a generation counter to invalidate stale in-flight checks.
class ProxyHealthChecker {
    private var timer: Timer?
    private var targetProfile: ProxyProfile?
    private var checkGeneration: UInt64 = 0
    private var currentTask: URLSessionDataTask?
    private var currentConnection: NWConnection?
    private var timeoutWork: DispatchWorkItem?

    var onStatusChange: ((ProxyHealth) -> Void)?

    init(interval: Double = 30) {
        startChecking(interval: interval)
    }

    deinit {
        timer?.invalidate()
        currentTask?.cancel()
        currentConnection?.cancel()
        timeoutWork?.cancel()
    }

    /// Updates the target profile and triggers an immediate check.
    func updateTarget(profile: ProxyProfile) {
        targetProfile = profile
        checkNow()
    }

    // MARK: One-shot Check (Static)

    /// Runs a full two-phase check for a single profile:
    ///   Phase 1 — TCP connect to proxy host:port → measures latency.
    ///   Phase 2 — HEAD request through proxy to testUrl → checks functionality.
    static func checkOnce(profile: ProxyProfile, testUrl: String, callback: @escaping (ProxyHealth) -> Void) {
        // Phase 1: TCP connect to proxy
        let port = profile.socksPort ?? profile.httpPort
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            callback(.unreachable)
            return
        }

        let tcpStart = CFAbsoluteTimeGetCurrent()
        let connection = NWConnection(host: NWEndpoint.Host(profile.host), port: nwPort, using: .tcp)
        var completed = false
        let lock = NSLock()

        let finish: (Int, Bool) -> Void = { ms, functional in
            lock.lock()
            defer { lock.unlock() }
            guard !completed else { return }
            completed = true
            connection.cancel()
            callback(.reachable(ms: ms, functional: functional))
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let latency = Int((CFAbsoluteTimeGetCurrent() - tcpStart) * 1000)
                // Phase 2: HTTP through proxy
                Self.checkFunctional(profile: profile, testUrl: testUrl) { functional in
                    finish(latency, functional)
                }
            case .failed, .waiting:
                lock.lock()
                if !completed {
                    completed = true
                    connection.cancel()
                    callback(.unreachable)
                }
                lock.unlock()
            default:
                break
            }
        }

        connection.start(queue: .global(qos: .utility))

        // 5-second TCP timeout
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
            lock.lock()
            if !completed {
                completed = true
                connection.cancel()
                callback(.unreachable)
            }
            lock.unlock()
        }
    }

    /// Sends a HEAD request through the proxy to verify it can forward traffic.
    private static func checkFunctional(profile: ProxyProfile, testUrl: String, callback: @escaping (Bool) -> Void) {
        guard let url = URL(string: testUrl) else {
            callback(false)
            return
        }

        let config = URLSessionConfiguration.ephemeral.copy() as! URLSessionConfiguration
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        Self.configureProxy(config: config, profile: profile)

        let session = URLSession(configuration: config)
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"

        let task = session.dataTask(with: request) { _, response, error in
            callback(error == nil && response is HTTPURLResponse)
            session.invalidateAndCancel()
        }
        task.resume()

        // 10-second hard timeout
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10) {
            task.cancel()
        }
    }

    // MARK: Periodic Checking

    private func startChecking(interval: Double) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.checkNow()
        }
    }

    // MARK: Single Check Cycle

    /// Runs one two-phase proxy health check. Increments `checkGeneration` so any
    /// in-flight handler from a previous check is silently discarded.
    private func checkNow() {
        guard let profile = targetProfile else { return }

        checkGeneration &+= 1
        let generation = checkGeneration

        currentTask?.cancel()
        currentTask = nil
        currentConnection?.cancel()
        currentConnection = nil
        timeoutWork?.cancel()
        timeoutWork = nil

        onStatusChange?(.checking)

        // Phase 1: TCP connect to proxy
        let port = profile.socksPort ?? profile.httpPort
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            onStatusChange?(.unreachable)
            return
        }

        let tcpStart = CFAbsoluteTimeGetCurrent()
        let connection = NWConnection(host: NWEndpoint.Host(profile.host), port: nwPort, using: .tcp)
        currentConnection = connection
        var phase1Done = false
        let lock = NSLock()

        connection.stateUpdateHandler = { [weak self] state in
            guard let self, generation == self.checkGeneration else { return }

            switch state {
            case .ready:
                let latency = Int((CFAbsoluteTimeGetCurrent() - tcpStart) * 1000)
                connection.cancel()
                lock.lock()
                phase1Done = true
                lock.unlock()
                // Phase 2: HTTP through proxy
                Self.checkFunctional(profile: profile, testUrl: self.testUrl) { functional in
                    guard generation == self.checkGeneration else { return }
                    self.timeoutWork?.cancel()
                    self.onStatusChange?(.reachable(ms: latency, functional: functional))
                }
            case .failed, .waiting:
                connection.cancel()
                lock.lock()
                let already = phase1Done
                lock.unlock()
                guard !already, generation == self.checkGeneration else { return }
                self.timeoutWork?.cancel()
                self.onStatusChange?(.unreachable)
            default:
                break
            }
        }

        connection.start(queue: .global(qos: .utility))

        // 5-second TCP timeout
        let work = DispatchWorkItem { [weak self] in
            guard let self, generation == self.checkGeneration else { return }
            lock.lock()
            let already = phase1Done
            lock.unlock()
            guard !already else { return }
            self.currentConnection?.cancel()
            self.onStatusChange?(.unreachable)
        }
        timeoutWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: work)
    }

    private var testUrl: String {
        UserDefaults.standard.string(forKey: "proxyTestUrl") ?? "https://www.google.com"
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
