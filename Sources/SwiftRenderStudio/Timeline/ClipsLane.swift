import SwiftUI
import SwiftRenderKit

// MARK: - Clips lane
//
// One row per Timeline depth (nested Timelines below their parent clip), plus a
// pinned row for `Clip(at:for:)` overlays. Transitions into a clip are hatched over
// their duration; labels come from `ClipLabels`. Click selects (Info shows the
// source), double-click opens it, right-click offers "Comment on this clip".

struct ClipsLane: LaneRenderer {
    var title = "CLIPS"
    var clips: [ClipInfo]
    var selectedID: String?
    /// id → display name (`ClipLabels`); falls back to `ClipLabels.name(_:auto:nil)`.
    var names: [String: String] = [:]

    static let rowHeight: CGFloat = 18
    static let inset: CGFloat = 3

    private var maxDepth: Int { clips.filter { !$0.pinned }.map(\.depth).max() ?? 0 }
    private var hasPinned: Bool { clips.contains { $0.pinned } }
    var rows: Int { max(1, (clips.contains { !$0.pinned } ? maxDepth + 1 : 0) + (hasPinned ? 1 : 0)) }
    var height: CGFloat { CGFloat(rows) * Self.rowHeight + 2 * Self.inset }

    /// Header labels per row: "0", "1", …, "pinned".
    var rowLabels: [String] {
        guard !clips.isEmpty else { return [] }
        let depths = clips.contains { !$0.pinned } ? (0...maxDepth).map { $0 == 0 ? "main" : "nest \($0)" } : []
        return depths + (hasPinned ? ["pinned"] : [])
    }

    func row(_ c: ClipInfo) -> Int {
        c.pinned ? (clips.contains { !$0.pinned } ? maxDepth + 1 : 0) : c.depth
    }

    func rowY(_ r: Int) -> CGFloat { Self.inset + CGFloat(r) * Self.rowHeight }

    func name(_ c: ClipInfo) -> String { names[c.id] ?? ClipLabels.name(c, auto: nil) }

    static func color(_ c: ClipInfo, index: Int) -> Color {
        if c.pinned { return Color(red: 0.62, green: 0.64, blue: 0.70) }
        let palette: [(Double, Double, Double)] = [(0.36, 0.54, 0.98), (0.30, 0.74, 0.86), (0.56, 0.48, 0.96), (0.36, 0.80, 0.62)]
        let (r, g, b) = palette[c.depth % palette.count]
        // Neighbours alternate brightness so butt-joined cuts still read as two clips.
        let k = index % 2 == 0 ? 0 : 0.16
        return Color(red: r + (1 - r) * k, green: g + (1 - g) * k, blue: b + (1 - b) * k)
    }

    func draw(in ctx: inout GraphicsContext, size: CGSize, viewport v: TimelineViewport) {
        guard !clips.isEmpty else {
            LaneDraw.empty(&ctx, "No Timeline in this scene — wrap shots in Timeline { Clip(…) } to see them here", size: size)
            return
        }
        // Row guides for nested/pinned rows.
        for r in 1..<max(1, rows) {
            var p = Path()
            p.move(to: CGPoint(x: 0, y: rowY(r) - 0.5)); p.addLine(to: CGPoint(x: size.width, y: rowY(r) - 0.5))
            ctx.stroke(p, with: .color(.white.opacity(0.04)), lineWidth: 1)
        }
        var labels = 0
        var indexInRow: [Int: Int] = [:]
        for c in clips.sorted(by: { ($0.start, $0.depth) < ($1.start, $1.depth) }) {
            let r = row(c)
            let i = indexInRow[r, default: 0]
            indexInRow[r] = i + 1
            guard c.end >= v.start, c.start <= v.end else { continue }
            let y = rowY(r) + 1
            let h = Self.rowHeight - 3
            let selected = c.id == selectedID
            let color = Self.color(c, index: i)
            LaneDraw.block(&ctx, viewport: v, from: c.start, to: c.end, y: y, height: h, color: color,
                           label: nil, labels: &labels, stroke: selected ? .white : nil, fill: selected ? 0.58 : 0.34)
            guard let rect = LaneDraw.rect(viewport: v, from: c.start, to: c.end, y: y, height: h) else { continue }
            if c.transitionDuration > 0, c.transitionIn != "cut" {
                let x1 = min(rect.maxX, v.x(c.start + c.transitionDuration))
                let tr = CGRect(x: rect.minX, y: rect.minY, width: max(0, x1 - rect.minX), height: rect.height)
                LaneDraw.hatch(&ctx, tr, color: .white.opacity(0.30), spacing: 3.5)
                var edge = Path()
                edge.move(to: CGPoint(x: tr.minX, y: tr.maxY)); edge.addLine(to: CGPoint(x: tr.maxX, y: tr.minY))
                ctx.stroke(edge, with: .color(.white.opacity(0.75)), lineWidth: 1)
            }
            LaneDraw.label(&ctx, name(c), in: rect, labels: &labels,
                           trailing: String(format: "%.1fs", c.duration),
                           color: .white.opacity(selected ? 1 : 0.9))
        }
    }

    func hit(_ p: CGPoint, viewport v: TimelineViewport) -> LaneHit? {
        guard !clips.isEmpty, p.y >= Self.inset else { return nil }
        let r = Int((p.y - Self.inset) / Self.rowHeight)
        let slop = 2 / v.pxPerSecond
        let t = v.t(p.x)
        // Latest start wins: it is drawn on top where clips overlap.
        guard let c = clips.filter({ row($0) == r && t >= $0.start - slop && t < $0.end + slop })
                .max(by: { $0.start < $1.start }) else { return nil }
        var detail = [LaneDraw.range(c.start, c.end) + " · " + LaneDraw.seconds(c.duration)]
        if c.transitionDuration > 0, c.transitionIn != "cut" {
            detail.append("\(c.transitionIn) in \(LaneDraw.seconds(c.transitionDuration))")
        }
        if let s = c.source { detail.append("\((s.file as NSString).lastPathComponent):\(s.line)") }
        if c.pinned { detail.append("pinned") } else if c.depth > 0 { detail.append("depth \(c.depth)") }
        return LaneHit(kind: .clip, id: c.id, start: c.start, end: c.end, title: name(c),
                       detail: detail[0]
                        + (detail.count > 1 ? "\n" + detail.dropFirst(1).joined(separator: " · ") : ""),
                       rect: LaneDraw.rect(viewport: v, from: c.start, to: c.end, y: rowY(r) + 1, height: Self.rowHeight - 3))
    }
}
