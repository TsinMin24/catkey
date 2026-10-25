import AppKit
import Foundation
import IOKit.hid

/// Routes the selected headset consumer-control button into MagicKey's
/// push-to-talk voice path. Keyboard media keys are intentionally excluded by
/// the device-name/usage filter below.
final class HeadsetButtonManager {
    static let shared = HeadsetButtonManager()

    private let targetUsagePage: UInt32 = 0x0C // Consumer
    private let targetUsage: UInt32 = 0xCD     // Play/Pause
    private var hidManager: IOHIDManager?
    private var buttonDown = false
    private var loggedDevices = Set<String>()
    private var seizedDevices: [IOHIDDevice] = []
    private var retryTimer: Timer?
    private var managerSeized = false

    private static let inputCallback: IOHIDValueCallback = { _, result, _, value in
        guard result == kIOReturnSuccess else { return }
        HeadsetButtonManager.shared.receive(value: value)
    }

    private static let deviceMatchingCallback: IOHIDDeviceCallback = { _, result, _, device in
        guard result == kIOReturnSuccess else { return }
        HeadsetButtonManager.shared.attach(device: device)
    }

    func start() {
        guard hidManager == nil else { return }

        // First discover only the actual Consumer-Control headset devices.
        // The old implementation opened a manager matching *all* HID devices
        // and then tried to seize one device afterwards; macOS had already
        // retained the normal media-key path, so Play/Pause still leaked.
        // We now discover candidates, close that non-exclusive manager, and
        // reopen a second manager with exact product/vendor matching and the
        // seize option. Keyboard HID devices are never included in that
        // second manager.
        let discovery = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(discovery, nil)
        let discoveryResult = IOHIDManagerOpen(discovery, IOOptionBits(kIOHIDOptionsTypeNone))
        guard discoveryResult == kIOReturnSuccess else {
            LogManager.shared.append(
                String(format: "耳机 HID 发现失败：IOKit 0x%08X（请检查输入监控权限）", discoveryResult),
                level: .err
            )
            scheduleRetry()
            return
        }

        let candidates = (IOHIDManagerCopyDevices(discovery) as? Set<IOHIDDevice> ?? [])
            .filter { accepts(device: $0) }
        let matchings = candidates.compactMap { matchingDictionary(for: $0) }
        IOHIDManagerClose(discovery, IOOptionBits(kIOHIDOptionsTypeNone))

        guard !matchings.isEmpty else {
            LogManager.shared.append("未找到可隔离的耳机 Consumer 0xCD 设备（保留重试）", level: .info)
            scheduleRetry()
            return
        }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        if matchings.count == 1, let matching = matchings.first {
            IOHIDManagerSetDeviceMatching(manager, matching)
        } else {
            IOHIDManagerSetDeviceMatchingMultiple(manager, matchings as CFArray)
        }
        IOHIDManagerRegisterDeviceMatchingCallback(manager, Self.deviceMatchingCallback, nil)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        guard result == kIOReturnSuccess else {
            LogManager.shared.append(
                String(format: "耳机 HID 隔离启动失败：IOKit 0x%08X（请检查输入监控权限）", result),
                level: .err
            )
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            scheduleRetry()
            return
        }

        hidManager = manager
        managerSeized = true
        if let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
            for device in devices { attach(device: device) }
        }
        retryTimer?.invalidate()
        retryTimer = nil
        LogManager.shared.append("耳机按钮监听已启动（Consumer 0x0C/0xCD → F20）", level: .ok)
    }

    func stop() {
        retryTimer?.invalidate()
        retryTimer = nil
        for device in seizedDevices {
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            if !managerSeized {
                IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            }
        }
        seizedDevices.removeAll()
        guard let manager = hidManager else { return }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        hidManager = nil
        managerSeized = false
        buttonDown = false
    }

    private func scheduleRetry() {
        guard retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.hidManager == nil { self.start() }
        }
    }

    private func attach(device: IOHIDDevice) {
        guard accepts(device: device) else { return }
        let identity = deviceIdentity(device)
        guard !seizedDevices.contains(where: { deviceIdentity($0) == identity }) else { return }

        if !managerSeized {
            let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
            guard result == kIOReturnSuccess else {
                LogManager.shared.append(
                    String(format: "耳机设备隔离失败：IOKit 0x%08X（请检查输入监控权限）", result),
                    level: .err
                )
                return
            }
        }

        IOHIDDeviceRegisterInputValueCallback(device, Self.inputCallback, nil)
        // Devices returned by IOHIDManagerCopyDevices are not guaranteed to
        // be scheduled for per-device callbacks merely because the manager
        // itself is scheduled. Explicitly schedule the device in both modes;
        // this is what makes the seized headset's down/up values reach us.
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        seizedDevices.append(device)
        LogManager.shared.append("已独占耳机 HID 设备：系统不再处理它的 Play/Pause", level: .ok)
    }

    private func receive(value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        guard IOHIDElementGetUsagePage(element) == targetUsagePage,
              IOHIDElementGetUsage(element) == targetUsage else { return }

        let device = IOHIDElementGetDevice(element)
        // The device was filtered before the manager seized it. Avoid calling
        // CopyMatchingElements again here: some HID drivers expose the
        // element list differently after an exclusive open, which used to
        // discard otherwise valid events.
        let identity = deviceIdentity(device)
        guard seizedDevices.contains(where: { deviceIdentity($0) == identity }) else { return }

        let isDown = IOHIDValueGetIntegerValue(value) != 0
        guard isDown != buttonDown else { return }
        buttonDown = isDown

        LogManager.shared.append("耳机 HID \(isDown ? "DOWN" : "UP") → 语音路径", level: .ok)

        DispatchQueue.main.async {
            PushToTalkManager.shared.handleHeadsetF20(isDown: isDown)
        }
    }

    private func accepts(device: IOHIDDevice) -> Bool {
        guard hasTargetButton(device) else { return false }
        let product = property(device, key: kIOHIDProductKey as CFString)
        let manufacturer = property(device, key: kIOHIDManufacturerKey as CFString)
        let transport = property(device, key: kIOHIDTransportKey as CFString)
        let primaryPage = numberProperty(device, key: kIOHIDPrimaryUsagePageKey as CFString)
        let primaryUsage = numberProperty(device, key: kIOHIDPrimaryUsageKey as CFString)
        let identity = "\(product)|\(manufacturer)|\(transport)|\(primaryPage)|\(primaryUsage)"

        if loggedDevices.insert(identity).inserted {
            LogManager.shared.append(
                "发现 Consumer 0xCD 设备：\(product.isEmpty ? "未命名" : product)（\(transport)）",
                level: .info
            )
        }

        if let configured = UserDefaults.standard.string(forKey: "MagicKeyHeadsetProduct"),
           !configured.isEmpty {
            return product.localizedCaseInsensitiveContains(configured)
        }

        let name = "\(product) \(manufacturer)".lowercased()
        let keyboardWords = ["keyboard", "trackpad", "mouse", "magic keyboard", "internal keyboard"]
        if keyboardWords.contains(where: { name.contains($0) }) { return false }

        let headsetWords = ["headset", "headphone", "earphone", "earbud", "applehda", "audio", "line control", "headphone jack"]
        if headsetWords.contains(where: { name.contains($0) }) { return true }

        // A standalone Consumer Control top-level collection is the usual
        // representation for a wired headset button; keyboard consumer
        // controls generally remain under a keyboard collection.
        return primaryPage == Int64(targetUsagePage) && primaryUsage == 0x01
    }

    private func hasTargetButton(_ device: IOHIDDevice) -> Bool {
        guard let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] else {
            return false
        }
        return elements.contains {
            IOHIDElementGetUsagePage($0) == targetUsagePage &&
            IOHIDElementGetUsage($0) == targetUsage
        }
    }

    private func property(_ device: IOHIDDevice, key: CFString) -> String {
        (IOHIDDeviceGetProperty(device, key) as? String) ?? ""
    }

    private func numberProperty(_ device: IOHIDDevice, key: CFString) -> Int64 {
        (IOHIDDeviceGetProperty(device, key) as? NSNumber)?.int64Value ?? -1
    }

    private func deviceIdentity(_ device: IOHIDDevice) -> String {
        let product = property(device, key: kIOHIDProductKey as CFString)
        let vendor = numberProperty(device, key: kIOHIDVendorIDKey as CFString)
        let productID = numberProperty(device, key: kIOHIDProductIDKey as CFString)
        let location = numberProperty(device, key: kIOHIDLocationIDKey as CFString)
        return "\(vendor):\(productID):\(location):\(product)"
    }

    private func matchingDictionary(for device: IOHIDDevice) -> CFDictionary? {
        let product = property(device, key: kIOHIDProductKey as CFString)
        let vendor = numberProperty(device, key: kIOHIDVendorIDKey as CFString)
        let productID = numberProperty(device, key: kIOHIDProductIDKey as CFString)
        let primaryPage = numberProperty(device, key: kIOHIDPrimaryUsagePageKey as CFString)
        let primaryUsage = numberProperty(device, key: kIOHIDPrimaryUsageKey as CFString)
        guard !product.isEmpty || vendor >= 0 || productID >= 0 else { return nil }

        var dict: [String: Any] = [:]
        if !product.isEmpty { dict[kIOHIDProductKey as String] = product }
        if vendor >= 0 { dict[kIOHIDVendorIDKey as String] = NSNumber(value: vendor) }
        if productID >= 0 { dict[kIOHIDProductIDKey as String] = NSNumber(value: productID) }
        if primaryPage >= 0 { dict[kIOHIDPrimaryUsagePageKey as String] = NSNumber(value: primaryPage) }
        if primaryUsage >= 0 { dict[kIOHIDPrimaryUsageKey as String] = NSNumber(value: primaryUsage) }
        return dict as CFDictionary
    }

}
