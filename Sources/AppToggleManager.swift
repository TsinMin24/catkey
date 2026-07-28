import AppKit
import CoreGraphics

class AppToggleManager {
    static let shared = AppToggleManager()

    func toggle(bundleID: String, frontmostBundleID: String? = nil) {
        guard !bundleID.isEmpty else { return }
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) else {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                NSWorkspace.shared.open(url)
            }
            return
        }

        let isFrontmost = frontmostBundleID == bundleID

        if app.isHidden {
            // 被隐藏 → 恢复
            app.unhide()
            app.activate(options: [.activateIgnoringOtherApps])
        } else if !hasVisibleWindows(for: app) {
            // 窗口全最小化 → 用 openApplication 恢复（用户确认有效）
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        } else if isFrontmost {
            // 在前台且有可见窗口 → 隐藏（效果类似最小化）
            app.hide()
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    private func hasVisibleWindows(for app: NSRunningApplication) -> Bool {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for window in windows {
            if let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid == app.processIdentifier {
                return true
            }
        }
        return false
    }
}
