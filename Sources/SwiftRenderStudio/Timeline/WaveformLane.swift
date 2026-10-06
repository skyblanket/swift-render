import SwiftUI
import SwiftRenderKit

// MARK: - Waveform lane
//
// Min/max waveform from `WaveformMips` (≤ 2 points per pixel from the right mip
// level), the host's loudness envelope (50/s) as a line on top, and silences
// hatched. Before the WAV is decoded the envelope alone is drawn as a mirrored area.
// Drawn with `rendersAsynchronously` — the only lane heavy enough to need it.

struct WaveformLane: LaneRenderer {
    var title = "Audio"
    var loudness: [Float]
    var rate: Double
    var overview: AudioOverview?
    /// The scene has a soundtrack that hasn't arrived yet.
    var pending = false
    var height: CGFloat = 40

    static let wave = StudioStyle.Lane.audio
    /// "No sound yet": the lane folds down to a single line.
    static let collapsedHeight: CGFloat = 22

    func draw(in ctx: inout GraphicsContext, size: CGSize, viewport v: TimelineViewport) {
        let hasEnvelope = !loudness.isEmpty && rate > 0
        guard overview != nil || hasEnvelope else {
            LaneDraw.empty(&ctx, pending ? "Mixing the music…" : "No sound yet", size: size)
            return
        }
        let mid = size.height / 2
        let cols = max(1, Int(size.width / 1))
        if let o = overview {
            let visibleEnd = min(v.end, o.duration)
            if visibleEnd > v.start {
                let wCols = max(1, min(cols, Int(v.x(visibleEnd).rounded(.up))))
                let peaks = o.mips.peaks(from: v.start, to: v.t(CGFloat(wCols)), buckets: wCols)
                var p = Path()
                // One closed outline: max edge left→right, min edge back right→left.
                for (i, pk) in peaks.enumerated() {
                    let pt = CGPoint(x: CGFloat(i) + 0.5, y: mid - CGFloat(min(1, pk.max)) * (mid - 2))
                    i == 0 ? p.move(to: pt) : p.addLine(to: pt)
                }
                for (i, pk) in peaks.enumerated().reversed() {
                    p.addLine(to: CGPoint(x: CGFloat(i) + 0.5, y: mid - CGFloat(max(-1, pk.min)) * (mid - 2)))
                }
                p.closeSubpath()
                ctx.fill(p, with: .color(Self.wave.opacity(0.55)))
            }
            for s in o.silences where s.upperBound >= v.start && s.lowerBound <= v.end {
                let x0 = max(0, v.x(s.lowerBound)), x1 = min(size.width, v.x(s.upperBound))
                let r = CGRect(x: x0, y: 1, width: max(0, x1 - x0), height: size.height - 2)
                LaneDraw.hatch(&ctx, r, color: Self.wave.opacity(0.18), spacing: 5)
                if r.width > 60 {
                    ctx.draw(Text("Quiet").font(StudioStyle.Fonts.footnote).foregroundStyle(.tertiary),
                             at: CGPoint(x: r.midX, y: r.midY))
                }
            }
        }
        if hasEnvelope {
            var top: [CGPoint] = []
            top.reserveCapacity(cols / 2 + 1)
            for c in stride(from: 0, through: cols, by: 2) {
                let x = CGFloat(c)
                let t0 = v.t(x), t1 = v.t(x + 2)
                let i0 = max(0, Int(t0 * rate)), i1 = min(loudness.count, max(i0 + 1, Int(t1 * rate)))
                guard i0 < loudness.count else { break }
                let peak = loudness[i0..<i1].max() ?? 0
                top.append(CGPoint(x: x, y: CGFloat(peak)))
            }
            guard let last = top.last else { return }
            if overview == nil {
                var p = Path()
                p.move(to: CGPoint(x: 0, y: mid))
                top.forEach { p.addLine(to: CGPoint(x: $0.x, y: mid - $0.y * (mid - 2))) }
                for pt in top.reversed() { p.addLine(to: CGPoint(x: pt.x, y: mid + pt.y * (mid - 2))) }
                p.closeSubpath()
                ctx.fill(p, with: .color(Self.wave.opacity(0.45)))
                var axis = Path()
                axis.move(to: CGPoint(x: 0, y: mid)); axis.addLine(to: CGPoint(x: last.x, y: mid))
                ctx.stroke(axis, with: .style(.quaternary), lineWidth: 0.5)
            } else {
                // Loudness as a line riding over the waveform, bottom = silence.
                var line = Path()
                for (i, pt) in top.enumerated() {
                    let q = CGPoint(x: pt.x, y: size.height - 2 - pt.y * (size.height - 5))
                    i == 0 ? line.move(to: q) : line.addLine(to: q)
                }
                ctx.stroke(line, with: .style(.secondary), style: StrokeStyle(lineWidth: 1, lineJoin: .round))
            }
        }
    }

    func hit(_ p: CGPoint, viewport v: TimelineViewport) -> LaneHit? {
        let t = v.t(p.x)
        if let s = overview?.silences.first(where: { $0.contains(t) }) {
            return LaneHit(kind: .silence, id: "silence:\(s.lowerBound)", start: s.lowerBound, end: s.upperBound,
                           title: "Quiet for \(LaneDraw.seconds(s.upperBound - s.lowerBound))",
                           detail: LaneDraw.range(s.lowerBound, s.upperBound) + " · below \(Int(AudioOverview.silenceDB)) dBFS",
                           rect: LaneDraw.rect(viewport: v, from: s.lowerBound, to: s.upperBound, y: 1, height: height - 2))
        }
        guard !loudness.isEmpty, rate > 0 else { return nil }
        let i = Int(t * rate)
        guard i >= 0, i < loudness.count else { return nil }
        return LaneHit(kind: .audio, id: "audio", start: t, end: t, title: "Loudness \(Int((loudness[i] * 100).rounded()))%",
                       detail: StudioTime.precise(t))
    }
}
