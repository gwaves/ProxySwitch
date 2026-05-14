import Foundation

// MARK: - Terminal Proxy Manager

/// Manages proxy environment variables in a shell config file (default `~/.zshrc`).
/// Uses marker blocks so edits are idempotent and don't interfere with manual content.
///
/// Block format:
/// ```
/// # >>> ProxySwitch >>>
/// export http_proxy="http://host:port"
/// ...
/// # <<< ProxySwitch <<<
/// ```
class TerminalProxyManager {
    private let beginMarker = "# >>> ProxySwitch >>>"
    private let endMarker = "# <<< ProxySwitch <<<"

    /// Resolves the shell config path: custom value from Settings, or `~/.zshrc`.
    var shellConfigPath: String {
        let customPath = UserDefaults.standard.string(forKey: "shellConfigPath")
        if let customPath, !customPath.isEmpty {
            return customPath
        }
        return NSHomeDirectory() + "/.zshrc"
    }

    // MARK: Enable / Disable

    /// Writes proxy env vars inside a marked block at the end of the shell config.
    func enable(proxy: ProxyProfile) {
        var lines = readConfigFile()

        // Remove any existing ProxySwitch block first (idempotent).
        removeProxyBlock(from: &lines)

        var proxyLines: [String] = []
        proxyLines.append(beginMarker)
        proxyLines.append("export http_proxy=\"\(proxy.httpUrl)\"")
        proxyLines.append("export https_proxy=\"\(proxy.httpUrl)\"")
        if let socksUrl = proxy.socksUrl {
            proxyLines.append("export ALL_PROXY=\"\(socksUrl)\"")
        }
        if !proxy.bypass.isEmpty {
            proxyLines.append("export no_proxy=\"\(proxy.bypass.joined(separator: ","))\"")
        }
        proxyLines.append(endMarker)

        // Ensure a blank line before the block.
        if !lines.isEmpty && lines.last?.isEmpty == false {
            lines.append("")
        }
        lines.append(contentsOf: proxyLines)

        writeConfigFile(lines)
    }

    /// Removes the ProxySwitch block from the shell config.
    func disable() {
        var lines = readConfigFile()
        removeProxyBlock(from: &lines)

        // Clean up trailing blank lines we may have introduced.
        while let last = lines.last, last.isEmpty {
            lines.removeLast()
        }

        writeConfigFile(lines)
    }

    /// Returns `true` if the shell config contains a ProxySwitch block.
    func isProxyEnabled() -> Bool {
        let lines = readConfigFile()
        return lines.contains(where: { $0.contains(beginMarker) })
    }

    // MARK: File I/O

    private func readConfigFile() -> [String] {
        let path = shellConfigPath
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return []
        }
        return content.components(separatedBy: "\n")
    }

    private func writeConfigFile(_ lines: [String]) {
        let path = shellConfigPath
        let content = lines.joined(separator: "\n")
        try? content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Removes the marker block and any empty line directly above it.
    private func removeProxyBlock(from lines: inout [String]) {
        guard let startIdx = lines.firstIndex(where: { $0.contains(beginMarker) }),
              let endIdx = lines.firstIndex(where: { $0.contains(endMarker) }),
              startIdx <= endIdx else {
            return
        }

        let removeStart = startIdx > 0 && lines[startIdx - 1].isEmpty ? startIdx - 1 : startIdx
        lines.removeSubrange(removeStart...endIdx)
    }
}
