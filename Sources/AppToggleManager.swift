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
            app.unhide()
            app.activate(options: [.activateIgnoringOtherApps])
        } else if !hasVisibleWindows(for: app) {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        } else if isFrontmost {
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
