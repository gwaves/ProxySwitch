import SwiftUI

// MARK: - Profile Row

/// A single row in the profile list. Shows name, address, health indicator,
/// and a checkmark when active. Clicking the row activates that profile.
struct ProfileRow: View {
    let profile: ProxyProfile
    let isActive: Bool
    let health: ProxyHealth
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                statusDot
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(isActive ? .primary : .secondary)
                    HStack(spacing: 4) {
                        Text(profile.displayAddress)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        healthBadge
                    }
                }
                Spacer()
                if isActive {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.accentColor)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(isActive ? Color.accentColor.opacity(0.08) : Color.clear)
            .cornerRadius(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Status Dot

    /// Colored dot or spinner indicating the profile's health.
    /// Non-active profiles show dimmed dots so the user can still see connectivity at a glance.
    private var statusDot: some View {
        Group {
            switch health {
            case .checking:
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 8, height: 8)
            case .unknown:
                if isActive {
                    Circle()
                        .fill(.gray)
                        .frame(width: 8, height: 8)
                }
            case .reachable:
                Circle()
                    .fill(isActive ? .green : .green.opacity(0.6))
                    .frame(width: 8, height: 8)
            case .unreachable:
                Circle()
                    .fill(isActive ? .red : .red.opacity(0.6))
                    .frame(width: 8, height: 8)
            }
        }
    }

    // MARK: Health Badge

    /// Text label next to the address showing latency or error state.
    /// Latency is color-coded: green < 100ms, orange < 300ms, red >= 300ms.
    private var healthBadge: some View {
        Group {
            switch health {
            case .reachable(let ms):
                Text("\(ms)ms")
                    .font(.caption2)
                    .foregroundColor(ms < 100 ? .green : ms < 300 ? .orange : .red)
            case .unreachable:
                Text("不可达")
                    .font(.caption2)
                    .foregroundColor(.red)
            case .checking:
                Text("检测中...")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            case .unknown:
                EmptyView()
            }
        }
    }
}
