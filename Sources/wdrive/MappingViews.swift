import PenCore
import SwiftUI

/// All displays as arranged for the tablet, at their real proportions. Drag one to rearrange.
struct DisplayMapView: View {
    @Bindable var model: AppModel

    private struct Drag {
        var id: String
        var startOrigin: CGPoint
        var translation: CGSize
        /// Frozen while dragging so the preview doesn't rescale under the pointer.
        var union: CGRect
    }

    @State private var drag: Drag?

    var body: some View {
        let union = drag?.union ?? model.layoutUnion
        if union.isNull || union.isEmpty {
            Text("No displays").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
        } else {
            GeometryReader { geo in
                let scale = min(geo.size.width / union.width, geo.size.height / union.height)
                let offset = CGPoint(x: (geo.size.width - union.width * scale) / 2,
                                     y: (geo.size.height - union.height * scale) / 2)
                let toView = { (r: CGRect) in
                    CGRect(x: offset.x + (r.minX - union.minX) * scale, y: offset.y + (r.minY - union.minY) * scale,
                           width: r.width * scale, height: r.height * scale)
                }
                let mapped = Set(model.mappedDisplays.map(\.id))

                ZStack(alignment: .topLeading) {
                    ForEach(model.displays) { display in
                        let frame = frame(of: display)
                        let r = toView(frame).insetBy(dx: 1.5, dy: 1.5)
                        DisplayTile(name: display.name, isMain: display.isMain, mapped: mapped.contains(display.id),
                                    lifted: drag?.id == display.id)
                            .frame(width: r.width, height: r.height)
                            .position(x: r.midX, y: r.midY)
                            .zIndex(drag?.id == display.id ? 1 : 0)
                            .gesture(model.displays.count > 1 ? dragGesture(display, union: union, scale: scale) : nil)
                    }

                    if drag == nil, let p = model.livePenLayoutPoint {
                        let v = toView(CGRect(origin: p, size: .zero)).origin
                        Circle()
                            .fill(model.live.tip || model.live.eraser ? Color.accentColor : Color.primary.opacity(0.6))
                            .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
                            .frame(width: 10, height: 10)
                            .position(v)
                            .allowsHitTesting(false)
                    }
                }
            }
            .aspectRatio(union.width / union.height, contentMode: .fit)
            .frame(maxHeight: 200)
            .frame(maxWidth: .infinity)
        }
    }

    private func frame(of display: DisplayInfo) -> CGRect {
        var f = model.layoutFrame(display)
        if let drag, drag.id == display.id {
            f.origin = CGPoint(x: drag.startOrigin.x + drag.translation.width, y: drag.startOrigin.y + drag.translation.height)
        }
        return f
    }

    private func dragGesture(_ display: DisplayInfo, union: CGRect, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if drag == nil {
                    drag = Drag(id: display.id, startOrigin: model.layoutFrame(display).origin, translation: .zero, union: union)
                }
                drag?.translation = CGSize(width: value.translation.width / scale, height: value.translation.height / scale)
            }
            .onEnded { _ in
                guard let drag else { return }
                model.moveDisplay(drag.id, to: CGPoint(x: drag.startOrigin.x + drag.translation.width,
                                                       y: drag.startOrigin.y + drag.translation.height))
                withAnimation(.snappy(duration: 0.2)) { self.drag = nil }
            }
    }
}

private struct DisplayTile: View {
    let name: String
    let isMain: Bool
    let mapped: Bool
    let lifted: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(mapped ? AnyShapeStyle(Color.accentColor.opacity(0.22)) : AnyShapeStyle(Color.primary.opacity(0.07)))
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(mapped ? Color.accentColor : Color.primary.opacity(0.18), lineWidth: mapped ? 1.5 : 1)
                if isMain {
                    // The menu bar, as in the macOS Displays arrangement.
                    UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(0.22))
                        .frame(height: max(3, geo.size.height * 0.05))
                }
                Text(name)
                    .font(.caption2)
                    .foregroundStyle(mapped ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .shadow(color: .black.opacity(lifted ? 0.25 : 0), radius: 6, y: 2)
        .contentShape(Rectangle())
    }
}

/// The tablet surface with its active area. The mapped displays are drawn inside the area
/// so it's clear which part of the tablet lands where.
struct TabletSurface: View {
    enum Style {
        /// Outlined area over tinted displays, with handles on the corners.
        case classic
        /// The terrain, faded except where the displays are. The area's edges and corners resize
        /// it, shown only by the pointer. Sizes itself to the tablet's shape, with a margin around it.
        case terrain
        /// The same with the dot grid instead of the terrain.
        case dots
    }

