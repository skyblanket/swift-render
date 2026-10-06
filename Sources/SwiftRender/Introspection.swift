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

    /// Discover the clips and knobs of the scene `make` builds (`make(t)` is the
    /// scene body at absolute time `t`).
    ///
    /// Two tiers, both pixel-free for real renders:
    /// - structural: call `make(t)` on a coarse grid and walk every clip's content
    ///   closure, which finds Timelines built in closures and helper functions;
    /// - render: tiny `ImageRenderer` passes at clip starts and midpoints
    ///   (breadth-first, capped at `maxRenders`), which finds Timelines built
    ///   inside custom `View` bodies.
    ///
    /// Nested Timelines report at their parent clip's offset with depth + 1; times
    /// assume a nested Timeline runs at 1× (`Timeline(local)` or `Timeline(local - k)`).
    /// Knobs read anywhere during the probe, on any thread, are declared. Knobs read
    /// only by `soundtrack(duration:)` are declared if the caller evaluates it between
    /// `KnobStore.shared.beginRecording()` and `endRecording()`.
    public static func probe(duration: Double, size: CGSize, fps: Int,
                             make: @escaping @MainActor (Double) -> AnyView) -> SceneStructure {
        let probe = ProbeCollector()
        KnobStore.shared.beginRecording()
        ProbeCollector.$current.withValue(probe) {
            let step = max(0.5, duration / 120)
            for t in stride(from: 0.0, to: max(duration, 1e-9), by: step) {
                probe.structural(at: t, make: make)
            }

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

    struct Lane {
        let parent: String?
        let depth: Int
        let label: String?
        let source: SourceLocation
    }

    struct Record {
        let lane: Lane
        let start: Double, end: Double
        let label: String?
        let source: SourceLocation
        let pinned: Bool
        let transition: Transition
    }

    /// Structural tier: the clip whose content is being evaluated right now.
    private struct Context { var parent: String?; var depth: Int; var absNow: Double }

    private(set) var isRendering = false
    private var renderTime = 0.0
    private var context = Context(parent: nil, depth: 0, absNow: 0)
    private var built: [(timeline: Timeline, context: Context)] = []
    private var descended = Set<String>()
    private var lanes: [String: Lane] = [:]
    private var laneOrder: [String] = []
    private(set) var records: [String: Record] = [:]
    /// Record keys in discovery order; a parent always precedes its children.
    private(set) var order: [String] = []

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

    /// Record every clip `tl` places, given that its local time `tl.t` is absolute `absNow`.
    /// First sighting wins, so results don't depend on which probe time saw a clip last.
    private func record(_ tl: Timeline, parent: String?, depth: Int, absNow: Double) -> [String] {
        let laneKey = Self.laneKey(parent: parent, tl)
        if lanes[laneKey] == nil {
            lanes[laneKey] = Lane(parent: parent, depth: depth, label: tl.label,
                                  source: SourceLocation(file: tl.file, line: tl.line))
            laneOrder.append(laneKey)
        }
        let lane = lanes[laneKey]!
        let keys = Self.clipKeys(lane: laneKey, tl)
        let offset = absNow - tl.t
        for (i, p) in tl.placed.enumerated() where records[keys[i]] == nil {
            records[keys[i]] = Record(lane: lane, start: offset + p.start, end: offset + p.start + p.clip.duration,
                                      label: p.clip.label, source: SourceLocation(file: p.clip.file, line: p.clip.line),
                                      pinned: p.clip.pinnedStart != nil, transition: p.clip.transition)
            order.append(keys[i])
        }
        return keys
    }

    // MARK: structural tier

    /// Called from `Timeline.init`.
    func timelineBuilt(_ tl: Timeline) {
        guard !isRendering else { return }      // the render tier reports from body, where its scope is
        built.append((tl, context))
    }

    @MainActor
    func structural(at t: Double, make: @MainActor (Double) -> AnyView) {
        context = Context(parent: nil, depth: 0, absNow: t)
        _ = make(t)
        // Breadth-first: walking a clip's content may build more Timelines, which append to `built`.
        while !built.isEmpty {
            let (tl, ctx) = built.removeFirst()
            let keys = record(tl, parent: ctx.parent, depth: ctx.depth, absNow: ctx.absNow)
            guard ctx.depth < SceneProbe.maxDepth else { continue }
            for (i, p) in tl.placed.enumerated() where descended.insert(keys[i]).inserted {
                let start = ctx.absNow - tl.t + p.start
                let d = p.clip.duration
                for local in Set([min(1e-3, d / 2), d / 2, max(0, d - 1e-3)]).sorted() {
                    context = Context(parent: keys[i], depth: ctx.depth + 1, absNow: start + local)
                    _ = p.clip.content(local)
                }
            }
        }
    }

    // MARK: render tier

    @MainActor
    func render(at t: Double, size: CGSize, fps: Int, duration: Double, make: @escaping @MainActor (Double) -> AnyView) {
        isRendering = true; renderTime = t
        defer { isRendering = false }
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
        if scope == nil, lanes[Self.laneKey(parent: nil, tl)] == nil,
           let known = laneOrder.lazy.compactMap({ self.lanes[$0] }).first(where: { $0.depth > 0 && $0.source == source }) {
            parent = known.parent; depth = known.depth
        }
        let keys = record(tl, parent: parent, depth: depth, absNow: renderTime)
        return keys.map { ProbeScope(parent: $0, depth: depth + 1) }
    }

    // MARK: output

    /// Absolute span of a record, clipped to its parent's span and to the scene.
    func span(_ key: String, duration: Double) -> (start: Double, end: Double)? {
        guard let r = records[key] else { return nil }
        var lo = max(0, r.start), hi = min(duration, r.end)
        if let parent = r.lane.parent {
            guard let p = span(parent, duration: duration) else { return nil }
            lo = max(lo, p.start); hi = min(hi, p.end)
        }
        return hi - lo > 1e-6 ? (lo, hi) : nil
    }

    /// Clips in tree order — each parent followed by its nested clips — siblings by start.
    func clipInfos(duration: Double) -> [ClipInfo] {
        func round6(_ x: Double) -> Double { (x * 1e6).rounded() / 1e6 + 0 }   // + 0 turns -0 into 0
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        var spans: [String: (start: Double, end: Double)] = [:]
        var children: [String: [String]] = [:]
        for key in order {
            guard let s = span(key, duration: duration) else { continue }
            spans[key] = (round6(s.start), round6(s.end))
            children[records[key]!.lane.parent ?? "", default: []].append(key)
        }
        var out: [ClipInfo] = [], ids: [String: String] = [:], used: [String: Int] = [:]
        func emit(_ parent: String) {
            let keys = (children[parent] ?? []).sorted { (spans[$0]!.start, rank[$0]!) < (spans[$1]!.start, rank[$1]!) }
            for key in keys {
                let r = records[key]!, s = spans[key]!
                let base = ClipInfo.id(depth: r.lane.depth, start: s.start, line: r.source.line)
                let n = used[base, default: 0]
                used[base] = n + 1
                let id = n == 0 ? base : "\(base)~\(n)"
                ids[key] = id
                out.append(ClipInfo(id: id, label: r.label, start: s.start, end: s.end, depth: r.lane.depth,
                                    pinned: r.pinned, transitionIn: r.transition.name,
                                    transitionDuration: r.transition.duration, source: r.source,
                                    parentID: r.lane.parent.flatMap { ids[$0] },
                                    timelineLabel: r.lane.label, timelineSource: r.lane.source))
                emit(key)
            }
        }
        emit("")
        return out
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
