import AVFoundation
import SwiftUI
import SwiftRenderKit

// MARK: - Scene introspection
//
// Lets an editor or agent see a scene's structure — clips (with source
// locations), knobs, score events — without parsing Swift. A probe evaluates
// the scene at a handful of times with a collector switched on; every Timeline
// it meets reports the clips it places. Collection never changes a pixel, and
// with no probe running each hook is one task-local read that returns nil.

public struct SceneStructure: Sendable, Equatable {
    public var clips: [ClipInfo]
    public var knobs: [KnobInfo]
    public init(clips: [ClipInfo] = [], knobs: [KnobInfo] = []) { self.clips = clips; self.knobs = knobs }
}

@MainActor
public enum SceneProbe {
    /// Most probe renders per call. Each is ~0.5–1.5 ms at 16 px wide.
    static let maxRenders = 64
    /// Nesting deeper than this is almost certainly recursion.
    static let maxDepth = 8
    /// Most clip-content evaluations the structural tier makes per call. `maxDepth`
    /// bounds depth, this bounds breadth: a scene whose clips each nest several
    /// more clips would otherwise cost branching^depth. Breadth-first, so the
    /// shallow levels (what editors show) are always complete first.
    static let maxEvaluations = 4_096

    /// Discover the clips and knobs of the scene `make` builds (`make(t)` is the
    /// scene body at absolute time `t`).
    ///
    /// Two tiers, both pixel-free for real renders:
    /// - structural: call `make(t)` on a coarse grid, then walk each clip's content
    ///   closure level by level, which finds Timelines built in closures and helper
    ///   functions. A clip's content is only ever evaluated at times the scene can
    ///   show it (inside its parent's span and the scene, at local times in
    ///   `0 ..< duration`), so the probe never asks for a frame a render wouldn't;
    /// - render: tiny `ImageRenderer` passes at clip starts and midpoints
    ///   (breadth-first, capped at `maxRenders`), which finds Timelines built
    ///   inside custom `View` bodies.
    ///
    /// Clip times are fitted, not assumed: every Timeline call site is seen at
    /// several scene times, and its local time is mapped onto the scene clock
    /// piecewise-linearly through those sightings. So `Timeline(t * speed)`,
    /// `Timeline(max(0, t - 1))` (whose first clip holds its first frame until 1 s)
    /// and nested `Timeline(local - k)` all report where their clips are actually on
    /// screen. A Timeline seen only once is assumed to run at 1×.
    /// A Timeline that is built but never drawn (`outro(0).duration`) is dropped
    /// when the render tier draws that call site elsewhere but never there.
    /// Knobs read anywhere during the probe, on any thread, are declared. Knobs read
    /// only by `soundtrack(duration:)` are declared if the caller evaluates it between
    /// `KnobStore.shared.beginRecording()` and `endRecording()`.
    public static func probe(duration: Double, size: CGSize, fps: Int,
                             make: @escaping @MainActor (Double) -> AnyView) -> SceneStructure {
        // A non-finite length has no frames to probe (and NaN would never end the grid).
        guard duration.isFinite else { return SceneStructure() }
        let probe = ProbeCollector()
        KnobStore.shared.beginRecording()
        ProbeCollector.$current.withValue(probe) {
            probe.structural(duration: duration, make: make)

            var times: [Double] = [], seen = Set<Int>(), next = 0, scheduled = 0
            func enqueue(_ t: Double) {
                let t = min(max(0, t), max(0, duration - 1e-3))
                if seen.insert(Int((t * 1000).rounded())).inserted { times.append(t) }
            }
            enqueue(0)
            for _ in 0..<maxRenders {
                // Breadth-first: clips discovered so far (tier 1, then each render) queue their times.
                while scheduled < probe.order.count {
                    let span = probe.span(probe.order[scheduled], duration: duration); scheduled += 1
                    guard let span else { continue }
                    enqueue(span.start + min(1e-3, (span.end - span.start) / 2))
                    enqueue((span.start + span.end) / 2)
                }
                guard next < times.count else { break }
                probe.render(at: times[next], size: size, fps: fps, duration: duration, make: make)
                next += 1
            }
            probe.dropPhantomLanes(duration: duration)
        }
        let knobs = KnobStore.shared.endRecording()
        return SceneStructure(clips: probe.clipInfos(duration: duration), knobs: knobs)
    }
}

// MARK: - Collector