    @Bindable var model: AppModel
    var style = Style.classic
    @State private var dragStart: CGRect?
    @State private var hovering = false
    /// Where the pointer is over the terrain style's surface, if it is.
    @State private var pointer: CGPoint?
    /// A button or the pen's tip is down over the terrain style's surface.
    @State private var pressing = false

    private enum Corner: CaseIterable, Identifiable {
        case topLeft, topRight, bottomLeft, bottomRight
        var id: Self { self }
        func point(in r: CGRect) -> CGPoint {
            switch self {
            case .topLeft: CGPoint(x: r.minX, y: r.minY)
            case .topRight: CGPoint(x: r.maxX, y: r.minY)
            case .bottomLeft: CGPoint(x: r.minX, y: r.maxY)
            case .bottomRight: CGPoint(x: r.maxX, y: r.maxY)
            }
        }
        var opposite: Corner {
            switch self {
            case .topLeft: .bottomRight
            case .topRight: .bottomLeft
            case .bottomLeft: .topRight
            case .bottomRight: .topLeft
            }
        }
        var resizePosition: FrameResizePosition {
            switch self {
            case .topLeft: .topLeading
            case .topRight: .topTrailing
            case .bottomLeft: .bottomLeading
            case .bottomRight: .bottomTrailing
            }
        }
    }

    private enum Side: CaseIterable, Identifiable {
        case left, right, top, bottom
        var id: Self { self }
        var isHorizontal: Bool { self == .left || self == .right }
        func point(in r: CGRect) -> CGPoint {
            switch self {
            case .left: CGPoint(x: r.minX, y: r.midY)
            case .right: CGPoint(x: r.maxX, y: r.midY)
            case .top: CGPoint(x: r.midX, y: r.minY)
            case .bottom: CGPoint(x: r.midX, y: r.maxY)
            }
        }
        var resizePosition: FrameResizePosition {
            switch self {
            case .left: .leading
            case .right: .trailing
            case .top: .top
            case .bottom: .bottom
            }
        }
    }

    /// Room around the tablet in the terrain style, as in the groups below it.
    private static let terrainInset: CGFloat = 12
    /// How far from the area's edges the pointer can grab them, inside and out.
    private static let edgeReach: CGFloat = 5
    private static let cornerReach: CGFloat = 7

    var body: some View {
        switch style {
        case .classic: classicSurface
        case .terrain, .dots: terrainSurface
        }
    }

    private var classicSurface: some View {
        GeometryReader { geo in
            let size = geo.size
            let tablet = CGRect(origin: .zero, size: size)
            let rect = areaRect(in: tablet)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
                    .onTapGesture(count: 2) { model.resetArea() }

                ForEach(displayRects(in: rect), id: \.display.id) { item in
                    let r = item.rect
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.accentColor.opacity(0.14))
                        .overlay(Text(item.display.name)
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.6).padding(4))
                        .frame(width: max(r.width, 0), height: max(r.height, 0))
                        .position(x: r.midX, y: r.midY)
                        .allowsHitTesting(false)
                }

                Rectangle()
                    .fill(Color.accentColor.opacity(dragStart != nil ? 0.10 : hovering ? 0.04 : 0.001))
                    .overlay(Rectangle().strokeBorder(Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .gesture(moveGesture(tablet))
                    .onTapGesture(count: 2) { model.resetArea() }

                if hovering || dragStart != nil {
                    ForEach(Corner.allCases) { corner in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(.background)
                            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.secondary))
                            .frame(width: 9, height: 9)
                            .contentShape(Rectangle().inset(by: -6))
                            .position(corner.point(in: rect))
                            .gesture(resizeGesture(corner, tablet))
                    }
                }

