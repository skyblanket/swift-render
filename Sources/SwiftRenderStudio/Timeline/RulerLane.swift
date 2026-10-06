import SwiftUI

// MARK: - Ruler
//
// Adaptive ticks and labels, the cache bar (frames already rendered for this
// generation, green like an NLE render bar) and the in/out range. Drag scrubs.

struct RulerLane: LaneRenderer {
    var title = "TIME"
    var height: CGFloat = 26
    var cached: [ClosedRange<Double>]
    var inOut: ClosedRange<Double>?
    var duration: Double

    func draw(in ctx: inout GraphicsContext, size: CGSize, viewport v: TimelineViewport) {
        let (major, minor) = v.tickSpacing()
        let tickColor = Color.white.opacity(0.28)
        var minorPath = Path(), majorPath = Path()
        var t = (v.start / minor).rounded(.down) * minor
        let end = min(v.end, duration)
        var labels = 0
        while t <= end + 1e-9 {
            let x = v.x(t)
            let isMajor = abs((t / major).rounded() * major - t) < minor * 0.01
            if isMajor {
                majorPath.move(to: CGPoint(x: x, y: size.height - 11)); majorPath.addLine(to: CGPoint(x: x, y: size.height - 4))
                if labels < LaneDraw.maxLabels {
                    labels += 1
                    ctx.draw(Text(TimelineViewport.label(t, major: major))
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.55)),
                             at: CGPoint(x: x + 3, y: 8), anchor: .leading)
                }
            } else {
                minorPath.move(to: CGPoint(x: x, y: size.height - 7)); minorPath.addLine(to: CGPoint(x: x, y: size.height - 4))
            }
            t += minor
        }
        ctx.stroke(minorPath, with: .color(tickColor.opacity(0.6)), lineWidth: 1)
        ctx.stroke(majorPath, with: .color(tickColor), lineWidth: 1)

        // Cache bar.
        for r in cached {
            let x0 = max(0, v.x(r.lowerBound)), x1 = min(v.width, v.x(r.upperBound))
            guard x1 > x0 else { continue }
            ctx.fill(Path(CGRect(x: x0, y: size.height - 3, width: x1 - x0, height: 3)),
                     with: .color(StudioStyle.ok.opacity(0.85)))
        }

        // In/out.
        if let io = inOut {
            let x0 = v.x(io.lowerBound), x1 = v.x(io.upperBound)
            ctx.fill(Path(CGRect(x: x0, y: 15, width: max(1, x1 - x0), height: size.height - 18)),
                     with: .color(StudioStyle.accent.opacity(0.16)))
            var p = Path()
            p.move(to: CGPoint(x: x0, y: 14)); p.addLine(to: CGPoint(x: x0, y: size.height))
            p.move(to: CGPoint(x: x1, y: 14)); p.addLine(to: CGPoint(x: x1, y: size.height))
            ctx.stroke(p, with: .color(StudioStyle.accent), lineWidth: 1.5)
        }

        // End of scene.
        let xe = v.x(duration)
        if xe < size.width {
            ctx.fill(Path(CGRect(x: xe, y: 0, width: size.width - xe, height: size.height)), with: .color(.black.opacity(0.35)))
        }
    }
}