/// Where a probe-render subtree sits: inside clip `parent` (a collector key) at `depth`.
/// Travels in the environment because custom view bodies run after `Timeline.body` returns.
struct ProbeScope: Hashable, Sendable {
    var parent: String
    var depth: Int
}

private struct ProbeScopeKey: EnvironmentKey {
    static let defaultValue: ProbeScope? = nil
}

extension EnvironmentValues {
    var probeScope: ProbeScope? {
        get { self[ProbeScopeKey.self] }
        set { self[ProbeScopeKey.self] = newValue }
    }
}

/// Reports a Timeline met during a probe render, then draws it with each clip's
/// subtree tagged. Only ever in the view tree while probing.
struct ProbeReporter: View {
    let timeline: Timeline
    let probe: ProbeCollector
    @Environment(\.probeScope) private var scope

    var body: some View {
        timeline.clips(scopes: probe.rendered(timeline, scope: scope))
    }
}

/// Accumulates the Timelines a probe meets. Bound to `current` only inside
/// `SceneProbe.probe`, and task-locals reach only that synchronous main-actor
/// call tree, so nothing here is shared across threads.
final class ProbeCollector: @unchecked Sendable {
    @TaskLocal static var current: ProbeCollector?

    /// A Timeline seen at scene time `abs` with its own clock at `local`. Render-tier
    /// sightings are ground truth; structural ones come from walking a clip's first
    /// closure, which may have captured stale values, so a render at the same time wins.
    struct Sighting {
        var abs: Double
        var local: Double
        var rendered: Bool
    }

    /// One Timeline call site under one parent clip.
    struct Lane {
        let parent: String?
        let depth: Int
        let label: String?
        let source: SourceLocation
        var sightings: [Sighting] = []
    }

    /// One placed clip, in its lane's local time.
    struct Record {
        let lane: String
        let start: Double, end: Double
        let label: String?
        let source: SourceLocation
        let pinned: Bool
        let transition: Transition
        /// From the first sighting; the structural tier walks it.
        let content: (Double) -> AnyView
    }

    /// Structural tier: the clip whose content is being evaluated right now.
    private struct Context { var parent: String?; var depth: Int; var absNow: Double }

    private(set) var isRendering = false
    private var renderTime = 0.0
    private var sceneDuration = 0.0
    private var context = Context(parent: nil, depth: 0, absNow: 0)
    private var built: [(timeline: Timeline, context: Context)] = []
    /// Structural tier: clips recorded since the last level was walked.
    private var frontier: [String] = []
    private var lanes: [String: Lane] = [:]
    private var laneOrder: [String] = []
    private(set) var records: [String: Record] = [:]
    /// Record keys in discovery order; a parent always precedes its children.
    private(set) var order: [String] = []
    private var renderTimes: [Double] = []
    private var renderedLanes = Set<String>()
    private var phantomLanes = Set<String>()
    private var maps: [String: LaneMap] = [:]
    private var spans: [String: (start: Double, end: Double)?] = [:]

    // MARK: keys
    // Internal keys survive retiming: lane = parent clip + Timeline source;
    // clip = lane + Clip source + occurrence (loops share a line). Public ids
    // ("<depth>:<start>:<line>") are derived at the end.

    private static func laneKey(parent: String?, _ tl: Timeline) -> String {
        "\(parent ?? "")|\(tl.file):\(tl.line)"
    }

    private static func clipKeys(lane: String, _ tl: Timeline) -> [String] {
        var seen: [String: Int] = [:]
        return tl.placed.map { p in
            let base = "\(p.clip.file):\(p.clip.line)"
            let n = seen[base, default: 0]
            seen[base] = n + 1
            return "\(lane)/\(base)~\(n)"
        }
    }

    /// Note that `tl`'s local time `tl.t` was scene time `absNow`, and record the clips
    /// it places (first sighting wins for a clip's local start, length and closure).
    private func record(_ tl: Timeline, parent: String?, depth: Int, absNow: Double, rendered: Bool,
                        sighted: Bool = true) -> [String] {
        let laneKey = Self.laneKey(parent: parent, tl)
        if lanes[laneKey] == nil {
            lanes[laneKey] = Lane(parent: parent, depth: depth, label: tl.label,
                                  source: SourceLocation(file: tl.file, line: tl.line))
            laneOrder.append(laneKey)
        }
        if rendered { renderedLanes.insert(laneKey) }
        if sighted { addSighting(Sighting(abs: absNow, local: tl.t, rendered: rendered), to: laneKey) }
        let keys = Self.clipKeys(lane: laneKey, tl)
        for (i, p) in tl.placed.enumerated() where records[keys[i]] == nil {
            records[keys[i]] = Record(lane: laneKey, start: p.start, end: p.start + p.clip.duration,
                                      label: p.clip.label, source: SourceLocation(file: p.clip.file, line: p.clip.line),
                                      pinned: p.clip.pinnedStart != nil, transition: p.clip.transition,
                                      content: p.clip.content)
            order.append(keys[i])
            if !rendered { frontier.append(keys[i]) }
        }
        return keys
    }