                if model.live.inRange {
                    Circle()
                        .fill(model.live.tip || model.live.eraser ? Color.accentColor : Color.secondary)
                        .frame(width: 9, height: 9)
                        .position(x: model.live.u * size.width, y: model.live.v * size.height)
                        .allowsHitTesting(false)
                }
            }
            .coordinateSpace(.named("surface"))
            .onHover { hovering = $0 }
            .overlay {
                if model.tablet == nil {
                    Text("Connect a Wacom or XP-Pen tablet").foregroundStyle(.secondary)
                }
            }
        }
    }

    private var terrainSurface: some View {
        let inset = Self.terrainInset
        return Color.clear
            .aspectRatio(model.tabletSizeMM.width / model.tabletSizeMM.height, contentMode: .fit)
            .padding(inset)
            .frame(maxWidth: .infinity)
            .overlay {
                GeometryReader { geo in
                    let tablet = CGRect(origin: .zero, size: geo.size).insetBy(dx: inset, dy: inset)
                    let rect = areaRect(in: tablet)
                    ZStack(alignment: .topLeading) {
                        terrain(tablet: tablet, displays: displayRects(in: rect).map(\.rect), cursor: dotCursor(tablet),
                                hidesPointer: { !Self.isOnHandle($0, of: rect) })

                        // Covering the whole tablet, the area has nowhere to move.
                        if !coversTablet || dragStart != nil {
                            Color.clear
                                .contentShape(Rectangle())
                                .frame(width: rect.width, height: rect.height)
                                .position(x: rect.midX, y: rect.midY)
                                .gesture(moveGesture(tablet))
                                .onTapGesture(count: 2) { model.resetArea() }
                        }

                        ForEach(Side.allCases) { side in
                            let edge = side.isHorizontal ? rect.height : rect.width
                            let along = max(edge - 2 * Self.cornerReach, 0), across = 2 * Self.edgeReach
                            Color.clear
                                .contentShape(Rectangle())
                                .frame(width: side.isHorizontal ? across : along, height: side.isHorizontal ? along : across)
                                .pointerStyle(.frameResize(position: side.resizePosition))
                                .position(side.point(in: rect))
                                .gesture(resizeGesture(side, tablet))
                        }
                        ForEach(Corner.allCases) { corner in
                            Color.clear
                                .contentShape(Rectangle())
                                .frame(width: 2 * Self.cornerReach, height: 2 * Self.cornerReach)
                                .pointerStyle(.frameResize(position: corner.resizePosition))
                                .position(corner.point(in: rect))
                                .gesture(cornerGesture(corner, tablet))
                        }

                        if !showsGridCursor, let pen = pointer ?? penPoint(tablet) {
                            let pressed = pressing || model.live.inRange && (model.live.tip || model.live.eraser)
                            // Ringed with the background, to stand out on the yellow around it.
                            Circle()
                                .fill(Self.penColor)
                                .padding(1.5)
                                .background(Circle().fill(SettingsLayout.paper))
                                .frame(width: 12, height: 12)
                                .scaleEffect(pressed ? 0.6 : 1)
                                .animation(.easeOut(duration: 0.1), value: pressed)
                                .position(pen)
                                .allowsHitTesting(false)
                        }
                    }
                    .coordinateSpace(.named("surface"))
                    // Over the surface, the pen's dot is right under the pointer.
                    .onContinuousHover(coordinateSpace: .named("surface")) { phase in
                        // The dot grid finds the pointer itself; updating this would redo the view at every move.
                        guard !showsGridCursor else { if pointer != nil { pointer = nil }; return }
                        if case .active(let location) = phase { pointer = location } else { pointer = nil }
                    }
                    // Hovering stops reporting while pressed; drags keep the pen's dot under the pointer.
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if !pressing { pressing = true }
                                guard !showsGridCursor else { return }
                                pointer = CGRect(origin: .zero, size: geo.size).contains(value.location) ? value.location : nil
                            }
                            .onEnded { _ in pressing = false }
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var coversTablet: Bool {
        let a = model.effectiveArea
        return a.width > 0.999 && a.height > 0.999
    }

    /// The dot grid draws the pen as its own nearest dot.
    private var showsGridCursor: Bool { style == .dots && DotStore.shared.tuning.gridCursor > 0 }

    /// Where the pen is on the drawn tablet, if it's in range.
    private func penPoint(_ tablet: CGRect) -> CGPoint? {
        guard model.live.inRange else { return nil }
        return CGPoint(x: tablet.minX + model.live.u * tablet.width, y: tablet.minY + model.live.v * tablet.height)
    }

    private func dotCursor(_ tablet: CGRect) -> DotCursor? {
        penPoint(tablet).map { _ in DotCursor(touching: model.live.tip || model.live.eraser) }
    }

    /// Slightly deeper than the palette's yellow at night; by day, the palette's.
    private static let penColor = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua ? TerrainPalette.accent
                                                                : NSColor(srgbRed: 0xE9 / 255, green: 0xBF / 255, blue: 0, alpha: 1)
    })

    /// Whether a point is on one of the area's edges or corners, which resize it.
    private static func isOnHandle(_ p: CGPoint, of rect: CGRect) -> Bool {
        let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
        if corners.contains(where: { abs($0.x - p.x) <= cornerReach && abs($0.y - p.y) <= cornerReach }) { return true }
        let alongX = p.x >= rect.minX && p.x <= rect.maxX, alongY = p.y >= rect.minY && p.y <= rect.maxY
        return (alongY && (abs(p.x - rect.minX) <= edgeReach || abs(p.x - rect.maxX) <= edgeReach))
            || (alongX && (abs(p.y - rect.minY) <= edgeReach || abs(p.y - rect.maxY) <= edgeReach))
    }

    /// The active area inside the tablet's rectangle.
    private func areaRect(in tablet: CGRect) -> CGRect {
        let a = model.effectiveArea
        return CGRect(x: tablet.minX + a.minX * tablet.width, y: tablet.minY + a.minY * tablet.height,
                      width: a.width * tablet.width, height: a.height * tablet.height)
    }

    /// Mapped displays, squeezed into the area exactly as the driver maps them.
    private func displayRects(in rect: CGRect) -> [(display: DisplayInfo, rect: CGRect)] {
        let target = model.targetLayoutRect
        return model.mappedDisplays.map { display in
            let f = model.layoutFrame(display)
            let r = CGRect(x: rect.minX + (f.minX - target.minX) / target.width * rect.width,
                           y: rect.minY + (f.minY - target.minY) / target.height * rect.height,
                           width: f.width / target.width * rect.width,
                           height: f.height / target.height * rect.height).insetBy(dx: 1.5, dy: 1.5)
            return (display, r)
        }
    }

    /// The live terrain or dots under the whole surface, faded everywhere but the displays. The
    /// bump on it follows the pointer to where it lands on the tablet; over the dots themselves,
    /// it follows the pointer exactly.
    @ViewBuilder
    private func terrain(tablet: CGRect, displays: [CGRect], cursor: DotCursor?,
                         hidesPointer: @escaping (CGPoint) -> Bool) -> some View {
        let model = model
        let pen = { model.driver.live }
        let locate: (CGSize) -> CGPoint? = { _ in
            let mouse = NSEvent.mouseLocation
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            guard let p = model.tabletPoint(forScreen: CGPoint(x: mouse.x, y: top - mouse.y)) else { return nil }
            return CGPoint(x: tablet.minX + p.x * tablet.width, y: tablet.minY + p.y * tablet.height)
        }
        Group {
            if style == .dots {
                DotSurface(tuning: DotStore.shared.tuning, pen: pen, interactive: false, locate: locate,
                           followsPointerInside: true, cursor: cursor, hidesPointer: hidesPointer,
                           usesPenTilt: model.settings.output == .tablet,
                           onSpace: { DotsFullScreen.shared.show(model: model) })
            } else {
                TerrainSurface(tuning: TerrainStore.shared.tuning.zoomedOut(by: 0.4), pen: pen, interactive: false, locate: locate)
            }
        }
        .allowsHitTesting(false)

        ZStack {
            SettingsLayout.paper
            Color.primary.opacity(0.1)
        }
        .opacity(0.8)
        .mask {
            ZStack(alignment: .topLeading) {
                Rectangle()
                ForEach(displays.indices, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .frame(width: max(displays[i].width, 0), height: max(displays[i].height, 0))
                        .position(x: displays[i].midX, y: displays[i].midY)
                        .blendMode(.destinationOut)
                }
            }
            .compositingGroup()
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.resetArea() }
    }

    /// A drag location as a point on the tablet, 0...1.
    private func tabletPoint(_ location: CGPoint, in tablet: CGRect) -> CGPoint {
        CGPoint(x: min(max((location.x - tablet.minX) / tablet.width, 0), 1),
                y: min(max((location.y - tablet.minY) / tablet.height, 0), 1))
    }

    private func moveGesture(_ tablet: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("surface"))
            .onChanged { value in
                let start = dragStart ?? model.effectiveArea
                dragStart = start
                if !showsGridCursor { pointer = value.location }
                var r = start
                r.origin.x = min(max(start.minX + value.translation.width / tablet.width, 0), 1 - r.width)
                r.origin.y = min(max(start.minY + value.translation.height / tablet.height, 0), 1 - r.height)
                model.setArea(r)
            }
            .onEnded { _ in dragStart = nil }
    }

    private func resizeGesture(_ corner: Corner, _ tablet: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("surface"))
            .onChanged { value in
                let start = dragStart ?? model.effectiveArea
                dragStart = start
                if !showsGridCursor { pointer = value.location }
                // Horizontally the opposite corner stays put; vertically the area stays centred on the tablet.
                let anchor = corner.opposite.point(in: start)
                let p = tabletPoint(value.location, in: tablet)
                let dirX: CGFloat = p.x >= anchor.x ? 1 : -1
                let maxW = dirX > 0 ? 1 - anchor.x : anchor.x
                let maxH = 1.0
                let minSide = 0.1
                var w = max(abs(p.x - anchor.x), minSide)
                var h = max(abs(p.y - 0.5) * 2, minSide)
                if model.settings.keepProportions {
                    let k = model.proportionalAspect
                    if w / h > k { h = w / k } else { w = h * k }
                    if w > maxW { w = maxW; h = w / k }
                    if h > maxH { h = maxH; w = h * k }
                } else {
                    w = min(w, maxW)
                    h = min(h, maxH)
                }
                model.setArea(CGRect(x: dirX > 0 ? anchor.x : anchor.x - w, y: 0.5 - h / 2, width: w, height: h))
            }
            .onEnded { _ in dragStart = nil }
    }

    /// Moves both edges at a corner; the opposite corner stays put. Keeping proportions, the
    /// side dragged further leads.
    private func cornerGesture(_ corner: Corner, _ tablet: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("surface"))
            .onChanged { value in
                let start = dragStart ?? model.effectiveArea
                dragStart = start
                if !showsGridCursor { pointer = value.location }
                let anchor = corner.opposite.point(in: start)
                let p = tabletPoint(value.location, in: tablet)
                let right = p.x >= anchor.x, down = p.y >= anchor.y
                let maxW = right ? 1 - anchor.x : anchor.x, maxH = down ? 1 - anchor.y : anchor.y
                let minSide = 0.1
                var w = max(abs(p.x - anchor.x), minSide)
                var h = max(abs(p.y - anchor.y), minSide)
                if model.settings.keepProportions {
                    let k = model.proportionalAspect
                    if w / h > k { h = w / k } else { w = h * k }
                    if w > maxW { w = maxW; h = w / k }
                    if h > maxH { h = maxH; w = h * k }
                } else {
                    w = min(w, maxW)
                    h = min(h, maxH)
                }
                model.setArea(CGRect(x: right ? anchor.x : anchor.x - w, y: down ? anchor.y : anchor.y - h, width: w, height: h))
            }
            .onEnded { _ in dragStart = nil }
    }

    /// Moves one edge; the opposite edge stays put. Keeping proportions, the other side follows
    /// about the area's centre.
    private func resizeGesture(_ side: Side, _ tablet: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("surface"))
            .onChanged { value in
                let start = dragStart ?? model.effectiveArea
                dragStart = start
                if !showsGridCursor { pointer = value.location }
                let p = tabletPoint(value.location, in: tablet)
                let minSide = 0.1
                var r = start
                switch side {
                case .left: r = CGRect(x: min(p.x, start.maxX - minSide), y: start.minY, width: 0, height: start.height)
                    r.size.width = start.maxX - r.minX
                case .right: r.size.width = max(p.x - start.minX, minSide)
                case .top: r = CGRect(x: start.minX, y: min(p.y, start.maxY - minSide), width: start.width, height: 0)
                    r.size.height = start.maxY - r.minY
                case .bottom: r.size.height = max(p.y - start.minY, minSide)
                }
                if model.settings.keepProportions {
                    let k = model.proportionalAspect
                    if side.isHorizontal {
                        r.size.width = min(r.width, k)
                        if side == .left { r.origin.x = start.maxX - r.width }
                        r.size.height = r.width / k
                        r.origin.y = start.midY - r.height / 2
                    } else {
                        r.size.height = min(r.height, 1 / k)
                        if side == .top { r.origin.y = start.maxY - r.height }
                        r.size.width = r.height * k
                        r.origin.x = start.midX - r.width / 2
                    }
                }
                r.size.width = min(r.width, 1)
                r.size.height = min(r.height, 1)
                r.origin.x = min(max(r.minX, 0), 1 - r.width)
                r.origin.y = min(max(r.minY, 0), 1 - r.height)
                model.setArea(r)
            }
            .onEnded { _ in dragStart = nil }
    }
}
