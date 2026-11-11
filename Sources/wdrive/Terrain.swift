import AppKit
import MetalKit
import SwiftUI

// MARK: - Tuning

/// The header's contour map, tuned live from the Terrain window. Heights are in contour
/// lines: a hill 10 high crosses 10 lines.
struct TerrainTuning: Equatable {
    var groundRelief = 3.0
    var groundScale = 150.0
    var drift = 3.0
    var wobble = 0.25
    var tilt = 50.0
    var turn = -20.0
    var elevation = 4.0
    var fogDensity = 0.5
    var fogStart = 0.25
    var fogFront = 0.4
    var fogFrontReach = 0.15
    var haze = 0.12
    var hoverHeight = 2.0
    var hoverRadius = 36.0
    var hoverLag = 0.12
    var hoverTint = 0.85
    var hillHeight = 10.0
    var hillRadius = 46.0
    var pressureGrowsRadius = 0.5
    var pressureCurve = 0.7
    var clickStrength = 0.15
    var holdToGrow = 1.2
    var clicksAnywhere = 1.0
    var heightMarker = 1.0
    var riseTime = 0.2
    var fadeHalfLife = 2.5
    var cellSize = 1.5
    var lineStyle = 0.0
    var lineWidth = 1.0
    var dashLength = 4.0
    var dashGap = 3.0
    var dotSpacing = 4.0
    var dotSize = 1.6
    var lineOpacity = 0.85
    var labelEvery = 5.0
    var labelStep = 10.0
    var labelSize = 8.0
    var filter = 0.0
    var filterStrength = 0.6

    enum LineStyle: Int { case solid, dashed, dots }
    var style: LineStyle { LineStyle(rawValue: Int(lineStyle)) ?? .solid }

    enum Filter: Int, CaseIterable {
        case none, grain, glitch, crt, dither
        var title: String { ["None", "Grain", "Glitch", "80s TV", "Dither"][rawValue] }
        /// Filters that change from frame to frame and so keep the view animating.
        var animates: Bool { self == .grain || self == .glitch || self == .crt }
    }
    var filterKind: Filter { Filter(rawValue: Int(filter)) ?? .none }
}

/// One tuning control: a slider over `range`, or a menu of `choices`.
struct TuningParameter<Tuning>: Identifiable {
    let key: String
    let title: String
    let keyPath: WritableKeyPath<Tuning, Double>
    let range: ClosedRange<Double>
    var step: Double?
    /// Shown as a menu of these instead of a slider; the value is the index.
    var choices: [String]?
    let format: (Double) -> String
    var id: String { key }

    static func choice(_ key: String, _ title: String, _ keyPath: WritableKeyPath<Tuning, Double>,
                       _ choices: [String]) -> TuningParameter {
        TuningParameter(key: key, title: title, keyPath: keyPath, range: 0...Double(choices.count - 1), step: 1,
                        choices: choices, format: { choices[min(max(Int($0), 0), choices.count - 1)] })
    }
}

typealias TerrainParameter = TuningParameter<TerrainTuning>

/// Settings tuned live from a tuning window, and kept in the user defaults.
protocol Tunable: Equatable {
    init()
    static var sections: [(title: String, parameters: [TuningParameter<Self>])] { get }
}

extension Tunable {
    static var parameters: [TuningParameter<Self>] { sections.flatMap(\.parameters) }

    /// With every parameter inside its range.
    var clamped: Self {
        var t = self
        for p in Self.parameters { t[keyPath: p.keyPath] = min(max(t[keyPath: p.keyPath], p.range.lowerBound), p.range.upperBound) }
        return t
    }

    /// Stored by key, so renamed or added parameters fall back to their defaults.
    init(defaultsKey: String) {
        self.init()
        guard let saved = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Double] else { return }
        for p in Self.parameters {
            if let v = saved[p.key] { self[keyPath: p.keyPath] = min(max(v, p.range.lowerBound), p.range.upperBound) }
        }
    }

    func save(defaultsKey: String) {
        let values = Dictionary(uniqueKeysWithValues: Self.parameters.map { ($0.key, self[keyPath: $0.keyPath]) })
        UserDefaults.standard.set(values, forKey: defaultsKey)
    }
}

