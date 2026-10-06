import SwiftUI
import SwiftRenderKit

// MARK: - Score lanes
//
// One row per `ScoreEventInfo.lane` group (voice, music, drums + marks, samples, fx)
// plus the captions row. Sustained sounds are blocks, packed into sub-rows so
// overlapping pads and bells stay readable; percussion and marks are glyphs scaled
// by amplitude. Whooshes and risers are amber and hatched: the house rule (and the
// `check` sweep warning) says new scores use swell/tick/rim/thump/blip instead.

struct ScoreLane: LaneRenderer {
    enum Style: Equatable { case blocks(maxRows: Int), hits }

    var title: String
    var lanes: Set<String>
    var style: Style
    /// This lane's events, sorted by time.
    var events: [ScoreEventInfo]
    /// Sub-row per event (parallel to `events`) and the row count.
    var rowOf: [Int]
    var rows: Int

    static let rowHeight: CGFloat = 13
    static let houseRuleNote = "House rule: no noise sweeps in new scores — use swell/tick/rim/thump/blip, or let the music mark the cut"

    init(title: String, lanes: Set<String>, style: Style, events all: [ScoreEventInfo]) {
        self.title = title
        self.lanes = lanes
        self.style = style
        let mine = all.filter { lanes.contains($0.lane) }.sorted { ($0.time, $0.lane) < ($1.time, $1.lane) }
        events = lanes.contains("melodic") ? Self.mergeChords(mine) : mine
        if case .blocks(let maxRows) = style {
            (rowOf, rows) = Self.pack(events.map { ($0.time, $0.time + $0.duration) }, maxRows: maxRows)
        } else {
            rowOf = Array(repeating: 0, count: events.count)
            rows = 1
        }
    }

    var height: CGFloat {
        switch style {
        case .hits: return 26
        case .blocks: return rows <= 1 ? 20 : CGFloat(rows) * Self.rowHeight + 4
        }
    }

    var warnings: Int { events.filter(Self.breaksHouseRule).count }

    static func breaksHouseRule(_ e: ScoreEventInfo) -> Bool { e.kind == "whoosh" || e.kind == "riser" }

    /// Same voice, same onset, same length → one block ("pad C4 E4 G4"): a chord
    /// written as four `.pad` events would otherwise fill four sub-rows.
    static func mergeChords(_ sorted: [ScoreEventInfo]) -> [ScoreEventInfo] {
        var out: [ScoreEventInfo] = []
        var index: [String: Int] = [:]
        for e in sorted {
            let key = "\(e.lane)|\(e.kind)|\(Int((e.time * 1000).rounded()))|\(Int((e.duration * 1000).rounded()))"
            if let i = index[key] {
                if let d = e.detail { out[i].detail = [out[i].detail, d].compactMap { $0 }.joined(separator: " ") }
                out[i].amp = max(out[i].amp, e.amp)
            } else {
                index[key] = out.count
                out.append(e)
            }
        }
        return out
    }

    /// Greedy interval packing: each interval takes the first sub-row that is free at
    /// its start; past `maxRows` it shares the row that frees up soonest.
    static func pack(_ intervals: [(Double, Double)], maxRows: Int) -> (rows: [Int], count: Int) {
        var ends: [Double] = []
        var out: [Int] = []
        out.reserveCapacity(intervals.count)
        for (a, b) in intervals {
            if let r = ends.firstIndex(where: { $0 <= a + 1e-6 }) {
                ends[r] = b; out.append(r)
            } else if ends.count < max(1, maxRows) {
                ends.append(b); out.append(ends.count - 1)
            } else {
                let r = ends.indices.min { ends[$0] < ends[$1] }!
                ends[r] = max(ends[r], b); out.append(r)
            }
        }
        return (out, max(1, ends.count))
    }

    private func rowRect(_ r: Int, size: CGSize) -> (y: CGFloat, h: CGFloat) {
        rows <= 1 ? (2, size.height - 4) : (2 + CGFloat(r) * Self.rowHeight, Self.rowHeight - 2)
    }

