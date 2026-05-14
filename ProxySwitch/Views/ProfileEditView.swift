import SwiftUI

// MARK: - Profile Edit Mode

enum ProfileEditMode {
    case add
    case edit(ProxyProfile)
}

// MARK: - Profile Edit View

/// Sheet for adding or editing a proxy profile.
/// Pre-populates fields when in `.edit` mode.
struct ProfileEditView: View {
    let mode: ProfileEditMode
    let onSave: (ProxyProfile) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var type: ProxyType = .http
    @State private var host: String = "127.0.0.1"
    @State private var httpPort: String = "7890"
    @State private var socksPort: String = "7891"
    @State private var bypass: String = "localhost, 127.0.0.1, *.local"

    init(mode: ProfileEditMode, onSave: @escaping (ProxyProfile) -> Void) {
        self.mode = mode
        self.onSave = onSave

        // Pre-fill state when editing an existing profile.
        if case .edit(let profile) = mode {
            _name = State(initialValue: profile.name)
            _type = State(initialValue: profile.type)
            _host = State(initialValue: profile.host)
            _httpPort = State(initialValue: String(profile.httpPort))
            _socksPort = State(initialValue: profile.socksPort.map(String.init) ?? "")
            _bypass = State(initialValue: profile.bypass.joined(separator: ", "))
        }
    }

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    /// Preserve the existing UUID so an edited profile is recognised as the same entity.
    private var existingId: UUID? {
        if case .edit(let profile) = mode { return profile.id }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isEditing ? "编辑代理配置" : "添加代理配置")
                .font(.headline)

            Form {
                TextField("名称", text: $name)

                Picker("代理类型", selection: $type) {
                    ForEach(ProxyType.allCases) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.segmented)

                LabeledContent("HTTP 代理地址") {
                    HStack {
                        TextField("地址", text: $host)
                            .frame(width: 140)
                        TextField("端口", text: $httpPort)
                            .frame(width: 60)
                    }
                }

                LabeledContent("SOCKS5 端口（可选）") {
                    TextField("端口", text: $socksPort)
                        .frame(width: 60)
                }

                LabeledContent("例外主机") {
                    TextField("Bypass 域名", text: $bypass)
                        .frame(width: 180)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") { save() }
                    .disabled(name.isEmpty || host.isEmpty || httpPort.isEmpty)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    // MARK: Save

    private func save() {
        guard let port = Int(httpPort) else { return }

        let profile = ProxyProfile(
            id: existingId ?? UUID(),
            name: name,
            type: type,
            host: host,
            httpPort: port,
            socksPort: Int(socksPort),
            bypass: bypass
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )

        onSave(profile)
        dismiss()
    }
}
