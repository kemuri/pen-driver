import AppKit
import MetalKit
import SwiftUI

// MARK: - Tuning

/// The dot grid, tuned live from the Dots window. Heights and lengths are in points.
struct DotTuning: Equatable {
    var spacing = 7.0
    var dotSize = 1.1
    var majorEvery = 5.0
    var majorPattern = 0.0
    var majorSize = 1.9
    var brightness = 0.32
    var majorBrightness = 0.6
    var groundRelief = 8.0
    var groundScale = 150.0
    var drift = 3.0
    var tilt = 0.0
    var turn = 0.0
    var perspective = 0.5
    var fog = 0.5
    var hoverHeight = 8.0
    var hoverRadius = 40.0
    var hoverLag = 0.1
    var hoverTint = 0.85
    /// On: the pen shows as the grid's dot nearest it, turned yellow, rather than a dot of its own.
    var gridCursor = 1.0
    var penTilt = 1.0
    var push = 3.0
    var sweep = 2.5
    var settle = 0.45
    var bounce = 0.4
    var hillHeight = 60.0
    var hillRadius = 46.0
    var pressureGrowsRadius = 0.5
    var pressureCurve = 0.7
    var clickStrength = 0.15
    var holdToGrow = 1.2
    var leanStretch = 2.5
    var clicksAnywhere = 1.0
    var riseTime = 0.2
    var fadeHalfLife = 2.5
    var heightGrows = 1.0
    var heightBrightens = 0.6
    var shading = 0.5

    enum MajorPattern: Int { case lines, crossings }
    var pattern: MajorPattern { MajorPattern(rawValue: Int(majorPattern)) ?? .lines }

    /// What leaning the pen does. In mouse mode apps don't get the lean, so it does nothing.
    enum PenTilt: Int {
        case off
        /// Hills stretch out the way the pen leans, longer the further it leans.
        case shapesHills
        /// The view tilts as far as the pen leans, turned the way it leans.
        case steersView
    }
    var penTiltUse: PenTilt { PenTilt(rawValue: Int(penTilt)) ?? .off }
}

extension DotTuning: Tunable {
    static let sections: [(title: String, parameters: [TuningParameter<DotTuning>])] = {
        func points(_ v: Double) -> String { String(format: "%.1f pt", v) }
        func degrees(_ v: Double) -> String { String(format: "%.0f°", v) }
        func seconds(_ v: Double) -> String { v == 0 ? "Instant" : String(format: "%.2f s", v) }
        func percent(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }
        typealias P = TuningParameter<DotTuning>
        return [
            ("Grid", [
                P(key: "spacing", title: "Spacing", keyPath: \.spacing, range: 3...24, format: points),
                P(key: "dotSize", title: "Dot size", keyPath: \.dotSize, range: 0.3...5, format: points),
                P(key: "brightness", title: "Brightness", keyPath: \.brightness, range: 0.05...1, format: percent),
                P(key: "majorEvery", title: "Bigger dot every", keyPath: \.majorEvery, range: 0...10, step: 1,
                  format: { $0 == 0 ? "Off" : String(format: "%.0f dots", $0) }),
                .choice("majorPattern", "Bigger dots", \.majorPattern, ["On the lines", "At the crossings"]),
                P(key: "majorSize", title: "Bigger dot size", keyPath: \.majorSize, range: 0.3...8, format: points),
                P(key: "majorBrightness", title: "Bigger dot brightness", keyPath: \.majorBrightness, range: 0.05...1, format: percent),
            ]),
            ("Ground", [
                P(key: "groundRelief", title: "Relief", keyPath: \.groundRelief, range: 0...40, format: points),
                P(key: "groundScale", title: "Feature size", keyPath: \.groundScale, range: 20...300, format: points),
                P(key: "drift", title: "Drift", keyPath: \.drift, range: 0...40,
                  format: { $0 == 0 ? "Still" : String(format: "%.1f pt/s", $0) }),
            ]),
            ("View", [
                P(key: "tilt", title: "Tilt", keyPath: \.tilt, range: 0...80, format: degrees),
                P(key: "turn", title: "Turn", keyPath: \.turn, range: -180...180, format: degrees),
                P(key: "perspective", title: "Perspective", keyPath: \.perspective, range: 0...1, format: percent),
                P(key: "fog", title: "Fog at the back", keyPath: \.fog, range: 0...1, format: percent),
            ]),
            ("Pointer", [
                P(key: "hoverHeight", title: "Height", keyPath: \.hoverHeight, range: -30...40, format: points),
                P(key: "hoverRadius", title: "Radius", keyPath: \.hoverRadius, range: 10...150, format: points),
                P(key: "hoverLag", title: "Follow lag", keyPath: \.hoverLag, range: 0...1, format: seconds),
                P(key: "hoverTint", title: "Highlight without pressure", keyPath: \.hoverTint, range: 0...1, format: percent),
                .choice("gridCursor", "Nearest dot shows the pen", \.gridCursor, ["Off", "On"]),
                .choice("penTilt", "Leaning the pen, in tablet mode", \.penTilt, ["Does nothing", "Shapes the hills", "Tilts and turns the view"]),
                P(key: "push", title: "Moving parts the dots", keyPath: \.push, range: 0...20, format: points),
                P(key: "sweep", title: "Moving sweeps the dots", keyPath: \.sweep, range: 0...20, format: points),
                P(key: "settle", title: "Settle time", keyPath: \.settle, range: 0.05...2, format: seconds),
                P(key: "bounce", title: "Bounce", keyPath: \.bounce, range: 0...1, format: percent),
            ]),
            ("Hills", [
                P(key: "hillHeight", title: "Height at full pressure", keyPath: \.hillHeight, range: -200...200, format: points),
                P(key: "hillRadius", title: "Radius at full pressure", keyPath: \.hillRadius, range: 10...200, format: points),
                P(key: "pressureGrowsRadius", title: "Pressure widens", keyPath: \.pressureGrowsRadius, range: 0...1, format: percent),
                P(key: "pressureCurve", title: "Pressure curve", keyPath: \.pressureCurve, range: 0.3...2.5,
                  format: { String(format: "%.2f", $0) }),
                .choice("clicksAnywhere", "Clicks anywhere raise hills", \.clicksAnywhere, ["Off", "On"]),
                P(key: "clickStrength", title: "Click without pressure starts at", keyPath: \.clickStrength,
                  range: 0.05...1, format: percent),
                P(key: "holdToGrow", title: "Hold to grow to full", keyPath: \.holdToGrow, range: 0.2...5, format: seconds),
                P(key: "leanStretch", title: "Leaning the pen stretches them", keyPath: \.leanStretch, range: 0...5,
                  format: { $0 == 0 ? "Off" : String(format: "Up to %.1f× long", 1 + $0) }),
                P(key: "riseTime", title: "Rise time", keyPath: \.riseTime, range: 0...2, format: seconds),
                P(key: "fadeHalfLife", title: "Fade half-life", keyPath: \.fadeHalfLife, range: 0.3...20, format: seconds),
            ]),
            ("Height", [
                P(key: "heightGrows", title: "Dots grow on top", keyPath: \.heightGrows, range: 0...3, format: percent),
                P(key: "heightBrightens", title: "Dots brighten on top", keyPath: \.heightBrightens, range: 0...2, format: percent),
                P(key: "shading", title: "Light from the top left", keyPath: \.shading, range: 0...1, format: percent),
            ]),
        ]
    }()
}

