import Foundation
import Darwin

/// All lifecycle and sample state is managed on the main queue. Only DNS
/// resolution, pipe reads and parsing run on a utility queue.
class ProxyTrafficMonitor {
    private var timer: Timer?
    private let executableURL: URL
    private var interval: TimeInterval
    private var targetProfile: ProxyProfile?
    private var previousSample: (bytes: Int64, time: TimeInterval)?
    private var generation: UInt64 = 0
    private var process: Process?
    private var timeout: DispatchWorkItem?
    private var resolvedHosts: Set<String>?

    var onSpeedUpdate: ((Double?) -> Void)?

    init(interval: Double = 15, executableURL: URL = URL(fileURLWithPath: "/usr/bin/nettop")) {
        self.interval = interval
        self.executableURL = executableURL
    }

    deinit {
        timer?.invalidate()
        timeout?.cancel()
        if let process, process.isRunning { process.terminate() }
    }

    func setInterval(_ interval: TimeInterval) {
        guard self.interval != interval else { return }
        self.interval = interval
        scheduleTimer()
    }

    func updateTarget(profile: ProxyProfile?) {
        generation &+= 1
        targetProfile = profile
        previousSample = nil
        resolvedHosts = nil
        timeout?.cancel()
        if let process, process.isRunning { process.terminate() }
        onSpeedUpdate?(nil)
        scheduleTimer()
        measureNow()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = nil
        guard targetProfile != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.measureNow()
        }
        timer?.tolerance = interval * 0.1
    }

    private func measureNow() {
        // Keep the old process tracked until its pipe has drained and it exits.
        guard process == nil, let profile = targetProfile else { return }
        let generation = self.generation
        let port = profile.type == .socks5 ? (profile.socksPort ?? profile.httpPort) : profile.httpPort
        let cachedHosts = resolvedHosts
        let process = Process()
        process.executableURL = executableURL
        // One cumulative snapshot is sufficient; our baseline spans invocations.
        // Numeric addresses avoid reverse DNS; select only the columns we use.
        process.arguments = ["-L", "1", "-n", "-x", "-J", "bytes_in,bytes_out"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            onSpeedUpdate?(nil)
            return
        }
        self.process = process
        let timeout = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        self.timeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)

        DispatchQueue.global(qos: .utility).async { [weak self] in
            // Drain while nettop runs, before waiting for exit, so a full pipe
            // cannot block the child and force every sample to time out.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let now = ProcessInfo.processInfo.systemUptime
            let hosts = cachedHosts ?? Self.resolveHosts(profile.host)
            let bytes = process.terminationStatus == 0
                ? Self.parseNettopOutput(String(decoding: data, as: UTF8.self), hosts: hosts, port: port)
                : nil
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                timeout.cancel()
                self.process = nil
                guard generation == self.generation else {
                    self.measureNow()
                    return
                }
                self.resolvedHosts = hosts
                if let bytes {
                    if let previous = self.previousSample, now > previous.time {
                        self.onSpeedUpdate?(Double(max(0, bytes - previous.bytes)) / (now - previous.time))
                    }
                    self.previousSample = (bytes, now)
                } else {
                    self.previousSample = nil
                    self.onSpeedUpdate?(nil)
                }
            }
        }
    }

    /// Resolve a configured hostname once per target, since nettop emits numeric
    /// addresses. Never perform reverse DNS for the machine's other connections.
    private static func resolveHosts(_ host: String) -> Set<String> {
        var hosts: Set<String> = [host]
        if ["localhost", "127.0.0.1", "::1"].contains(host) {
            return ["127.0.0.1", "::1"]
        }
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, nil, &result) == 0 else { return hosts }
        defer { if let result { freeaddrinfo(result) } }
        var current = result
        while let info = current {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen,
                           &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                hosts.insert(String(cString: buffer))
            }
            current = info.pointee.ai_next
        }
        return hosts
    }

    /// With -J, nettop emits description,bytes_in,bytes_out (no time column).
    /// Match complete endpoints so :7890 cannot accidentally match :78901.
    static func parseNettopOutput(_ output: String, hosts: Set<String>, port: Int) -> Int64? {
        let endpoints = Set(hosts.flatMap { host in
            host.contains(":")
                ? ["\(host):\(port)", "[\(host)]:\(port)", "\(host).\(port)"]
                : ["\(host):\(port)"]
        })
        var total: Int64 = 0
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3 else { continue }
            let description = fields[0].trimmingCharacters(in: .whitespaces)
            guard let separator = description.range(of: "<->") else { continue }
            let destination = String(description[separator.upperBound...])
            // Count the client side only; loopback also has a mirrored server
            // socket whose source is the proxy port.
            guard endpoints.contains(destination),
                  let bytesIn = Int64(fields[1].trimmingCharacters(in: .whitespaces)),
                  let bytesOut = Int64(fields[2].trimmingCharacters(in: .whitespaces)) else { continue }
            total += bytesIn + bytesOut
        }
        // A successful empty snapshot means idle traffic, not a failed sample.
        return total
    }
}

// MARK: - Traffic Speed Formatting

extension Double {
    /// Concise format for menu bar: ↓1.2M, ↓856K, ↓12.5M
    var trafficMenuBarString: String {
        if self >= 1_000_000 {
            return String(format: "↓%.1fM", self / 1_000_000)
        } else if self >= 1_000 {
            return String(format: "↓%.0fK", self / 1_000)
        } else {
            return String(format: "↓%.0fB", self)
        }
    }

    /// Full readable format: 1.2 MB/s, 856 KB/s, 12.5 MB/s
    var trafficFullString: String {
        if self >= 1_000_000_000 {
            return String(format: "%.2f GB/s", self / 1_000_000_000)
        } else if self >= 1_000_000 {
            return String(format: "%.1f MB/s", self / 1_000_000)
        } else if self >= 1_000 {
            return String(format: "%.0f KB/s", self / 1_000)
        } else {
            return String(format: "%.0f B/s", self)
        }
    }
}