extension TerrainTuning: Tunable {
    static let sections: [(title: String, parameters: [TerrainParameter])] = {
        func lines(_ v: Double) -> String { String(format: "%.1f lines", v) }
        func points(_ v: Double) -> String { String(format: "%.0f pt", v) }
        func degrees(_ v: Double) -> String { String(format: "%.0f°", v) }
        func seconds(_ v: Double) -> String { v == 0 ? "Instant" : String(format: "%.2f s", v) }
        func percent(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }
        return [
            ("Ground", [
                TerrainParameter(key: "groundRelief", title: "Relief", keyPath: \.groundRelief, range: 0...8, format: lines),
                TerrainParameter(key: "groundScale", title: "Feature size", keyPath: \.groundScale, range: 20...300, format: points),
                TerrainParameter(key: "drift", title: "Drift", keyPath: \.drift, range: 0...40,
                                 format: { $0 == 0 ? "Still" : String(format: "%.1f pt/s", $0) }),
                TerrainParameter(key: "wobble", title: "Wobble", keyPath: \.wobble, range: 0...1, format: percent),
            ]),
            ("View", [
                TerrainParameter(key: "tilt", title: "Tilt", keyPath: \.tilt, range: 0...80, format: degrees),
                TerrainParameter(key: "turn", title: "Turn", keyPath: \.turn, range: -180...180, format: degrees),
                TerrainParameter(key: "elevation", title: "Line spacing in height", keyPath: \.elevation, range: 0...12,
                                 format: { String(format: "%.1f pt", $0) }),
            ]),
            ("Fog", [
                TerrainParameter(key: "fogDensity", title: "At the back", keyPath: \.fogDensity, range: 0...1, format: percent),
                TerrainParameter(key: "fogStart", title: "Back fog starts", keyPath: \.fogStart, range: 0...1,
                                 format: { String(format: "%.0f%% back", $0 * 100) }),
                TerrainParameter(key: "fogFront", title: "At the front", keyPath: \.fogFront, range: 0...1, format: percent),
                TerrainParameter(key: "fogFrontReach", title: "Front fog reaches", keyPath: \.fogFrontReach, range: 0.02...0.6,
                                 format: { String(format: "%.0f%% back", $0 * 100) }),
                TerrainParameter(key: "haze", title: "Haze", keyPath: \.haze, range: 0...0.5, format: percent),
            ]),
            ("Pointer", [
                TerrainParameter(key: "hoverHeight", title: "Height", keyPath: \.hoverHeight, range: -4...6, format: lines),
                TerrainParameter(key: "hoverRadius", title: "Radius", keyPath: \.hoverRadius, range: 10...150, format: points),
                TerrainParameter(key: "hoverLag", title: "Follow lag", keyPath: \.hoverLag, range: 0...1, format: seconds),
                TerrainParameter(key: "hoverTint", title: "Highlight", keyPath: \.hoverTint, range: 0...1, format: percent),
            ]),
            ("Hills", [
                TerrainParameter(key: "hillHeight", title: "Height at full pressure", keyPath: \.hillHeight, range: 1...30, format: lines),
                TerrainParameter(key: "hillRadius", title: "Radius at full pressure", keyPath: \.hillRadius, range: 10...200, format: points),
                TerrainParameter(key: "pressureGrowsRadius", title: "Pressure widens", keyPath: \.pressureGrowsRadius, range: 0...1, format: percent),
                TerrainParameter(key: "pressureCurve", title: "Pressure curve", keyPath: \.pressureCurve, range: 0.3...2.5,
                                 format: { String(format: "%.2f", $0) }),
                .choice("clicksAnywhere", "Clicks anywhere raise hills", \.clicksAnywhere, ["Off", "On"]),
                TerrainParameter(key: "clickStrength", title: "Click without pressure starts at", keyPath: \.clickStrength,
                                 range: 0.05...1, format: percent),
                TerrainParameter(key: "holdToGrow", title: "Hold to grow to full", keyPath: \.holdToGrow, range: 0.2...5, format: seconds),
                .choice("heightMarker", "Height marker while pressing", \.heightMarker, ["Off", "On"]),
                TerrainParameter(key: "riseTime", title: "Rise time", keyPath: \.riseTime, range: 0...2, format: seconds),
                TerrainParameter(key: "fadeHalfLife", title: "Fade half-life", keyPath: \.fadeHalfLife, range: 0.3...20, format: seconds),
            ]),
            ("Lines", [
                .choice("lineStyle", "Style", \.lineStyle, ["Solid", "Dashed", "Dots"]),
                TerrainParameter(key: "lineWidth", title: "Width", keyPath: \.lineWidth, range: 0.25...3,
                                 format: { String(format: "%.2f pt", $0) }),
                TerrainParameter(key: "dashLength", title: "Dash length", keyPath: \.dashLength, range: 1...20,
                                 format: { String(format: "%.1f pt", $0) }),
                TerrainParameter(key: "dashGap", title: "Dash gap", keyPath: \.dashGap, range: 1...20,
                                 format: { String(format: "%.1f pt", $0) }),
                TerrainParameter(key: "dotSpacing", title: "Dot spacing", keyPath: \.dotSpacing, range: 1.5...20,
                                 format: { String(format: "%.1f pt", $0) }),
                TerrainParameter(key: "dotSize", title: "Dot size", keyPath: \.dotSize, range: 0.5...6,
                                 format: { String(format: "%.1f pt", $0) }),
                TerrainParameter(key: "lineOpacity", title: "Brightness", keyPath: \.lineOpacity, range: 0.1...1, format: percent),
                TerrainParameter(key: "cellSize", title: "Detail", keyPath: \.cellSize, range: 0.5...6,
                                 format: { String(format: "%.1f pt", $0) }),
                TerrainParameter(key: "labelEvery", title: "Height label every", keyPath: \.labelEvery, range: 0...10, step: 1,
                                 format: { $0 == 0 ? "Off" : String(format: "%.0f lines", $0) }),
                TerrainParameter(key: "labelStep", title: "Height per line", keyPath: \.labelStep, range: 1...50, step: 1,
                                 format: { String(format: "%.0f", $0) }),
                TerrainParameter(key: "labelSize", title: "Label size", keyPath: \.labelSize, range: 6...14,
                                 format: { String(format: "%.1f pt", $0) }),
            ]),
            ("Filter", [
                .choice("filter", "Filter", \.filter, Filter.allCases.map(\.title)),
                TerrainParameter(key: "filterStrength", title: "Strength", keyPath: \.filterStrength, range: 0...1, format: percent),
            ]),
        ]
    }()

    /// The same landscape seen from further away, for a small preview: every length shrunk
    /// by `k`, and no height labels, which would be too small to read.
    func zoomedOut(by k: Double) -> TerrainTuning {
        var t = self
        t.groundScale *= k
        t.drift *= k
        t.elevation *= k
        t.hoverRadius *= k
        t.hillRadius *= k
        t.lineWidth *= max(k, 0.75)
        t.labelEvery = 0
        return t
    }
}

@Observable
final class TerrainStore {
    static let shared = TerrainStore()

    var tuning: TerrainTuning {
        didSet { if tuning != oldValue { save() } }
    }
    @ObservationIgnored private static let defaultsKey = "terrain.v2"

    init() {
        tuning = TerrainTuning(defaultsKey: Self.defaultsKey)
    }

    private func save() {
        tuning.save(defaultsKey: Self.defaultsKey)
    }
}

