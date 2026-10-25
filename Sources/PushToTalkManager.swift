import AppKit
import CoreGraphics

// MARK: - 录音键设置

enum PTTMode: String, CaseIterable, Identifiable {
    case hold
    case toggle

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hold: return "按住说话"
        case .toggle: return "按一下切换"
        }
    }
}

struct PTTSettings {
    private static let d = UserDefaults.standard

    /// 默认 F20（kVK_F20 = 0x5A）
    static var keyCode: Int {
        get { d.object(forKey: "PTTKeyCode") as? Int ?? 0x5A }
        set { d.set(newValue, forKey: "PTTKeyCode") }
    }

    /// 只记录 ⌃⌥⇧⌘ 四个修饰键（CGEventFlags / NSEvent.ModifierFlags 数值一致）
    static var modifiers: UInt {
        get { d.object(forKey: "PTTModifiers") as? UInt ?? 0 }
        set { d.set(newValue, forKey: "PTTModifiers") }
    }

    static var label: String {
        get { d.string(forKey: "PTTKeyLabel") ?? "F20" }
        set { d.set(newValue, forKey: "PTTKeyLabel") }
    }

    static var mode: PTTMode {
        get { PTTMode(rawValue: d.string(forKey: "PTTMode") ?? "") ?? .hold }
        set { d.set(newValue.rawValue, forKey: "PTTMode") }
    }
}

enum KeyNamer {
    static let functionKeys: [Int: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17",
        79: "F18", 80: "F19", 90: "F20",
    ]

    static let specialKeys: [Int: String] = [
        49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 53: "Esc",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    static func baseName(keyCode: Int, characters: String?) -> String {
        if let name = functionKeys[keyCode] { return name }
        if let name = specialKeys[keyCode] { return name }
        if let chars = characters, !chars.isEmpty {
            let upper = chars.uppercased()
            if let scalar = upper.unicodeScalars.first, scalar.value >= 0x20, scalar.value != 0x7F {
                return upper
            }
        }
        return "Key\(keyCode)"
    }

    static func label(keyCode: Int, characters: String?, flags: NSEvent.ModifierFlags) -> String {
        var prefix = ""
        if flags.contains(.control) { prefix += "⌃" }
        if flags.contains(.option) { prefix += "⌥" }
        if flags.contains(.shift) { prefix += "⇧" }
        if flags.contains(.command) { prefix += "⌘" }
        return prefix + baseName(keyCode: keyCode, characters: characters)
    }
}

// MARK: - 录音键监听

/// Push-to-talk：用 CGEventTap 监听按下/松开，按键与触发方式都可在设置里改
class PushToTalkManager {
    static let shared = PushToTalkManager()

    /// 只跟踪这四个修饰键；Fn 会被部分键盘额外带上，比较时忽略
    static let trackedModifiers: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retryTimer: Timer?
    private var keyDown = false
    private var headsetDown = false

    private var activeKeyCode: CGKeyCode = 0x5A
    private var activeModifiers: CGEventFlags = []

    func start() {
        guard tap == nil else { return }

        if #available(macOS 10.15, *) {
            if !AXIsProcessTrusted() || !CGPreflightListenEventAccess() {
                LogManager.shared.append(
                    "等待授权：请允许 辅助功能 + 输入监控（系统会弹窗，或到 系统设置→隐私与安全性 手动开启），授权后 \(PTTSettings.label) 自动生效",
                    level: .info
                )
                scheduleRetry()
                return
            }
        } else if !AXIsProcessTrusted() {
            LogManager.shared.append("等待授权：辅助功能", level: .info)
            scheduleRetry()
            return
        }
        createTap()
    }

    /// 改完录音键后调用：重建监听，无需重启 App
    func reload() {
        stop()
        start()
    }