@Observable
final class DotStore {
    static let shared = DotStore()

    var tuning: DotTuning {
        didSet { if tuning != oldValue { tuning.save(defaultsKey: Self.defaultsKey) } }
    }
    @ObservationIgnored private static let defaultsKey = "dots.v1"

    init() {
        tuning = DotTuning(defaultsKey: Self.defaultsKey)
    }
}

// MARK: - Field

/// Ground plane to screen: turned about the view's centre, tilted away, every dot lifted by its
/// height, and then seen from a camera in front of the centre, so higher dots come nearer and grow.
struct DotProjection {
    var cx = 0.0, cy = 0.0
    var cosTurn = 1.0, sinTurn = 0.0
    var cosTilt = 1.0, sinTilt = 0.0
    /// One over the camera's distance; 0 looks straight on, without perspective.
    var inverseDistance = 0.0

    init() {}

    init(size: CGSize, tuning: DotTuning) {
        let tilt = min(max(tuning.tilt, 0), 80) * .pi / 180, turn = tuning.turn * .pi / 180
        cosTurn = cos(turn); sinTurn = sin(turn)
        cosTilt = cos(tilt); sinTilt = sin(tilt)
        cx = size.width / 2
        cy = size.height / 2
        inverseDistance = min(max(tuning.perspective, 0), 1) * 1.5 / max(size.width, size.height, 1)
    }

    /// The ground point seen at a point in the view, at a height.
    func ground(_ point: CGPoint, height h: Double) -> (x: Double, y: Double) {
        let sx = point.x - cx, sy = point.y - cy
        // Past the horizon there's no ground; take the farthest that's still in front.
        let ry = (sy * (1 - h * cosTilt * inverseDistance) + h * sinTilt) / max(cosTilt + sy * sinTilt * inverseDistance, 0.05)
        let rx = sx * (1 - (ry * sinTilt + h * cosTilt) * inverseDistance)
        return (cosTurn * rx + sinTurn * ry, -sinTurn * rx + cosTurn * ry)
    }
}

/// The height field under the dots: noisy ground, a bump that follows the pointer and pushes
/// dots aside as it moves, and hills raised by pressing. The GPU places and draws the dots
/// (`DotRenderer`); this keeps the state and maps the pointer onto the ground.
final class DotField {
    struct Hill {
        var x, y: Double
        /// Strongest press so far, 0...1. Sets the hill's footprint and how high it climbs.
        var peak = 0.0
        /// Current height as a fraction of `DotTuning.hillHeight`.
        var amount = 0.0
        var held = true
        var fading = false
        /// The way the pen leaned, on the ground, as long as how far it leaned (0...1).
        var lean = (x: 0.0, y: 0.0)
        /// Which press-and-drag raised it.
        var stroke = 0
        /// The ridge of its stroke runs on to here from the hill before.
        var joinsPrevious = false
    }

    /// A raised patch of the ground: an upturned bell, round or stretched out, drawn out from
    /// `tail` to `tip`, so a stroke is one ridge however far apart its points are.
    struct Bump {
        struct End {
            /// `amount` is its height as a fraction of `DotTuning.hillHeight`.
            var x, y, amount: Double
            /// Its shape: a point's offset `d` from the centre is `a dx² + 2b dx dy + c dy²` radii out.
            var a, b, c: Double
            /// How far from the centre it lifts anything at all, in points.
            var reach: Double
        }
        var tip, tail: End
        var stroke: Int
    }

    /// A dot of the grid, by its index, turning into the pen's dot or back.
    struct CursorDot: Equatable {
        var x, y: Int
        /// 0 is an ordinary dot, 1 the pen's.
        var amount = 0.0
    }

    /// Everything the GPU needs for one frame.
    struct Frame {
        var projection: DotProjection
        /// The first dot's index on the ground, and how many there are across and down.
        var firstX = 0, firstY = 0, nx = 0, ny = 0
        var bumps: [Bump]
        /// How yellow the dots around the pointer are, 0...1. Nowhere else turns yellow.
        var highlight: Double
        var noiseOffsetX, noiseOffsetY: Double
        var pointerX, pointerY: Double
        /// The pointer's own bump, centred on it, `DotTuning.hoverRadius` across.
        var pointerHeight: Double
        /// How far dots move away from the pointer, and along its way, in points.
        var push: Double
        var sweepX, sweepY: Double
        var cursorDots: [CursorDot]
    }