/// Which landscape a view shows: contour lines, or a grid of dots.
enum Landscape: String {
    case terrain
    case dots
}

/// Warm ink on near-black at night and on warm white by day, following the system's appearance,
/// yellow where the pointer reaches. Renderers read these as they draw; views get the adaptive ones.
enum TerrainPalette {
    private static func color(_ rgb: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
    private static let nightPaper = color(0x0F0C07), nightInk = color(0xDCD8D2), nightAccent = color(0xFFCD28)
    private static let dayPaper = color(0xF5F2EC), dayInk = color(0x26221C), dayAccent = color(0xE39A00)

    static var isDay: Bool { NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua }
    static var paper: NSColor { isDay ? dayPaper : nightPaper }
    static var ink: NSColor { isDay ? dayInk : nightInk }
    static var accent: NSColor { isDay ? dayAccent : nightAccent }

    private static func adaptive(night: NSColor, day: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .aqua ? day : night }
    }
    static let adaptivePaper = adaptive(night: nightPaper, day: dayPaper)
    static let adaptiveInk = adaptive(night: nightInk, day: dayInk)

    /// Dimmed toward the paper rather than made transparent, so crossing lines don't add up.
    static func ink(opacity: Double) -> NSColor {
        paper.blended(withFraction: opacity, of: ink) ?? ink
    }

    /// What far-off lines and ground fade into: the paper, lifted toward the ink.
    static func haze(_ amount: Double) -> NSColor {
        paper.blended(withFraction: amount, of: ink) ?? paper
    }
}

// MARK: - Field

/// Ground plane to screen: turned about the view's centre, tilted away, and every point
/// lifted by its height, so each contour line floats at its own level.
struct TerrainProjection {
    var cx = 0.0, cy = 0.0
    var cosTurn = 1.0, sinTurn = 0.0
    var cosTilt = 1.0, sinTilt = 0.0
    /// Points of lift on screen per line of height.
    var elevation = 0.0
    /// Height of a line in ground points, for depth.
    var rise = 0.0
    /// Nearness at the bottom edge, and from there to the top edge, on the ground plane.
    var fogNear = 0.0, fogRange = 1.0

    init() {}

    init(size: CGSize, tuning: TerrainTuning) {
        let tilt = min(max(tuning.tilt, 0), 80) * .pi / 180, turn = tuning.turn * .pi / 180
        cosTurn = cos(turn); sinTurn = sin(turn)
        cosTilt = cos(tilt); sinTilt = sin(tilt)
        elevation = tuning.elevation * sinTilt
        cx = size.width / 2
        // Lifting raises the ground; drop it back by half the relief so it stays centred.
        cy = size.height / 2 + tuning.groundRelief * 0.5 * elevation
        rise = tuning.elevation
        fogNear = (size.height - cy) / cosTilt * sinTilt
        fogRange = max(size.height / cosTilt * sinTilt, 1)
    }

    @inline(__always) func screen(_ gx: Double, _ gy: Double, _ height: Double) -> CGPoint {
        CGPoint(x: cx + cosTurn * gx - sinTurn * gy,
                y: cy + (sinTurn * gx + cosTurn * gy) * cosTilt - height * elevation)
    }

    /// How close a point is to the eye, which looks down at the tilt: lower on the screen
    /// and higher up are both nearer, so peaks rise out of the fog.
    @inline(__always) func nearness(_ gx: Double, _ gy: Double, _ height: Double) -> Double {
        (sinTurn * gx + cosTurn * gy) * sinTilt + height * rise * cosTilt
    }

    /// The nearness of the ground plane seen at a height on the screen.
    func groundNearness(atScreenY y: Double) -> Double {
        (y - cy) / cosTilt * sinTilt
    }

    /// How much fog lies in front of a point that near, 0...1. Matches the shader.
    func fog(_ nearness: Double, tuning: TerrainTuning) -> Double {
        // 0 at the bottom edge, 1 at the top, on the ground plane.
        let t = (fogNear - nearness) / fogRange
        let back = tuning.fogDensity * 6 * max(t - tuning.fogStart, 0)
        let front = tuning.fogFront * 3 * max(tuning.fogFrontReach - t, 0) / tuning.fogFrontReach
        return 1 - exp(-(back + front))
    }

    @inline(__always) func ground(_ point: CGPoint, height: Double) -> (x: Double, y: Double) {
        let a = point.x - cx, b = (point.y - cy + height * elevation) / cosTilt
        return (cosTurn * a + sinTurn * b, -sinTurn * a + cosTurn * b)
    }
}


/// The height field under the header: noisy ground that never goes flat, a bump that
/// follows the pointer, and hills raised by pressing. Positions are on the ground plane, in points.
///
/// The GPU samples and draws it (`TerrainRenderer`); this keeps the state, maps the pointer
/// onto the ground, and places the height labels from a coarse copy the GPU hands back.
final class TerrainField {
    struct Hill {
        var x, y: Double
        /// Strongest press so far, 0...1. Sets the hill's footprint and how high it climbs.
        var peak = 0.0
        /// Current height as a fraction of `TerrainTuning.hillHeight`.
        var amount = 0.0
        /// How yellow its lines are: full while held, gone soon after.
        var tint = 0.0
        var held = true
        var fading = false
    }

    struct Bump { var x, y, inverseRadius2, height: Double }

    /// Where the lines turn yellow: graded around the pointer, solid on a held hill.
    struct Tint { var x, y, inverseReach2, strength: Double; var solid: Bool }

    struct Grid {
        var originX = 0.0, originY = 0.0, cell = 1.0
        var nx = 0, ny = 0
    }

    /// Everything the GPU needs for one frame.
    struct Frame {
        var projection: TerrainProjection
        var grid: Grid
        /// Where to sample the coarse copy for next frame.
        var coarse: Grid
        var bumps: [Bump]
        var tints: [Tint]
        var noiseOffsetX, noiseOffsetY: Double
        var firstLevel: Int
        var levelCount: Int
    }

