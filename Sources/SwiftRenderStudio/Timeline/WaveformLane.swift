import SwiftUI
import SwiftRenderKit

// MARK: - Waveform lane   // S5
//
// Shell: the host's loudness envelope (SceneInfo.loudness, 50/s) as a mirrored area.
// S5 adds the min/max waveform from `WaveformMips` (score WAV), loudness on top,
// silence shading (< −45 dB for ≥ 0.5 s, the `check` thresholds), async rendering.

struct WaveformLane: LaneRenderer {
    var title = "AUDIO"
    var loudness: [Float]
    var rate: Double
    var height: CGFloat = 34

    func draw(in ctx: inout GraphicsContext, size: CGSize, viewport v: TimelineViewport) {
        guard !loudness.isEmpty, rate > 0 else {
            ctx.draw(Text("No audio").font(.system(size: 10)).foregroundStyle(.white.opacity(0.35)),
                     at: CGPoint(x: 8, y: size.height / 2), anchor: .leading)
            return
        }
        let mid = size.height / 2
        let cols = Int(size.width / 2)
        var top: [CGPoint] = []
        top.reserveCapacity(cols + 1)
        for c in 0...cols {
            let x = CGFloat(c * 2)
            let t0 = v.t(x), t1 = v.t(x + 2)
            let i0 = max(0, Int(t0 * rate)), i1 = min(loudness.count, max(i0 + 1, Int(t1 * rate)))
            guard i0 < loudness.count else { break }
            let peak = loudness[i0..<i1].max() ?? 0
            top.append(CGPoint(x: x, y: mid - CGFloat(peak) * (mid - 1)))
        }
        guard let last = top.last else { return }
        var p = Path()
        p.move(to: CGPoint(x: 0, y: mid))
        top.forEach { p.addLine(to: $0) }
        for pt in top.reversed() { p.addLine(to: CGPoint(x: pt.x, y: 2 * mid - pt.y)) }
        p.addLine(to: CGPoint(x: 0, y: mid))
        ctx.fill(p, with: .color(Color(red: 0.40, green: 0.80, blue: 0.70).opacity(0.55)))
        var axis = Path()
        axis.move(to: CGPoint(x: 0, y: mid)); axis.addLine(to: CGPoint(x: last.x, y: mid))
        ctx.stroke(axis, with: .color(.white.opacity(0.15)), lineWidth: 0.5)
    }
}