    /// The most hills there can be, and how many can stand before the oldest start to sink
    /// early. Between the two there's room for those to fade away before their turn to go.
    static let maxHills = 256
    private static let unhurriedHills = 160
    /// The oldest hills' half-life, in seconds, when there are too many.
    private static let hurriedHalfLife = 0.3

    var tuning = DotTuning()
    private(set) var hills: [Hill] = []
    private var hoverPosition = (x: 0.0, y: 0.0)
    private var hoverTarget = (x: 0.0, y: 0.0)
    private var hoverShown = false
    private var hoverAmount = 0.0
    /// How hard the pointer presses, 0...1, and that eased, for the highlight.
    var pressure = 0.0
    private var shownPressure = 0.0
    /// The pointer's velocity on the ground, smoothed, and the way it last went.
    private var velocity = (x: 0.0, y: 0.0)
    private var heading = (x: 1.0, y: 0.0)
    /// How stirred the dots are, 0...1 and a little past it when they bounce: a spring
    /// pulled toward the pointer's speed.
    private var stir = 0.0
    private var stirSpeed = 0.0
    private var driftDistance = 0.0
    private(set) var projection = DotProjection()
    private(set) var cursorDots: [CursorDot] = []
    private var cursorTarget: (x: Int, y: Int)?
    /// How far and which way the pen leans, in degrees across and down the view, while it steers it.
    var penLean: (x: Double, y: Double)?
    /// The view's tilt and turn as shown, easing toward `viewTarget`.
    private var view: (tilt: Double, turn: Double)?

    /// Nothing moves but the drifting ground, which looks smooth at a low frame rate.
    var isOnlyDrifting: Bool {
        hills.isEmpty && shownPressure == pressure && hoverAmount == (hoverShown ? 1 : 0) && hoverPosition == hoverTarget && stir == 0 && stirSpeed == 0
            && cursorDots.allSatisfy { isCursorTarget($0) && $0.amount == 1 }
            && (view.map { $0 == viewTarget } ?? true)
    }

    /// The tuning's tilt and turn, or with the pen steering, tilted as far as it leans and turned
    /// the way it leans.
    private var viewTarget: (tilt: Double, turn: Double) {
        guard let penLean else { return (tuning.tilt, tuning.turn) }
        let tilt = min(hypot(penLean.x, penLean.y), 80)
        return (tilt, tilt < 1 ? view?.turn ?? tuning.turn : tuning.turn + atan2(penLean.x, penLean.y) * 180 / .pi)
    }

    var isSettled: Bool { isOnlyDrifting && tuning.drift == 0 }

    /// The ground point whose top shows at a point in the view. Tilted away, whatever is lifted
    /// shows further up the view than the ground under it, so this follows the height there
    /// (the ground, the hills, and the pointer's own bump on top) back down to where it stands.
    /// Hills don't count: the point stays under the pointer as it moves over them, rather than
    /// sticking to the face of one standing in the way, and hills pressed there rise from it.
    func groundPoint(under point: CGPoint) -> (x: Double, y: Double) {
        // Down the line of sight from the highest the ground could stand, the first height where
        // it meets it: found in steps, then narrowed down.
        let top = tuning.groundRelief + max(tuning.hoverHeight, 0) + 1
        let bottom = min(tuning.hoverHeight, 0) - 1
        func above(_ h: Double) -> Bool { topHeight(at: projection.ground(point, height: h)) >= h }
        let steps = 16
        var high = top, low = bottom
        for i in 1...steps {
            let h = top - (top - bottom) * Double(i) / Double(steps)
            if above(h) { low = h; break }
            high = h
        }
        for _ in 0..<12 {
            let mid = (high + low) / 2
            if above(mid) { low = mid } else { high = mid }
        }
        return projection.ground(point, height: low)
    }

    /// How high the ground stands at a point with the pointer's bump centred on it: the shader's
    /// height field without the hills, on the CPU.
    private func topHeight(at g: (x: Double, y: Double)) -> Double {
        let scale = 1 / tuning.groundScale
        var h = tuning.groundRelief * Double(DotNoise.ground(Float((g.x + driftDistance * 0.92) * scale),
                                                             Float((g.y + driftDistance * 0.39) * scale)))
        return h + tuning.hoverHeight
    }

    func hover(_ point: CGPoint?) {
        guard let point else { hoverShown = false; return }
        let g = groundPoint(under: point)
        // Coming back in: appear under the pointer rather than sweeping over from where it left.
        if hoverAmount < 0.01 { hoverPosition = g }
        hoverTarget = g
        hoverShown = true
    }

    /// On: the grid's dot on the top of the pointer's bump is the pen's dot, turned yellow.
    var showsCursor = false

    /// Moves the pen's dot to the grid's dot under the pointer, or lets it go. The dots in
    /// between hand the yellow over in `step(_:)`.
    func updateCursor() {
        guard showsCursor, hoverShown else { cursorTarget = nil; return }
        // Under the pointer itself, not the bump following it: the pen's dot keeps up.
        let s = tuning.spacing, p = hoverTarget
        let nearest = (x: Int((p.x / s).rounded()), y: Int((p.y / s).rounded()))
        func distance(_ i: (x: Int, y: Int)) -> Double { hypot(Double(i.x) * s - p.x, Double(i.y) * s - p.y) }
        // Between two about as near, the one showing it keeps it, so it doesn't flicker.
        if let current = cursorTarget, distance(current) < distance(nearest) + s * 0.15 { return }
        cursorTarget = nearest
        guard !cursorDots.contains(where: { $0.x == nearest.x && $0.y == nearest.y }) else { return }
        cursorDots.append(CursorDot(x: nearest.x, y: nearest.y))
        // Racing across the grid, only the latest few are still worth fading.
        if cursorDots.count > 8 { cursorDots.removeFirst(cursorDots.count - 8) }
    }