    struct Label: Equatable {
        var position: CGPoint
        var angle: Double
        var text: String
        var tint: Double
        var fog: Double
        /// The fog on the ground behind it, for its halo.
        var groundFog: Double
    }

    var tuning = TerrainTuning()
    private(set) var hills: [Hill] = []
    private var hoverPosition = (x: 0.0, y: 0.0)
    private var hoverTarget = (x: 0.0, y: 0.0)
    private var hoverShown = false
    private var hoverAmount = 0.0
    private var driftDistance = 0.0
    private(set) var projection = TerrainProjection()

    /// The coarse copy of the field, a frame late, for labels and the pointer: the ground
    /// alone, and with hills and hover.
    static let coarseCell = 6.0
    /// Dashes and dots are placed along lines traced from the copy, so it's finer for them.
    static let fineCoarseCell = 3.0
    private var coarse = Grid()
    private var ground: [Double] = []
    private var values: [Double] = []
    // Scratch for chaining segments into lines, by grid edge.
    private var nextA: [Int32] = [], nextB: [Int32] = [], linked: [Int32] = [], visited: [Int32] = []
    private var generation: Int32 = 0

    /// Nothing moves but the drifting ground, which looks smooth at a low frame rate.
    var isOnlyDrifting: Bool {
        hills.isEmpty && hoverAmount == (hoverShown ? 1 : 0) && hoverPosition == hoverTarget
    }

    var isSettled: Bool { isOnlyDrifting && tuning.drift == 0 }

    /// The ground point drawn under a point in the view. Hills and hover are left out so a
    /// bump can't push the point it's drawn from.
    func groundPoint(under point: CGPoint) -> (x: Double, y: Double) {
        var g = projection.ground(point, height: 0)
        for _ in 0..<4 { g = projection.ground(point, height: groundHeight(g.x, g.y)) }
        return g
    }

    func hover(_ point: CGPoint?) {
        guard let point else { hoverShown = false; return }
        let g = groundPoint(under: point)
        // Coming back in: appear under the pointer rather than sweeping over from where it left.
        if hoverAmount < 0.01 { hoverPosition = g }
        hoverTarget = g
        hoverShown = true
    }

    func press(at point: CGPoint, strength: Double) {
        let g = groundPoint(under: point)
        hills.append(Hill(x: g.x, y: g.y, peak: strength))
        if hills.count > 32, let old = hills.firstIndex(where: { !$0.held }) { hills.remove(at: old) }
    }

    func hold(strength: Double) {
        for i in hills.indices where hills[i].held { hills[i].peak = max(hills[i].peak, strength) }
    }

    func release() {
        for i in hills.indices { hills[i].held = false }
    }

    func step(_ dt: Double) {
        driftDistance += tuning.drift * dt

        let follow = tuning.hoverLag <= 0 ? 1 : 1 - exp(-dt / tuning.hoverLag)
        hoverPosition.x += (hoverTarget.x - hoverPosition.x) * follow
        hoverPosition.y += (hoverTarget.y - hoverPosition.y) * follow
        if hypot(hoverTarget.x - hoverPosition.x, hoverTarget.y - hoverPosition.y) < 0.05 { hoverPosition = hoverTarget }
        let shown = hoverShown ? 1.0 : 0
        hoverAmount += (shown - hoverAmount) * (1 - exp(-dt / 0.2))
        if abs(shown - hoverAmount) < 0.002 { hoverAmount = shown }

        let rise = tuning.riseTime <= 0 ? 1 : 1 - exp(-dt / tuning.riseTime)
        let fade = exp(-M_LN2 * dt / tuning.fadeHalfLife)
        let tint = 1 - exp(-dt / 0.06)
        for i in hills.indices {
            // A quick tap still climbs to its peak before it starts to sink.
            if !hills[i].held, hills[i].amount >= hills[i].peak * 0.97 { hills[i].fading = true }
            if hills[i].fading { hills[i].amount *= fade }
            else { hills[i].amount += (hills[i].peak - hills[i].amount) * rise }
            hills[i].tint += ((hills[i].held ? 1 : 0) - hills[i].tint) * tint
            if hills[i].tint < 0.002 { hills[i].tint = 0 }
        }
        hills.removeAll { $0.fading && $0.amount * tuning.hillHeight < 0.05 }
    }

    // MARK: Frame

    /// Updates the projection for `size` and describes the frame for the GPU.
    func frame(in size: CGSize) -> Frame {
        projection = TerrainProjection(size: size, tuning: tuning)
        let bumps = currentBumps()
        let low = min(0, bumps.map(\.height).min() ?? 0)
        let high = tuning.groundRelief + bumps.map { max($0.height, 0) }.reduce(0, +)
        let firstLevel = Int(low.rounded(.down))
        return Frame(projection: projection, grid: grid(covering: size, cell: tuning.cellSize),
                     coarse: grid(covering: size, cell: tuning.style == .solid ? Self.coarseCell : Self.fineCoarseCell), bumps: bumps,
                     tints: currentTints(), noiseOffsetX: driftDistance * 0.92, noiseOffsetY: driftDistance * 0.39,
                     firstLevel: firstLevel, levelCount: min(Int(high.rounded(.up)) - firstLevel + 1, 256))
    }

    private func currentBumps() -> [Bump] {
        var bumps: [Bump] = []
        if hoverAmount > 0, tuning.hoverHeight != 0 {
            let r = tuning.hoverRadius
            bumps.append(Bump(x: hoverPosition.x, y: hoverPosition.y, inverseRadius2: 1 / (r * r),
                              height: tuning.hoverHeight * hoverAmount))
        }
        for hill in hills where hill.amount > 0 {
            let r = hillRadius(hill)
            bumps.append(Bump(x: hill.x, y: hill.y, inverseRadius2: 1 / (r * r), height: tuning.hillHeight * hill.amount))
        }
        return bumps
    }

