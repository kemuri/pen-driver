import CoreGraphics
import IOKit.hid

/// Modifier keys as physically held, read from the keyboards themselves, so a ⌘-click with the pen
/// works. Not `CGEventSource` state: the events we post carry flags that feed back into it, so a
/// modifier released mid-drag (⌥ for a window resize) stayed held on every later click.
/// Lives on the HID thread, like the event output that reads it.
final class KeyboardModifiers {
    private(set) var flags: CGEventFlags = .maskNonCoalesced
    private var manager: IOHIDManager?
    /// Held keys per keyboard, as usage page << 16 | usage.
    private var held: [IOHIDDevice: Set<UInt32>] = [:]

    private static let keyboardPage: UInt32 = 0x07
    private static let appleTopCasePage: UInt32 = 0xFF, appleKeyboardPage: UInt32 = 0xFF01, fnUsage: UInt32 = 0x03

    /// Starts listening on the current run loop.
    func start() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard,
        ] as CFDictionary)
        IOHIDManagerSetInputValueMatchingMultiple(manager, [
            [kIOHIDElementUsagePageKey: Self.keyboardPage,
             kIOHIDElementUsageMinKey: kHIDUsage_KeyboardLeftControl, kIOHIDElementUsageMaxKey: kHIDUsage_KeyboardRightGUI],
            [kIOHIDElementUsagePageKey: Self.appleTopCasePage, kIOHIDElementUsageKey: Self.fnUsage],
            [kIOHIDElementUsagePageKey: Self.appleKeyboardPage, kIOHIDElementUsageKey: Self.fnUsage],
        ] as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            Unmanaged<KeyboardModifiers>.fromOpaque(context!).takeUnretainedValue().changed(value)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            let me = Unmanaged<KeyboardModifiers>.fromOpaque(context!).takeUnretainedValue()
            me.held[device] = nil
            me.update()
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
    }

    private func changed(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let key = IOHIDElementGetUsagePage(element) << 16 | IOHIDElementGetUsage(element)
        let device = IOHIDElementGetDevice(element)
        if IOHIDValueGetIntegerValue(value) != 0 {
            held[device, default: []].insert(key)
        } else {
            held[device]?.remove(key)
        }
        update()
    }

    private func update() {
        var f: CGEventFlags = .maskNonCoalesced
        for key in held.values.joined() {
            // Device-dependent bits too (left/right side), as a real keyboard sets them.
            switch key {
            case Self.keyboardPage << 16 | 0xE0: f.formUnion([.maskControl, CGEventFlags(rawValue: 0x0001)])
            case Self.keyboardPage << 16 | 0xE1: f.formUnion([.maskShift, CGEventFlags(rawValue: 0x0002)])
            case Self.keyboardPage << 16 | 0xE2: f.formUnion([.maskAlternate, CGEventFlags(rawValue: 0x0020)])
            case Self.keyboardPage << 16 | 0xE3: f.formUnion([.maskCommand, CGEventFlags(rawValue: 0x0008)])
            case Self.keyboardPage << 16 | 0xE4: f.formUnion([.maskControl, CGEventFlags(rawValue: 0x2000)])
            case Self.keyboardPage << 16 | 0xE5: f.formUnion([.maskShift, CGEventFlags(rawValue: 0x0004)])
            case Self.keyboardPage << 16 | 0xE6: f.formUnion([.maskAlternate, CGEventFlags(rawValue: 0x0040)])
            case Self.keyboardPage << 16 | 0xE7: f.formUnion([.maskCommand, CGEventFlags(rawValue: 0x0010)])
            default: f.insert(.maskSecondaryFn)
            }
        }
        flags = f
    }
}
