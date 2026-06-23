import Foundation

// MARK: - Proxy Traffic Monitor

/// Monitors real-time traffic flowing through the proxy port using `nettop`.
/// Measures actual bytes passing through proxy connections (not test download speed).
///
/// How it works:
/// 1. Runs `nettop -L -x` to get CSV-formatted connection data with raw byte counts.
/// 2. Filters connections whose description contains the proxy host:port.
/// 3. Sums bytes_in + bytes_out across all matching connections.
/// 4. On the next sample, computes (delta bytes) / (delta time) = bytes/second.
class ProxyTrafficMonitor {
    private var timer: Timer?
    /// Previous sample: total cumulative bytes and timestamp.
    private var previousSample: (bytes: Int64, time: Date)?
    private var targetProfile: ProxyProfile?

    var onSpeedUpdate: ((Double?) -> Void)?

    init(interval: Double = 3) {
        startMonitoring(interval: interval)
    }

    deinit {
        timer?.invalidate()
    }

    /// Updates the target profile and resets the sample baseline.
    func updateTarget(profile: ProxyProfile?) {
        targetProfile = profile
        previousSample = nil
        measureNow()
    }

    // MARK: Periodic Monitoring

    private func startMonitoring(interval: Double) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.measureNow()
        }
    }

    // MARK: Measurement

    private func measureNow() {
        guard let profile = targetProfile else {
            onSpeedUpdate?(nil)
            return
        }

        let port = profile.type == .socks5 ? (profile.socksPort ?? profile.httpPort) : profile.httpPort

        sampleTraffic(host: profile.host, port: port) { [weak self] totalBytes in
            guard let self = self else { return }

            let now = Date()

            if let prev = self.previousSample, let current = totalBytes {
                let dt = now.timeIntervalSince(prev.time)
                guard dt > 0 else { return }

                let speed: Double
                if current >= prev.bytes {
                    speed = Double(current - prev.bytes) / dt
                } else {
                    // Connections were reset (disconnected + reconnected), report 0 for this sample
                    speed = 0
                }
                self.onSpeedUpdate?(speed)
            }

            if let current = totalBytes {
                self.previousSample = (current, now)
            }
        }
    }

    private func sampleTraffic(host: String, port: Int, completion: @escaping (Int64?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let total = self.runNettop(host: host, port: port)
            DispatchQueue.main.async {
                completion(total)
            }
        }
    }

    // MARK: nettop Runner

    /// Runs `nettop -L 2 -x` to collect 2 CSV samples, then parses proxy-port traffic.
    /// Uses DispatchGroup + terminationHandler for reliable async waiting.
    private func runNettop(host: String, port: Int) -> Int64? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = ["-L", "2", "-x"]

        let pipe = Pipe()
        process.standardOutput = pipe

        let group = DispatchGroup()
        group.enter()

        var outputString: String?

        process.terminationHandler = { _ in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            outputString = String(data: data, encoding: .utf8)
            group.leave()
        }

        do {
            try process.run()
        } catch {
            group.leave()
            return nil
        }

        // 5-second hard timeout on a separate queue.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
            if process.isRunning {
                process.terminate()
            }
        }

        group.wait()

        guard let output = outputString else { return nil }
        return parseNettopOutput(output, host: host, port: port)
    }

    // MARK: Output Parser

    /// Parses nettop CSV output and sums bytes_in + bytes_out for connections matching the proxy port.
    ///
    /// nettop -L -x CSV format (per line):
    ///   time,connection_desc,interface,state,bytes_in,bytes_out,...
    ///
    /// connection_desc examples:
    ///   tcp4 10.0.1.6:52272<->192.168.88.234:7890
    ///   tcp4 127.0.0.1:xxxxx<->127.0.0.1:7890
    ///   tcp6 *.5900<->*.*
    private func parseNettopOutput(_ output: String, host: String, port: Int) -> Int64? {
        var totalBytes: Int64 = 0
        var foundAny = false

        let portSuffix = ":\(port)"
        let isLocalhost = (host == "127.0.0.1" || host == "localhost" || host == "::1")

        let lines = output.split(separator: "\n")
        for line in lines {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            // Need at least: time, conn_desc, interface, state, bytes_in, bytes_out
            guard fields.count >= 6 else { continue }

            // Skip the header line
            let firstField = String(fields[0]).trimmingCharacters(in: .whitespaces)
            if firstField == "time" || firstField.hasPrefix("time,") {
                continue
            }

            let connDesc = String(fields[1]).trimmingCharacters(in: .whitespaces)
            let bytesInStr = String(fields[4]).trimmingCharacters(in: .whitespaces)
            let bytesOutStr = String(fields[5]).trimmingCharacters(in: .whitespaces)

            // Skip process summary lines (they don't have a connection description with <->)
            guard connDesc.contains("<->") else { continue }

            // Match connections where the description contains the proxy port.
            // For localhost proxies, any connection ending with :port is likely the proxy.
            // For remote proxies, the description should contain host:port.
            let hasPort = connDesc.contains(portSuffix)
            guard hasPort else { continue }

            // For non-localhost proxies, also verify the host appears in the connection.
            if !isLocalhost {
                guard connDesc.contains(host) else { continue }
            }

            if let bytesIn = Int64(bytesInStr), let bytesOut = Int64(bytesOutStr) {
                totalBytes += bytesIn + bytesOut
                foundAny = true
            }
        }

        return foundAny ? totalBytes : nil
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
