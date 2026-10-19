import Foundation
import Network

/// Periodic checks and their callbacks are serialized on the main queue.
class ProxyHealthChecker {
    private var timer: Timer?
    private let interval: TimeInterval
    private var targetProfile: ProxyProfile?
    private var currentCheck: HealthCheckOperation?
    var onStatusChange: ((ProxyHealth) -> Void)?

    init(interval: Double = 30) {
        self.interval = interval
    }

    deinit { stop() }

    func stop() {
        timer?.invalidate()
        timer = nil
        currentCheck?.cancel()
        currentCheck = nil
        targetProfile = nil
    }

    func updateTarget(profile: ProxyProfile?) {
        currentCheck?.cancel()
        currentCheck = nil
        targetProfile = profile
        timer?.invalidate()
        timer = nil
        guard profile != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.checkNow()
        }
        timer?.tolerance = interval * 0.1
        checkNow()
    }

    @discardableResult
    static func checkOnce(profile: ProxyProfile, testUrl: String,
                          callback: @escaping (ProxyHealth) -> Void) -> HealthCheckOperation {
        let operation = HealthCheckOperation(profile: profile, testUrl: testUrl, callback: callback)
        // Keep even immediate failures asynchronous so callers can retain the
        // cancellation handle before a completion arrives.
        DispatchQueue.main.async { operation.start() }
        return operation
    }

    private func checkNow() {
        guard currentCheck == nil, let profile = targetProfile else { return }
        onStatusChange?(.checking)
        currentCheck = Self.checkOnce(
            profile: profile,
            testUrl: UserDefaults.standard.string(forKey: "proxyTestUrl") ?? "https://www.google.com"
        ) { [weak self] health in
            self?.currentCheck = nil
            self?.onStatusChange?(health)
        }
    }

    // MARK: Proxy Configuration

    /// Configures URLSession proxy settings based on the profile type.
    fileprivate static func configureProxy(config: URLSessionConfiguration, profile: ProxyProfile) {
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


/// Owns both phases and their timeout. Cancellation closes the TCP connection
/// and the HTTP task, and prevents late results from changing application state.
final class HealthCheckOperation {
    private let profile: ProxyProfile
    private let testUrl: String
    private var callback: ((ProxyHealth) -> Void)?
    private var connection: NWConnection?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var timeout: DispatchWorkItem?
    private var tcpStart: TimeInterval = 0

    init(profile: ProxyProfile, testUrl: String, callback: @escaping (ProxyHealth) -> Void) {
        self.profile = profile
        self.testUrl = testUrl
        self.callback = callback
    }

    deinit { cancel() }

    func cancel() {
        callback = nil
        timeout?.cancel()
        timeout = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    fileprivate func start() {
        guard callback != nil else { return }
        let port = profile.type == .socks5 ? (profile.socksPort ?? profile.httpPort) : profile.httpPort
        guard let rawPort = UInt16(exactly: port),
              let nwPort = NWEndpoint.Port(rawValue: rawPort) else {
            finish(.unreachable)
            return
        }
        tcpStart = ProcessInfo.processInfo.systemUptime
        let connection = NWConnection(host: NWEndpoint.Host(profile.host), port: nwPort, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, self.callback != nil, self.connection != nil else { return }
            switch state {
            case .ready:
                let latency = Int((ProcessInfo.processInfo.systemUptime - self.tcpStart) * 1000)
                self.timeout?.cancel()
                self.timeout = nil
                self.connection?.stateUpdateHandler = nil
                self.connection?.cancel()
                self.connection = nil
                self.checkFunctional(latency: latency)
            case .failed:
                self.finish(.unreachable)
            default:
                break
            }
        }
        // One queue owns completion and cancellation, including TCP timeout.
        connection.start(queue: .main)
        let timeout = DispatchWorkItem { [weak self] in self?.finish(.unreachable) }
        self.timeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
    }

    private func checkFunctional(latency: Int) {
        guard let url = URL(string: testUrl) else {
            finish(.reachable(ms: latency, functional: false))
            return
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        ProxyHealthChecker.configureProxy(config: config, profile: profile)
        let session = URLSession(configuration: config)
        self.session = session
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        task = session.dataTask(with: request) { [weak self] _, response, error in
            let functional = error == nil && response is HTTPURLResponse
            DispatchQueue.main.async { [weak self] in
                self?.finish(.reachable(ms: latency, functional: functional))
            }
        }
        task?.resume()
    }

    private func finish(_ health: ProxyHealth) {
        guard let callback else { return }
        cancel()
        callback(health)
    }
}
