import CoreGraphics

/// One decoded pen report, device-independent.
public struct PenSample: Equatable, Sendable {
    /// Position across the whole tablet surface, 0...1, in the tablet's native orientation.
    public var x: Double
    public var y: Double
    /// 0...1, or -1 if the device reports no pressure.
    public var pressure: Double
    public var tipSwitch: Bool
    public var inRange: Bool
    /// Lower side button.
    public var barrel: Bool
    /// Upper side button.
    public var secondaryBarrel: Bool
    /// The eraser end is the one near the tablet.
    public var eraser: Bool

    public init(x: Double, y: Double, pressure: Double = 0, tipSwitch: Bool = false, inRange: Bool = true,
                barrel: Bool = false, secondaryBarrel: Bool = false, eraser: Bool = false) {
        self.x = x; self.y = y; self.pressure = pressure; self.tipSwitch = tipSwitch; self.inRange = inRange
        self.barrel = barrel; self.secondaryBarrel = secondaryBarrel; self.eraser = eraser
    }
}

public enum ButtonAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case nothing, leftClick, rightClick, middleClick, back, forward

    public var id: Self { self }

    public var title: String {
        switch self {
        case .nothing: "Nothing"
        case .leftClick: "Left click"
        case .rightClick: "Right click"
        case .middleClick: "Middle click"
        case .back: "Back"
        case .forward: "Forward"
        }
    }

    /// CGEvent mouse button number.
    public var mouseButton: Int? {
        switch self {
        case .nothing: nil
        case .leftClick: 0
        case .rightClick: 1
        case .middleClick: 2
        case .back: 3
        case .forward: 4
        }
    }
}

/// A display as placed in the tablet's arrangement, and where it really is on screen.
/// The two differ when the user arranges displays differently for the tablet than in macOS.
public struct DisplaySegment: Equatable, Sendable {
    public var layout: CGRect
    public var screen: CGRect

    public init(layout: CGRect, screen: CGRect) {
        self.layout = layout
        self.screen = screen
    }
}

public struct PenConfig: Equatable, Sendable {
    /// Active part of the tablet, normalized 0...1, in the orientation the user sees.
    public var area = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// Tablet used upside down: rotate input 180°.
    public var leftHanded = false
    /// What the area maps onto: the bounding box of `segments` in layout space, or, without
    /// segments, a rectangle in global display coordinates (points, top-left origin).
    public var target = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    /// Mapped displays. Points falling between displays go to the nearest one.
    public var segments: [DisplaySegment] = []
    /// Pressure (0...1) needed to press the tip.
    public var tipThreshold = 0.10
    /// Click guard: how far (points) the pen may wobble after touching down before it becomes a drag. 0 = off.
    public var tapRadius = 7.0
    /// Right after touchdown the pen wobbles most, so the radius is larger for this long.
    public var tapGraceNs: UInt64 = 150_000_000
    public var doubleClickNs: UInt64 = 500_000_000
    public var upper: ButtonAction = .rightClick
    public var lower: ButtonAction = .middleClick
    public var eraser: ButtonAction = .leftClick

    public init() {}
}

public enum PenEvent: Equatable, Sendable {
    /// `held` is a bitmask of mouse buttons currently down (bit n = button n).
    case move(CGPoint, held: UInt8)
    case down(button: Int, at: CGPoint, clicks: Int, held: UInt8)
    case up(button: Int, at: CGPoint, clicks: Int, held: UInt8)
}

/// Turns pen samples into pointer events: area mapping, tip threshold with hysteresis,
/// click guard (tap stability), side buttons and click counting.
/// Allocation-free per sample; meant to run on the real-time HID thread.
public struct PenProcessor {
    private enum Source: UInt8 { case tip = 1, eraser = 2, lower = 4, upper = 8 }
    private struct ClickRecord { var time: UInt64 = 0; var point = CGPoint.zero; var count = 0 }

    private var contact: Source?
    private var contactAction: ButtonAction = .nothing
    private var pinned = false
    private var anchor = CGPoint.zero
    private var downTime: UInt64 = 0
    private var lowerAction: ButtonAction?
    private var upperAction: ButtonAction?
    /// Which sources hold each mouse button down.
    private var sources = SIMD8<UInt8>()
    private var held: UInt8 = 0
    private var clicks = ContiguousArray(repeating: ClickRecord(), count: 5)

    public private(set) var cursor: CGPoint?
    public var isTouching: Bool { contact != nil }
    public var isErasing: Bool { contact == .eraser }

    public init() {}

    /// Screen point for a sample, in global display coordinates.
    public static func map(_ s: PenSample, _ c: PenConfig) -> CGPoint {
        var u = s.x, v = s.y
        if c.leftHanded { u = 1 - u; v = 1 - v }
        return toScreen(layoutPoint(u: u, v: v, c), c)
    }

    /// Point in layout space for a tablet position that is already oriented (left-handed applied).
    public static func layoutPoint(u: Double, v: Double, _ c: PenConfig) -> CGPoint {
        let a = c.area
        let sx = min(max((u - a.minX) / max(a.width, 1e-6), 0), 1)
        let sy = min(max((v - a.minY) / max(a.height, 1e-6), 0), 1)
        return CGPoint(x: c.target.minX + sx * max(c.target.width - 1, 0),
                       y: c.target.minY + sy * max(c.target.height - 1, 0))
    }