    private func hillRadius(_ hill: Hill) -> Double {
        let g = tuning.pressureGrowsRadius
        return tuning.hillRadius * (1 - g + g * hill.peak)
    }

    private func currentTints() -> [Tint] {
        var tints: [Tint] = []
        let reach = 1.24
        if hoverAmount > 0, tuning.hoverTint > 0 {
            let r = tuning.hoverRadius * reach
            tints.append(Tint(x: hoverPosition.x, y: hoverPosition.y, inverseReach2: 1 / (r * r),
                              strength: tuning.hoverTint * hoverAmount, solid: false))
        }
        for hill in hills where hill.tint > 0 {
            let r = hillRadius(hill) * reach
            tints.append(Tint(x: hill.x, y: hill.y, inverseReach2: 1 / (r * r), strength: hill.tint, solid: true))
        }
        return tints
    }

    /// The same falloff as the shader, for label colours.
    private func tint(at x: Double, _ y: Double, _ tints: [Tint]) -> Double {
        var t = 0.0
        for tint in tints {
            let dx = x - tint.x, dy = y - tint.y
            let s2 = (dx * dx + dy * dy) * tint.inverseReach2
            guard s2 < 2.56 else { continue }
            // A peak shape, eased to nothing between 1.2 and 1.6 reaches.
            var e = exp(-3 * s2)
            let s = s2.squareRoot()
            if s > 1.2 { let u = (s - 1.2) / 0.4; e *= 1 - u * u * (3 - 2 * u) }
            t = max(t, tint.strength * (tint.solid ? min(1, e / 0.15) : e))
        }
        return t
    }

    // MARK: Grid

    /// The ground under the view, from its corners at the lowest and highest heights the
    /// tuning allows. Fixed per tuning, so the grid doesn't change size as hills come and go.
    private func grid(covering size: CGSize, cell: Double) -> Grid {
        let top = tuning.groundRelief + tuning.hillHeight + max(0, tuning.hoverHeight)
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        for corner in [CGPoint.zero, CGPoint(x: size.width, y: 0), CGPoint(x: 0, y: size.height), CGPoint(x: size.width, y: size.height)] {
            for h in [min(0, tuning.hoverHeight), top] {
                let g = projection.ground(corner, height: h)
                minX = min(minX, g.x); maxX = max(maxX, g.x); minY = min(minY, g.y); maxY = max(maxY, g.y)
            }
        }
        // Snapped to the cell so lines don't shimmer as the covered area changes.
        var grid = Grid(cell: cell)
        grid.originX = ((minX / cell).rounded(.down) - 1) * cell
        grid.originY = ((minY / cell).rounded(.down) - 1) * cell
        grid.nx = max(2, min(Int(((maxX - grid.originX) / cell).rounded(.up)) + 2, 4096))
        grid.ny = max(2, min(Int(((maxY - grid.originY) / cell).rounded(.up)) + 2, 4096))
        return grid
    }

    func setCoarse(_ grid: Grid, ground: [Float], full: [Float]) {
        coarse = grid
        self.ground = ground.map(Double.init)
        values = full.map(Double.init)
    }

    /// The ground's height from the coarse copy, bilinear between samples; 0 off the grid.
    private func groundHeight(_ x: Double, _ y: Double) -> Double {
        let g = coarse, nx = g.nx
        guard !ground.isEmpty, ground.count == nx * g.ny else { return 0 }
        let fx = (x - g.originX) / g.cell, fy = (y - g.originY) / g.cell
        guard fx >= 0, fy >= 0, fx < Double(nx - 1), fy < Double(g.ny - 1) else { return 0 }
        let i = Int(fx), j = Int(fy), tx = fx - Double(i), ty = fy - Double(j)
        let a = ground[j * nx + i], b = ground[j * nx + i + 1], c = ground[(j + 1) * nx + i], d = ground[(j + 1) * nx + i + 1]
        return a + (b - a) * tx + (c - a) * ty + (a - b - c + d) * tx * ty
    }

    // MARK: Lines on the CPU

    private typealias Polyline = (level: Double, ground: [(x: Double, y: Double)], screen: [CGPoint], closed: Bool)

    /// Contour lines at every `every`-th level, from marching squares over the coarse copy:
    /// on the ground, and lifted onto the screen.
    private func polylines(every: Int, smooth: Bool) -> [Polyline] {
        let nx = coarse.nx, ny = coarse.ny
        guard every > 0, values.count == nx * ny, let lo = values.min(), let hi = values.max() else { return [] }
        let first = Int((lo / Double(every)).rounded(.up)), last = Int((hi / Double(every)).rounded(.down))
        guard last >= first, last - first < 256 else { return [] }
        var segments = [[Int32]](repeating: [], count: last - first + 1)
        for j in 0..<(ny - 1) {
            for i in 0..<(nx - 1) {
                let a = values[j * nx + i], b = values[j * nx + i + 1]
                let c = values[(j + 1) * nx + i + 1], d = values[(j + 1) * nx + i]
                let cellHi = max(a, b, c, d)
                var step = Int((min(a, b, c, d) / Double(every)).rounded(.up))
                while Double(step * every) < cellHi {
                    addSegments(&segments[step - first], Double(step * every), a, b, c, d, i, j)
                    step += 1
                }
            }
        }
        var lines: [Polyline] = []
        for (n, levelSegments) in segments.enumerated() where !levelSegments.isEmpty {
            let level = Double((first + n) * every)
            for line in chain(levelSegments) {
                var g = line.edges.map { edgePoint($0, level) }
                if smooth { g = chaikin(g, closed: line.closed) }
                lines.append((level, g, g.map { projection.screen($0.x, $0.y, level) }, line.closed))
            }
        }
        return lines
    }

