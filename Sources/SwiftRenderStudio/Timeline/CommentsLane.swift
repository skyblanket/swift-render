import SwiftUI
import SwiftRenderKit

// MARK: - Comments lane   // S6
//
// Markers (point-in-time comments) and ranges colored by status, numbered in scene
// order like the viewer pins; agent comments get a violet ring. Drag a range end to
// retime it, drag a marker (or a range's middle) to move it — snapped to frames,
// written on release. Click selects and seeks; double-click empty lane = new comment.

struct CommentsLane: LaneRenderer {
    var title = "NOTES"
    var comments: [ReviewComment]
    var selection: String?
    var height: CGFloat = 22
    /// Live retime preview while dragging: id → (t, end).
    var preview: (id: String, t: Double, end: Double?)?

    /// Which part of a comment a drag grabbed.
    enum Part: Equatable, Sendable { case start, end, whole }

    static let handleSlop: CGFloat = 5

    private func times(_ c: ReviewComment) -> (Double, Double?) {
        if let p = preview, p.id == c.id { return (p.t, p.end) }
        return (c.t, c.end)
    }

    func draw(in ctx: inout GraphicsContext, size: CGSize, viewport v: TimelineViewport) {
        let numbers = ReviewController.numbering(comments)
        let mid = size.height / 2
        // Ranges first so markers sit on top.
        for c in comments {
            let (t, end) = times(c)
            guard let end else { continue }
            let x0 = v.x(t), x1 = v.x(end)
            guard x1 >= -4, x0 <= size.width + 4 else { continue }
            let color = StudioStyle.color(c.status)
            let selected = c.id == selection
            let bar = CGRect(x: x0, y: mid - 3, width: max(2, x1 - x0), height: 6)
            ctx.fill(Path(roundedRect: bar, cornerRadius: 3), with: .color(color.opacity(selected ? 0.75 : 0.45)))
            if selected {
                // End handles.
                for x in [x0, x1] {
                    ctx.fill(Path(roundedRect: CGRect(x: x - 2, y: mid - 7, width: 4, height: 14), cornerRadius: 1.5),
                             with: .color(.white))
                }
            }
        }
        for c in comments {
            let (t, _) = times(c)
            let x = v.x(t)
            guard x >= -10, x <= size.width + 10 else { continue }
            let agent = c.author.kind == .agent
            let r = CGRect(x: x - 7.5, y: mid - 7.5, width: 15, height: 15)
            ctx.fill(Path(ellipseIn: r), with: .color(StudioStyle.color(c.status)))
            if agent { ctx.stroke(Path(ellipseIn: r.insetBy(dx: -1.5, dy: -1.5)), with: .color(ReviewStyle.agent), lineWidth: 1.5) }
            if c.id == selection {
                ctx.stroke(Path(ellipseIn: r.insetBy(dx: agent ? -3.5 : -2, dy: agent ? -3.5 : -2)), with: .color(.white), lineWidth: 1.5)
            }
            let label = c.status == .resolved ? "✓" : "\(numbers[c.id] ?? 0)"
            ctx.draw(Text(label).font(.system(size: 8.5, weight: .bold, design: .rounded)).foregroundStyle(.black),
                     at: CGPoint(x: r.midX, y: r.midY))
        }
    }

    func hit(_ p: CGPoint, viewport v: TimelineViewport) -> LaneHit? {
        guard let (c, _) = grab(p, viewport: v) else { return nil }
        return LaneHit(kind: .comment, id: c.id, start: c.t, end: c.end ?? c.t)
    }

    /// What a press at `p` grabs: a selected range's end handles first, then markers,
    /// then range bodies.
    func grab(_ p: CGPoint, viewport v: TimelineViewport) -> (ReviewComment, Part)? {
        if let s = selection, let c = comments.first(where: { $0.id == s }), let end = c.end {
            if abs(p.x - v.x(end)) <= Self.handleSlop { return (c, .end) }
            if abs(p.x - v.x(c.t)) <= Self.handleSlop { return (c, .start) }
        }
        let slop = 8 / v.pxPerSecond
        let t = v.t(p.x)
        if let c = comments.min(by: { abs($0.t - t) < abs($1.t - t) }), abs(c.t - t) < slop { return (c, .whole) }
        if let c = comments.first(where: { c in c.end.map { t >= c.t && t <= $0 } ?? false }) { return (c, .whole) }
        return nil
    }