    /// Layout space → global display coordinates, via the nearest display.
    public static func toScreen(_ p: CGPoint, _ c: PenConfig) -> CGPoint {
        guard !c.segments.isEmpty else { return p }
        var best = p, bestDistance = Double.infinity
        for seg in c.segments {
            let x = min(max(p.x, seg.layout.minX), seg.layout.maxX - 1)
            let y = min(max(p.y, seg.layout.minY), seg.layout.maxY - 1)
            let d = (x - p.x) * (x - p.x) + (y - p.y) * (y - p.y)
            if d < bestDistance {
                bestDistance = d
                best = CGPoint(x: x - seg.layout.minX + seg.screen.minX, y: y - seg.layout.minY + seg.screen.minY)
                if d == 0 { break }
            }
        }
        return best
    }

    public mutating func process(_ s: PenSample, config c: PenConfig, now: UInt64, emit: (PenEvent) -> Void) {
        guard s.inRange else { releaseAll(emit: emit); return }
        let p = Self.map(s, c)

        let pressed: Bool
        if s.pressure >= 0 {
            // Hysteresis so pressure hovering around the threshold doesn't chatter.
            pressed = s.pressure >= (contact == nil ? c.tipThreshold : max(c.tipThreshold * 0.75, 0.002))
        } else {
            pressed = s.tipSwitch
        }

        // Lift.
        if let src = contact, !pressed {
            if !pinned { moveTo(p, emit) }
            if let mb = contactAction.mouseButton { release(src, mb, emit) }
            contact = nil
            pinned = false
        }

        // Movement. While pinned, the pointer stays at the touchdown point until the pen
        // clearly moves away; a tap with some wobble stays a clean click.
        if contact != nil {
            if pinned {
                let radius = now &- downTime < c.tapGraceNs ? c.tapRadius * 2.5 : c.tapRadius
                if distance(p, anchor) > radius { pinned = false }
            }
            moveTo(pinned ? anchor : p, emit)
        } else if !pressed {
            moveTo(p, emit)
        }

        // Touchdown.
        if contact == nil, pressed {
            let src: Source = s.eraser ? .eraser : .tip
            let action = src == .eraser ? c.eraser : .leftClick
            var point = p
            // Second tap of a double-click lands exactly on the first one.
            let snap = c.tapRadius * 2.5
            if snap > 0, let mb = action.mouseButton {
                let last = clicks[mb]
                if last.count > 0, now &- last.time <= c.doubleClickNs, distance(p, last.point) <= snap { point = last.point }
            }
            moveTo(point, emit)
            contact = src
            contactAction = action
            pinned = c.tapRadius > 0
            anchor = point
            downTime = now
            if let mb = action.mouseButton { press(src, mb, c, now, emit) }
        }

        // Side buttons (ignored while the eraser end is in use).
        var lower = lowerAction, upper = upperAction
        side(.lower, isDown: s.barrel && !s.eraser, action: c.lower, state: &lower, c, now, emit)
        side(.upper, isDown: s.secondaryBarrel && !s.eraser, action: c.upper, state: &upper, c, now, emit)
        lowerAction = lower
        upperAction = upper
    }

    /// Lets go of everything, e.g. when the pen leaves the tablet or the driver is disabled.
    public mutating func releaseAll(emit: (PenEvent) -> Void) {
        if let src = contact, let mb = contactAction.mouseButton { release(src, mb, emit) }
        if let a = lowerAction, let mb = a.mouseButton { release(.lower, mb, emit) }
        if let a = upperAction, let mb = a.mouseButton { release(.upper, mb, emit) }
        contact = nil
        pinned = false
        lowerAction = nil
        upperAction = nil
    }

    private mutating func side(_ src: Source, isDown: Bool, action: ButtonAction, state: inout ButtonAction?,
                               _ c: PenConfig, _ now: UInt64, _ emit: (PenEvent) -> Void) {
        if isDown, state == nil {
            state = action
            if let mb = action.mouseButton { press(src, mb, c, now, emit) }
        } else if !isDown, let held = state {
            state = nil
            if let mb = held.mouseButton { release(src, mb, emit) }
        }
    }

    private mutating func press(_ src: Source, _ mb: Int, _ c: PenConfig, _ now: UInt64, _ emit: (PenEvent) -> Void) {
        let wasDown = sources[mb] != 0
        sources[mb] |= src.rawValue
        guard !wasDown else { return }
        held |= 1 << UInt8(mb)
        let at = cursor ?? anchor
        let last = clicks[mb]
        let nearby = distance(at, last.point) <= max(6, c.tapRadius * 2.5)
        let count = last.count > 0 && now &- last.time <= c.doubleClickNs && nearby ? last.count + 1 : 1
        clicks[mb] = ClickRecord(time: now, point: at, count: count)
        emit(.down(button: mb, at: at, clicks: count, held: held))
    }

    private mutating func release(_ src: Source, _ mb: Int, _ emit: (PenEvent) -> Void) {
        guard sources[mb] & src.rawValue != 0 else { return }
        sources[mb] &= ~src.rawValue
        guard sources[mb] == 0 else { return }
        held &= ~(1 << UInt8(mb))
        emit(.up(button: mb, at: cursor ?? anchor, clicks: clicks[mb].count, held: held))
    }

    private mutating func moveTo(_ point: CGPoint, _ emit: (PenEvent) -> Void) {
        if let cur = cursor, abs(cur.x - point.x) < 0.01, abs(cur.y - point.y) < 0.01 { return }
        cursor = point
        emit(.move(point, held: held))
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = a.x - b.x, dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }
}
