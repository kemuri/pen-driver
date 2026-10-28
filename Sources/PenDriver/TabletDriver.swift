import CoreGraphics
import Foundation
import IOKit.hid
import os
import PenCore

struct TabletInfo: Identifiable, Equatable {
    enum Status: Equatable {
        case disabled
        case active(exclusive: Bool)
        case needsPermission
        case failed(IOReturn)
    }

    let id: UInt64
    var name: String
    var widthMM: Double
    var heightMM: Double
    var pressureLevels: Int?
    var status: Status
}

struct LiveState: Equatable {
    var inRange = false
    /// Pen position on the tablet, 0...1, in the orientation the user sees.
    var u = 0.0
    var v = 0.0
    var pressure = 0.0
    var tip = false
    var eraser = false
    var lower = false
    var upper = false
}

/// Reads pen reports and moves the pointer.
///
/// Everything latency-sensitive happens on one thread with a real-time (time-constraint)
/// scheduling policy: IOKit delivers each report straight into `handle`, which decodes it,
/// runs the click guard and posts the CGEvent before returning. No queues, no thread hops,
/// so a busy system can't delay the pointer the way it delays normal-priority threads.
final class TabletDriver: @unchecked Sendable {
    private static let vendorIDs = [0x056A /* Wacom */, 0x28BD /* XP-Pen */]
    private let log = Logger(subsystem: "express.looop.pendriver", category: "driver")

    // Shared with the main thread.
    private let configLock = OSAllocatedUnfairLock(initialState: PenConfig())
    private let liveLock = OSAllocatedUnfairLock(initialState: LiveState())
    var onTabletsChanged: (([TabletInfo]) -> Void)?

    // Owned by the HID thread.
    private var runLoop: CFRunLoop?
    private var manager: IOHIDManager?
    private var devices: [Device] = []
    private var enabled = false
    private var processor = PenProcessor()
    private let output = EventOutput()

    fileprivate final class Device {
        let ref: IOHIDDevice
        let id: UInt64
        let name: String
        let layouts: [PenLayout]
        let usesReportIDs: Bool
        let bufferSize: Int
        let buffer: UnsafeMutablePointer<UInt8>
        var openOptions: IOOptionBits?
        var status: TabletInfo.Status = .disabled
        unowned let driver: TabletDriver

        init(ref: IOHIDDevice, id: UInt64, name: String, parsed: HIDReportDescriptor.Parsed, bufferSize: Int, driver: TabletDriver) {
            self.ref = ref
            self.id = id
            self.name = name
            self.layouts = parsed.pens
            self.usesReportIDs = parsed.usesReportIDs
            self.bufferSize = bufferSize
            self.buffer = .allocate(capacity: bufferSize)
            self.driver = driver
        }

        deinit { buffer.deallocate() }

        @inline(__always) func layout(for reportID: UInt8) -> PenLayout? {
            for l in layouts where l.reportID == reportID { return l }
            return nil
        }

        var info: TabletInfo {
            let pen = layouts[0]
            let w = pen.widthMM ?? 224, h = pen.heightMM ?? w * Double(pen.y.logicalMax) / Double(max(pen.x.logicalMax, 1))
            return TabletInfo(id: id, name: name, widthMM: w, heightMM: h, pressureLevels: pen.pressureLevels, status: status)
        }
    }

    // MARK: Main-thread API

    func start() {
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            Realtime.promoteCurrentThread()
            runLoop = CFRunLoopGetCurrent()
            setUpManager()
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "PenDriver HID"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
    }

    func update(_ config: PenConfig) {
        configLock.withLock { $0 = config }
    }

    func setEnabled(_ on: Bool) {
        perform { [self] in
            guard on != enabled else { return }
            enabled = on
            if on {
                devices.forEach(open)
            } else {
                processor.releaseAll(emit: output.post)
                devices.forEach(close)
                liveLock.withLock { $0 = LiveState() }
            }
            publishTablets()
        }
    }

