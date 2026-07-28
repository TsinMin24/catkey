import Carbon.HIToolbox
import Foundation
import AppKit

class HotkeyManager {
    static let shared = HotkeyManager()
    private var hotkeyRefs: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?

    private let keyCodes: [String: Int] = [
        "F13": 0x69, "F14": 0x6B, "F15": 0x71, "F16": 0x6A,
    ]

    func registerAll() {
        unregisterAll()
        installHandler()
        for binding in KeyBindingStore.shared.bindings {
            guard let keyCode = keyCodes[binding.key] else { continue }
            register(keyCode: keyCode, tag: tagFor(key: binding.key))
        }
    }

    func unregisterAll() {
        for ref in hotkeyRefs { UnregisterEventHotKey(ref) }
        hotkeyRefs.removeAll()
        if let handler = eventHandler { RemoveEventHandler(handler); eventHandler = nil }
    }

    private func tagFor(key: String) -> UInt32 {
        switch key {
        case "F13": return 1; case "F14": return 2
        case "F15": return 3; case "F16": return 4
        default: return 0
        }
    }

    private func installHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        let handler: EventHandlerUPP = { _, event, _ -> OSStatus in
            var hotkeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotkeyID)
            let keyName = HotkeyManager.keyForTag(hotkeyID.id)
            let frontmostApp = NSWorkspace.shared.frontmostApplication
            let frontBundleID = frontmostApp?.bundleIdentifier

            DispatchQueue.main.async {
                guard let binding = KeyBindingStore.shared.bindings.first(where: { $0.key == keyName }),
                      !binding.appBundleID.isEmpty else { return }
                AppToggleManager.shared.toggle(bundleID: binding.appBundleID, frontmostBundleID: frontBundleID)
            }
            return noErr
        }

        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType, nil, &eventHandler)
    }

    private func register(keyCode: Int, tag: UInt32) {
        var hotkeyID = EventHotKeyID(signature: OSType(0x4D4B_5953), id: tag)
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(keyCode), 0, hotkeyID, GetApplicationEventTarget(), 0, &ref)
        if let ref = ref { hotkeyRefs.append(ref) }
    }

    private static func keyForTag(_ tag: UInt32) -> String {
        switch tag {
        case 1: return "F13"; case 2: return "F14"
        case 3: return "F15"; case 4: return "F16"
        default: return ""
        }
    }
}
