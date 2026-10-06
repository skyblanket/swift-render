import SwiftUI
import SwiftRenderKit

// MARK: - Score lanes
//
// One row per `ScoreEventInfo.lane` group (voice, music, drums & hits, samples, effects)
// plus the captions row, each in one muted tone. Music collapses into phrases: notes
// closer than a few points merge, so a fit-zoomed score reads as one calm row and the
// notes come apart as you zoom in. Drums and hits are ticks scaled by amplitude.
// Whooshes and risers are hatched with a warning: the house rule (and the `check`
// sweep warning) says new scores use swell/tick/rim/thump/blip instead.

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
        case .hits: return 24
        case .blocks: return rows <= 1 ? 22 : CGFloat(rows) * Self.rowHeight + 4
        }
    }

    /// Music draws phrases rather than single notes.
    var phrases: Bool { lanes.contains("melodic") }

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

    static func color(_ e: ScoreEventInfo) -> Color { StudioStyle.Lane.tone(e.lane) }

    func draw(in ctx: inout GraphicsContext, size: CGSize, viewport v: TimelineViewport) {
        switch style {
        case .blocks: phrases ? drawPhrases(&ctx, size: size, viewport: v) : drawBlocks(&ctx, size: size, viewport: v)
        case .hits: drawHits(&ctx, size: size, viewport: v)
        }
    }

    /// Spans of notes closer than `gap` points, at this zoom.
    static func phraseSpans(_ events: ArraySlice<ScoreEventInfo>, pxPerSecond: Double, gap: CGFloat = 6) -> [(start: Double, end: Double, kinds: [String])] {
        let join = Double(gap) / max(pxPerSecond, 1e-6)
        var out: [(start: Double, end: Double, kinds: [String])] = []
        for e in events.sorted(by: { $0.time < $1.time }) {
            let end = e.time + max(e.duration, 0.01)
            if let last = out.last, e.time <= last.end + join {
                out[out.count - 1].end = max(last.end, end)
                out[out.count - 1].kinds.append(e.kind)
            } else {
                out.append((e.time, end, [e.kind]))
            }
        }
        return out
    }

    /// One row: every note a faint block (overlaps build up, so busy passages read
    /// darker), and each voice's phrases labelled where there's room ("Pad", "Bass").
    private func drawPhrases(_ ctx: inout GraphicsContext, size: CGSize, viewport v: TimelineViewport) {
        var labels = 0
        let tone = StudioStyle.Lane.music
        let slice = LaneDraw.visible(events, viewport: v, start: \.time, end: { $0.time + $0.duration })
        let y: CGFloat = 3, h = size.height - 6
        var notes = Path()
        for e in slice where e.time + e.duration >= v.start {
            if let r = LaneDraw.rect(viewport: v, from: e.time, to: e.time + max(e.duration, 0.01), y: y, height: h) {
                notes.addRoundedRect(in: r, cornerSize: CGSize(width: 2, height: 2), style: .continuous)
            }
        }
        ctx.fill(notes, with: .color(tone.opacity(0.22)))
        // Labels: the widest phrases first, never two over the same stretch.
        var taken: [ClosedRange<CGFloat>] = []
        let byKind = Dictionary(grouping: slice, by: \.kind)
        let spans = byKind.flatMap { kind, evs in
            Self.phraseSpans(evs[...], pxPerSecond: v.pxPerSecond, gap: 12).map { (kind, $0.start, $0.end) }
        }
        .compactMap { k, a, b -> (String, CGRect)? in
            LaneDraw.rect(viewport: v, from: a, to: b, y: y, height: h).map { (k, $0) }
        }
        .sorted { $0.1.width > $1.1.width }
        for (kind, r) in spans where r.width >= 60 {
            let lane = r.minX...r.maxX
            guard !taken.contains(where: { $0.overlaps(lane) }) else { continue }
            taken.append(lane)
            LaneDraw.label(&ctx, kind.prefix(1).uppercased() + kind.dropFirst(), in: r, labels: &labels)
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
            LaneDraw.block(&ctx, viewport: v, from: e.time, to: e.time + e.duration, y: y, height: h, color: color,
                           label: nil, labels: &labels, stroke: warn ? StudioStyle.warning : nil, dashed: warn,
                           fill: StudioStyle.Lane.fill)
            guard let r = LaneDraw.rect(viewport: v, from: e.time, to: e.time + e.duration, y: y, height: h) else { continue }
            if warn { LaneDraw.hatch(&ctx, r, color: StudioStyle.warning.opacity(0.3), spacing: 5) }
            if rows <= 1 || h >= 12 {
                LaneDraw.label(&ctx, label(e), in: r, labels: &labels)
            }
        }
    }

    /// Ticks rising from the baseline, height by amplitude (kicks a little heavier); marks
    /// (tick, rim, blip, thump) are small dots above; booms and swells a faint wedge.
    private func drawHits(_ ctx: inout GraphicsContext, size: CGSize, viewport v: TimelineViewport) {
        let base = size.height - 3
        let markY: CGFloat = 6
        let full = base - markY - 4
        var ticks = Path(), heavy = Path(), dots = Path(), wedges = Path()
        let tone = StudioStyle.Lane.drums
        for e in LaneDraw.visible(events, viewport: v, start: \.time, end: { $0.time + $0.duration }) {
            let x = v.x(e.time)
            guard x >= -20, x <= size.width + 4 else { continue }
            let amp = CGFloat(0.35 + 0.65 * min(1, max(0, e.amp)))
            switch e.kind {
            case "kick", "crash":
                heavy.move(to: CGPoint(x: x, y: base)); heavy.addLine(to: CGPoint(x: x, y: base - full * amp))
            case "boom", "swell":
                let x1 = v.x(e.time + e.duration)
                if e.kind == "boom" {
                    wedges.move(to: CGPoint(x: x, y: base)); wedges.addLine(to: CGPoint(x: x, y: base - full * amp))
                    wedges.addLine(to: CGPoint(x: x1, y: base))
                } else {
                    wedges.move(to: CGPoint(x: x, y: base)); wedges.addLine(to: CGPoint(x: x1, y: base - full * amp))
                    wedges.addLine(to: CGPoint(x: x1, y: base))
                }
                wedges.closeSubpath()
            case "tick", "rim", "blip", "thump":
                let r: CGFloat = e.kind == "thump" ? 2.5 : 1.75
                dots.addEllipse(in: CGRect(x: x - r, y: markY - r, width: 2 * r, height: 2 * r))
            default:
                ticks.move(to: CGPoint(x: x, y: base)); ticks.addLine(to: CGPoint(x: x, y: base - full * 0.7 * amp))
            }
        }
        ctx.fill(wedges, with: .color(tone.opacity(0.25)))
        ctx.stroke(ticks, with: .color(tone.opacity(0.7)), lineWidth: 1)
        ctx.stroke(heavy, with: .color(tone.opacity(0.95)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        ctx.fill(dots, with: .color(tone.opacity(0.9)))
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
        let lane = ["speech": "Voice", "melodic": "Music", "drums": "Drums", "mark": "Hit", "sample": "Sample", "fx": "Effect"][e.lane] ?? e.lane
        var detail = "\(lane) · \(StudioTime.precise(e.time)) · \(LaneDraw.seconds(e.duration)) · \(Int((e.amp * 100).rounded()))% level"
        if e.lane == "sample", let d = e.detail { detail += "\n" + d }
        if Self.breaksHouseRule(e) { detail += "\n" + Self.houseRuleNote }
        let title = e.lane == "speech" ? "“\(e.detail ?? "")”" : label(e).replacingOccurrences(of: "⚠ ", with: "⚠︎ ")
        return LaneHit(kind: .event, id: "\(e.lane):\(i)", start: e.time, end: e.time + e.duration,
                       title: title, detail: detail, rect: rect)
    }
}

struct CaptionsLane: LaneRenderer {
    var title = "Captions"
    var captions: [CaptionInfo]
    var height: CGFloat = 20

    func draw(in ctx: inout GraphicsContext, size: CGSize, viewport v: TimelineViewport) {
        var labels = 0
        for c in LaneDraw.visible(captions, viewport: v, start: \.start, end: \.end) where c.end >= v.start {
            LaneDraw.block(&ctx, viewport: v, from: c.start, to: c.end, y: 3, height: size.height - 6,
                           color: StudioStyle.Lane.captions, label: c.text, labels: &labels, fill: StudioStyle.Lane.fill)
        }
    }

    func hit(_ p: CGPoint, viewport v: TimelineViewport) -> LaneHit? {
        let t = v.t(p.x)
        guard let i = captions.firstIndex(where: { t >= $0.start && t <= $0.end }) else { return nil }
        let c = captions[i]
        return LaneHit(kind: .caption, id: "caption:\(i)", start: c.start, end: c.end, title: c.text,
                       detail: "Caption · " + LaneDraw.range(c.start, c.end),
                       rect: LaneDraw.rect(viewport: v, from: c.start, to: c.end, y: 2, height: height - 4))
    }
}

enum ScoreLanes {
    /// Lane rows in display order (label, lanes grouped into the row, style).
    static let rows: [(title: String, lanes: Set<String>, style: ScoreLane.Style)] = [
        ("Voice", ["speech"], .blocks(maxRows: 2)),
        ("Music", ["melodic"], .blocks(maxRows: 1)),
        ("Drums & Hits", ["drums", "mark"], .hits),
        ("Samples", ["sample"], .blocks(maxRows: 2)),
        ("Effects", ["fx"], .blocks(maxRows: 2)),
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
