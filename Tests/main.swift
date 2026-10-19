import Foundation
import Network

// Compile the services independently of SwiftUI and the user's saved settings.
enum ProxyHealth: Equatable {
    case unknown, checking, reachable(ms: Int, functional: Bool), unreachable
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}
func spin(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}
func waitUntil(_ message: String, condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(8)
    while !condition() && Date() < deadline { spin(0.05) }
    expect(condition(), message)
}
func profile(_ port: Int) -> ProxyProfile {
    ProxyProfile(name: "test", type: .http, host: "127.0.0.1", httpPort: port, bypass: [])
}

let csv = """
,bytes_in,bytes_out,
app.123,999999,999999,
tcp4 127.0.0.1:50000<->127.0.0.1:7890,100,200,
tcp4 127.0.0.1:7890<->127.0.0.1:50000,200,100,
tcp4 127.0.0.1:50001<->127.0.0.1:78901,900,900,
tcp4 127.0.0.1:50002<->192.0.2.1:7890,900,900,
tcp6 ::1.50003<->::1.7890,30,40,
tcp6 [::1]:50004<->[::1]:7890,5,6,
tcp4 127.0.0.1:7890<->*:*, , ,
"""
expect(ProxyTrafficMonitor.parseNettopOutput(csv, hosts: ["127.0.0.1", "::1"], port: 7890) == 381,
       "Parse real CSV columns, IPv6, exact endpoints, and avoid loopback double counting")
expect(ProxyTrafficMonitor.parseNettopOutput(csv, hosts: ["192.0.2.1"], port: 7890) == 1800,
       "Remote endpoint must match")
expect(ProxyTrafficMonitor.parseNettopOutput("", hosts: ["127.0.0.1"], port: 7890) == 0,
       "An empty successful sample means idle")
print("PASS: traffic parser")

let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dir) }
let log = dir.appendingPathComponent("events")
let executable = dir.appendingPathComponent("fake-nettop")
// Emit more than a pipe's capacity before sleeping, to exercise draining.
let script = """
#!/bin/sh
printf 'start\\n' >> '\(log.path)'
printf ',bytes_in,bytes_out,\\n'
i=0
while [ "$i" -lt 6000 ]; do
  printf 'tcp4 127.0.0.1:50000<->127.0.0.1:7890,100,200,\\n'
  i=$((i + 1))
done
sleep 0.25
printf 'end\\n' >> '\(log.path)'
"""
try script.write(to: executable, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
var speeds: [Double?] = []
let monitor = ProxyTrafficMonitor(interval: 0.03, executableURL: executable)
monitor.onSpeedUpdate = { speeds.append($0) }
monitor.updateTarget(profile: profile(7890))
waitUntil("Repeated samples should produce speed") { speeds.contains(where: { $0 != nil }) }
let events = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
expect(events.filter { $0 == "end" }.count >= 2, "Large output must drain without a timeout")
var running = 0
for event in events {
    running += event == "start" ? 1 : -1
    expect((0...1).contains(running), "Timer must never overlap samples")
}
expect(speeds.contains(where: { $0 != nil }), "Repeated samples should produce speed")
monitor.updateTarget(profile: profile(7891))
let afterSwitch = speeds.count
waitUntil("New target should produce speed") { speeds.dropFirst(afterSwitch).contains(where: { $0 != nil }) }
expect(speeds.dropFirst(afterSwitch).compactMap { $0 }.allSatisfy { $0 == 0 }, "Old target results must be discarded")
monitor.updateTarget(profile: nil)
let stoppedCount = speeds.count
spin(0.5)
let stoppedEvents = try String(contentsOf: log, encoding: .utf8)
spin(0.2)
expect(speeds.count == stoppedCount, "Disabled monitor must not publish stale results")
let finalEvents = try String(contentsOf: log, encoding: .utf8)
expect(finalEvents == stoppedEvents, "Disabled monitor must stop starting processes")
print("PASS: no overlapping samples; pipe draining; target switching; stopping")

var callbacks = 0
let operation = ProxyHealthChecker.checkOnce(profile: profile(-1), testUrl: "http://127.0.0.1:9") { _ in callbacks += 1 }
operation.cancel()
spin(0.1)
expect(callbacks == 0, "Cancelled checks must not callback")
let checker = ProxyHealthChecker(interval: 0.04)
checker.onStatusChange = { _ in callbacks += 1 }
checker.updateTarget(profile: profile(-1))
spin(0.15)
expect(callbacks > 0, "Checker should check a configured target")
checker.stop()
let afterStop = callbacks
spin(0.15)
expect(callbacks == afterStop, "Stopping health checks must cancel the timer and in-flight work")
checker.updateTarget(profile: profile(-1))
spin(0.1)
checker.updateTarget(profile: nil)
let afterClear = callbacks
spin(0.1)
expect(callbacks == afterClear, "Removing the target must stop periodic checks")
print("PASS: health cancellation; timer stop; restart; target removal")

// Exercise both phases against a local HTTP proxy, without internet access.
let listener = try NWListener(using: .tcp, on: .any)
var clients: [NWConnection] = []
listener.newConnectionHandler = { connection in
    clients.append(connection)
    connection.start(queue: .main)
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
        guard data != nil else { return }
        let response = Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}
listener.start(queue: .main)
spin(0.1)
guard let port = listener.port else { fatalError("Local proxy listener failed") }
var result: ProxyHealth?
let httpCheck = ProxyHealthChecker.checkOnce(profile: profile(Int(port.rawValue)), testUrl: "http://127.0.0.1:1/") { result = $0 }
let deadline = Date().addingTimeInterval(3)
while result == nil && Date() < deadline { spin(0.05) }
if case .reachable(_, functional: true) = result {} else { fatalError("TCP and HTTP proxy check failed: \(String(describing: result))") }
httpCheck.cancel()
listener.cancel()
clients.forEach { $0.cancel() }
print("PASS: TCP and HTTP phases against a local proxy")
