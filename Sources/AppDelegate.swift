import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotkeyManager: HotkeyManager?
    private var settingsWindow: NSWindow?
    private var logWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        hotkeyManager = HotkeyManager.shared
        hotkeyManager?.registerAll()

        // Check Accessibility permission and prompt if needed
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        if !AXIsProcessTrustedWithOptions(opts as CFDictionary) {
            LogManager.shared.append("请在 系统设置→隐私与安全性→辅助功能 中勾选 MagicKey，否则无法注入文字", level: .err)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyManager?.unregisterAll()
    }

    func showSettings() {
        showWindow(key: &settingsWindow,
                   title: "Magic Key 设置",
                   size: NSSize(width: 500, height: 550),
                   view: AnyView(SettingsView()))
    }

    func showLog() {
        showWindow(key: &logWindow,
                   title: "Magic Key 日志",
                   size: NSSize(width: 520, height: 400),
                   view: AnyView(LogWindow()))
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