    /// One round of corner cutting, so lines from a coarse grid don't show its cells.
    private func chaikin(_ p: [(x: Double, y: Double)], closed: Bool) -> [(x: Double, y: Double)] {
        let n = p.count
        guard n >= 3 else { return p }
        var out: [(x: Double, y: Double)] = []
        out.reserveCapacity(2 * n + 2)
        if !closed { out.append(p[0]) }
        for i in 0..<(closed ? n : n - 1) {
            let a = p[i], b = p[(i + 1) % n]
            out.append((0.75 * a.x + 0.25 * b.x, 0.75 * a.y + 0.25 * b.y))
            out.append((0.25 * a.x + 0.75 * b.x, 0.25 * a.y + 0.75 * b.y))
        }
        if !closed { out.append(p[n - 1]) }
        return out
    }

    /// Height labels along every `labelEvery`-th line. Call after `frame(in:)`.
    func labels() -> [Label] {
        let every = Int(tuning.labelEvery)
        guard every > 0 else { return [] }
        let tints = currentTints()
        var labels: [Label] = []
        for line in polylines(every: every, smooth: false) where line.level != 0 {
            guard let spot = label(on: line.screen) else { continue }
            let foot = line.ground[spot.index]
            labels.append(Label(position: spot.position, angle: spot.angle,
                                text: String(format: "%.0f", line.level * tuning.labelStep),
                                tint: tint(at: foot.x, foot.y, tints),
                                fog: projection.fog(projection.nearness(foot.x, foot.y, line.level), tuning: tuning),
                                groundFog: projection.fog(projection.groundNearness(atScreenY: spot.position.y), tuning: tuning)))
        }
        return labels
    }

    /// A dash, or a dot when both ends meet, on the screen.
    struct Stroke {
        var a, b: CGPoint
        var tint: Double
        var nearness: Double
    }

