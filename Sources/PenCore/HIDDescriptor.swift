import Foundation

/// One variable input field from a HID report descriptor.
public struct HIDField: Equatable, Sendable {
    /// `page << 16 | usage`, after mapping vendor pages onto their standard equivalents.
    public var usage: UInt32
    /// Bit offset from the start of the report buffer (including the report ID byte, if any).
    public var bitOffset: Int
    public var bitSize: Int
    public var logicalMin: Int64
    public var logicalMax: Int64
    public var physicalMin: Int64
    public var physicalMax: Int64
    public var unit: UInt32
    public var unitExponent: Int

    @inline(__always)
    public func read(_ p: UnsafePointer<UInt8>, _ length: Int) -> Int64 {
        let start = bitOffset >> 3
        let shift = bitOffset & 7
        let byteCount = (shift + bitSize + 7) >> 3
        guard bitSize > 0, bitSize <= 32, start + byteCount <= length else { return 0 }
        var raw: UInt64 = 0
        for i in 0..<byteCount { raw |= UInt64(p[start + i]) << (8 * i) }
        raw = (raw >> shift) & ((1 << UInt64(bitSize)) - 1)
        if logicalMin < 0, raw & (1 << UInt64(bitSize - 1)) != 0 {
            return Int64(raw) - (1 << Int64(bitSize))
        }
        return Int64(raw)
    }

    /// Value scaled to 0...1 across the logical range.
    @inline(__always)
    public func normalized(_ p: UnsafePointer<UInt8>, _ length: Int) -> Double {
        let span = Double(logicalMax - logicalMin)
        guard span > 0 else { return 0 }
        return min(max(Double(read(p, length) - logicalMin) / span, 0), 1)
    }

    /// Physical extent in millimetres, if the descriptor declares a length unit.
    public var physicalLengthMM: Double? {
        let span = Double(physicalMax - physicalMin)
        guard span > 0 else { return nil }
        let scale: Double
        switch unit {
        case 0x11: scale = 10      // SI linear, centimetres
        case 0x13: scale = 25.4    // English linear, inches
        default: return nil
        }
        return span * pow(10, Double(unitExponent)) * scale
    }
}

/// What one pen report looks like, derived from the descriptor.
public struct PenLayout: Sendable {
    public var reportID: UInt8
    public var x: HIDField
    public var y: HIDField
    public var pressure: HIDField?
    public var tipSwitch: HIDField?
    public var barrel: HIDField?
    public var secondaryBarrel: HIDField?
    public var eraser: HIDField?
    public var invert: HIDField?
    public var inRange: HIDField?

    public var widthMM: Double? { x.physicalLengthMM }
    public var heightMM: Double? { y.physicalLengthMM }
    public var pressureLevels: Int? { pressure.map { Int($0.logicalMax - $0.logicalMin) + 1 } }

    @inline(__always)
    public func decode(_ p: UnsafePointer<UInt8>, _ length: Int) -> PenSample {
        @inline(__always) func bit(_ f: HIDField?) -> Bool { f.map { $0.read(p, length) != 0 } ?? false }
        let eraserEnd = bit(invert) || bit(eraser)
        return PenSample(
            x: x.normalized(p, length),
            y: y.normalized(p, length),
            pressure: pressure.map { $0.normalized(p, length) } ?? -1,
            tipSwitch: bit(tipSwitch) || bit(eraser),
            inRange: inRange.map { $0.read(p, length) != 0 } ?? true,
            barrel: bit(barrel),
            secondaryBarrel: bit(secondaryBarrel),
            eraser: eraserEnd
        )
    }
}

public enum HIDReportDescriptor {
    public struct Parsed: Sendable {
        public var usesReportIDs: Bool
        public var pens: [PenLayout]
    }

    // Standard usages (page << 16 | id).
    static let genericDesktopX: UInt32 = 0x0001_0030
    static let genericDesktopY: UInt32 = 0x0001_0031
    static let digitizer: UInt32 = 0x000D_0001
    static let pen: UInt32 = 0x000D_0002
    static let touchScreen: UInt32 = 0x000D_0004
    static let touchPad: UInt32 = 0x000D_0005
    static let stylus: UInt32 = 0x000D_0020
    static let finger: UInt32 = 0x000D_0022
    static let tipPressure: UInt32 = 0x000D_0030
    static let inRange: UInt32 = 0x000D_0032
    static let invert: UInt32 = 0x000D_003C
    static let tipSwitch: UInt32 = 0x000D_0042
    static let barrelSwitch: UInt32 = 0x000D_0044
    static let eraser: UInt32 = 0x000D_0045
    static let secondaryBarrelSwitch: UInt32 = 0x000D_005A

    /// Wacom puts its pen data on vendor page 0xFF0D, where the high byte of the usage
    /// selects a standard page (0x00 → Digitizer, 0x01 → Generic Desktop) and the low
    /// byte is the usage on that page. This is the same mapping Linux uses.
    static func equivalent(_ usage: UInt32) -> UInt32 {
        guard usage >> 16 == 0xFF0D else { return usage }
        let low = usage & 0xFF
        switch (usage >> 8) & 0xFF {
        case 0x00: return 0x000D_0000 | low
        case 0x01: return 0x0001_0000 | low
        default: return usage
        }
    }