    /// Straight to where the pen's dot is going, for a still picture.
    func finishCursor() {
        updateCursor()
        for i in cursorDots.indices { cursorDots[i].amount = isCursorTarget(cursorDots[i]) ? 1 : 0 }
        cursorDots.removeAll { $0.amount == 0 }
    }

    private func isCursorTarget(_ dot: CursorDot) -> Bool {
        cursorTarget.map { $0.x == dot.x && $0.y == dot.y } ?? false
    }

    /// Raises a hill at a point in the view. `lean` is which way and how far the pen leans across
    /// and down the view, 0...1, if it shapes the hills.
    func press(at point: CGPoint, strength: Double, lean: CGVector?) {
        let g = groundPoint(under: point)
        if !hills.contains(where: \.held) { stroke &+= 1 }
        retracing = false
        dragPosition = g
        heldPoint = point
        raise(g, peak: strength, lean: groundLean(lean, at: point), joinsPrevious: false)
    }

    private func raise(_ g: (x: Double, y: Double), peak: Double, lean: (x: Double, y: Double), joinsPrevious: Bool) {
        hills.append(Hill(x: g.x, y: g.y, peak: peak, lean: lean, stroke: stroke, joinsPrevious: joinsPrevious))
        // Scribbling faster than even the hurried ones can fade, the oldest, nearly gone, go.
        while hills.count > Self.maxHills { hills.remove(at: hills.firstIndex(where: { !$0.held }) ?? 0) }
    }

    /// Where in the view the hill being raised was pressed.
    private var heldPoint = CGPoint.zero
    private var stroke = 0
    /// Where a drag last was on the ground, and whether it has been going back over its stroke.
    private var dragPosition = (x: 0.0, y: 0.0)
    private var retracing = false

    /// The hill being raised, under the pen, follows its pressure and lean.
    func hold(strength: Double, lean: CGVector?) {
        guard let i = hills.lastIndex(where: \.held) else { return }
        hills[i].peak = max(hills[i].peak, strength)
        if lean != nil { hills[i].lean = groundLean(lean, at: heldPoint) }
    }

    /// Dragging a press along draws it out like a brush: each new point carries the ridge on from
    /// the last, however fast the drag and far apart the points. Going back over the stroke adds
    /// none: those already there are high enough.
    func drag(to point: CGPoint, strength: Double, lean: CGVector?) {
        guard let last = hills.last, last.held else { return }
        let g = groundPoint(under: point)
        defer { dragPosition = g }
        guard hypot(g.x - last.x, g.y - last.y) >= hillRadius(last) * 0.5 else { return }
        guard !hills.contains(where: { $0.held && hypot(g.x - $0.x, g.y - $0.y) < hillRadius($0) * 0.25 }) else {
            retracing = true
            return
        }
        let groundLean = groundLean(lean, at: point)
        // Off the stroke again: the ridge goes on from here, not across from the end of the stroke.
        if retracing { raise(dragPosition, peak: strength, lean: groundLean, joinsPrevious: false) }
        retracing = false
        heldPoint = point
        raise(g, peak: strength, lean: groundLean, joinsPrevious: true)
    }

    /// A lean across the view, turned onto the ground under `point`.
    private func groundLean(_ lean: CGVector?, at point: CGPoint) -> (x: Double, y: Double) {
        guard let lean else { return (0, 0) }
        let m = min(hypot(lean.dx, lean.dy), 1)
        guard m > 0.01 else { return (0, 0) }
        let from = projection.ground(point, height: 0)
        let to = projection.ground(CGPoint(x: point.x + lean.dx / m * 10, y: point.y + lean.dy / m * 10), height: 0)
        let length = hypot(to.x - from.x, to.y - from.y)
        guard length > 1e-6 else { return (0, 0) }
        return ((to.x - from.x) / length * m, (to.y - from.y) / length * m)
    }

    func release() {
        for i in hills.indices { hills[i].held = false }
    }

    func step(_ dt: Double) {
        guard dt > 0 else { return }
        driftDistance += tuning.drift * dt
        stepView(dt)

        let last = hoverPosition
        let follow = tuning.hoverLag <= 0 ? 1 : 1 - exp(-dt / tuning.hoverLag)
        hoverPosition.x += (hoverTarget.x - hoverPosition.x) * follow
        hoverPosition.y += (hoverTarget.y - hoverPosition.y) * follow
        if hypot(hoverTarget.x - hoverPosition.x, hoverTarget.y - hoverPosition.y) < 0.05 { hoverPosition = hoverTarget }
        let shown = hoverShown ? 1.0 : 0
        hoverAmount += (shown - hoverAmount) * (1 - exp(-dt / 0.2))
        if abs(shown - hoverAmount) < 0.002 { hoverAmount = shown }

        stepStir(dt, moved: (hoverPosition.x - last.x, hoverPosition.y - last.y))

        updateCursor()
        let turn = 1 - exp(-dt / 0.05)
        for i in cursorDots.indices {
            let target = isCursorTarget(cursorDots[i]) ? 1.0 : 0
            cursorDots[i].amount += (target - cursorDots[i].amount) * turn
            if abs(target - cursorDots[i].amount) < 0.01 { cursorDots[i].amount = target }
        }
        cursorDots.removeAll { $0.amount == 0 && !isCursorTarget($0) }

        shownPressure += (pressure - shownPressure) * (1 - exp(-dt / 0.06))
        if abs(pressure - shownPressure) < 0.002 { shownPressure = pressure }

        let rise = tuning.riseTime <= 0 ? 1 : 1 - exp(-dt / tuning.riseTime)
        let fade = exp(-M_LN2 * dt / tuning.fadeHalfLife)
        let hurriedFade = min(fade, exp(-M_LN2 * dt / Self.hurriedHalfLife))
        let hurried = hills.count - Self.unhurriedHills
        for i in hills.indices {
            // A quick tap still climbs to its peak before it starts to sink.
            if i < hurried || !hills[i].held && hills[i].amount >= hills[i].peak * 0.97 { hills[i].fading = true }
            if hills[i].fading { hills[i].amount *= i < hurried ? hurriedFade : fade }
            else { hills[i].amount += (hills[i].peak - hills[i].amount) * rise }
        }
        hills.removeAll { $0.fading && $0.amount * abs(tuning.hillHeight) < 0.5 }
    }

