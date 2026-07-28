import SwiftUI
import AppKit

struct SettingsView: View {
    @StateObject private var store = KeyBindingStore.shared

    var body: some View {
        VStack(spacing: 0) {
            Text("Magic Key 设置")
                .font(.headline)
                .padding(.top, 20)
                .padding(.bottom, 8)

            Text("点击「选择应用」为每个按键绑定一个应用")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.bottom, 16)

            ForEach(Array(store.bindings.enumerated()), id: \.offset) { index, binding in
                BindingRow(binding: binding) { newBinding in
                    store.bindings[index] = newBinding
                    HotkeyManager.shared.registerAll()
                }
                Divider().padding(.horizontal, 20)
            }

            Spacer()

            Text("需要在系统设置中授予辅助功能权限")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.bottom, 8)

            Button("打开辅助功能设置") {
                let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                NSWorkspace.shared.open(url)
            }
            .buttonStyle(.link)
            .padding(.bottom, 16)
        }
        .frame(width: 480, height: 360)
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
