import SwiftUI

// MARK: - Lane renderer
//
// One Canvas per lane (a comment change never redraws the waveform). No per-event
// SwiftUI views: a lane draws its visible primitives into one GraphicsContext and
// hit-tests in code. Labels only on blocks wider than 40 pt, ≤ ~60 per draw.

struct LaneHit: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case clip, event, caption, comment }
    var kind: Kind
    var id: String
    var start: Double
    var end: Double
}

protocol LaneRenderer {
    var title: String { get }
    var height: CGFloat { get }
    func draw(in ctx: inout GraphicsContext, size: CGSize, viewport: TimelineViewport)
    func hit(_ p: CGPoint, viewport: TimelineViewport) -> LaneHit?
}

extension LaneRenderer {
    func hit(_ p: CGPoint, viewport: TimelineViewport) -> LaneHit? { nil }
}

enum LaneDraw {
    static let maxLabels = 60

    /// A rounded block from `a` to `b` seconds, clipped to the viewport.
    static func block(_ ctx: inout GraphicsContext, viewport v: TimelineViewport, from a: Double, to b: Double,
                      y: CGFloat, height: CGFloat, color: Color, label: String?, labels: inout Int,
                      stroke: Color? = nil, dashed: Bool = false) {
        let x0 = max(-2, v.x(a)), x1 = min(v.width + 2, v.x(b))
        guard x1 > x0 - 0.5 else { return }
        let r = CGRect(x: x0, y: y, width: max(1.5, x1 - x0 - 1), height: height)
        let path = Path(roundedRect: r, cornerRadius: min(3, height / 3))
        ctx.fill(path, with: .color(color.opacity(0.32)))
        ctx.stroke(path, with: .color(stroke ?? color.opacity(0.75)),
                   style: StrokeStyle(lineWidth: 1, dash: dashed ? [3, 2] : []))
        if let label, r.width > 40, labels < maxLabels {
            labels += 1
            var c = ctx
            c.clip(to: Path(r.insetBy(dx: 4, dy: 0)))
            c.draw(Text(label).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.white.opacity(0.92)),
                   at: CGPoint(x: r.minX + 5, y: r.midY), anchor: .leading)
        }
    }

    /// Visible slice of a time-sorted array (binary search on start, generous on the left).
    static func visible<T>(_ items: [T], viewport v: TimelineViewport, start: (T) -> Double, end: (T) -> Double) -> ArraySlice<T> {
        let lo = v.start - 30, hi = v.end
        var a = 0, b = items.count
        while a < b { let m = (a + b) / 2; if start(items[m]) < lo { a = m + 1 } else { b = m } }
        var z = a
        while z < items.count, start(items[z]) <= hi { z += 1 }
        return items[a..<z]
    }
}