    /// One sighting per scene time per lane: a render beats a structural walk, then
    /// the later local time wins. Two instances of one call site drawn at once
    /// (`HStack { card(t); card(t - 1) }`) share a lane, and SwiftUI evaluates bodies in
    /// no promised order, so the tie-break must not depend on which was met first.
    private func addSighting(_ s: Sighting, to laneKey: String) {
        guard s.abs.isFinite, s.local.isFinite else { return }
        if let i = lanes[laneKey]!.sightings.firstIndex(where: { abs($0.abs - s.abs) < 1e-9 }) {
            let old = lanes[laneKey]!.sightings[i]
            guard (s.rendered && !old.rendered) || (s.rendered == old.rendered && s.local > old.local) else { return }
            lanes[laneKey]!.sightings[i] = s
        } else {
            lanes[laneKey]!.sightings.append(s)
        }
        maps[laneKey] = nil
        spans.removeAll(keepingCapacity: true)
    }

    private func map(_ laneKey: String) -> LaneMap {
        if let m = maps[laneKey] { return m }
        let m = LaneMap(lanes[laneKey]?.sightings ?? [])
        maps[laneKey] = m
        return m
    }

    // MARK: structural tier

    /// Called from `Timeline.init`.
    func timelineBuilt(_ tl: Timeline) {
        guard !isRendering else { return }      // the render tier reports from body, where its scope is
        built.append((tl, context))
    }

    private func drainBuilt() {
        var i = 0
        while i < built.count {
            let (tl, ctx) = built[i]; i += 1
            _ = record(tl, parent: ctx.parent, depth: ctx.depth, absNow: ctx.absNow, rendered: false)
        }
        built.removeAll(keepingCapacity: true)
    }

    /// Evaluate the scene on a coarse grid, then walk clip content level by level.
    /// Each level's lanes have all their structural sightings (they come from walking
    /// the level above) before any of their clips is walked, so the times a clip is
    /// walked at come from its lane's fitted clock, and lie where the clip is on screen.
    @MainActor
    func structural(duration: Double, make: @MainActor (Double) -> AnyView) {
        sceneDuration = duration
        let step = max(0.5, duration / 120)
        for t in stride(from: 0.0, to: max(duration, 1e-9), by: step) {    // t = 0 at least, for knobs
            context = Context(parent: nil, depth: 0, absNow: t)
            _ = make(t)
            drainBuilt()
        }
        var budget = SceneProbe.maxEvaluations
        while !frontier.isEmpty, budget > 0 {
            let level = frontier
            frontier = []
            for key in level {
                guard budget > 0 else { break }
                guard let r = records[key], let lane = lanes[r.lane], lane.depth < SceneProbe.maxDepth,
                      let span = span(key, duration: duration) else { continue }
                let clock = map(r.lane)
                let length = r.end - r.start
                let edge = min(1e-3, (span.end - span.start) / 2)
                for a in Set([span.start + edge, (span.start + span.end) / 2, span.end - edge]).sorted() {
                    let local = clock.local(at: a) - r.start
                    // The render only ever asks for 0 ..< length; neither does the probe.
                    guard local.isFinite, local >= 0, local < length, budget > 0 else { continue }
                    budget -= 1
                    context = Context(parent: key, depth: lane.depth + 1, absNow: a)
                    _ = r.content(local)
                    drainBuilt()
                }
            }
        }
        frontier = []
    }

    // MARK: render tier

    @MainActor
    func render(at t: Double, size: CGSize, fps: Int, duration: Double, make: @escaping @MainActor (Double) -> AnyView) {
        isRendering = true; renderTime = t
        defer { isRendering = false }
        renderTimes.append(t)
        let renderer = ImageRenderer(content: RenderFrame(size: size, fps: fps, duration: duration,
                                                          t: t, postFX: false) { make(t) })
        renderer.scale = 16 / max(1, size.width)
        _ = renderer.cgImage
    }

