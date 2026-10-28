import CoreGraphics
import Testing
@testable import PenCore

func bytes(_ hex: String) -> [UInt8] {
    var out: [UInt8] = []
    var it = hex.makeIterator()
    while let a = it.next(), let b = it.next() { out.append(UInt8(String([a, b]), radix: 16)!) }
    return out
}

func decode(_ layout: PenLayout, _ report: [UInt8]) -> PenSample {
    report.withUnsafeBufferPointer { layout.decode($0.baseAddress!, $0.count) }
}

@Suite struct DescriptorTests {
    @Test func wacomPTH660() throws {
        let parsed = HIDReportDescriptor.parse(bytes(wacomPTH660Descriptor))
        #expect(parsed.usesReportIDs)
        #expect(parsed.pens.count == 1)
        let pen = try #require(parsed.pens.first)
        #expect(pen.reportID == 0x10)
        #expect(pen.x.bitOffset == 16 && pen.x.bitSize == 24 && pen.x.logicalMax == 44800)
        #expect(pen.y.bitOffset == 40 && pen.y.bitSize == 24 && pen.y.logicalMax == 29600)
        #expect(pen.pressureLevels == 8192)
        #expect(abs(pen.widthMM! - 224) < 0.01)
        #expect(abs(pen.heightMM! - 148) < 0.01)
        #expect(pen.tipSwitch?.bitOffset == 8)
        #expect(pen.barrel?.bitOffset == 9)
        #expect(pen.secondaryBarrel?.bitOffset == 10)
        #expect(pen.inRange?.bitOffset == 13)

        // Pen hovering at (22400, 7400), lower button held.
        var report = [UInt8](repeating: 0, count: 27)
        report[0] = 0x10
        report[1] = 0b0010_0010            // in range + barrel
        report[2] = 0x80; report[3] = 0x57  // X = 0x005780
        report[5] = 0xE8; report[6] = 0x1C  // Y = 0x001CE8
        var s = decode(pen, report)
        #expect(abs(s.x - 0.5) < 1e-9 && abs(s.y - 0.25) < 1e-9)
        #expect(s.inRange && s.barrel && !s.secondaryBarrel && !s.tipSwitch && !s.eraser)
        #expect(s.pressure == 0)

        // Touching with full pressure, eraser end (invert bit).
        report[1] = 0b0011_0001
        report[8] = 0xFF; report[9] = 0x1F
        s = decode(pen, report)
        #expect(s.pressure == 1 && s.tipSwitch && s.eraser)

        report[1] = 0  // left proximity
        #expect(!decode(pen, report).inRange)
    }

    /// Typical UC-Logic / XP-Pen style standard digitizer interface: Push/Pop, inches, 16-bit fields.
    @Test func standardDigitizer() throws {
        let desc = bytes(
            "050D" + "0902" + "A101" + "8507" + "0920" + "A100" +
            "0942" + "0944" + "0945" + "093C" + "1500" + "2501" + "7501" + "9504" + "8102" +
            "9501" + "8103" + "0932" + "8102" + "9502" + "8103" +
            "7510" + "9501" + "3500" + "A4" + "0501" + "0930" + "6513" + "550D" + "4710270000" + "2750C30000" + "8102" +
            "0931" + "4770170000" + "27F0490000" + "8102" + "B4" +
            "0930" + "2700200000" + "8102" + "C0" + "C0")
        let parsed = HIDReportDescriptor.parse(desc)
        let pen = try #require(parsed.pens.first)
        #expect(pen.reportID == 7)
        #expect(pen.x.bitOffset == 16 && pen.y.bitOffset == 32 && pen.pressure?.bitOffset == 48)
        #expect(pen.x.logicalMax == 50000 && pen.y.logicalMax == 18928)
        #expect(abs(pen.widthMM! - 254) < 0.01)   // 10.000 in
        #expect(abs(pen.heightMM! - 152.4) < 0.01) // 6.000 in
        #expect(pen.pressure?.logicalMax == 8192)
        #expect(pen.secondaryBarrel == nil && pen.eraser != nil)

        let s = decode(pen, [0x07, 0b0010_0001, 0x50, 0xC3, 0, 0, 0x00, 0x10])
        #expect(s.x == 1 && s.y == 0 && s.tipSwitch && s.inRange && abs(s.pressure - 0.5) < 1e-9)
    }

    @Test func wacomTouchInterfaceIsIgnored() {
        #expect(HIDReportDescriptor.parse(bytes(wacomPTH660TouchDescriptor)).pens.isEmpty)
    }

    @Test func fingerCollectionsAreIgnored() {
        let desc = bytes("050D" + "0905" + "A101" + "8501" + "0922" + "A102" + "0501" + "0930" + "0931" +
                         "7510" + "9502" + "2700100000" + "8102" + "C0" + "C0")
        #expect(HIDReportDescriptor.parse(desc).pens.isEmpty)
    }
}