    /// New (t, end) for a drag of `dt` seconds on `part`, snapped to frames, inside
    /// [0, duration], ranges at least one frame long.
    static func retime(t: Double, end: Double?, part: Part, by dt: Double, fps: Int, duration: Double) -> (Double, Double?) {
        let f = 1 / Double(max(1, fps))
        func snap(_ x: Double) -> Double { (x / f).rounded() * f }
        switch part {
        case .whole:
            let len = end.map { $0 - t } ?? 0
            let t0 = min(max(0, snap(t + dt)), max(0, duration - len))
            return (t0, end.map { _ in t0 + len })
        case .start:
            guard let end else { return retime(t: t, end: nil, part: .whole, by: dt, fps: fps, duration: duration) }
            return (min(max(0, snap(t + dt)), end - f), end)
        case .end:
            guard let end else { return (t, nil) }
            return (t, max(t + f, min(duration, snap(end + dt))))
        }
    }
}

/// The NOTES lane with its gestures: retime drags, click select/seek, double-click new.
struct CommentsLaneView: View {
    @Bindable var model: ProjectModel
    @State private var drag: (id: String, part: CommentsLane.Part, t: Double, end: Double?)?
    @State private var preview: (id: String, t: Double, end: Double?)?

    private var lane: CommentsLane {
        CommentsLane(comments: model.review.comments, selection: model.review.selection, preview: preview)
    }

    var body: some View {
        let v = model.ui.viewport
        let lane = self.lane
        Canvas { ctx, size in lane.draw(in: &ctx, size: size, viewport: v) }
            .frame(height: lane.height)
            .contentShape(Rectangle())
            .gesture(retimeGesture.exclusively(before: taps))
            .contextMenu {
                Button("New Comment at Playhead") { model.perform(.newComment) }
                if let c = model.review.selected {
                    Button("Comment \(c.id) → Playhead") { retime(c.id, t: model.playback.t, end: c.end.map { $0 - c.t + model.playback.t }) }
                }
            }
            .help("Notes: click to select · drag a marker or range end to retime · double-click to comment")
    }

    private var retimeGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { g in
                let v = model.ui.viewport
                if drag == nil {
                    guard let (c, part) = lane.grab(g.startLocation, viewport: v) else { return }
                    drag = (c.id, part, c.t, c.end)
                    model.review.selection = c.id
                    model.playback.pause()
                }
                guard let d = drag else { return }
                let dt = Double(g.translation.width) / v.pxPerSecond
                let (t, end) = CommentsLane.retime(t: d.t, end: d.end, part: d.part, by: dt,
                                                   fps: model.info?.fps ?? v.fps, duration: model.playback.duration)
                preview = (d.id, t, end)
                model.playback.seek(d.part == .end ? (end ?? t) : t, precise: false)
            }
            .onEnded { _ in
                defer { drag = nil; preview = nil }
                guard let p = preview, let d = drag, p.t != d.t || p.end != d.end else { return }
                retime(p.id, t: p.t, end: p.end)
                model.playback.seek(d.part == .end ? (p.end ?? p.t) : p.t, precise: true)
            }
    }

    private var taps: some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { e in
                let v = model.ui.viewport
                if lane.hit(e.location, viewport: v) == nil {
                    let t = min(max(0, v.t(e.location.x)), model.playback.duration)
                    model.playback.pause()
                    model.playback.seek(t, precise: true)
                    model.review.beginComment(t: t)
                    model.ui.inspectorTab = .comments
                    model.ui.showInspector = true
                }
            }
            .exclusively(before: SpatialTapGesture(count: 1).onEnded { e in
                let v = model.ui.viewport
                if let hit = lane.hit(e.location, viewport: v) {
                    model.review.selection = hit.id
                    model.ui.inspectorTab = .comments
                    model.playback.seek(hit.start, precise: true)
                } else {
                    model.playback.seek(v.t(e.location.x), precise: true)
                }
            })
    }

    private func retime(_ id: String, t: Double, end: Double?) {
        do { try model.review.retime(id, t: t, end: end, duration: model.playback.duration) }
        catch { model.ui.toast = "\(error)" }
    }
}