    private func stepView(_ dt: Double) {
        let target = viewTarget
        guard var current = view else { view = target; return }
        let follow = 1 - exp(-dt / 0.15)
        current.tilt += (target.tilt - current.tilt) * follow
        // The short way round.
        current.turn += remainder(target.turn - current.turn, 360) * follow
        if abs(target.tilt - current.tilt) < 0.05, abs(remainder(target.turn - current.turn, 360)) < 0.05 { current = target }
        view = current
    }

    /// Moving fast stirs the dots fully; stopping lets them spring back, overshooting with bounce.
    private func stepStir(_ dt: Double, moved: (x: Double, y: Double)) {
        let smooth = 1 - exp(-dt / 0.05)
        velocity.x += (moved.x / dt - velocity.x) * smooth
        velocity.y += (moved.y / dt - velocity.y) * smooth
        let speed = hypot(velocity.x, velocity.y)
        if speed > 1 { heading = (velocity.x / speed, velocity.y / speed) }
        if speed < 0.5 { velocity = (0, 0) }
        // Crossing the pointer's own size in about a tenth of a second is fast.
        let target = min(speed / (tuning.hoverRadius * 10), 1) * hoverAmount
        let omega = 8 / tuning.settle, damping = 1 - 0.9 * min(max(tuning.bounce, 0), 1)
        let steps = Int((dt * 240).rounded(.up))
        let h = dt / Double(steps)
        for _ in 0..<steps {
            stirSpeed += (omega * omega * (target - stir) - 2 * damping * omega * stirSpeed) * h
            stir += stirSpeed * h
        }
        if target == 0, abs(stir) < 0.002, abs(stirSpeed) < 0.02 { stir = 0; stirSpeed = 0 }
    }

    // MARK: Frame

    /// Updates the projection for `size` and describes the frame for the GPU.
    func frame(in size: CGSize) -> Frame {
        var seen = tuning
        if let view { seen.tilt = view.tilt; seen.turn = view.turn }
        projection = DotProjection(size: size, tuning: seen)
        var frame = Frame(projection: projection, bumps: currentBumps(),
                          highlight: (tuning.hoverTint + (1 - tuning.hoverTint) * shownPressure) * hoverAmount,
                          noiseOffsetX: driftDistance * 0.92, noiseOffsetY: driftDistance * 0.39,
                          pointerX: hoverPosition.x, pointerY: hoverPosition.y,
                          pointerHeight: tuning.hoverHeight * hoverAmount, push: tuning.push * stir,
                          sweepX: heading.x * tuning.sweep * stir, sweepY: heading.y * tuning.sweep * stir,
                          cursorDots: cursorDots)
        coverGround(size, &frame)
        return frame
    }

    /// The dots on the ground under the view, from its corners at the lowest and highest heights
    /// the tuning allows, and a little more for dots pushed in from outside.
    private func coverGround(_ size: CGSize, _ frame: inout Frame) {
        let top = tuning.groundRelief + max(0, tuning.hillHeight) + max(0, tuning.hoverHeight)
        let bottom = min(0, tuning.hillHeight, tuning.hoverHeight)
        let reach = max(size.width, size.height) * 4
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        for corner in [CGPoint.zero, CGPoint(x: size.width, y: 0), CGPoint(x: 0, y: size.height), CGPoint(x: size.width, y: size.height)] {
            for h in [bottom, top] {
                let g = projection.ground(corner, height: h)
                minX = min(minX, g.x); maxX = max(maxX, g.x); minY = min(minY, g.y); maxY = max(maxY, g.y)
            }
        }
        let margin = tuning.push + tuning.sweep + tuning.spacing
        minX = max(minX - margin, -reach); minY = max(minY - margin, -reach)
        maxX = min(maxX + margin, reach); maxY = min(maxY + margin, reach)
        // Seen flat from far off, the back holds more dots than are worth drawing; the fog hides
        // those, so at most so many either side of the centre.
        let s = tuning.spacing, limit = 250
        frame.firstX = max(Int((minX / s).rounded(.down)), -limit)
        frame.firstY = max(Int((minY / s).rounded(.down)), -limit)
        frame.nx = max(1, min(Int((maxX / s).rounded(.up)), limit) - frame.firstX + 1)
        frame.ny = max(1, min(Int((maxY / s).rounded(.up)), limit) - frame.firstY + 1)
    }

    /// The hills, oldest first. The GPU joins those of one stroke, so going over it again adds
    /// nothing, and has each stroke build on the ones before, up to the full height.
    private func currentBumps() -> [Bump] {
        var bumps: [Bump] = []
        var previous: (end: Bump.End, stroke: Int)?
        for hill in hills {
            let end = hillEnd(hill)
            if hill.amount > 0 {
                let joined = hill.joinsPrevious && previous?.stroke == hill.stroke
                bumps.append(Bump(tip: end, tail: joined ? previous!.end : end, stroke: hill.stroke))
            }
            previous = (end, hill.stroke)
        }
        return bumps
    }