@Suite struct ProcessorTests {
    var config: PenConfig = {
        var c = PenConfig()
        c.target = CGRect(x: 0, y: 0, width: 1001, height: 1001)  // 1 normalized unit = 1000 pt
        c.tapRadius = 5
        c.tipThreshold = 0.1
        return c
    }()

    func run(_ p: inout PenProcessor, _ samples: [(PenSample, UInt64)], config: PenConfig? = nil) -> [PenEvent] {
        var out: [PenEvent] = []
        for (s, t) in samples { p.process(s, config: config ?? self.config, now: t * 1_000_000) { out.append($0) } }
        return out
    }

    func downs(_ e: [PenEvent]) -> [PenEvent] { e.filter { if case .down = $0 { true } else { false } } }
    func ups(_ e: [PenEvent]) -> [PenEvent] { e.filter { if case .up = $0 { true } else { false } } }

    @Test func mapsAreaAndLeftHanded() {
        var c = config
        c.area = CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        #expect(PenProcessor.map(PenSample(x: 0.75, y: 0.5), c) == CGPoint(x: 500, y: 0))
        #expect(PenProcessor.map(PenSample(x: 0.1, y: 0.1), c) == CGPoint(x: 0, y: 0))  // clamped
        c.leftHanded = true
        #expect(PenProcessor.map(PenSample(x: 0.25, y: 0.5), c) == CGPoint(x: 500, y: 0))
    }

    @Test func wobblyTapIsACleanClick() {
        var p = PenProcessor()
        let e = run(&p, [
            (PenSample(x: 0.5, y: 0.5), 0),
            (PenSample(x: 0.5, y: 0.5, pressure: 0.3), 10),
            (PenSample(x: 0.503, y: 0.502, pressure: 0.4), 20),   // 3.6 pt wobble
            (PenSample(x: 0.504, y: 0.5, pressure: 0.05), 30),     // lifting
        ])
        #expect(downs(e) == [.down(button: 0, at: CGPoint(x: 500, y: 500), clicks: 1, held: 1)])
        #expect(ups(e) == [.up(button: 0, at: CGPoint(x: 500, y: 500), clicks: 1, held: 0)])
        // Only the hover move before touchdown and the hover move after lifting.
        #expect(e.filter { if case .move = $0 { true } else { false } }.count == 2)
        #expect(e.last == .move(CGPoint(x: 504, y: 500), held: 0))
    }

    @Test func movingPastTheRadiusDrags() {
        var p = PenProcessor()
        let e = run(&p, [
            (PenSample(x: 0.5, y: 0.5, pressure: 0.3), 0),
            (PenSample(x: 0.51, y: 0.5, pressure: 0.3), 200),  // 10 pt after the grace period
            (PenSample(x: 0.52, y: 0.5, pressure: 0.3), 210),
            (PenSample(x: 0.52, y: 0.5, pressure: 0), 220),
        ])
        #expect(e.contains(.move(CGPoint(x: 510, y: 500), held: 1)))
        #expect(e.contains(.move(CGPoint(x: 520, y: 500), held: 1)))
        #expect(ups(e) == [.up(button: 0, at: CGPoint(x: 520, y: 500), clicks: 1, held: 0)])
    }

    @Test func graceRadiusRightAfterTouchdown() {
        var p = PenProcessor()
        // 10 pt within 150 ms stays pinned (grace radius 12.5), the same 10 pt later does not.
        var e = run(&p, [(PenSample(x: 0.5, y: 0.5, pressure: 0.3), 0), (PenSample(x: 0.51, y: 0.5, pressure: 0.3), 50)])
        #expect(!e.contains(.move(CGPoint(x: 510, y: 500), held: 1)))
        e = run(&p, [(PenSample(x: 0.51, y: 0.5, pressure: 0.3), 160)])
        #expect(e == [.move(CGPoint(x: 510, y: 500), held: 1)])
    }