    /// Dashes or dots along every line, for the styles the GPU can't draw from the field alone:
    /// they need to know how far along the line they are. Call after `frame(in:)`.
    func strokes() -> [Stroke] {
        guard tuning.style != .solid else { return [] }
        let dots = tuning.style == .dots
        let dash = dots ? 0 : tuning.dashLength
        let period = dots ? tuning.dotSpacing : tuning.dashLength + tuning.dashGap
        let tints = currentTints()
        var strokes: [Stroke] = []
        for line in polylines(every: 1, smooth: true) {
            var points = line.screen, ground = line.ground
            if line.closed, let first = points.first, let g = ground.first { points.append(first); ground.append(g) }
            let n = points.count
            guard n >= 2 else { continue }
            var lengths = [0.0]
            lengths.reserveCapacity(n)
            for i in 1..<n { lengths.append(lengths[i - 1] + hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y)) }
            let total = lengths[n - 1]
            // Both ends only move forward, so walking the line once places every stroke.
            func point(at distance: Double, _ cursor: inout Int) -> CGPoint {
                while cursor < n - 2, lengths[cursor + 1] < distance { cursor += 1 }
                let t = min(max((distance - lengths[cursor]) / max(lengths[cursor + 1] - lengths[cursor], 1e-9), 0), 1)
                return CGPoint(x: points[cursor].x + (points[cursor + 1].x - points[cursor].x) * t,
                               y: points[cursor].y + (points[cursor + 1].y - points[cursor].y) * t)
            }
            var start = 0, end = 0
            var distance = dots ? period / 2 : 0
            while distance <= total, strokes.count < 60_000 {
                let a = point(at: distance, &start)
                let b = dots ? a : point(at: min(distance + dash, total), &end)
                let g = ground[start]
                strokes.append(Stroke(a: a, b: b, tint: tint(at: g.x, g.y, tints),
                                      nearness: projection.nearness(g.x, g.y, line.level)))
                distance += period
            }
        }
        return strokes
    }

    /// The yellow line and height chip over a hill being pressed.
    struct Marker: Equatable {
        var base: CGPoint
        var peak: CGPoint
        var text: String
        var opacity: Double
    }

    func markers() -> [Marker] {
        guard tuning.heightMarker > 0 else { return [] }
        return hills.filter { $0.tint > 0.01 }.map { hill in
            let foot = groundHeight(hill.x, hill.y), top = foot + tuning.hillHeight * hill.amount
            return Marker(base: projection.screen(hill.x, hill.y, foot), peak: projection.screen(hill.x, hill.y, top),
                          text: String(format: "%.0f", top * tuning.labelStep), opacity: hill.tint)
        }
    }

    // Grid edges: 2·k runs right from sample k, 2·k + 1 runs down from it.
    @inline(__always) private func right(_ i: Int, _ j: Int) -> Int32 { Int32(2 * (j * coarse.nx + i)) }
    @inline(__always) private func down(_ i: Int, _ j: Int) -> Int32 { Int32(2 * (j * coarse.nx + i) + 1) }

    private func edgePoint(_ edge: Int32, _ level: Double) -> (x: Double, y: Double) {
        let g = coarse
        let k = Int(edge) >> 1, i = k % g.nx, j = k / g.nx
        let a = values[k]
        if edge & 1 == 0 {
            let t = (level - a) / (values[k + 1] - a)
            return (g.originX + (Double(i) + t) * g.cell, g.originY + Double(j) * g.cell)
        } else {
            let t = (level - a) / (values[k + g.nx] - a)
            return (g.originX + Double(i) * g.cell, g.originY + (Double(j) + t) * g.cell)
        }
    }

    /// One cell of marching squares. Corners clockwise from top-left: a, b, c, d.
    @inline(__always)
    private func addSegments(_ out: inout [Int32], _ level: Double, _ a: Double, _ b: Double, _ c: Double, _ d: Double,
                             _ i: Int, _ j: Int) {
        let top = right(i, j), bottom = right(i, j + 1), left = down(i, j), rightEdge = down(i + 1, j)
        func line(_ e1: Int32, _ e2: Int32) { out.append(e1); out.append(e2) }
        let index = (a > level ? 8 : 0) | (b > level ? 4 : 0) | (c > level ? 2 : 0) | (d > level ? 1 : 0)
        let centreAbove = (a + b + c + d) / 4 > level
        switch index {
        case 1, 14: line(left, bottom)
        case 2, 13: line(bottom, rightEdge)
        case 3, 12: line(left, rightEdge)
        case 4, 11: line(top, rightEdge)
        case 6, 9: line(top, bottom)
        case 7, 8: line(top, left)
        case 5: if centreAbove { line(top, left); line(bottom, rightEdge) } else { line(top, rightEdge); line(left, bottom) }
        case 10: if centreAbove { line(top, rightEdge); line(left, bottom) } else { line(top, left); line(bottom, rightEdge) }
        default: break
        }
    }

    /// Joins one level's segments into lines through the edges they share. Each edge is
    /// crossed once per level, so it has at most two neighbours.
    private func chain(_ segments: [Int32]) -> [(edges: [Int32], closed: Bool)] {
        let edgeCount = 2 * coarse.nx * coarse.ny
        if linked.count != edgeCount {
            nextA = Array(repeating: -1, count: edgeCount); nextB = nextA
            linked = Array(repeating: 0, count: edgeCount); visited = linked
            generation = 0
        }
        generation &+= 1
        if generation == 0 {
            for i in linked.indices { linked[i] = 0; visited[i] = 0 }
            generation = 1
        }
        let gen = generation
        func link(_ from: Int32, _ to: Int32) {
            let f = Int(from)
            if linked[f] != gen { linked[f] = gen; nextA[f] = to; nextB[f] = -1 } else { nextB[f] = to }
        }
        for s in stride(from: 0, to: segments.count, by: 2) {
            link(segments[s], segments[s + 1])
            link(segments[s + 1], segments[s])
        }
        var lines: [(edges: [Int32], closed: Bool)] = []
        func walk(from start: Int32) {
            var edges = [start]
            visited[Int(start)] = gen
            var previous: Int32 = -1, current = start, closed = false
            while true {
                var next: Int32 = -1
                for candidate in [nextA[Int(current)], nextB[Int(current)]] where candidate >= 0 && candidate != previous {
                    if visited[Int(candidate)] != gen { next = candidate; break }
                    if candidate == start, edges.count > 2 { closed = true }
                }
                guard next >= 0 else { break }
                visited[Int(next)] = gen
                edges.append(next)
                previous = current
                current = next
            }
            lines.append((edges, closed))
        }
        // Lines that run off the grid first, from one end; then the loops.
        for e in segments where visited[Int(e)] != gen && nextB[Int(e)] == -1 { walk(from: e) }
        for e in segments where visited[Int(e)] != gen { walk(from: e) }
        return lines
    }

    /// Halfway along a line long enough to carry a label, turned to follow it and kept upright.
    private func label(on points: [CGPoint]) -> (position: CGPoint, angle: Double, index: Int)? {
        guard points.count >= 3 else { return nil }
        var lengths = [0.0]
        for i in 1..<points.count { lengths.append(lengths[i - 1] + hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y)) }
        let total = lengths[lengths.count - 1]
        let span = tuning.labelSize * 3
        guard total > span * 2.5 else { return nil }
        let middle = total / 2
        guard let i = lengths.firstIndex(where: { $0 >= middle }) else { return nil }
        let a = lengths.lastIndex(where: { $0 <= middle - span / 2 }) ?? 0
        let b = lengths.firstIndex(where: { $0 >= middle + span / 2 }) ?? points.count - 1
        // Between the samples either side of the middle, so it sits on the line.
        let t = (middle - lengths[i - 1]) / max(lengths[i] - lengths[i - 1], 1e-9)
        let position = CGPoint(x: points[i - 1].x + (points[i].x - points[i - 1].x) * t,
                               y: points[i - 1].y + (points[i].y - points[i - 1].y) * t)
        var angle = atan2(points[b].y - points[a].y, points[b].x - points[a].x)
        if angle > .pi / 2 { angle -= .pi } else if angle < -.pi / 2 { angle += .pi }
        return (position, angle, i)
    }
}

// MARK: - View

extension NSWindow {
    /// Open, showing, and in the frontmost app: the only time a landscape runs. Any of wdrive's
    /// windows will do, so a preview keeps moving beside the panel that tunes it.
    @MainActor var isInForeground: Bool { NSApp.isActive && occlusionState.contains(.visible) }

    /// Calls `change` whenever `isInForeground` may have changed.
    @MainActor func observeForeground(_ change: @escaping @MainActor () -> Void) -> [NSObjectProtocol] {
        let sources: [(Notification.Name, Any?)] = [(NSWindow.didChangeOcclusionStateNotification, self),
                                                    (NSApplication.didBecomeActiveNotification, nil),
                                                    (NSApplication.didResignActiveNotification, nil)]
        return sources.map { name, object in
            NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { _ in
                MainActor.assumeIsolated { change() }
            }
        }
    }
}

