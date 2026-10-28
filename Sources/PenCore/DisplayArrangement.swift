import CoreGraphics

public enum DisplayArrangement {
    /// Where a display dropped at `r` should land: touching the nearest side of another display,
    /// without overlapping any, with edges or centres aligned when they're close (like macOS).
    public static func snap(_ r: CGRect, to others: [CGRect]) -> CGRect {
        guard !others.isEmpty else { return r }
        var best = r, bestDistance = Double.infinity
        for o in others {
            // Keep at least a little shared edge so displays stay connected.
            let overlapY = min(r.height, o.height) * 0.1, overlapX = min(r.width, o.width) * 0.1
            let y = min(max(r.minY, o.minY - r.height + overlapY), o.maxY - overlapY)
            let x = min(max(r.minX, o.minX - r.width + overlapX), o.maxX - overlapX)
            let candidates = [
                (CGPoint(x: o.minX - r.width, y: y), true), (CGPoint(x: o.maxX, y: y), true),
                (CGPoint(x: x, y: o.minY - r.height), false), (CGPoint(x: x, y: o.maxY), false),
            ]
            for (origin, sideBySide) in candidates {
                var c = CGRect(origin: origin, size: r.size)
                if sideBySide {
                    let threshold = r.height * 0.06
                    for t in [o.minY, o.maxY - r.height, o.midY - r.height / 2] where abs(c.minY - t) < threshold {
                        c.origin.y = t
                        break
                    }
                } else {
                    let threshold = r.width * 0.06
                    for t in [o.minX, o.maxX - r.width, o.midX - r.width / 2] where abs(c.minX - t) < threshold {
                        c.origin.x = t
                        break
                    }
                }
                guard !others.contains(where: { overlaps($0, c) }) else { continue }
                let d = (c.minX - r.minX) * (c.minX - r.minX) + (c.minY - r.minY) * (c.minY - r.minY)
                if d < bestDistance {
                    best = c
                    bestDistance = d
                }
            }
        }
        return best
    }

    static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        a.minX < b.maxX - 0.5 && a.maxX > b.minX + 0.5 && a.minY < b.maxY - 0.5 && a.maxY > b.minY + 0.5
    }
}