    /// Round, or leaning like a brush laid on its side: stretched out from the pen's tip the way
    /// it leans, by `DotTuning.leanStretch` at full lean, and narrower across.
    private func hillEnd(_ hill: Hill) -> Bump.End {
        let r = hillRadius(hill), m = hypot(hill.lean.x, hill.lean.y)
        let along = r * (1 + tuning.leanStretch * m), across = r * (1 - 0.35 * m * min(tuning.leanStretch, 1))
        let ux = m > 0 ? hill.lean.x / m : 1, uy = m > 0 ? hill.lean.y / m : 0
        // The rest lies along the pen, with the tip still near the top, under the pen's dot.
        let shift = (along - r) * 0.4
        let ia = 1 / (along * along), ic = 1 / (across * across)
        return Bump.End(x: hill.x + ux * shift, y: hill.y + uy * shift, amount: hill.amount,
                        a: ux * ux * ia + uy * uy * ic, b: ux * uy * (ia - ic), c: uy * uy * ia + ux * ux * ic,
                        reach: 2 * max(along, across))
    }

    private func hillRadius(_ hill: Hill) -> Double {
        let g = tuning.pressureGrowsRadius
        return tuning.hillRadius * (1 - g + g * hill.peak)
    }
}

/// The shader's ground noise, the same on the CPU, to find how high the ground stands.
enum DotNoise {
    private static func hash(_ x: Int32, _ y: Int32) -> Float {
        var h = UInt32(bitPattern: x) &* 374761393 &+ UInt32(bitPattern: y) &* 668265263
        h = (h ^ (h >> 13)) &* 1274126177
        h ^= h >> 16
        return Float(h & 0xFFFFFF) / Float(0xFFFFFF)
    }

    private static func value(_ x: Float, _ y: Float) -> Float {
        let fx = x.rounded(.down), fy = y.rounded(.down)
        let ix = Int32(min(max(fx, -1e9), 1e9)), iy = Int32(min(max(fy, -1e9), 1e9))
        let tx = x - fx, ty = y - fy
        let sx = tx * tx * (3 - 2 * tx), sy = ty * ty * (3 - 2 * ty)
        let a = hash(ix, iy), b = hash(ix &+ 1, iy), c = hash(ix, iy &+ 1), d = hash(ix &+ 1, iy &+ 1)
        return a + (b - a) * sx + (c - a) * sy + (a - b - c + d) * sx * sy
    }

    static func ground(_ x: Float, _ y: Float) -> Float {
        let wx = x + 0.9 * value(x + 3.1, y + 7.7), wy = y + 0.9 * value(x - 5.3, y + 1.9)
        return 0.6 * value(wx, wy) + 0.28 * value(wx * 2.03, wy * 2.03) + 0.12 * value(wx * 4.1, wy * 4.1)
    }
}

// MARK: - View

/// The pen's dot on the view: the grid's dot under the pointer, drawn yellow and big.
struct DotCursor: Equatable {
    var touching = false
    /// 0...1: how far the dot has shrunk for a press.
    var press = 0.0
}

/// Shows the dots and plays with the pointer like `TerrainView`: a bump follows it across all
/// the displays and stirs the dots as it moves, and pressing (here, or anywhere else) raises a
/// hill there. Dragging past a few points moves the window instead. Frames are drawn only by the
/// display link, however often the pointer reports in.
final class DotView: NSView, MTKViewDelegate {
    var tuning = DotTuning() {
        didSet {
            guard tuning != oldValue else { return }
            field.tuning = tuning
            redraw()
            updateAnimation()
        }
    }
    /// The pen as wdrive last read it. Posted clicks carry no pressure, so it comes from here.
    var pen: () -> LiveState = { LiveState() }
    /// Where the pointer shows on this view, for a view size; nil hides it. By default the whole
    /// desktop is scaled onto the view.
    var locate: ((CGSize) -> CGPoint?)?
    /// On: over the view itself, the pointer shows right where it is, wherever `locate` puts it.
    var followsPointerInside = false {
        didSet { if followsPointerInside != oldValue { updateTrackingAreas() } }
    }
    /// Off: clicks go to whatever is underneath, and the dots only follow the pointer.
    var interactive = true
    /// With `followsPointerInside`: whether to hide the pointer at a point over the view, where
    /// the pen's dot stands in for it.
    var hidesPointer: ((CGPoint) -> Bool)?
    /// Where the pen is, if it's in range. With `followsPointerInside`, over the view the pen's
    /// dot is at the pointer instead, pen or not. Only with `DotTuning.gridCursor` on.
    var cursor: DotCursor? {
        didSet { if cursor != oldValue { redraw() } }
    }
    /// Off, as in mouse mode, where apps don't get it: leaning the pen does nothing here either.
    var usesPenTilt = true {
        didSet { if usesPenTilt != oldValue { updateAnimation() } }
    }
    private var penTiltUse: DotTuning.PenTilt { usesPenTilt ? tuning.penTiltUse : .off }
    /// Space with the pointer over the view calls this, if set.
    var onSpace: (() -> Void)?

    private var shownCursor: DotCursor? {
        guard tuning.gridCursor > 0 else { return nil }
        var shown = cursor
        if insidePoint != nil { shown = DotCursor(touching: cursor?.touching ?? false) }
        shown?.press = cursorPress
        return shown
    }

    /// The pointer over the view, as of the last pointer event, with `followsPointerInside`.
    private var insidePoint: CGPoint?

    private let field = DotField()
    private let metalView: TerrainMetalView?
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval?
    private var foregroundObservers: [NSObjectProtocol] = []
    private var pointerMonitors: [Any] = []
    private var mouseDown: NSEvent?
    private var trackpadPressure: Double?
    /// When the current press began, wherever it is; nil when nothing is pressed.
    private var pressStart: CFTimeInterval?
    /// The press came through a monitor, so its release does too.
    private var pressIsMonitored = false
    private var needsFrame = false
    private var pointerHidden = false
    /// Eases to 1 while pressed, so the pen's dot shrinks into the press.
    private var cursorPress = 0.0
    private var isPressing: Bool { pressStart != nil || cursor?.touching == true }
    private var isForeground: Bool { window?.isInForeground == true }