    func label(_ e: ScoreEventInfo) -> String {
        switch e.lane {
        case "speech": return e.detail ?? e.kind
        case "sample": return e.detail.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } ?? e.kind
        default:
            let s = [e.kind, e.detail].compactMap { $0 }.joined(separator: " ")
            return Self.breaksHouseRule(e) ? "⚠ " + s : s
        }
    }

    static func color(_ e: ScoreEventInfo) -> Color {
        if e.lane == "fx", !breaksHouseRule(e) { return Color(red: 0.85, green: 0.55, blue: 0.75) }
        if e.lane == "melodic" {
            // Sustained beds sit back; struck notes come forward.
            switch e.kind {
            case "pad", "drone": return Color(red: 0.58, green: 0.46, blue: 0.95)
            case "bass", "triBass": return Color(red: 0.45, green: 0.42, blue: 0.90)
            default: return Color(red: 0.76, green: 0.62, blue: 1.0)
            }
        }
        return StudioStyle.lane(e.lane)
    }

    func draw(in ctx: inout GraphicsContext, size: CGSize, viewport v: TimelineViewport) {
        switch style {
        case .blocks: drawBlocks(&ctx, size: size, viewport: v)
        case .hits: drawHits(&ctx, size: size, viewport: v)
        }
    }

    private func drawBlocks(_ ctx: inout GraphicsContext, size: CGSize, viewport v: TimelineViewport) {
        var labels = 0
        let slice = LaneDraw.visible(events, viewport: v, start: \.time, end: { $0.time + $0.duration })
        for i in slice.indices {
            let e = events[i]
            guard e.time + e.duration >= v.start else { continue }
            let (y, h) = rowRect(rowOf[i], size: size)
            let warn = Self.breaksHouseRule(e)
            let color = Self.color(e)
            let fill = e.lane == "speech" ? 0.40 : 0.22 + 0.22 * min(1, e.amp)
            LaneDraw.block(&ctx, viewport: v, from: e.time, to: e.time + e.duration, y: y, height: h, color: color,
                           label: nil, labels: &labels, dashed: warn, fill: fill)
            guard let r = LaneDraw.rect(viewport: v, from: e.time, to: e.time + e.duration, y: y, height: h) else { continue }
            if warn { LaneDraw.hatch(&ctx, r, color: StudioStyle.warn.opacity(0.35), spacing: 5) }
            if e.lane == "speech" {
                // Onset marker: where the line starts speaking.
                ctx.fill(Path(CGRect(x: r.minX, y: r.minY, width: 2, height: r.height)), with: .color(color))
            }
            LaneDraw.label(&ctx, label(e), in: r, labels: &labels,
                           color: warn ? StudioStyle.warn : .white.opacity(0.9),
                           font: .system(size: rows > 1 ? 8.5 : 9.5, weight: .medium))
        }
    }

    private func drawHits(_ ctx: inout GraphicsContext, size: CGSize, viewport v: TimelineViewport) {
        let base = size.height - 2
        let markY: CGFloat = 7
        var thin = Path(), thick = Path()
        for e in LaneDraw.visible(events, viewport: v, start: \.time, end: { $0.time + $0.duration }) {
            let x = v.x(e.time)
            guard x >= -20, x <= size.width + 4 else { continue }
            let amp = CGFloat(0.35 + 0.65 * min(1, max(0, e.amp)))
            let color = StudioStyle.lane(e.lane)
            switch e.kind {
            case "kick":
                thick.addRect(CGRect(x: x - 1, y: base - 15 * amp, width: 2.5, height: 15 * amp))
            case "clap":
                thin.move(to: CGPoint(x: x, y: base)); thin.addLine(to: CGPoint(x: x, y: base - 11 * amp))
                thin.move(to: CGPoint(x: x - 2, y: base - 11 * amp)); thin.addLine(to: CGPoint(x: x + 2, y: base - 11 * amp))
            case "hat":
                thin.move(to: CGPoint(x: x, y: base)); thin.addLine(to: CGPoint(x: x, y: base - 6 * amp))
            case "crash":
                thin.move(to: CGPoint(x: x, y: base)); thin.addLine(to: CGPoint(x: x, y: base - 13 * amp))
                ctx.stroke(Path(ellipseIn: CGRect(x: x - 2.5, y: base - 13 * amp - 5, width: 5, height: 5)),
                           with: .color(color), lineWidth: 1)
            case "boom", "swell":
                // Decaying boom / rising swell drawn as a wedge over its length.
                let x1 = v.x(e.time + e.duration)
                let top = e.kind == "boom" ? base - 15 * amp : markY - 4
                let bottom = e.kind == "boom" ? base : markY + 4
                var w = Path()
                if e.kind == "boom" {
                    w.move(to: CGPoint(x: x, y: bottom)); w.addLine(to: CGPoint(x: x, y: top)); w.addLine(to: CGPoint(x: x1, y: bottom))
                } else {
                    w.move(to: CGPoint(x: x, y: markY)); w.addLine(to: CGPoint(x: x1, y: top)); w.addLine(to: CGPoint(x: x1, y: bottom))
                }
                w.closeSubpath()
                ctx.fill(w, with: .color(color.opacity(0.35)))
                ctx.stroke(w, with: .color(color.opacity(0.8)), lineWidth: 0.75)
            case "tick", "rim", "blip":
                let s: CGFloat = e.kind == "tick" ? 2.5 : e.kind == "rim" ? 3.5 : 3
                var d = Path()
                if e.kind == "blip" {
                    d.addEllipse(in: CGRect(x: x - s, y: markY - s, width: 2 * s, height: 2 * s))
                } else {
                    d.move(to: CGPoint(x: x, y: markY - s)); d.addLine(to: CGPoint(x: x + s, y: markY))
                    d.addLine(to: CGPoint(x: x, y: markY + s)); d.addLine(to: CGPoint(x: x - s, y: markY)); d.closeSubpath()
                }
                ctx.fill(d, with: .color(color.opacity(0.4 + 0.6 * Double(amp))))
            case "thump":
                ctx.fill(Path(ellipseIn: CGRect(x: x - 4, y: markY - 4, width: 8, height: 8)), with: .color(color.opacity(0.35)))
                ctx.stroke(Path(ellipseIn: CGRect(x: x - 4, y: markY - 4, width: 8, height: 8)), with: .color(color), lineWidth: 1)
            default:
                thin.move(to: CGPoint(x: x, y: base)); thin.addLine(to: CGPoint(x: x, y: base - 8 * amp))
            }
        }
        let drums = StudioStyle.lane("drums")
        ctx.stroke(thin, with: .color(drums.opacity(0.85)), lineWidth: 1)
        ctx.fill(thick, with: .color(drums))
    }

    func hit(_ p: CGPoint, viewport v: TimelineViewport) -> LaneHit? {
        let t = v.t(p.x)
        let candidates = events.indices.filter { i in
            let e = events[i]
            switch style {
            case .hits:
                return abs(v.x(e.time) - p.x) <= 4 || (e.duration > 0.3 && t >= e.time && t <= e.time + e.duration
                                                         && ["boom", "swell"].contains(e.kind))
            case .blocks:
                let (y, h) = rowRect(rowOf[i], size: CGSize(width: v.width, height: height))
                return t >= e.time && t <= e.time + e.duration && p.y >= y - 1 && p.y <= y + h + 1
            }
        }
        // Nearest onset wins among overlapping candidates.
        guard let i = candidates.min(by: { abs(events[$0].time - t) < abs(events[$1].time - t) }) else { return nil }
        let e = events[i]
        var rect: CGRect?
        if case .blocks = style {
            let (y, h) = rowRect(rowOf[i], size: CGSize(width: v.width, height: height))
            rect = LaneDraw.rect(viewport: v, from: e.time, to: e.time + e.duration, y: y, height: h)
        }
        let lane = ["speech": "voice", "melodic": "music", "drums": "drums", "mark": "mark", "sample": "sample", "fx": "fx"][e.lane] ?? e.lane
        var detail = "\(lane) · \(StudioStyle.timecode(e.time)) · \(LaneDraw.seconds(e.duration)) · amp \(String(format: "%.2f", e.amp))"
        if e.lane == "sample", let d = e.detail { detail += "\n" + d }
        if Self.breaksHouseRule(e) { detail += "\n" + Self.houseRuleNote }
        let title = e.lane == "speech" ? "“\(e.detail ?? "")”" : label(e).replacingOccurrences(of: "⚠ ", with: "⚠︎ ")
        return LaneHit(kind: .event, id: "\(e.lane):\(i)", start: e.time, end: e.time + e.duration,
                       title: title, detail: detail, rect: rect)
    }
}

