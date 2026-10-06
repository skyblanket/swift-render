import SwiftUI
import SwiftRenderKit

// MARK: - Comments lane   // S6
//
// Shell: markers (point comments) and ranges colored by status, numbered in scene
// order, click → select. S6 adds drag-to-retime range ends (edits `t`/`end`).

struct CommentsLane: LaneRenderer {
    var title = "NOTES"
    var comments: [ReviewComment]
    var selection: String?
    var height: CGFloat = 20

    func draw(in ctx: inout GraphicsContext, size: CGSize, viewport v: TimelineViewport) {
        let ordered = comments.sorted { $0.t < $1.t }
        for (i, c) in ordered.enumerated() {
            let color = StudioStyle.color(c.status)
            let x = v.x(c.t)
            if let end = c.end {
                let x1 = v.x(end)
                guard x1 >= 0, x <= size.width else { continue }
                ctx.fill(Path(roundedRect: CGRect(x: x, y: size.height / 2 - 2, width: max(2, x1 - x), height: 4), cornerRadius: 2),
                         with: .color(color.opacity(0.7)))
            }
            guard x >= -10, x <= size.width + 10 else { continue }
            let r = CGRect(x: x - 7, y: size.height / 2 - 7, width: 14, height: 14)
            ctx.fill(Path(ellipseIn: r), with: .color(color))
            if c.id == selection { ctx.stroke(Path(ellipseIn: r.insetBy(dx: -2, dy: -2)), with: .color(.white), lineWidth: 1.5) }
            let label = c.status == .resolved ? "✓" : "\(i + 1)"
            ctx.draw(Text(label).font(.system(size: 8.5, weight: .bold, design: .rounded)).foregroundStyle(.black),
                     at: CGPoint(x: r.midX, y: r.midY))
        }
    }

    func hit(_ p: CGPoint, viewport v: TimelineViewport) -> LaneHit? {
        let t = v.t(p.x)
        let slop = 8 / v.pxPerSecond
        guard let c = comments.first(where: { c in
            if abs(c.t - t) < slop { return true }
            if let e = c.end { return t >= c.t && t <= e }
            return false
        }) else { return nil }
        return LaneHit(kind: .comment, id: c.id, start: c.t, end: c.end ?? c.t)
    }
}