    private func createTap() {
        activeKeyCode = CGKeyCode(PTTSettings.keyCode)
        activeModifiers = CGEventFlags(rawValue: UInt64(PTTSettings.modifiers))
            .intersection(Self.trackedModifiers)

        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.tapDisabledByTimeout.rawValue) | (1 << CGEventType.tapDisabledByUserInput.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = PushToTalkManager.shared.tap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            guard type == .keyDown || type == .keyUp else {
                return Unmanaged.passUnretained(event)
            }

            let manager = PushToTalkManager.shared
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            guard code == Int(manager.activeKeyCode) else {
                return Unmanaged.passUnretained(event)
            }

            if type == .keyDown {
                // 修饰键必须完全一致，避免 ⌘F20 之类的组合被误吞
                let flags = event.flags.intersection(PushToTalkManager.trackedModifiers)
                guard flags == manager.activeModifiers else {
                    return Unmanaged.passUnretained(event)
                }
                // 按住会持续发 keyDown 自动重复事件：只在状态变化时处理一次
                if manager.keyDown { return nil }
                manager.keyDown = true
            } else {
                // 松开只看键码：修饰键可能先被松开
                guard manager.keyDown else { return Unmanaged.passUnretained(event) }
                manager.keyDown = false
            }

            let isDown = (type == .keyDown)
            let mode = PTTSettings.mode
            let label = PTTSettings.label

            DispatchQueue.main.async {
                switch mode {
                case .hold:
                    if isDown {
                        LogManager.shared.append("\(label) 按下 → 开始语音", level: .ok)
                        VoiceInputManager.shared.startVoiceInput()
                    } else {
                        LogManager.shared.append("\(label) 松开 → 停止语音", level: .ok)
                        VoiceInputManager.shared.stopVoiceInput()
                    }
                case .toggle:
                    guard isDown else { return }
                    let starting = !VoiceInputManager.shared.isRecording()
                    LogManager.shared.append("\(label) → \(starting ? "开始" : "停止")语音", level: .ok)
                    VoiceInputManager.shared.toggleVoiceInput()
                }
            }
            return nil // 消费该按键，不让它漏到前台应用
        }

        tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: nil
        )

        guard let tap = tap else {
            LogManager.shared.append("\(PTTSettings.label) 事件监听启动失败：请检查 辅助功能/输入监控 权限", level: .err)
            scheduleRetry()
            return
        }
        stopRetry()

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        let label = PTTSettings.label
        let modeText = PTTSettings.mode == .hold ? "按住" : "按一下切换"
        LogManager.shared.append("\(label) Push-to-talk 已启动（\(modeText)）", level: .ok)

        // 录音键如果同时被绑成了应用切换键，提醒一下（事件会被这里消费）
        if let binding = KeyBindingStore.shared.binding(for: label), !binding.appBundleID.isEmpty {
            LogManager.shared.append("提示：\(label) 同时绑定了 \(binding.appName)，该键将优先用于录音", level: .info)
        }
    }

    /// HeadsetButtonManager uses the same press/release semantics as the
    /// keyboard key, but calls the voice path directly instead of injecting a
    /// second system key event.
    func handleHeadsetF20(isDown: Bool) {
        guard isDown != headsetDown else { return }
        headsetDown = isDown
        DispatchQueue.main.async {
            if isDown {
                LogManager.shared.append("耳机键按下 → 开始流式语音", level: .ok)
                VoiceInputManager.shared.startVoiceInput()
            } else {
                LogManager.shared.append("耳机键松开 → 停止流式语音", level: .ok)
                VoiceInputManager.shared.stopVoiceInput()
            }
        }
    }

    /// 权限授予后无需重启 app，每 2 秒自动检测并启动监听
    private func scheduleRetry() {
        guard retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.tap != nil {
                self.stopRetry()
                return
            }
            self.start()
        }
    }

    private func stopRetry() {
        retryTimer?.invalidate()
        retryTimer = nil
    }

    func stop() {
        stopRetry()
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap = tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            self.tap = nil
        }
        headsetDown = false
        keyDown = false
    }
}