    /// Called from `ProbeReporter.body`; returns the scope for each placed clip's subtree.
    func rendered(_ tl: Timeline, scope: ProbeScope?) -> [ProbeScope] {
        var parent = scope?.parent, depth = scope?.depth ?? 0
        // A nested ImageRenderer (Dither, PixelGrid) starts a fresh environment, so a
        // Timeline inside one arrives unscoped; reuse the lane the structural tier
        // already placed for the same source rather than inventing a root lane.
        let source = SourceLocation(file: tl.file, line: tl.line)
        var sighted = true
        if scope == nil, lanes[Self.laneKey(parent: nil, tl)] == nil,
           let known = laneOrder.lazy.compactMap({ self.lanes[$0] }).first(where: { $0.depth > 0 && $0.source == source }) {
            parent = known.parent; depth = known.depth
            // That guess may be another instance of the same helper; only let it move the
            // lane's clock while the guessed parent is actually on screen.
            sighted = known.parent.flatMap { span($0, duration: sceneDuration) }
                .map { $0.start <= renderTime && renderTime < $0.end } ?? true
        }
        let keys = record(tl, parent: parent, depth: depth, absNow: renderTime, rendered: true, sighted: sighted)
        return keys.map { ProbeScope(parent: $0, depth: depth + 1) }
    }

    /// A Timeline built but never drawn — typically one made only to read its
    /// `.duration` (`let n = outro(0).duration`) — is still met by the structural
    /// tier. Drop its lane when the evidence is unambiguous: the render tier drew the
    /// same call site elsewhere (so it can see it), rendered while this lane's clips
    /// would be on screen, and never met it there.
    func dropPhantomLanes(duration: Double) {
        var bySource: [SourceLocation: [String]] = [:]
        for key in laneOrder { bySource[lanes[key]!.source, default: []].append(key) }
        var laneClips: [String: [String]] = [:]
        for key in order { laneClips[records[key]!.lane, default: []].append(key) }
        var phantoms = Set<String>()
        for key in laneOrder where !renderedLanes.contains(key) {
            let lane = lanes[key]!
            guard bySource[lane.source]!.contains(where: { $0 != key && renderedLanes.contains($0) }) else { continue }
            let shown = (laneClips[key] ?? []).compactMap { span($0, duration: duration) }
            if renderTimes.contains(where: { t in shown.contains { $0.start <= t && t < $0.end } }) {
                phantoms.insert(key)
            }
        }
        phantomLanes = phantoms
        spans.removeAll()
    }

    // MARK: output

    /// Absolute span of a record: where its lane's fitted clock puts its local range,
    /// clipped to its parent's span and to the scene. nil when it is never on screen.
    func span(_ key: String, duration: Double) -> (start: Double, end: Double)? {
        if let cached = spans[key] { return cached }
        var result: (start: Double, end: Double)? = nil
        if let r = records[key], let lane = lanes[r.lane], !phantomLanes.contains(r.lane) {
            var lo = 0.0, hi = duration
            var parentShown = true
            if let parent = lane.parent {
                if let p = span(parent, duration: duration) { lo = p.start; hi = p.end } else { parentShown = false }
            }
            if parentShown { result = map(r.lane).visible(r.start, r.end, within: lo, hi) }
        }
        spans[key] = .some(result)
        return result
    }

    /// Clips in tree order — each parent followed by its nested clips — siblings by start.
    func clipInfos(duration: Double) -> [ClipInfo] {
        func round6(_ x: Double) -> Double { (x * 1e6).rounded() / 1e6 + 0 }   // + 0 turns -0 into 0
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        var shown: [String: (start: Double, end: Double)] = [:]
        var children: [String: [String]] = [:]
        for key in order {
            guard let s = span(key, duration: duration) else { continue }
            shown[key] = (round6(s.start), round6(s.end))
            children[lanes[records[key]!.lane]!.parent ?? "", default: []].append(key)
        }
        var out: [ClipInfo] = [], ids: [String: String] = [:], used: [String: Int] = [:]
        func emit(_ parent: String) {
            let keys = (children[parent] ?? []).sorted { (shown[$0]!.start, rank[$0]!) < (shown[$1]!.start, rank[$1]!) }
            for key in keys {
                let r = records[key]!, s = shown[key]!, lane = lanes[r.lane]!
                let base = ClipInfo.id(depth: lane.depth, start: s.start, line: r.source.line)
                let n = used[base, default: 0]
                used[base] = n + 1
                let id = n == 0 ? base : "\(base)~\(n)"
                ids[key] = id
                out.append(ClipInfo(id: id, label: r.label, start: s.start, end: s.end, depth: lane.depth,
                                    pinned: r.pinned, transitionIn: r.transition.name,
                                    transitionDuration: r.transition.duration, source: r.source,
                                    parentID: lane.parent.flatMap { ids[$0] },
                                    timelineLabel: lane.label, timelineSource: lane.source))
                emit(key)
            }
        }
        emit("")
        return out
    }
}

