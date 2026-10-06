import SwiftUI

// MARK: - Ruler
//
// Adaptive ticks and labels (mm:ss → mm:ss.ff → mm:ss:ff frames as you zoom), the
// cache bar (frames already rendered for this generation, green like an NLE render
// bar) and the in/out range with draggable flags. Drag elsewhere scrubs.

struct RulerLane: LaneRenderer {
    var title = "TIME"
    var height: CGFloat = 28
    var cached: [ClosedRange<Double>]
    var inOut: ClosedRange<Double>?
    var duration: Double

    static let flagSlop: CGFloat = 6

    func draw(in ctx: inout GraphicsContext, size: CGSize, viewport v: TimelineViewport) {
        let (major, minor) = v.tickSpacing()
        let tickColor = Color.white.opacity(0.30)
        var minorPath = Path(), majorPath = Path()
        var t = max(0, (v.start / minor).rounded(.down) * minor)
        let end = min(v.end, duration)
        var labels = 0
        let tickBottom = size.height - 5
        while t <= end + 1e-9 {
            let x = v.x(t)
            let isMajor = abs((t / major).rounded() * major - t) < minor * 0.01
            if isMajor {
                majorPath.move(to: CGPoint(x: x, y: tickBottom - 9)); majorPath.addLine(to: CGPoint(x: x, y: tickBottom))
                if labels < LaneDraw.maxLabels, x + 34 <= size.width {
                    labels += 1
                    ctx.draw(Text(TimelineViewport.label(t, major: major, fps: v.fps))
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.55)),
                             at: CGPoint(x: x + 3, y: 8), anchor: .leading)
                }
            } else {
                minorPath.move(to: CGPoint(x: x, y: tickBottom - 4)); minorPath.addLine(to: CGPoint(x: x, y: tickBottom))
            }
            t += minor
        }
        ctx.stroke(minorPath, with: .color(tickColor.opacity(0.6)), lineWidth: 1)
        ctx.stroke(majorPath, with: .color(tickColor), lineWidth: 1)

        // Cache bar on a faint track, so "nothing cached yet" still reads as a bar.
        let xe = min(size.width, v.x(duration))
        ctx.fill(Path(CGRect(x: max(0, v.x(0)), y: size.height - 3, width: max(0, xe - max(0, v.x(0))), height: 3)),
                 with: .color(.white.opacity(0.06)))
        for r in cached {
            let x0 = max(0, v.x(r.lowerBound)), x1 = min(v.width, v.x(r.upperBound))
            guard x1 > x0 else { continue }
            ctx.fill(Path(CGRect(x: x0, y: size.height - 3, width: max(1, x1 - x0), height: 3)),
                     with: .color(StudioStyle.ok.opacity(0.85)))
        }

        // In/out: tinted span and two flags.
        if let io = inOut {
            let x0 = v.x(io.lowerBound), x1 = v.x(io.upperBound)
            ctx.fill(Path(CGRect(x: x0, y: 14, width: max(1, x1 - x0), height: size.height - 17)),
                     with: .color(StudioStyle.accent.opacity(0.14)))
            var edges = Path()
            edges.move(to: CGPoint(x: x0, y: 14)); edges.addLine(to: CGPoint(x: x0, y: size.height - 3))
            edges.move(to: CGPoint(x: x1, y: 14)); edges.addLine(to: CGPoint(x: x1, y: size.height - 3))
            ctx.stroke(edges, with: .color(StudioStyle.accent), lineWidth: 1.5)
            flag(&ctx, x: x0, label: "I", leading: true)
            flag(&ctx, x: x1, label: "O", leading: false)
        }

        // Past the end of the scene.
        if xe < size.width {
            ctx.fill(Path(CGRect(x: xe, y: 0, width: size.width - xe, height: size.height)), with: .color(.black.opacity(0.35)))
        }
    }

    private func flag(_ ctx: inout GraphicsContext, x: CGFloat, label: String, leading: Bool) {
        let r = CGRect(x: leading ? x : x - 11, y: 14, width: 11, height: 10)
        var p = Path()
        if leading {
            p.move(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX - 2, y: r.minY))
            p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + 2), control: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        } else {
            p.move(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.minX + 2, y: r.minY))
            p.addQuadCurve(to: CGPoint(x: r.minX, y: r.minY + 2), control: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        }
        p.closeSubpath()
        ctx.fill(p, with: .color(StudioStyle.accent))
        ctx.draw(Text(label).font(.system(size: 7.5, weight: .heavy, design: .rounded)).foregroundStyle(.black.opacity(0.8)),
                 at: CGPoint(x: r.midX, y: r.midY))
    }

    /// The in or out flag under `p` (drag adjusts that edge); nil means scrub.
    func hit(_ p: CGPoint, viewport v: TimelineViewport) -> LaneHit? {
        guard let io = inOut, p.y >= 10 else { return nil }
        let dIn = abs(p.x - v.x(io.lowerBound)), dOut = abs(p.x - v.x(io.upperBound))
        guard min(dIn, dOut) <= Self.flagSlop else { return nil }
        // Coincident flags: grab the side the pointer is on.
        let isIn = dIn < dOut || (dIn == dOut && p.x <= v.x(io.lowerBound))
        let t = isIn ? io.lowerBound : io.upperBound
        return LaneHit(kind: .inOut, id: isIn ? "in" : "out", start: t, end: t,
                       part: isIn ? .startHandle : .endHandle,
                       title: isIn ? "In \(StudioStyle.timecode(t))" : "Out \(StudioStyle.timecode(t))",
                       detail: "In→out " + LaneDraw.seconds(io.upperBound - io.lowerBound))
    }
}