    /// Try again to open devices that failed, e.g. after Input Monitoring was granted,
    /// and to take exclusive control of ones we had to share (e.g. after OpenTabletDriver quit).
    func retryFailedDevices() {
        perform { [self] in
            guard enabled else { return }
            for d in devices where d.status == .active(exclusive: false) {
                processor.releaseAll(emit: output.post)
                close(d)
            }
            for d in devices where d.openOptions == nil { open(d) }
            publishTablets()
        }
    }

    var live: LiveState { liveLock.withLock { $0 } }

    // MARK: HID thread

    private func perform(_ block: @escaping () -> Void) {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    private func setUpManager() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching = Self.vendorIDs.map { [kIOHIDVendorIDKey: $0] as CFDictionary }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            Unmanaged<TabletDriver>.fromOpaque(context!).takeUnretainedValue().deviceAdded(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            Unmanaged<TabletDriver>.fromOpaque(context!).takeUnretainedValue().deviceRemoved(device)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        self.manager = manager
    }

    private func deviceAdded(_ ref: IOHIDDevice) {
        guard let descriptor = IOHIDDeviceGetProperty(ref, kIOHIDReportDescriptorKey as CFString) as? Data else { return }
        let parsed = HIDReportDescriptor.parse([UInt8](descriptor))
        guard !parsed.pens.isEmpty else { return }  // touch, express keys, vendor interfaces

        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(ref), &id)
        let maxReport = IOHIDDeviceGetProperty(ref, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 64
        let device = Device(ref: ref, id: id, name: Self.displayName(ref), parsed: parsed,
                            bufferSize: max(maxReport, 64), driver: self)
        devices.append(device)
        log.info("Tablet attached: \(device.name, privacy: .public), \(parsed.pens.count) pen report(s)")
        if enabled { open(device) }
        publishTablets()
    }

    private func deviceRemoved(_ ref: IOHIDDevice) {
        guard let index = devices.firstIndex(where: { $0.ref == ref }) else { return }
        let device = devices.remove(at: index)
        close(device)
        processor.releaseAll(emit: output.post)
        liveLock.withLock { $0 = LiveState() }
        publishTablets()
    }

    private func open(_ d: Device) {
        guard d.openOptions == nil else { return }
        // Seize the pen interface so macOS doesn't also drive the pointer from it.
        let seize = IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
        var options = seize
        var result = IOHIDDeviceOpen(d.ref, options)
        if result != kIOReturnSuccess {
            log.error("Exclusive open failed (\(String(format: "0x%08x", result), privacy: .public)), trying shared")
            options = 0
            result = IOHIDDeviceOpen(d.ref, options)
        }
        guard result == kIOReturnSuccess else {
            d.status = result == kIOReturnNotPermitted ? .needsPermission : .failed(result)
            log.error("Open failed: \(String(format: "0x%08x", result), privacy: .public)")
            return
        }
        d.openOptions = options
        d.status = .active(exclusive: options == seize)
        IOHIDDeviceRegisterInputReportCallback(d.ref, d.buffer, d.bufferSize, { context, _, _, _, _, report, length in
            let device = Unmanaged<Device>.fromOpaque(context!).takeUnretainedValue()
            device.driver.handle(device, report, length)
        }, Unmanaged.passUnretained(d).toOpaque())
    }

    private func close(_ d: Device) {
        guard let options = d.openOptions else { return }
        IOHIDDeviceRegisterInputReportCallback(d.ref, d.buffer, d.bufferSize, nil, nil)
        IOHIDDeviceClose(d.ref, options)
        d.openOptions = nil
        d.status = .disabled
    }

    /// Hot path: called by IOKit for every report, on the real-time thread.
    @inline(__always)
    private func handle(_ d: Device, _ report: UnsafeMutablePointer<UInt8>, _ length: CFIndex) {
        guard enabled, length > 0, let layout = d.layout(for: d.usesReportIDs ? report[0] : 0) else { return }
        let sample = layout.decode(report, length)
        let config = configLock.withLock { $0 }
        processor.process(sample, config: config, now: clock_gettime_nsec_np(CLOCK_UPTIME_RAW), emit: output.post)

        var u = sample.x, v = sample.y
        if config.leftHanded { u = 1 - u; v = 1 - v }
        let state = LiveState(
            inRange: sample.inRange, u: u, v: v, pressure: max(sample.pressure, 0),
            tip: processor.isTouching && !processor.isErasing, eraser: processor.isErasing,
            lower: sample.inRange && sample.barrel, upper: sample.inRange && sample.secondaryBarrel)
        liveLock.withLock { $0 = state }
    }

    private func publishTablets() {
        let infos = devices.map(\.info)
        DispatchQueue.main.async { [weak self] in self?.onTabletsChanged?(infos) }
    }

    private static func displayName(_ ref: IOHIDDevice) -> String {
        let product = (IOHIDDeviceGetProperty(ref, kIOHIDProductKey as CFString) as? String)?
            .trimmingCharacters(in: .whitespaces) ?? "Tablet"
        let vendorID = IOHIDDeviceGetProperty(ref, kIOHIDVendorIDKey as CFString) as? Int
        let vendor = vendorID == 0x056A ? "Wacom" : vendorID == 0x28BD ? "XP-Pen" : nil
        if let vendor, !product.localizedCaseInsensitiveContains(vendor) { return "\(vendor) \(product)" }
        return product
    }
}

/// Posts pointer events into the HID event stream, like a real mouse.
final class EventOutput {
    private let source = CGEventSource(stateID: .hidSystemState)
    private var last: CGPoint?

