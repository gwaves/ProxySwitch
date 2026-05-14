import Foundation
import Network

// MARK: - Proxy Health Checker

/// Performs TCP connectivity checks against a proxy host:port.
/// Uses a generation counter to invalidate stale in-flight checks
/// (e.g. when a new check starts or the target changes).
class ProxyHealthChecker {
    private var timer: Timer?
    private var targetHost: String = ""
    private var targetPort: Int = 0
    private var currentConnection: NWConnection?
    private var checkGeneration: UInt64 = 0
    private var timeoutWork: DispatchWorkItem?

    var onStatusChange: ((ProxyHealth) -> Void)?

    init(interval: Double = 30) {
        startChecking(interval: interval)
    }

    deinit {
        timer?.invalidate()
        currentConnection?.cancel()
        timeoutWork?.cancel()
    }

    /// Updates the target and triggers an immediate check.
    func updateTarget(host: String, port: Int) {
        targetHost = host
        targetPort = port
        checkNow()
    }

    // MARK: One-shot Check (Static)

    /// Performs a single TCP connectivity check without needing a timer.
    /// Used for batch profile checks on startup and after add/edit.
    static func checkOnce(host: String, port: Int, callback: @escaping (ProxyHealth) -> Void) {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            callback(.unreachable)
            return
        }

        let startTime = CFAbsoluteTimeGetCurrent()
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        var completed = false
        let lock = NSLock()

        let finish: (ProxyHealth) -> Void = { health in
            lock.lock()
            defer { lock.unlock() }
            guard !completed else { return }
            completed = true
            connection.cancel()
            callback(health)
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let elapsed = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
                finish(.reachable(ms: elapsed))
            case .failed:
                finish(.unreachable)
            case .waiting(let error):
                if error == .posix(.EHOSTUNREACH) || error == .posix(.ETIMEDOUT) || error == .posix(.ECONNREFUSED) {
                    finish(.unreachable)
                }
            default: break
            }
        }

        connection.start(queue: .global(qos: .utility))

        // 5-second timeout
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
            finish(.unreachable)
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

    /// Runs one connectivity check. Increments `checkGeneration` so any
    /// in-flight handler from a previous check is silently discarded.
    private func checkNow() {
        guard !targetHost.isEmpty, targetPort > 0 else { return }

        checkGeneration &+= 1
        let generation = checkGeneration

        currentConnection?.cancel()
        currentConnection = nil
        timeoutWork?.cancel()
        timeoutWork = nil

        onStatusChange?(.checking)

        let host = targetHost
        let port = UInt16(targetPort)
        let startTime = CFAbsoluteTimeGetCurrent()

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            onStatusChange?(.unreachable)
            return
        }

        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: nwPort,
            using: .tcp
        )
        currentConnection = connection

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            guard generation == self.checkGeneration else { return }

            switch state {
            case .ready:
                let elapsed = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
                connection.cancel()
                self.timeoutWork?.cancel()
                self.onStatusChange?(.reachable(ms: elapsed))

            case .failed:
                connection.cancel()
                self.timeoutWork?.cancel()
                self.onStatusChange?(.unreachable)

            case .waiting(let error):
                if error == .posix(.EHOSTUNREACH)
                    || error == .posix(.ETIMEDOUT)
                    || error == .posix(.ECONNREFUSED) {
                    connection.cancel()
                    self.timeoutWork?.cancel()
                    self.onStatusChange?(.unreachable)
                }

            case .cancelled:
                break

            default:
                break
            }
        }

        connection.start(queue: .global(qos: .utility))

        // 5-second timeout
        let work = DispatchWorkItem { [weak self] in
            guard let self, generation == self.checkGeneration else { return }
            self.currentConnection?.cancel()
            self.onStatusChange?(.unreachable)
        }
        timeoutWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: work)
    }
}
