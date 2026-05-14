import Foundation

// MARK: - Profile Store

/// Persists `[ProxyProfile]` as JSON in the Application Support directory.
/// Uses atomic writes to avoid data corruption on crash.
class ProfileStore {
    static let shared = ProfileStore()

    private let fileURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("ProxySwitch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("config.json")
    }

    func load() -> [ProxyProfile] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([ProxyProfile].self, from: data)) ?? []
    }

    func save(_ profiles: [ProxyProfile]) {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
