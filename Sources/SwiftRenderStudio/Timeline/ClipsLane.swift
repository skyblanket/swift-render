import SwiftUI
import SwiftRenderKit

// MARK: - Clips lane
//
// One row per Timeline depth (nested Timelines below their parent clip), plus an
// overlay row for `Clip(at:for:)`. Every clip is the same quiet tone; neighbours are
// told apart by a gap, not by color. A transition into a clip is a soft hatch at its
// head, and the clip's name starts after it, so nothing strikes through a label.
// Durations are in the hover card. Click selects (Info shows the source), double-click
// opens it, right-click offers "Comment on This Clip".

struct ClipsLane: LaneRenderer {
    var title = "Clips"
    var clips: [ClipInfo]
    var selectedID: String?
    /// id → display name (`ClipLabels`); falls back to `ClipLabels.name(_:auto:nil)`.
    var names: [String: String] = [:]

    static let rowHeight: CGFloat = 20
    static let inset: CGFloat = 3

    private var maxDepth: Int { clips.filter { !$0.pinned }.map(\.depth).max() ?? 0 }
    private var hasPinned: Bool { clips.contains { $0.pinned } }
    var rows: Int { max(1, (clips.contains { !$0.pinned } ? maxDepth + 1 : 0) + (hasPinned ? 1 : 0)) }
    var height: CGFloat { CGFloat(rows) * Self.rowHeight + 2 * Self.inset }

    /// Header labels per row: "" (the main row), "Nested", "Overlay".
    var rowLabels: [String] {
        guard !clips.isEmpty else { return [] }
        let depths = clips.contains { !$0.pinned } ? (0...maxDepth).map { $0 == 0 ? "" : maxDepth > 1 ? "Nested \($0)" : "Nested" } : []
        return depths + (hasPinned ? ["Overlay"] : [])
    }

    func row(_ c: ClipInfo) -> Int {
        c.pinned ? (clips.contains { !$0.pinned } ? maxDepth + 1 : 0) : c.depth
    }

    func rowY(_ r: Int) -> CGFloat { Self.inset + CGFloat(r) * Self.rowHeight }

    func name(_ c: ClipInfo) -> String { names[c.id] ?? ClipLabels.name(c, auto: nil) }

    func draw(in ctx: inout GraphicsContext, size: CGSize, viewport v: TimelineViewport) {
        guard !clips.isEmpty else {
            LaneDraw.empty(&ctx, "One continuous shot", size: size)
            return
        }
        var labels = 0
        let sorted = clips.sorted(by: { ($0.start, $0.depth) < ($1.start, $1.depth) })
        let tone = StudioStyle.Lane.clips
        for (k, c) in sorted.enumerated() {
            let r = row(c)
            // Where the next clip in this row starts: it covers the rest of this one.
            let covered = sorted[(k + 1)...].first { row($0) == r && $0.start > c.start && $0.start < c.end }?.start
            guard c.end >= v.start, c.start <= v.end else { continue }
            let y = rowY(r) + 1
            let h = Self.rowHeight - 3
            let selected = c.id == selectedID
            guard var rect = LaneDraw.rect(viewport: v, from: c.start, to: c.end, y: y, height: h) else { continue }
            // A 2 pt gap at each cut, so butt-joined clips read as two.
            if rect.width > 6 { rect = rect.insetBy(dx: 1, dy: 0) }
            let shape = Path(roundedRect: rect, cornerRadius: StudioStyle.Radius.small, style: .continuous)
            // Opaque base: an overlapping (crossfading) clip covers the one before it.
            ctx.fill(shape, with: .color(StudioStyle.chrome))
            ctx.fill(shape, with: .color(selected ? StudioStyle.accent.opacity(0.35) : tone.opacity(c.pinned ? 0.22 : StudioStyle.Lane.fill)))
            if selected { ctx.stroke(shape, with: .color(StudioStyle.accent), lineWidth: 1.5) }
            var labelStart = rect.minX
            if c.transitionDuration > 0, c.transitionIn != "cut" {
                let x1 = min(rect.maxX, v.x(c.start + c.transitionDuration))
                let tr = CGRect(x: rect.minX, y: rect.minY, width: max(0, x1 - rect.minX), height: rect.height)
                var hatch = ctx
                hatch.clip(to: shape)
                LaneDraw.hatch(&hatch, tr, color: tone.opacity(0.5), spacing: 4)
                if tr.width < rect.width * 0.6 { labelStart = tr.maxX }
            }
            var visible = CGRect(x: labelStart, y: rect.minY, width: max(0, rect.maxX - labelStart), height: rect.height)
            if let covered { visible.size.width = max(0, min(rect.maxX, v.x(covered)) - labelStart) }
            LaneDraw.label(&ctx, name(c), in: visible, labels: &labels)
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
            detail.append("\(c.transitionIn.capitalized) in over \(LaneDraw.seconds(c.transitionDuration))")
        }
        if let s = c.source { detail.append((s.file as NSString).lastPathComponent) }
        if c.pinned { detail.append("Overlay") } else if c.depth > 0 { detail.append("Nested") }
        return LaneHit(kind: .clip, id: c.id, start: c.start, end: c.end, title: name(c),
                       detail: detail[0]
                        + (detail.count > 1 ? "\n" + detail.dropFirst(1).joined(separator: " · ") : ""),
                       rect: LaneDraw.rect(viewport: v, from: c.start, to: c.end, y: rowY(r) + 1, height: Self.rowHeight - 3))
    }
}
