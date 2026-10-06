import SwiftUI
import SwiftRenderKit

// MARK: - Score lanes   // S5
//
// Shell: one renderer per `ScoreEventInfo.lane` plus the captions row. S5 adds
// note/sample/speech detail, hover inspection, and amber "house rule" marking of
// whoosh/riser (fx lane) with the `check` sweep warning text.

struct ScoreLane: LaneRenderer {
    var title: String
    var lanes: Set<String>
    var events: [ScoreEventInfo]
    var height: CGFloat = 17

    func draw(in ctx: inout GraphicsContext, size: CGSize, viewport v: TimelineViewport) {
        var labels = 0
        let mine = events.filter { lanes.contains($0.lane) }
        for e in LaneDraw.visible(mine, viewport: v, start: \.time, end: { $0.time + $0.duration }) {
            let color = StudioStyle.lane(e.lane)
            let w = v.x(e.time + e.duration) - v.x(e.time)
            if w < 3 {
                // Hits (drums, marks) as ticks scaled by amplitude.
                let x = v.x(e.time)
                let hgt = (size.height - 4) * CGFloat(0.4 + 0.6 * min(1, e.amp))
                var p = Path()
                p.move(to: CGPoint(x: x, y: size.height - 2)); p.addLine(to: CGPoint(x: x, y: size.height - 2 - hgt))
                ctx.stroke(p, with: .color(color.opacity(0.9)), lineWidth: e.kind == "kick" ? 2 : 1)
            } else {
                LaneDraw.block(&ctx, viewport: v, from: e.time, to: e.time + e.duration, y: 2, height: size.height - 4,
                               color: color, label: [e.kind, e.detail].compactMap { $0 }.joined(separator: " "),
                               labels: &labels, dashed: e.lane == "fx")
            }
        }
    }
}

struct CaptionsLane: LaneRenderer {
    var title = "CAPTIONS"
    var captions: [CaptionInfo]
    var height: CGFloat = 18

    func draw(in ctx: inout GraphicsContext, size: CGSize, viewport v: TimelineViewport) {
        var labels = 0
        for c in LaneDraw.visible(captions, viewport: v, start: \.start, end: \.end) {
            LaneDraw.block(&ctx, viewport: v, from: c.start, to: c.end, y: 2, height: size.height - 4,
                           color: Color(white: 0.75), label: c.text, labels: &labels)
        }
    }
}

enum ScoreLanes {
    /// Lane rows in display order (label, lanes grouped into the row).
    static let rows: [(title: String, lanes: Set<String>)] = [
        ("VOICE", ["speech"]),
        ("MUSIC", ["melodic"]),
        ("DRUMS · MARKS", ["drums", "mark"]),
        ("SAMPLES", ["sample"]),
        ("FX", ["fx"]),
    ]

    static func renderers(_ events: [ScoreEventInfo]) -> [ScoreLane] {
        let sorted = events.sorted { $0.time < $1.time }
        let present = Set(events.map(\.lane))
        return rows.filter { !$0.lanes.isDisjoint(with: present) }
            .map { ScoreLane(title: $0.title, lanes: $0.lanes, events: sorted) }
    }
}
