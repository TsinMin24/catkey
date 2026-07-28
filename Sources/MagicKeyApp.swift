import SwiftUI
import AppKit

class RecordingObserver: ObservableObject {
    static let shared = RecordingObserver()
    @Published var isRecording = false

    init() {
        NotificationCenter.default.addObserver(self, selector: #selector(stateChanged), name: Notification.Name("voiceRecordingStateChanged"), object: nil)
    }

    @objc private func stateChanged(_ notif: Notification) {
        if let val = notif.object as? Bool {
            DispatchQueue.main.async { self.isRecording = val }
        }
    }
}

@main
struct MagicKeyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            Button("设置...") {
                appDelegate.showSettings()
            }
            .keyboardShortcut(",", modifiers: .command)
            Button("实时日志...") {
                appDelegate.showLog()
            }
            Divider()
            Button("关于 Magic Key") {
                NSApp.orderFrontStandardAboutPanel(nil)
            }
            if RecordingObserver.shared.isRecording {
                Divider()
                Text("正在录音...")
                    .foregroundColor(.red)
            }
            Divider()
            Button("退出") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            MenuBarLabelView()
        }
    }
}

struct MenuBarLabelView: View {
    @ObservedObject private var observer = RecordingObserver.shared

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(nsImage: catPawImage())
                .renderingMode(.template)
            if observer.isRecording {
                Circle()
                    .fill(.red)
                    .frame(width: 6, height: 6)
            }
        }
    }
}

func catPawImage() -> NSImage {
    let s: CGFloat = 18
    let img = NSImage(size: NSSize(width: s, height: s))
    img.isTemplate = true
    img.lockFocus()

    NSColor.black.setFill()
    let sc = s / 18.0

    // Main pad
    let main = NSBezierPath(roundedRect: NSRect(x: 3*sc, y: 2*sc, width: 12*sc, height: 9*sc), xRadius: 4*sc, yRadius: 4*sc)
    main.fill()

    // Toe pads (4 small circles)
    let toes: [(CGFloat, CGFloat)] = [
        (1.5, 10.5), (5.5, 11.5), (9.5, 11.5), (13.5, 10.5),
    ]
    for (x, y) in toes {
        let toe = NSBezierPath(ovalIn: NSRect(x: x*sc, y: y*sc, width: 4.5*sc, height: 5*sc))
        toe.fill()
    }

    img.unlockFocus()
    return img
}
