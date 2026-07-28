import SwiftUI
import AppKit

struct SettingsView: View {
    @StateObject private var store = KeyBindingStore.shared
    @State private var appKey = VoiceInputManager.shared.volcengineAppKey
    @State private var accessKey = VoiceInputManager.shared.volcengineAccessKey
    @State private var secretKey = VoiceInputManager.shared.volcengineSecretKey
    @State private var savedText = ""
    @State private var savedColor = Color.secondary
    @State private var showAppKey = false
    @State private var showAccessKey = false
    @State private var showSecretKey = false

    private func saveApiConfig() {
        VoiceInputManager.shared.volcengineAppKey = appKey
        VoiceInputManager.shared.volcengineAccessKey = accessKey
        VoiceInputManager.shared.volcengineSecretKey = secretKey
        savedText = "已保存"
        savedColor = .green
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            savedText = ""
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Magic Key 设置")
                .font(.headline)
                .padding(.top, 20)
                .padding(.bottom, 8)

            // ── App Toggle Bindings ──
            Text("应用切换按键 (F13-F16)")
                .font(.subheadline)
                .fontWeight(.medium)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 4)

            ForEach(Array(store.bindings.enumerated()), id: \.offset) { index, binding in
                BindingRow(binding: binding) { newBinding in
                    store.bindings[index] = newBinding
                    HotkeyManager.shared.registerAll()
                }
                Divider().padding(.horizontal, 20)
            }

            // ── Voice Input ──
            Text("语音输入 (F20)")
                .font(.subheadline)
                .fontWeight(.medium)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 4)

            VStack(spacing: 8) {
                HStack {
                    Text("App ID").frame(width: 90, alignment: .trailing)
                    ZStack(alignment: .trailing) {
                        if showAppKey {
                            TextField("App ID", text: $appKey)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField("App ID", text: $appKey)
                        }
                        Button(action: { showAppKey.toggle() }) {
                            Image(systemName: showAppKey ? "eye.slash.fill" : "eye.fill")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 6)
                    }
                    .font(.system(.caption, design: .monospaced))
                }
                HStack {
                    Text("Access Token").frame(width: 90, alignment: .trailing)
                    ZStack(alignment: .trailing) {
                        if showAccessKey {
                            TextField("Access Token", text: $accessKey)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField("Access Token", text: $accessKey)
                        }
                        Button(action: { showAccessKey.toggle() }) {
                            Image(systemName: showAccessKey ? "eye.slash.fill" : "eye.fill")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 6)
                    }
                    .font(.system(.caption, design: .monospaced))
                }
                HStack {
                    Text("Secret Key").frame(width: 90, alignment: .trailing)
                    ZStack(alignment: .trailing) {
                        if showSecretKey {
                            TextField("Secret Key（留空则不签名）", text: $secretKey)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField("Secret Key（留空则不签名）", text: $secretKey)
                        }
                        Button(action: { showSecretKey.toggle() }) {
                            Image(systemName: showSecretKey ? "eye.slash.fill" : "eye.fill")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 6)
                    }
                    .font(.system(.caption, design: .monospaced))
                }
            }
            .padding(.horizontal, 20)

            // ── API Save ──
            HStack(spacing: 12) {
                Button("保存 API 配置") {
                    saveApiConfig()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Text(savedText)
                    .font(.caption)
                    .foregroundColor(savedColor)
            }
            .padding(.top, 6)
            .padding(.bottom, 4)

            // ── Functional Keys Info ──
            Text("P0.22 = 回车键  |  P0.24(F20) = 按一下录音，再按停止并识别")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.top, 8)
                .padding(.bottom, 4)

            // ── Footer ──
            Text("需要在系统设置中授予「辅助功能」和「麦克风」权限")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.bottom, 4)

            HStack(spacing: 16) {
                Button("打开辅助功能设置") {
                    let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(.link)
                .controlSize(.small)

                Button("打开麦克风设置") {
                    let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(.link)
                .controlSize(.small)
            }
            .padding(.bottom, 16)
        }
        .frame(width: 500, height: 550)
    }
}

struct BindingRow: View {
    let binding: KeyBinding
    let onUpdate: (KeyBinding) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(binding.key)
                .font(.system(.body, design: .monospaced))
                .fontWeight(.semibold)
                .frame(width: 40)

            if let icon = appIcon(for: binding.appBundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 24, height: 24)
            } else {
                Image(systemName: "app.dashed")
                    .resizable()
                    .frame(width: 24, height: 24)
                    .foregroundColor(.secondary)
            }

            Text(binding.appName.isEmpty ? "未绑定" : binding.appName)
                .foregroundColor(binding.appName.isEmpty ? .secondary : .primary)
                .lineLimit(1)

            Spacer()

            Button("选择应用") {
                selectApp()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if !binding.appName.isEmpty {
                Button(action: {
                    onUpdate(KeyBinding(key: binding.key, appName: "", appBundleID: ""))
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private func selectApp() {
        let panel = NSOpenPanel()
        panel.title = "选择应用"
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        if panel.runModal() == .OK, let url = panel.url {
            let bundle = Bundle(url: url)
            let appName = url.deletingPathExtension().lastPathComponent
            let bundleID = bundle?.bundleIdentifier ?? ""
            onUpdate(KeyBinding(key: binding.key, appName: appName, appBundleID: bundleID))
        }
    }

    private func appIcon(for bundleID: String) -> NSImage? {
        guard !bundleID.isEmpty else { return nil }
        return NSWorkspace.shared.icon(forFile: NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path ?? "")
    }
}