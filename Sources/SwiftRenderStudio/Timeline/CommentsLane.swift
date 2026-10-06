import SwiftUI
import SwiftRenderKit

// MARK: - Comments lane
//
// Each comment is its numbered disc (the same grammar as the pins and the list) and,
// for a range, a bar to its end. Click opens the thread; dragging a point or a range
// body moves it, dragging a range's start/end handle retimes that end. The drag draws
// from `preview` and is written once, on release, through `ReviewController`.

struct CommentsLane: LaneRenderer {
    var title = "Comments"
    var comments: [ReviewComment]
    var selection: String?
    /// A retime in progress: the comment drawn at these times instead.
    var preview: RetimePreview?
    var height: CGFloat = 26

    static let markerSize: CGFloat = 18
    static let handleSlop: CGFloat = 6

    /// Scene order (by stored time), so overlapping discs stack the same way while dragging.
    var ordered: [ReviewComment] { comments.sorted { ($0.t, $0.createdAt) < ($1.t, $1.createdAt) } }

    private func times(_ c: ReviewComment) -> (t: Double, end: Double?) {
        if let p = preview, p.id == c.id { return (p.t, p.end) }
        return (c.t, c.end)
    }

    func draw(in ctx: inout GraphicsContext, size: CGSize, viewport v: TimelineViewport) {
        let list = ordered
        guard !list.isEmpty else {
            LaneDraw.empty(&ctx, "Press C to add a comment", size: size)
            return
        }
        let numbers = ReviewController.numbering(comments)
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
            let state = CommentState(c)
            let tone = state == .readyForReview ? StudioStyle.accent : StudioStyle.discFill
            let faded = state.isSettled
            let x = v.x(t)
            if let p = preview, p.id == c.id {
                // Ghost of where it was.
                let gx = v.x(c.t)
                let ghost = c.end.map { CGRect(x: gx, y: mid - 2, width: max(2, v.x($0) - gx), height: 4) }
                    ?? CGRect(x: gx - 6, y: mid - 6, width: 12, height: 12)
                ctx.stroke(Path(roundedRect: ghost, cornerRadius: 3), with: .color(tone.opacity(0.5)),
                           style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            }
            if let end {
                let x1 = v.x(end)
                if x1 >= 0, x <= size.width {
                    let bar = CGRect(x: x, y: mid - 2, width: max(2, x1 - x), height: 4)
                    ctx.fill(Path(roundedRect: bar, cornerRadius: 2), with: .color(tone.opacity(faded ? 0.25 : 0.5)))
                    // End handle: a slim tab.
                    let tab = CGRect(x: x1 - 1.5, y: mid - 6, width: 3, height: 12)
                    ctx.fill(Path(roundedRect: tab, cornerRadius: 1.5), with: .color(tone.opacity(faded ? 0.4 : 0.9)))
                }
            }
            guard x >= -12, x <= size.width + 12 else { continue }
            let selected = c.id == selection || c.id == preview?.id
            Self.disc(&ctx, center: CGPoint(x: x, y: mid), number: numbers[c.id], state: state, selected: selected)
        }
    }

    /// `CommentDisc`, drawn into a lane Canvas.
    static func disc(_ ctx: inout GraphicsContext, center: CGPoint, number: Int?, state: CommentState, selected: Bool) {
        let s = markerSize
        let r = CGRect(x: center.x - s / 2, y: center.y - s / 2, width: s, height: s)
        ctx.fill(Path(ellipseIn: r.insetBy(dx: -1.5, dy: -1.5)), with: .color(StudioStyle.chrome))
        let ink: Color
        switch state {
        case .open:
            ctx.fill(Path(ellipseIn: r), with: .color(StudioStyle.discFill))
            ink = StudioStyle.discInk
        case .inProgress, .claudeOnIt:
            ctx.fill(Path(ellipseIn: r), with: .color(StudioStyle.raised))
            ctx.stroke(Path(ellipseIn: r.insetBy(dx: 0.75, dy: 0.75)), with: .color(StudioStyle.discFill), lineWidth: 1.5)
            ink = StudioStyle.discFill
        case .readyForReview:
            ctx.fill(Path(ellipseIn: r), with: .color(StudioStyle.accent))
            ink = .white
        case .done:
            ctx.fill(Path(ellipseIn: r), with: .color(StudioStyle.discFill.opacity(0.35)))
            ink = StudioStyle.discInk.opacity(0.9)
        case .wontFix:
            ctx.stroke(Path(ellipseIn: r.insetBy(dx: 0.75, dy: 0.75)), with: .color(StudioStyle.discFill.opacity(0.45)),
                       style: StrokeStyle(lineWidth: 1.25, dash: [2.5, 2]))
            ink = StudioStyle.discFill.opacity(0.6)
        }
        if selected {
            ctx.stroke(Path(ellipseIn: r.insetBy(dx: -3, dy: -3)), with: .color(StudioStyle.accent), lineWidth: 2)
        }
        let label = number.map(String.init) ?? "•"
        ctx.draw(Text(label).font(StudioStyle.Fonts.rounded(10, weight: .bold)).monospacedDigit().foregroundStyle(ink),
                 at: CGPoint(x: r.midX, y: r.midY))
        if state == .done {
            let b = CGRect(x: r.maxX - 6, y: r.maxY - 6, width: 8, height: 8)
            ctx.fill(Path(ellipseIn: b), with: .color(StudioStyle.discFill))
            var check = Path()
            check.move(to: CGPoint(x: b.minX + 2, y: b.midY)); check.addLine(to: CGPoint(x: b.midX - 0.5, y: b.maxY - 2.2))
            check.addLine(to: CGPoint(x: b.maxX - 1.8, y: b.minY + 2))
            ctx.stroke(check, with: .color(StudioStyle.discInk), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
        }
    }

    func hit(_ p: CGPoint, viewport v: TimelineViewport) -> LaneHit? {
        let list = ordered
        let numbers = ReviewController.numbering(comments)
        let mid = height / 2
        var best: (LaneHit, CGFloat)?
        for c in list {
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
            let n = numbers[c.id] ?? 0
            let replies = c.replies.filter { !ReviewStyle.isStudioNote($0.author) }.count
            let hit = LaneHit(kind: .comment, id: c.id, start: t, end: end ?? t, part: part,
                              title: "#\(n) · \(c.body.split(separator: "\n").first.map(String.init) ?? "")",
                              detail: "\(CommentState(c).title) · \(StudioTime.range(t, end)) · \(ReviewStyle.displayName(c.author))"
                                + (replies == 0 ? "" : " · \(ReviewStyle.replies(replies))"),
                              rect: nil)
            if best == nil || dist < best!.1 { best = (hit, dist) }
        }
        return best?.0
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
