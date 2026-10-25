import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotkeyManager: HotkeyManager?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        hotkeyManager = HotkeyManager.shared
        hotkeyManager?.registerAll()
        PushToTalkManager.shared.start()
        // Headset HID control is intentionally disabled. The 3.5mm inline
        // button shares the microphone conductor with the audio input, so
        // seizing it can mute the headset mic. Keyboard F20 remains the only
        // push-to-talk trigger in this build.
        LogManager.shared.append("耳机按键控制已关闭（仅使用键盘录音键）", level: .info)

        // CGEventTap 监听键盘事件需要“输入监控”权限
        if #available(macOS 10.15, *) {
            let listen = CGPreflightListenEventAccess()
            LogManager.shared.append(
                "输入监控权限：\(listen ? "已授权" : "未授权")",
                level: listen ? .ok : .err
            )
            // Do not call CGRequestListenEventAccess() automatically. macOS
            // can show the permission sheet repeatedly when the app is
            // rebuilt or when TCC has not yet accepted this code signature.
            // The Settings window has an explicit button for opening the
            // Input Monitoring pane instead.
        }

        // Check Accessibility permission and prompt if needed
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
        if !AXIsProcessTrustedWithOptions(opts as CFDictionary) {
            LogManager.shared.append("请在 系统设置→隐私与安全性→辅助功能 中手动勾选 MagicKey，否则无法注入按键/文字", level: .err)
        }

        // 启动自检：语音凭证未配置时提示
        if !VoiceInputManager.shared.isReady {
            LogManager.shared.append("提示：语音 API Key 未配置，请在设置中选择供应商并填写对应 API Key", level: .info)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        PushToTalkManager.shared.stop()
        hotkeyManager?.unregisterAll()
    }

    func showSettings() {
        showWindow(key: &settingsWindow,
                   title: "Magic Key 设置",
                   size: NSSize(width: 520, height: 800),
                   view: AnyView(SettingsView()))
    }

    private func showWindow(key: inout NSWindow?, title: String, size: NSSize, view: AnyView) {
        if let window = key, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(size)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        key = window
    }
}