    override init(frame: NSRect) {
        // `--snapshot` can't read a Metal layer back, so it renders offscreen in `draw(_:)`.
        metalView = Snapshot.path == nil ? DotRenderer.shared.map { TerrainMetalView(device: $0.device) } : nil
        super.init(frame: frame)
        clipsToBounds = true
        if let metalView {
            metalView.frame = bounds
            metalView.autoresizingMask = [.width, .height]
            metalView.delegate = self
            addSubview(metalView)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// The Metal view inside only draws; the pointer is all this view's.
    override func hitTest(_ point: NSPoint) -> NSView? {
        interactive && frame.contains(point) ? self : nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        foregroundObservers.forEach(NotificationCenter.default.removeObserver)
        foregroundObservers = []
        stopWatchingPointer()
        link?.invalidate()
        link = nil
        guard let window else { return }
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        foregroundObservers = window.observeForeground { [weak self] in self?.foregroundChanged() }
        foregroundChanged()
        redraw()
    }

    /// Out of the foreground nothing runs: no pointer, no frames, the last picture stays.
    private func foregroundChanged() {
        if isForeground {
            if pointerMonitors.isEmpty {
                watchPointer()
                followPointer(nil)
                redraw()
            }
        } else {
            stopWatchingPointer()
        }
        updateAnimation()
    }

    private func watchPointer() {
        // Moves over other apps come through the global monitor, over wdrive through the local one.
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.followPointer(event) }
        }) { pointerMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { [weak self] event in
            self?.followPointer(event)
            return event
        }) { pointerMonitors.append(local) }
        // Clicks in other apps raise hills where the pointer shows on the view.
        if let clicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.clickElsewhere(event) }
        }) { pointerMonitors.append(clicks) }
        // Not interactive, clicks on the view still raise hills on their way to what's underneath.
        if let clicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp], handler: { [weak self] event in
            self?.clickInside(event)
            return event
        }) { pointerMonitors.append(clicks) }
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self, let onSpace, event.keyCode == 49, event.window === window, insidePoint != nil,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return event }
            if !event.isARepeat { onSpace() }
            return nil
        }) { pointerMonitors.append(keys) }
    }

    private func stopWatchingPointer() {
        pointerMonitors.forEach(NSEvent.removeMonitor)
        pointerMonitors = []
        // Its release won't be seen now.
        if pressStart != nil { endPress() }
        // The pointer isn't the app's to hide now.
        insidePoint = nil
        updatePointerHidden()
    }

    /// Moves over the view reach it even when its window isn't key, and leaving it hands the
    /// pointer back to `locate`.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        guard followsPointerInside else { return }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self))
    }

    // Moves come through the local monitor; entering and leaving don't.
    override func mouseEntered(with event: NSEvent) { followPointer(event) }
    override func mouseExited(with event: NSEvent) { followPointer(event) }

    override func layout() {
        super.layout()
        followPointer(nil)
        redraw()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        redraw()
    }

    /// Runs the display link only while something moves and the window is in the foreground.
    private func updateAnimation() {
        guard let link else { return }
        // Leaning the pen steers the view without moving it, so nothing else would ask for frames.
        let steering = penTiltUse == .steersView && pen().inRange
        let shrinking = cursorPress != (isPressing ? 1 : 0)
        let paused = (field.isSettled && !needsFrame && !steering && !shrinking) || !isForeground
        if paused { lastTick = nil }
        if link.isPaused != paused { link.isPaused = paused }
        // Drift looks fine at a low rate; the pointer and hills get the full one.
        let rate = field.isOnlyDrifting ? CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
                                        : CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        if link.preferredFrameRateRange != rate { link.preferredFrameRateRange = rate }
    }

    @objc private func tick(_ link: CADisplayLink) {
        let dt = lastTick.map { min(max(link.timestamp - $0, 0), 0.1) } ?? 1.0 / 60
        lastTick = link.timestamp
        let pen = pen()
        field.penLean = penTiltUse == .steersView && pen.inRange ? (pen.tiltX, pen.tiltY) : nil
        if pressStart != nil { field.hold(strength: strength(), lean: lean()) }
        field.pressure = isPressing ? strength() : 0
        let press = isPressing ? 1.0 : 0
        cursorPress += (press - cursorPress) * (1 - exp(-dt / 0.05))
        if abs(press - cursorPress) < 0.01 { cursorPress = press }
        field.showsCursor = shownCursor != nil
        field.step(dt)
        needsFrame = false
        if bounds.width > 0, bounds.height > 0 { metalView?.draw() }
        updateAnimation()
    }

    /// Draws on the next display frame.
    private func redraw() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        guard let metalView else { needsDisplay = true; return }
        // Behind other apps no frames are coming, and a new appearance still has to show.
        guard isForeground else { metalView.draw(); return }
        needsFrame = true
        updateAnimation()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard metalView == nil, let renderer = DotRenderer.shared, let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = Double(window?.backingScaleFactor ?? 2)
        // A still picture: the pen's dot all the way there.
        field.showsCursor = shownCursor != nil
        field.finishCursor()
        guard let image = renderer.image(scene(), size: bounds.size, scale: scale) else { return }
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: bounds)
        context.restoreGState()
    }

    private func scene() -> DotRenderer.Scene {
        DotRenderer.Scene(frame: field.frame(in: bounds.size), tuning: tuning, cursor: shownCursor)
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        DotRenderer.shared?.draw(scene(), in: view)
    }

    // MARK: Pointer

    override func mouseDown(with event: NSEvent) {
        mouseDown = event
        trackpadPressure = nil
        pressStart = CACurrentMediaTime()
        field.press(at: convert(event.locationInWindow, from: nil), strength: strength(), lean: lean())
        updateAnimation()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDown else { return }
        if hypot(event.locationInWindow.x - down.locationInWindow.x, event.locationInWindow.y - down.locationInWindow.y) > 4 {
            // The window drag swallows the mouse up, so the press ends when it returns.
            window?.performDrag(with: down)
            endPress()
        }
    }

    override func mouseUp(with event: NSEvent) { endPress() }

    /// Force Touch trackpads report how hard the click is; a force click goes further.
    override func pressureChange(with event: NSEvent) {
        guard mouseDown != nil, event.stage >= 1 else { return }
        let progress = event.stage >= 2 ? 0.5 + 0.5 * Double(event.pressure) : 0.5 * Double(event.pressure)
        trackpadPressure = max(trackpadPressure ?? 0, 0.3 + 0.7 * progress)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: "Tune Dots…", action: #selector(openTuning), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func openTuning() { TuningWindow.dots.show() }

    /// The pointer anywhere on the displays, as macOS arranges them, mapped onto the view.
    private func pointerOnView() -> CGPoint? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        if let insidePoint { return insidePoint }
        if let locate { return locate(bounds.size) }
        let desktop = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        guard !desktop.isNull, desktop.width > 0, desktop.height > 0 else { return nil }
        let p = NSEvent.mouseLocation
        let u = min(max((p.x - desktop.minX) / desktop.width, 0), 1)
        let v = min(max((desktop.maxY - p.y) / desktop.height, 0), 1)
        return CGPoint(x: u * bounds.width, y: v * bounds.height)
    }

    /// The pointer in the view's coordinates if an event puts it over the view. Events go to the
    /// window under the pointer, so one for another window or app means another covers the view.
    /// Without an event (a layout), it stays over the view if it was.
    private func pointerInside(_ event: NSEvent?) -> CGPoint? {
        guard followsPointerInside, let window, window.isVisible else { return nil }
        let point: CGPoint
        if let event {
            guard event.window === window else { return nil }
            point = convert(event.locationInWindow, from: nil)
        } else {
            guard insidePoint != nil else { return nil }
            point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        }
        return bounds.contains(point) ? point : nil
    }

    private func followPointer(_ event: NSEvent?) {
        let inside = pointerInside(event)
        if inside != insidePoint {
            insidePoint = inside
            if tuning.gridCursor > 0 { redraw() }
        }
        updatePointerHidden()
        let point = pointerOnView()
        field.hover(point)
        // A press that came through a monitor sees its drags here too.
        if pressIsMonitored, pressStart != nil, let point { field.drag(to: point, strength: strength(), lean: lean()) }
        updateAnimation()
    }

    /// Hides the pointer over the view where `hidesPointer` says to, shows it everywhere else.
    /// While a button is down it stays as it was, so a drag keeps the pointer it started with.
    private func updatePointerHidden() {
        let hide: Bool
        if let insidePoint, let hidesPointer, NSApp.isActive {
            hide = NSEvent.pressedMouseButtons != 0 ? pointerHidden : hidesPointer(insidePoint)
        } else {
            hide = false
        }
        guard hide != pointerHidden else { return }
        pointerHidden = hide
        if hide { NSCursor.hide() } else { NSCursor.unhide() }
    }

    private func clickInside(_ event: NSEvent) {
        if event.type == .leftMouseUp {
            if pressIsMonitored { endPress() }
            // After the button, the pointer can follow where it is again.
            DispatchQueue.main.async { [weak self] in self?.updatePointerHidden() }
            return
        }
        guard !interactive, pressStart == nil, let point = pointerInside(event) else { return }
        insidePoint = point
        pressIsMonitored = true
        pressStart = CACurrentMediaTime()
        trackpadPressure = nil
        field.hover(point)
        field.press(at: point, strength: strength(), lean: lean())
        updateAnimation()
    }

    private func clickElsewhere(_ event: NSEvent) {
        if event.type == .leftMouseUp {
            if pressIsMonitored { endPress() }
            return
        }
        guard tuning.clicksAnywhere > 0, pressStart == nil, let point = pointerOnView() else { return }
        pressIsMonitored = true
        pressStart = CACurrentMediaTime()
        trackpadPressure = nil
        field.hover(point)
        field.press(at: point, strength: strength(), lean: lean())
        updateAnimation()
    }

    private func endPress() {
        mouseDown = nil
        pressStart = nil
        pressIsMonitored = false
        trackpadPressure = nil
        field.release()
        updateAnimation()
    }

    /// Which way and how far the pen leans across and down the view, 0...1 at 50°, if that
    /// shapes the hills. Held naturally a pen leans 30–50°, so that's where it should tell.
    private func lean() -> CGVector? {
        let pen = pen()
        guard penTiltUse == .shapesHills, pen.inRange else { return nil }
        return CGVector(dx: pen.tiltX / 50, dy: pen.tiltY / 50)
    }

    /// 0...1: pen pressure if the pen made the click, else trackpad force, else growing for
    /// as long as the click is held.
    private func strength() -> Double {
        let pen = pen()
        let raw: Double
        if pen.inRange, pen.pressure > 0 { raw = pen.pressure }
        else if let trackpadPressure { raw = trackpadPressure }
        else {
            let held = pressStart.map { CACurrentMediaTime() - $0 } ?? 0
            return tuning.clickStrength + (1 - tuning.clickStrength) * min(held / tuning.holdToGrow, 1)
        }
        return pow(min(max(raw, 0), 1), tuning.pressureCurve)
    }
}

struct DotSurface: NSViewRepresentable {
    let tuning: DotTuning
    let pen: () -> LiveState
    var interactive = true
    var locate: ((CGSize) -> CGPoint?)?
    var followsPointerInside = false
    var cursor: DotCursor?
    var hidesPointer: ((CGPoint) -> Bool)?
    var usesPenTilt = true
    var onSpace: (() -> Void)?

    func makeNSView(context: Context) -> DotView {
        let view = DotView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: DotView, context: Context) {
        view.tuning = tuning
        view.pen = pen
        view.interactive = interactive
        view.locate = locate
        view.followsPointerInside = followsPointerInside
        view.cursor = cursor
        view.hidesPointer = hidesPointer
        view.usesPenTilt = usesPenTilt
        view.onSpace = onSpace
    }
}