    public static func parse(_ d: [UInt8]) -> Parsed {
        struct Globals {
            var page: UInt32 = 0
            var logicalMin: Int64 = 0
            var logicalMaxSigned: Int64 = 0
            var logicalMaxUnsigned: Int64 = 0
            var physicalMin: Int64 = 0
            var physicalMaxSigned: Int64 = 0
            var physicalMaxUnsigned: Int64 = 0
            var unit: UInt32 = 0
            var unitExponent = 0
            var reportSize = 0
            var reportCount = 0
            var reportID: UInt8 = 0
        }
        struct Found { var reportID: UInt8; var path: [UInt32]; var field: HIDField }

        var g = Globals()
        var globalStack: [Globals] = []
        var usages: [UInt32] = []
        var usageMin: UInt32?
        var usageMax: UInt32?
        var collections: [UInt32] = []
        var offsets: [UInt8: Int] = [:]
        var usesReportIDs = false
        var found: [Found] = []

        func clearLocals() { usages.removeAll(keepingCapacity: true); usageMin = nil; usageMax = nil }

        var i = 0
        while i < d.count {
            let prefix = d[i]
            if prefix == 0xFE {  // long item
                guard i + 1 < d.count else { break }
                i += 3 + Int(d[i + 1])
                continue
            }
            let size = [0, 1, 2, 4][Int(prefix & 3)]
            guard i + 1 + size <= d.count else { break }
            var u: UInt32 = 0
            for k in 0..<size { u |= UInt32(d[i + 1 + k]) << (8 * k) }
            var s = Int64(u)
            if size > 0, s & (1 << Int64(size * 8 - 1)) != 0 { s -= 1 << Int64(size * 8) }
            let tag = prefix >> 4
            i += 1 + size

            switch (prefix >> 2) & 3 {
            case 0:  // main
                switch tag {
                case 0x8:  // Input
                    let base = offsets[g.reportID, default: 0]
                    let isConstant = u & 1 != 0, isVariable = u & 2 != 0
                    if !isConstant, isVariable, g.reportSize > 0 {
                        var list = usages
                        if list.isEmpty, let lo = usageMin, let hi = usageMax, hi >= lo {
                            let last = min(hi, lo &+ UInt32(max(g.reportCount - 1, 0)))
                            list = Array(lo...last)
                        }
                        if !list.isEmpty {
                            let logicalMax = g.logicalMin < 0 ? g.logicalMaxSigned : g.logicalMaxUnsigned
                            let physicalMax = g.physicalMin < 0 ? g.physicalMaxSigned : g.physicalMaxUnsigned
                            for k in 0..<g.reportCount {
                                let field = HIDField(
                                    usage: equivalent(list[min(k, list.count - 1)]),
                                    bitOffset: base + k * g.reportSize,
                                    bitSize: g.reportSize,
                                    logicalMin: g.logicalMin, logicalMax: logicalMax,
                                    physicalMin: g.physicalMin, physicalMax: physicalMax,
                                    unit: g.unit, unitExponent: g.unitExponent)
                                found.append(Found(reportID: g.reportID, path: collections, field: field))
                            }
                        }
                    }
                    offsets[g.reportID] = base + g.reportCount * g.reportSize
                    clearLocals()
                case 0xA:  // Collection
                    collections.append(equivalent(usages.first ?? 0))
                    clearLocals()
                case 0xC:  // End Collection
                    _ = collections.popLast()
                    clearLocals()
                default:  // Output, Feature
                    clearLocals()
                }
            case 1:  // global
                switch tag {
                case 0x0: g.page = u
                case 0x1: g.logicalMin = s
                case 0x2: g.logicalMaxSigned = s; g.logicalMaxUnsigned = Int64(u)
                case 0x3: g.physicalMin = s
                case 0x4: g.physicalMaxSigned = s; g.physicalMaxUnsigned = Int64(u)
                case 0x5: let n = Int(u & 0xF); g.unitExponent = n > 7 ? n - 16 : n
                case 0x6: g.unit = u
                case 0x7: g.reportSize = Int(u)
                case 0x8: g.reportID = UInt8(truncatingIfNeeded: u); usesReportIDs = true
                case 0x9: g.reportCount = Int(u)
                case 0xA: globalStack.append(g)
                case 0xB: if let top = globalStack.popLast() { g = top }
                default: break
                }
            case 2:  // local
                let full = size == 4 ? u : (g.page << 16) | u
                switch tag {
                case 0x0: usages.append(full)
                case 0x1: usageMin = full
                case 0x2: usageMax = full
                default: break
                }
            default:
                break
            }
        }

        let idBits = usesReportIDs ? 8 : 0
        var pens: [PenLayout] = []
        let reportIDs = Array(Set(found.map(\.reportID))).sorted()
        for id in reportIDs {
            let fields = found
                .filter { $0.reportID == id && isPenCollection($0.path) }
                .map { f -> HIDField in var field = f.field; field.bitOffset += idBits; return field }
            func first(_ usage: UInt32) -> HIDField? { fields.first { $0.usage == usage } }
            guard let x = first(genericDesktopX), let y = first(genericDesktopY) else { continue }
            pens.append(PenLayout(
                reportID: id, x: x, y: y,
                pressure: first(tipPressure),
                tipSwitch: first(tipSwitch),
                barrel: first(barrelSwitch),
                secondaryBarrel: first(secondaryBarrelSwitch),
                eraser: first(eraser),
                invert: first(invert),
                inRange: first(inRange)))
        }
        return Parsed(usesReportIDs: usesReportIDs, pens: pens)
    }

    /// Pen data lives under a Digitizer/Pen/Stylus collection; finger and touch surfaces are skipped.
    static func isPenCollection(_ path: [UInt32]) -> Bool {
        let excluded: Set<UInt32> = [finger, touchScreen, touchPad]
        return path.contains { $0 == digitizer || $0 == pen || $0 == stylus }
            && !path.contains { excluded.contains($0) }
    }
}
