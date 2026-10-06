import SwiftUI
import SwiftRenderKit

// MARK: - Clips lane   // S5
//
// Shell: depth rows + pinned row from `SceneInfo.clips`, fade hatching, labels.
// S5 adds: auto-labels from source (`in\s+([A-Za-z_]\w*)\(`), "File.swift:42"
// fallback, double-click → source, context menu "Comment on this clip", the
// "No Timeline — cuts estimated" state with the cut detector, selection.

struct ClipsLane: LaneRenderer {
    var title = "CLIPS"
    var clips: [ClipInfo]
    var selectedID: String?

    static let rowHeight: CGFloat = 17
    var rows: Int { max(1, (clips.filter { !$0.pinned }.map(\.depth).max() ?? 0) + 1 + (clips.contains { $0.pinned } ? 1 : 0)) }
    var height: CGFloat { CGFloat(rows) * Self.rowHeight + 6 }

    private func row(_ c: ClipInfo) -> Int {
        let maxDepth = clips.filter { !$0.pinned }.map(\.depth).max() ?? 0
        return c.pinned ? maxDepth + 1 : c.depth
    }

    func draw(in ctx: inout GraphicsContext, size: CGSize, viewport v: TimelineViewport) {
        guard !clips.isEmpty else {
            ctx.draw(Text("No Timeline in this scene").font(.system(size: 10)).foregroundStyle(.white.opacity(0.35)),
                     at: CGPoint(x: 8, y: size.height / 2), anchor: .leading)
            return
        }
        var labels = 0
        for c in clips where c.end >= v.start && c.start <= v.end {
            let y = 3 + CGFloat(row(c)) * Self.rowHeight
            let base: Color = c.pinned ? .gray : (c.depth == 0 ? Color(red: 0.38, green: 0.55, blue: 0.95)
                                                                : Color(red: 0.45, green: 0.75, blue: 0.95))
            LaneDraw.block(&ctx, viewport: v, from: c.start, to: c.end, y: y, height: Self.rowHeight - 3,
                           color: base, label: c.label ?? c.source.map { "\(URL(fileURLWithPath: $0.file).lastPathComponent):\($0.line)" },
                           labels: &labels, stroke: c.id == selectedID ? .white : nil)
            if c.transitionDuration > 0 {
                let x0 = v.x(c.start), x1 = v.x(c.start + c.transitionDuration)
                var p = Path()
                p.move(to: CGPoint(x: x0, y: y + Self.rowHeight - 3)); p.addLine(to: CGPoint(x: x1, y: y))
                ctx.stroke(p, with: .color(.white.opacity(0.6)), lineWidth: 1)
            }
        }
    }

    func hit(_ p: CGPoint, viewport v: TimelineViewport) -> LaneHit? {
        let t = v.t(p.x)
        let r = Int((p.y - 3) / Self.rowHeight)
        guard let c = clips.last(where: { row($0) == r && $0.contains(t) }) else { return nil }
        return LaneHit(kind: .clip, id: c.id, start: c.start, end: c.end)
    }
}
