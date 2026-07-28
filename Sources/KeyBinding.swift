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
            bindings = decoded
        } else {
            bindings = [
                KeyBinding(key: "F13", appName: "", appBundleID: ""),
                KeyBinding(key: "F14", appName: "", appBundleID: ""),
                KeyBinding(key: "F15", appName: "", appBundleID: ""),
                KeyBinding(key: "F16", appName: "", appBundleID: ""),
            ]
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(bindings) {
            defaults.set(data, forKey: storageKey)
        }
    }
}
