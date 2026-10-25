import Foundation
import AppKit

struct KeyBinding: Codable, Identifiable {
    var id: String { key }
    let key: String
    var appName: String
    var appBundleID: String

    static func defaultBinding(key: String) -> KeyBinding {
        KeyBinding(key: key, appName: "", appBundleID: "")
    }
}

class KeyBindingStore: ObservableObject {
    static let shared = KeyBindingStore()

    @Published var bindings: [KeyBinding] {
        didSet { save() }
    }

    private let defaults = UserDefaults.standard
    private let storageKey = "MagicKeyBindings"

    init() {
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([KeyBinding].self, from: data) {
            // 旧版本可能只存了 F13–F16，这里自动补齐所有按键
            var merged = decoded
            for key in FunctionKey.allCases where !merged.contains(where: { $0.key == key.rawValue }) {
                merged.append(KeyBinding.defaultBinding(key: key.rawValue))
            }
            bindings = merged
        } else {
            bindings = FunctionKey.allCases.map { KeyBinding.defaultBinding(key: $0.rawValue) }
        }
    }

    func binding(for key: String) -> KeyBinding? {
        bindings.first(where: { $0.key == key })
            ?? KeyBinding.defaultBinding(key: key)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(bindings) {
            defaults.set(data, forKey: storageKey)
        }
    }
}
