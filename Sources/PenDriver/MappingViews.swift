import PenCore
import SwiftUI

/// All displays as arranged for the tablet, at their real proportions. Mapped displays are
/// highlighted; click one to map to it, drag to rearrange.
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
                            .onTapGesture {
                                if model.displays.count > 1 { model.settings.display = display.id }
                            }
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
    @Bindable var model: AppModel
    @State private var dragStart: CGRect?
    @State private var hovering = false

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
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let a = model.effectiveArea
            let rect = CGRect(x: a.minX * size.width, y: a.minY * size.height,
                              width: a.width * size.width, height: a.height * size.height)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
                    .onTapGesture(count: 2) { model.resetArea() }

                // Mapped displays, squeezed into the area exactly as the driver maps them.
                let target = model.targetLayoutRect
                ForEach(model.mappedDisplays) { display in
                    let f = model.layoutFrame(display)
                    let r = CGRect(x: rect.minX + (f.minX - target.minX) / target.width * rect.width,
                                   y: rect.minY + (f.minY - target.minY) / target.height * rect.height,
                                   width: f.width / target.width * rect.width,
                                   height: f.height / target.height * rect.height).insetBy(dx: 1.5, dy: 1.5)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.accentColor.opacity(0.14))
                        .overlay(Text(model.mappedDisplays.count > 1 ? display.name : "")
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
                    .gesture(moveGesture(size))
                    .onTapGesture(count: 2) { model.resetArea() }

                if hovering || dragStart != nil {
                    ForEach(Corner.allCases) { corner in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(.background)
                            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.secondary))
                            .frame(width: 9, height: 9)
                            .contentShape(Rectangle().inset(by: -6))
                            .position(corner.point(in: rect))
                            .gesture(resizeGesture(corner, size))
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

    private func moveGesture(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("surface"))
            .onChanged { value in
                let start = dragStart ?? model.effectiveArea
                dragStart = start
                var r = start
                r.origin.x = min(max(start.minX + value.translation.width / size.width, 0), 1 - r.width)
                r.origin.y = min(max(start.minY + value.translation.height / size.height, 0), 1 - r.height)
                model.setArea(r)
            }
            .onEnded { _ in dragStart = nil }
    }

    private func resizeGesture(_ corner: Corner, _ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("surface"))
            .onChanged { value in
                let start = dragStart ?? model.effectiveArea
                dragStart = start
                let anchor = corner.opposite.point(in: start)
                let p = CGPoint(x: min(max(value.location.x / size.width, 0), 1),
                                y: min(max(value.location.y / size.height, 0), 1))
                let dirX: CGFloat = p.x >= anchor.x ? 1 : -1
                let dirY: CGFloat = p.y >= anchor.y ? 1 : -1
                let maxW = dirX > 0 ? 1 - anchor.x : anchor.x
                let maxH = dirY > 0 ? 1 - anchor.y : anchor.y
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
                model.setArea(CGRect(x: dirX > 0 ? anchor.x : anchor.x - w, y: dirY > 0 ? anchor.y : anchor.y - h,
                                     width: w, height: h))
            }
            .onEnded { _ in dragStart = nil }
    }
}