struct CaptionsLane: LaneRenderer {
    var title = "CAPTIONS"
    var captions: [CaptionInfo]
    var height: CGFloat = 20

    func draw(in ctx: inout GraphicsContext, size: CGSize, viewport v: TimelineViewport) {
        var labels = 0
        for c in LaneDraw.visible(captions, viewport: v, start: \.start, end: \.end) where c.end >= v.start {
            LaneDraw.block(&ctx, viewport: v, from: c.start, to: c.end, y: 2, height: size.height - 4,
                           color: Color(white: 0.80), label: c.text, labels: &labels, stroke: Color(white: 0.80).opacity(0.45), fill: 0.13)
        }
    }

    func hit(_ p: CGPoint, viewport v: TimelineViewport) -> LaneHit? {
        let t = v.t(p.x)
        guard let i = captions.firstIndex(where: { t >= $0.start && t <= $0.end }) else { return nil }
        let c = captions[i]
        return LaneHit(kind: .caption, id: "caption:\(i)", start: c.start, end: c.end, title: c.text,
                       detail: "caption · " + LaneDraw.range(c.start, c.end),
                       rect: LaneDraw.rect(viewport: v, from: c.start, to: c.end, y: 2, height: height - 4))
    }
}

enum ScoreLanes {
    /// Lane rows in display order (label, lanes grouped into the row, style).
    static let rows: [(title: String, lanes: Set<String>, style: ScoreLane.Style)] = [
        ("VOICE", ["speech"], .blocks(maxRows: 2)),
        ("MUSIC", ["melodic"], .blocks(maxRows: 4)),
        ("DRUMS · MARKS", ["drums", "mark"], .hits),
        ("SAMPLES", ["sample"], .blocks(maxRows: 3)),
        ("FX", ["fx"], .blocks(maxRows: 2)),
    ]

    static func renderers(_ events: [ScoreEventInfo]) -> [ScoreLane] {
        let present = Set(events.map(\.lane))
        return rows.filter { !$0.lanes.isDisjoint(with: present) }
            .map { ScoreLane(title: $0.title, lanes: $0.lanes, style: $0.style, events: events) }
    }

    /// The one lane titled `title` (a lane view redraws only itself).
    static func renderer(title: String, events: [ScoreEventInfo]) -> ScoreLane {
        let row = rows.first { $0.title == title }
        return ScoreLane(title: title, lanes: row?.lanes ?? [], style: row?.style ?? .hits, events: events)
    }
}
