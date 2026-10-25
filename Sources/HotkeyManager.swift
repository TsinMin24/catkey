import Carbon.HIToolbox
import Foundation
import AppKit

// MARK: - 功能键统一表（唯一来源）
//
// 覆盖当前硬件：
//   C3 键盘:  F5, F13–F20   (GPIO0–7、GPIO10)
//   keycat:   F20 语音, F22 回车, F24 语音 (nice_nano P0.20/P0.22/P0.24)
enum FunctionKey: String, CaseIterable, Codable, Identifiable {
    case f5 = "F5"
    case f13 = "F13"
    case f14 = "F14"
    case f15 = "F15"
    case f16 = "F16"
    case f17 = "F17"
    case f18 = "F18"
    case f19 = "F19"
    case f20 = "F20"
    case f22 = "F22"
    case f24 = "F24"

    var id: String { rawValue }

    /// Carbon 虚拟键码（kVK_*）
    var carbonKeyCode: UInt32 {
        switch self {
        case .f5:  return 0x60  // kVK_F5
        case .f13: return 0x69  // kVK_F13
        case .f14: return 0x6B  // kVK_F14
        case .f15: return 0x71  // kVK_F15
        case .f16: return 0x6A  // kVK_F16
        case .f17: return 0x40  // kVK_F17
        case .f18: return 0x4F  // kVK_F18
        case .f19: return 0x50  // kVK_F19
        case .f20: return 0x5A  // kVK_F20
        case .f22: return 0x42  // F22（keycat 回车）
        case .f24: return 0x44  // F24（keycat 语音）
        }
    }

    /// 事件标签，从 1 开始
    var tag: UInt32 { UInt32(Self.allCases.firstIndex(of: self)! + 1) }
}

class HotkeyManager {
    static let shared = HotkeyManager()

    private var hotkeyRefs: [FunctionKey: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?

    func registerAll() {
        unregisterAll()
        installHandler()

        // 录音键完全交给 PushToTalkManager 的 CGEventTap
        // （Carbon kEventHotKeyReleased 在 macOS 上不总是触发，导致“松开即停”失效）
        let pttKey = FunctionKey(rawValue: PTTSettings.label)
        let keys = FunctionKey.allCases.filter { $0 != .f20 && $0 != pttKey }
        for key in keys {
            register(key)
        }
        LogManager.shared.append(
            "按键监听已启动：\(keys.map(\.rawValue).joined(separator: " "))（\(PTTSettings.label) 走 Push-to-talk）",
            level: .ok
        )
    }

    func unregisterAll() {
        for (_, ref) in hotkeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotkeyRefs.removeAll()

        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
    }

    private func installHandler() {
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]

        let handler: EventHandlerUPP = { _, event, _ -> OSStatus in
            var hotkeyID = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotkeyID
            )
            guard let key = FunctionKey.allCases.first(where: { $0.tag == hotkeyID.id }) else {
                return noErr
            }
            let isRelease = GetEventKind(event) == OSType(kEventHotKeyReleased)
            DispatchQueue.main.async {
                HotkeyManager.handle(key, isRelease: isRelease)
            }
            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            eventTypes.count,
            &eventTypes,
            nil,
            &eventHandler
        )
    }

    private func register(_ key: FunctionKey) {
        let hotkeyID = EventHotKeyID(signature: OSType(0x4D4B_5953), id: key.tag)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            key.carbonKeyCode,
            0,
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        if status == noErr, let ref = ref {
            hotkeyRefs[key] = ref
            LogManager.shared.append("已注册 \(key.rawValue)（keyCode \(key.carbonKeyCode)）", level: .ok)
        } else {
            LogManager.shared.append("注册失败 \(key.rawValue)：OSStatus \(status)", level: .err)
        }
    }

    // MARK: - 按键分发

    private static func handle(_ key: FunctionKey, isRelease: Bool) {
        let binding = KeyBindingStore.shared.binding(for: key.rawValue)

        // 录音键不在这里注册（见 registerAll），这里只处理应用切换
        guard !isRelease else { return }

        guard let binding = binding, !binding.appBundleID.isEmpty else {
            LogManager.shared.append("\(key.rawValue) 已按下，但未绑定应用（请在设置中选择）", level: .info)
            return
        }
        toggleApp(binding, for: key)
    }

    private static func toggleApp(_ binding: KeyBinding, for key: FunctionKey) {
        let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        AppToggleManager.shared.toggle(bundleID: binding.appBundleID, frontmostBundleID: frontmostBundleID)
        LogManager.shared.append("\(key.rawValue) → \(binding.appName)", level: .ok)
    }
}