/// Shows the terrain and plays with the pointer: a bump follows it across all the displays,
/// scaled down onto the header, and pressing (here, or anywhere else) raises a hill there,
/// as big as the press is hard or as long as it's held. Dragging past a few points moves the window instead,
/// since the header stands in for the title bar.
final class TerrainView: NSView, MTKViewDelegate {
    var tuning = TerrainTuning() {
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
    /// Off: clicks go to whatever is underneath, and the terrain only follows the pointer.
    var interactive = true

    private let field = TerrainField()
    private let metalView: TerrainMetalView?
    private let canvas = TerrainCanvas()
    private let startTime = CACurrentMediaTime()
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval?
    private var foregroundObservers: [NSObjectProtocol] = []
    private var pointerMonitors: [Any] = []
    private var mouseDown: NSEvent?
    private var trackpadPressure: Double?
    /// When the current press began, wherever it is; nil when nothing is pressed.
    private var pressStart: CFTimeInterval?
    private var pressIsElsewhere = false
    private var isForeground: Bool { window?.isInForeground == true }

    override init(frame: NSRect) {
        // `--snapshot` can't read a Metal layer back, so it renders offscreen in `draw(_:)`.
        metalView = Snapshot.path == nil ? TerrainRenderer.shared.map { TerrainMetalView(device: $0.device) } : nil
        super.init(frame: frame)
        // Lifted lines reach past the edges.
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
                followPointer()
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
        if let global = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.followPointer() }
        }) { pointerMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { [weak self] event in
            self?.followPointer()
            return event
        }) { pointerMonitors.append(local) }
        // Clicks in other apps raise hills where the pointer shows on the header.
        if let clicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.clickElsewhere(event) }
        }) { pointerMonitors.append(clicks) }
    }

    private func stopWatchingPointer() {
        pointerMonitors.forEach(NSEvent.removeMonitor)
        pointerMonitors = []
        // Its release won't be seen now.
        if pressStart != nil { endPress() }
    }

    override func layout() {
        super.layout()
        followPointer()
        redraw()
    }

    /// Runs the display link only while something moves and the window is in the foreground.
    private func updateAnimation() {
        guard let link else { return }
        let paused = (field.isSettled && !tuning.filterKind.animates) || !isForeground
        if paused { lastTick = nil }
        if link.isPaused != paused { link.isPaused = paused }
        // Drift and filters look fine at a low rate; the pointer and hills get the full one.
        let rate = field.isOnlyDrifting ? CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
                                        : CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        if link.preferredFrameRateRange != rate { link.preferredFrameRateRange = rate }
    }

    @objc private func tick(_ link: CADisplayLink) {
        let dt = lastTick.map { min(max(link.timestamp - $0, 0), 0.1) } ?? 1.0 / 60
        lastTick = link.timestamp
        if pressStart != nil { field.hold(strength: strength()) }
        field.step(dt)
        redraw()
        updateAnimation()
    }

    private func redraw() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        if let metalView { metalView.draw() } else { needsDisplay = true }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // After the app's appearance has caught up, which the palette reads.
        DispatchQueue.main.async { [weak self] in self?.redraw() }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard metalView == nil, let renderer = TerrainRenderer.shared, let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = Double(window?.backingScaleFactor ?? 2)
        // Once for the coarse copy the labels and dashes come from, then for real.
        _ = renderer.image(scene(), size: bounds.size, scale: scale, canvas: canvas)
        if let coarse = canvas.latest() { field.setCoarse(coarse.grid, ground: coarse.ground, full: coarse.full) }
        guard let image = renderer.image(scene(), size: bounds.size, scale: scale, canvas: canvas) else { return }
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: bounds)
        context.restoreGState()
    }

    private func scene() -> TerrainRenderer.Scene {
        let frame = field.frame(in: bounds.size)
        return TerrainRenderer.Scene(frame: frame, tuning: tuning, labels: field.labels(), markers: field.markers(),
                                     strokes: field.strokes(), time: CACurrentMediaTime() - startTime)
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        if let coarse = canvas.latest() { field.setCoarse(coarse.grid, ground: coarse.ground, full: coarse.full) }
        TerrainRenderer.shared?.draw(scene(), in: view, canvas: canvas)
    }

    // MARK: Pointer

    override func mouseDown(with event: NSEvent) {
        mouseDown = event
        trackpadPressure = nil
        pressStart = CACurrentMediaTime()
        field.press(at: convert(event.locationInWindow, from: nil), strength: strength())
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
        let item = NSMenuItem(title: "Tune Terrain…", action: #selector(openTuning), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func openTuning() { TuningWindow.terrain.show() }

    /// The pointer anywhere on the displays, as macOS arranges them, mapped onto the header.
    /// The pen moves the same pointer, so it shows up here too.
    private func pointerOnHeader() -> CGPoint? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        if let locate { return locate(bounds.size) }
        let desktop = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        guard !desktop.isNull, desktop.width > 0, desktop.height > 0 else { return nil }
        let p = NSEvent.mouseLocation
        let u = min(max((p.x - desktop.minX) / desktop.width, 0), 1)
        let v = min(max((desktop.maxY - p.y) / desktop.height, 0), 1)
        return CGPoint(x: u * bounds.width, y: v * bounds.height)
    }

    private func followPointer() {
        field.hover(pointerOnHeader())
        updateAnimation()
    }

    private func clickElsewhere(_ event: NSEvent) {
        if event.type == .leftMouseUp {
            if pressIsElsewhere { endPress() }
            return
        }
        guard tuning.clicksAnywhere > 0, pressStart == nil, let point = pointerOnHeader() else { return }
        pressIsElsewhere = true
        pressStart = CACurrentMediaTime()
        trackpadPressure = nil
        field.hover(point)
        field.press(at: point, strength: strength())
        updateAnimation()
    }

    private func endPress() {
        mouseDown = nil
        pressStart = nil
        pressIsElsewhere = false
        trackpadPressure = nil
        field.release()
        updateAnimation()
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

struct TerrainSurface: NSViewRepresentable {
    let tuning: TerrainTuning
    let pen: () -> LiveState
    var interactive = true
    var locate: ((CGSize) -> CGPoint?)?

    func makeNSView(context: Context) -> TerrainView {
        let view = TerrainView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: TerrainView, context: Context) {
        view.tuning = tuning
        view.pen = pen
        view.interactive = interactive
        view.locate = locate
    }
}
