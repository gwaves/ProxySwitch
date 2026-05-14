import Foundation

// MARK: - Proxy Type

enum ProxyType: String, Codable, CaseIterable, Identifiable {
    case http = "HTTP"
    case socks5 = "SOCKS5"

    var id: String { rawValue }
}

// MARK: - Proxy Profile

/// A saved proxy configuration. `Codable` for JSON persistence via `ProfileStore`.
struct ProxyProfile: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var type: ProxyType
    var host: String
    var httpPort: Int
    var socksPort: Int?
    var bypass: [String]

    /// Full URL string for HTTP/HTTPS proxy env vars.
    var httpUrl: String {
        "http://\(host):\(httpPort)"
    }

    /// Full URL string for SOCKS5 proxy env var. `nil` if `socksPort` is not set.
    var socksUrl: String? {
        guard let socksPort else { return nil }
        return "socks5://\(host):\(socksPort)"
    }

    /// Short display label shown in the profile row (e.g. "HTTP 127.0.0.1:7890").
    var displayAddress: String {
        switch type {
        case .http:
            return "HTTP \(host):\(httpPort)"
        case .socks5:
            if let socksPort {
                return "SOCKS5 \(host):\(socksPort)"
            }
            return "SOCKS5 \(host):\(httpPort)"
        }
    }

    static func == (lhs: ProxyProfile, rhs: ProxyProfile) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Preview Helper

extension ProxyProfile {
    static let preview = ProxyProfile(
        name: "本地代理",
        type: .http,
        host: "127.0.0.1",
        httpPort: 7890,
        socksPort: 7891,
        bypass: ["localhost", "127.0.0.1", "*.local"]
    )
}