    func post(_ event: PenEvent) {
        let cg: CGEvent?
        switch event {
        case let .move(p, held):
            let type: CGEventType, button: Int
            if held & 1 != 0 { (type, button) = (.leftMouseDragged, 0) }
            else if held & 2 != 0 { (type, button) = (.rightMouseDragged, 1) }
            else if held != 0 { (type, button) = (.otherMouseDragged, held.trailingZeroBitCount) }
            else { (type, button) = (.mouseMoved, 0) }
            cg = make(type, p, button)
            if let last {
                cg?.setIntegerValueField(.mouseEventDeltaX, value: Int64((p.x - last.x).rounded()))
                cg?.setIntegerValueField(.mouseEventDeltaY, value: Int64((p.y - last.y).rounded()))
            }
            if held != 0 { cg?.flags = CGEventSource.flagsState(.hidSystemState) }
            last = p
        case let .down(button, p, clicks, _):
            cg = make(button == 0 ? .leftMouseDown : button == 1 ? .rightMouseDown : .otherMouseDown, p, button)
            cg?.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
            cg?.flags = CGEventSource.flagsState(.hidSystemState)
        case let .up(button, p, clicks, _):
            cg = make(button == 0 ? .leftMouseUp : button == 1 ? .rightMouseUp : .otherMouseUp, p, button)
            cg?.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
            cg?.flags = CGEventSource.flagsState(.hidSystemState)
        }
        cg?.post(tap: .cghidEventTap)
    }

    private func make(_ type: CGEventType, _ p: CGPoint, _ button: Int) -> CGEvent? {
        let cg = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p,
                         mouseButton: CGMouseButton(rawValue: UInt32(button)) ?? .center)
        if button > 1 { cg?.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button)) }
        return cg
    }
}

enum Realtime {
    nonisolated(unsafe) static var lastResult: kern_return_t = -1

    /// Time-constraint policy: the scheduler runs this thread ahead of all normal work.
    /// Budget is generous for decoding a report and posting one event (~tens of µs).
    static func promoteCurrentThread() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ms = 1_000_000 * Double(timebase.denom) / Double(timebase.numer)
        var policy = thread_time_constraint_policy_data_t(
            period: UInt32(4 * ms), computation: UInt32(1 * ms), constraint: UInt32(3 * ms), preemptible: 1)
        let count = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &policy) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_policy_set(pthread_mach_thread_np(pthread_self()), thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, count)
            }
        }
        lastResult = result
        if result != KERN_SUCCESS {
            Logger(subsystem: "express.looop.pendriver", category: "driver").error("Real-time policy failed: \(result)")
        }
    }
}