    @Test func doubleTapSnapsAndCounts() {
        var p = PenProcessor()
        let e = run(&p, [
            (PenSample(x: 0.5, y: 0.5, pressure: 0.3), 0),
            (PenSample(x: 0.5, y: 0.5, pressure: 0), 50),
            (PenSample(x: 0.508, y: 0.5, pressure: 0), 100),
            (PenSample(x: 0.508, y: 0.5, pressure: 0.3), 150),   // 8 pt away, within snap distance
            (PenSample(x: 0.508, y: 0.5, pressure: 0), 200),
        ])
        #expect(downs(e) == [
            .down(button: 0, at: CGPoint(x: 500, y: 500), clicks: 1, held: 1),
            .down(button: 0, at: CGPoint(x: 500, y: 500), clicks: 2, held: 1),
        ])
        #expect(ups(e).last == .up(button: 0, at: CGPoint(x: 500, y: 500), clicks: 2, held: 0))
    }

    @Test func offMeansNoPinning() {
        var c = config
        c.tapRadius = 0
        var p = PenProcessor()
        let e = run(&p, [(PenSample(x: 0.5, y: 0.5, pressure: 0.3), 0), (PenSample(x: 0.501, y: 0.5, pressure: 0.3), 10)], config: c)
        #expect(e.last == .move(CGPoint(x: 501, y: 500), held: 1))
    }

    @Test func hysteresis() {
        var p = PenProcessor()
        let e = run(&p, [
            (PenSample(x: 0.5, y: 0.5, pressure: 0.09), 0),    // below threshold
            (PenSample(x: 0.5, y: 0.5, pressure: 0.11), 10),   // press
            (PenSample(x: 0.5, y: 0.5, pressure: 0.08), 20),   // still above 75 %
            (PenSample(x: 0.5, y: 0.5, pressure: 0.07), 30),   // release
        ])
        #expect(downs(e).count == 1)
        #expect(ups(e).count == 1)
        #expect(e.firstIndex(where: { if case .up = $0 { true } else { false } }) == e.count - 1)
    }

    @Test func sideButtonsAndProximity() {
        var c = config
        c.lower = .rightClick
        c.upper = .middleClick
        var p = PenProcessor()
        let e = run(&p, [
            (PenSample(x: 0.2, y: 0.2, barrel: true), 0),
            (PenSample(x: 0.2, y: 0.2, barrel: true, secondaryBarrel: true), 10),
            (PenSample(x: 0.2, y: 0.2, inRange: false), 20),
        ], config: c)
        #expect(downs(e) == [
            .down(button: 1, at: CGPoint(x: 200, y: 200), clicks: 1, held: 2),
            .down(button: 2, at: CGPoint(x: 200, y: 200), clicks: 1, held: 6),
        ])
        #expect(Set(ups(e).map { if case let .up(b, _, _, _) = $0 { b } else { -1 } }) == [1, 2])
        #expect(!p.isTouching)
    }

    @Test func eraserUsesItsOwnAction() {
        var c = config
        c.eraser = .middleClick
        var p = PenProcessor()
        let e = run(&p, [(PenSample(x: 0.5, y: 0.5, pressure: 0.5, eraser: true), 0), (PenSample(x: 0.5, y: 0.5, eraser: true), 10)], config: c)
        #expect(downs(e) == [.down(button: 2, at: CGPoint(x: 500, y: 500), clicks: 1, held: 4)])
        #expect(ups(e).count == 1)
    }
}

@Suite struct MultiDisplayTests {
    // Two 2560×1440 displays; in macOS the left one sits 13 pt lower.
    let left = CGRect(x: -2560, y: 13, width: 2560, height: 1440)
    let main = CGRect(x: 0, y: 0, width: 2560, height: 1440)

    @Test func customArrangementMapsToRealScreens() {
        var c = PenConfig()
        // For the tablet, the user lined them up flush at the top.
        let layoutLeft = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let layoutMain = CGRect(x: 2560, y: 0, width: 2560, height: 1440)
        c.segments = [DisplaySegment(layout: layoutLeft, screen: left), DisplaySegment(layout: layoutMain, screen: main)]
        c.target = layoutLeft.union(layoutMain)
        #expect(PenProcessor.map(PenSample(x: 0, y: 0), c) == CGPoint(x: -2560, y: 13))
        #expect(PenProcessor.map(PenSample(x: 1, y: 1), c) == CGPoint(x: 2559, y: 1439))
        #expect(PenProcessor.map(PenSample(x: 0.75, y: 0.5), c).x > 0)
    }

    @Test func gapsGoToTheNearestDisplay() {
        var c = PenConfig()
        c.segments = [DisplaySegment(layout: left, screen: left), DisplaySegment(layout: main, screen: main)]
        c.target = left.union(main)  // y 0...1453: the left display's top 13 pt and main's bottom 13 pt are gaps
        let topLeft = PenProcessor.map(PenSample(x: 0, y: 0), c)
        #expect(topLeft == CGPoint(x: -2560, y: 13))
        let bottomRight = PenProcessor.map(PenSample(x: 1, y: 1), c)
        #expect(bottomRight == CGPoint(x: 2559, y: 1439))
    }

    @Test func snapsSideBySideAndAligns() {
        // Dropped a bit right of main and 40 pt low: lands flush right, tops aligned.
        let dropped = CGRect(x: 2600, y: 40, width: 2560, height: 1440)
        #expect(DisplayArrangement.snap(dropped, to: [main]) == CGRect(x: 2560, y: 0, width: 2560, height: 1440))
        // Dropped overlapping from the left: pushed out to the left.
        let overlapping = CGRect(x: -2000, y: 300, width: 2560, height: 1440)
        #expect(DisplayArrangement.snap(overlapping, to: [main]) == CGRect(x: -2560, y: 300, width: 2560, height: 1440))
        // Small display dropped above: sits on top, centred if close.
        let small = CGRect(x: 600, y: -1200, width: 1440, height: 900)
        #expect(DisplayArrangement.snap(small, to: [main]) == CGRect(x: 560, y: -900, width: 1440, height: 900))
    }
}
