import SwiftUI
import SwiftRenderKit

// MARK: - Comments lane
//
// Markers (point comments) and ranges colored by status, numbered in scene order
// (resolved ones show ✓). Click selects the thread; dragging a point or a range
// body moves it, dragging a range's start/end handle retimes that end. The drag
// draws from `preview` and is written once, on release, through `ReviewController`.

struct CommentsLane: LaneRenderer {
    var title = "NOTES"
    var comments: [ReviewComment]
    var selection: String?
    /// A retime in progress: the comment drawn at these times instead.
    var preview: RetimePreview?
    var height: CGFloat = 22

    static let markerSize: CGFloat = 14
    static let handleSlop: CGFloat = 6

    /// Scene order (by stored time), so numbers don't jump while dragging.
    var ordered: [ReviewComment] { comments.sorted { ($0.t, $0.createdAt) < ($1.t, $1.createdAt) } }

    private func times(_ c: ReviewComment) -> (t: Double, end: Double?) {
        if let p = preview, p.id == c.id { return (p.t, p.end) }
        return (c.t, c.end)
    }

    func draw(in ctx: inout GraphicsContext, size: CGSize, viewport v: TimelineViewport) {
        let list = ordered
        guard !list.isEmpty else {
            LaneDraw.empty(&ctx, "No comments — press C at the playhead", size: size)
            return
        }
        let mid = size.height / 2
        // Selected and dragged comments draw last (on top).
        let order = list.indices.sorted { a, b in
            let ka = list[a].id == selection || list[a].id == preview?.id
            let kb = list[b].id == selection || list[b].id == preview?.id
            return ka == kb ? a < b : !ka
        }
        for i in order {
            let c = list[i]
            let (t, end) = times(c)
            let color = StudioStyle.color(c.status)
            let dim = c.status == .resolved || c.status == .wontFix
            let x = v.x(t)
            if let p = preview, p.id == c.id {
                // Ghost of where it was.
                let gx = v.x(c.t)
                let ghost = c.end.map { CGRect(x: gx, y: mid - 2, width: max(2, v.x($0) - gx), height: 4) }
                    ?? CGRect(x: gx - 5, y: mid - 5, width: 10, height: 10)
                ctx.stroke(Path(roundedRect: ghost, cornerRadius: 3), with: .color(color.opacity(0.5)),
                           style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            }
            if let end {
                let x1 = v.x(end)
                if x1 >= 0, x <= size.width {
                    let bar = CGRect(x: x, y: mid - 2.5, width: max(2, x1 - x), height: 5)
                    ctx.fill(Path(roundedRect: bar, cornerRadius: 2.5), with: .color(color.opacity(dim ? 0.35 : 0.7)))
                    // End handle: a slim tab.
                    let tab = CGRect(x: x1 - 2, y: mid - 6, width: 4, height: 12)
                    ctx.fill(Path(roundedRect: tab, cornerRadius: 1.5), with: .color(color.opacity(dim ? 0.5 : 1)))
                }
            }
            guard x >= -10, x <= size.width + 10 else { continue }
            let s = Self.markerSize
            let r = CGRect(x: x - s / 2, y: mid - s / 2, width: s, height: s)
            ctx.fill(Path(ellipseIn: r.insetBy(dx: -1.5, dy: -1.5)), with: .color(StudioStyle.laneBackground))
            ctx.fill(Path(ellipseIn: r), with: .color(color.opacity(dim ? 0.55 : 1)))
            // Agent comments get the violet ring the viewer pins use.
            let agent = c.author.kind == .agent
            if agent { ctx.stroke(Path(ellipseIn: r.insetBy(dx: -1.5, dy: -1.5)), with: .color(ReviewStyle.agent), lineWidth: 1.5) }
            if c.id == selection || c.id == preview?.id {
                let o: CGFloat = agent ? -3.5 : -2.5
                ctx.stroke(Path(ellipseIn: r.insetBy(dx: o, dy: o)), with: .color(.white), lineWidth: 1.5)
            }
            let label = c.status == .resolved ? "✓" : c.status == .wontFix ? "–" : "\(i + 1)"
            ctx.draw(Text(label).font(.system(size: i + 1 >= 10 ? 7.5 : 8.5, weight: .bold, design: .rounded))
                        .foregroundStyle(.black.opacity(0.85)),
                     at: CGPoint(x: r.midX, y: r.midY))
        }
    }

    func hit(_ p: CGPoint, viewport v: TimelineViewport) -> LaneHit? {
        let list = ordered
        let mid = height / 2
        var best: (LaneHit, CGFloat)?
        for (i, c) in list.enumerated() {
            let (t, end) = times(c)
            let x = v.x(t)
            var part: LaneHit.Part?
            var dist = abs(p.x - x)
            if dist <= Self.markerSize / 2 + 2, abs(p.y - mid) <= Self.markerSize / 2 + 3 {
                part = end == nil ? .body : .startHandle
            } else if let end {
                let x1 = v.x(end)
                if abs(p.x - x1) <= Self.handleSlop { part = .endHandle; dist = abs(p.x - x1) }
                else if p.x > x, p.x < x1 { part = .body; dist = Self.markerSize }   // body loses to markers
            }
            guard let part else { continue }
            let who = c.author.kind == .agent ? "\(c.author.name) (agent)" : c.author.name
            let hit = LaneHit(kind: .comment, id: c.id, start: t, end: end ?? t, part: part,
                              title: "#\(i + 1) · \(c.body.split(separator: "\n").first.map(String.init) ?? "")",
                              detail: "\(Self.statusName(c.status)) · \(LaneDraw.range(t, end ?? t)) · \(who)"
                                + (c.replies.isEmpty ? "" : " · \(c.replies.count) repl\(c.replies.count == 1 ? "y" : "ies")"),
                              rect: nil)
            if best == nil || dist < best!.1 { best = (hit, dist) }
        }
        return best?.0
    }

    static func statusName(_ s: ReviewStatus) -> String {
        switch s {
        case .open: return "Open"
        case .inProgress: return "In progress"
        case .resolved: return "Resolved"
        case .wontFix: return "Won't fix"
        }
    }
}

/// A comment's times while its marker is dragged.
struct RetimePreview: Equatable, Sendable {
    var id: String
    var t: Double
    var end: Double?
}

/// Pure retime math (snapped to frames, kept inside the scene, ranges ≥ 1 frame).
enum RetimeMath {
    static func apply(_ part: LaneHit.Part, t t0: Double, end end0: Double?, delta: Double,
                      duration: Double, fps: Int) -> (t: Double, end: Double?) {
        let f = Double(max(1, fps))
        let frame = 1 / f
        func snap(_ x: Double) -> Double { (x * f).rounded() / f }
        switch part {
        case .body:
            let len = (end0 ?? t0) - t0
            let t = min(max(0, snap(t0 + delta)), max(0, snap(duration - len)))
            return (t, end0.map { _ in t + len })
        case .startHandle:
            guard let end0 else { return apply(.body, t: t0, end: nil, delta: delta, duration: duration, fps: fps) }
            return (min(max(0, snap(t0 + delta)), end0 - frame), end0)
        case .endHandle:
            guard let end0 else { return (t0, nil) }
            return (t0, max(min(duration, snap(end0 + delta)), t0 + frame))
        }
    }
}

extension ReviewController {
    /// Move a comment (timeline drag). Goes through `retime`, which writes via
    /// `ReviewStore`, so the CLI, MCP and other windows see it via the watcher.
    func retimeComment(_ id: String, t: Double, end: Double?) throws {
        try retime(id, t: t, end: end, duration: nil)
    }
}