// MARK: - Lane clock

/// How a Timeline's local time follows the scene clock, fitted from its sightings:
/// piecewise linear through them, extended past the first and last with the end
/// slopes. Where a clamp or freeze meets a moving stretch between two sightings
/// (`max(0, t - 1.2)` seen at 1.0 and 1.5), the kink is placed where the
/// neighbouring stretches' lines cross rather than smeared across the gap.
/// One sighting can't show a rate, so it assumes 1×.
struct LaneMap {
    private(set) var points: [(a: Double, l: Double)] = []
    private var leftSlope = 1.0, rightSlope = 1.0

    init(_ sightings: [ProbeCollector.Sighting]) {
        let pts = sightings.map { (a: $0.abs, l: $0.local) }.sorted { $0.a < $1.a }
        guard pts.count >= 2 else { points = pts; return }
        func slope(_ i: Int) -> Double { (pts[i + 1].l - pts[i].l) / (pts[i + 1].a - pts[i].a) }
        func same(_ x: Double, _ y: Double) -> Bool { abs(x - y) <= 1e-9 * max(1, abs(x), abs(y)) }
        var out = [pts[0]]
        for i in 0..<(pts.count - 1) {
            if i > 0, i + 2 < pts.count {
                let mL = slope(i - 1), m = slope(i), mR = slope(i + 1)
                if !same(mL, mR), !same(m, mL), !same(m, mR) {
                    // Left stretch's line through pts[i] meets right stretch's line through pts[i+1].
                    let ak = (pts[i + 1].l - pts[i].l - mR * pts[i + 1].a + mL * pts[i].a) / (mL - mR)
                    if ak > pts[i].a, ak < pts[i + 1].a {
                        out.append((ak, pts[i].l + mL * (ak - pts[i].a)))
                    }
                }
            }
            out.append(pts[i + 1])
        }
        points = out
        leftSlope = (out[1].l - out[0].l) / (out[1].a - out[0].a)
        let n = out.count
        rightSlope = (out[n - 1].l - out[n - 2].l) / (out[n - 1].a - out[n - 2].a)
    }

    /// The lane's local time at scene time `a` (NaN with no sightings).
    func local(at a: Double) -> Double {
        guard let first = points.first, let last = points.last else { return .nan }
        if a <= first.a { return first.l + leftSlope * (a - first.a) }
        if a >= last.a { return last.l + rightSlope * (a - last.a) }
        var lo = 0, hi = points.count - 1           // points[lo].a < a < points[hi].a
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if points[mid].a <= a { lo = mid } else { hi = mid }
        }
        let p = points[lo], q = points[hi]
        return p.l + (q.l - p.l) * (a - p.a) / (q.a - p.a)
    }

    /// Scene times within `lo ..< hi` at which local time is in `s ..< e`, as one
    /// span (the hull, if the clock runs backwards and shows a clip twice).
    func visible(_ s: Double, _ e: Double, within lo: Double, _ hi: Double) -> (start: Double, end: Double)? {
        guard !points.isEmpty, !s.isNaN, !e.isNaN, s < e, lo.isFinite, hi.isFinite, lo < hi else { return nil }
        var knots = [(a: lo, l: local(at: lo))]
        for p in points where p.a > lo && p.a < hi { knots.append(p) }
        knots.append((hi, local(at: hi)))
        var start = Double.infinity, end = -Double.infinity
        for i in 0..<(knots.count - 1) {
            let (a1, l1) = knots[i], (a2, l2) = knots[i + 1]
            guard a2 > a1 else { continue }
            var x1 = a1, x2 = a2
            if l1 == l2 {
                guard s <= l1, l1 < e else { continue }
            } else {
                let m = (l2 - l1) / (a2 - a1)
                let atS = a1 + (s - l1) / m, atE = a1 + (e - l1) / m
                if m > 0 { x1 = max(a1, atS); x2 = min(a2, atE) } else { x1 = max(a1, atE); x2 = min(a2, atS) }
            }
            if x2 > x1 { start = min(start, x1); end = max(end, x2) }
        }
        return end - start > 1e-6 ? (start, end) : nil
    }
}

// MARK: - Score lanes

public extension Score {
    /// Score events flattened for an editor's lanes: drums, mark, melodic, sample,
    /// speech, fx. Cheap — never synthesizes. Speech lengths come from the TTS
    /// cache when the line was already rendered, else an estimate; sample lengths
    /// come from the file header.
    var eventInfos: [ScoreEventInfo] {
        var fileLengths: [String: Double] = [:]
        func fileLength(_ path: String) -> Double {
            if let d = fileLengths[path] { return d }
            var d = 0.0
            if let url = AssetPaths.resolve(path), let f = try? AVAudioFile(forReading: url),
               f.fileFormat.sampleRate > 0 {
                d = Double(f.length) / f.fileFormat.sampleRate
            }
            fileLengths[path] = d
            return d
        }
        return events.map { e in
            func len(_ natural: Double) -> Double { e.duration > 0 ? e.duration : natural }
            let info: (lane: String, kind: String, detail: String?, duration: Double)
            // Natural lengths mirror ScoreSynth.render and the Voice bank; kick/clap/hat/
            // crash/tick/rim/thump are fixed-length voices that ignore `duration`.
            switch e.sound {
            case .kick: info = ("drums", "kick", nil, 0.4)
            case .clap: info = ("drums", "clap", nil, 0.28)
            case .hat: info = ("drums", "hat", nil, 0.05)
            case .crash: info = ("drums", "crash", nil, 0.9)
            case .boom: info = ("drums", "boom", nil, len(2.6))
            case .tick: info = ("mark", "tick", nil, 0.07)
            case .rim: info = ("mark", "rim", nil, 0.10)
            case .thump: info = ("mark", "thump", nil, 0.30)
            case .blip(let n): info = ("mark", "blip", n.pitchName, len(0.14))
            case .swell(let n): info = ("mark", "swell", n.pitchName, len(1.5))
            case .bass(let n): info = ("melodic", "bass", n.pitchName, len(0.5))
            case .drone(let n): info = ("melodic", "drone", n.pitchName, len(7.0))
            case .pluck(let n): info = ("melodic", "pluck", n.pitchName, len(0.9))
            case .bell(let n): info = ("melodic", "bell", n.pitchName, len(1.6))
            case .pad(let n): info = ("melodic", "pad", n.pitchName, len(2.0))
            case .chip(let n): info = ("melodic", "chip", n.pitchName, len(0.18))
            case .triBass(let n): info = ("melodic", "triBass", n.pitchName, len(0.5))
            case .sample(let r):
                let available = max(0, fileLength(r.path) - r.offset) / max(r.rate, 1e-6)
                info = ("sample", "sample", r.path, e.duration > 0 ? min(e.duration, available) : available)
            case .speech(let s): info = ("speech", "speak", s.text, Self.spokenLength(s))
            case .whoosh(let rising): info = ("fx", "whoosh", rising ? "rising" : "falling", len(0.7))
            case .riser: info = ("fx", "riser", nil, len(3.4))
            case .laser: info = ("fx", "laser", nil, len(0.2))
            case .crackle: info = ("fx", "crackle", nil, len(4))
            }
            return ScoreEventInfo(lane: info.lane, kind: info.kind, detail: info.detail,
                                  time: e.time, duration: info.duration, amp: e.amp)
        }
    }

    /// Voiced length of a line: the cached TTS file when present (no synthesis),
    /// else the same estimate CaptionTrack falls back to.
    private static func spokenLength(_ s: SpeechSpec) -> Double {
        let url = Speech.cachedURL(s)
        if FileManager.default.fileExists(atPath: url.path), let b = try? SampleLibrary.load(url: url) {
            return Speech.voicedSpan(b).end
        }
        return max(0.6, Double(s.text.count) / 15)
    }
}

extension Note {
    /// Nearest equal-tempered name, A4 = 440 Hz: `Note.a1` → "A1", `Note.c4` → "C4".
    var pitchName: String? {
        guard hz > 0, hz.isFinite else { return nil }
        let midi = Int((69 + 12 * Foundation.log2(hz / 440)).rounded())
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let octave = Int((Double(midi) / 12).rounded(.down)) - 1
        return names[((midi % 12) + 12) % 12] + String(octave)
    }
}
