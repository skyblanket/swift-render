import SwiftUI

// MARK: - Transition
// A cross-transition between two sequential clips. The incoming clip starts
// `duration` seconds before the outgoing clip ends; during that overlap the
// outgoing view gets phase `.out` and the incoming view gets phase `.in`,
// each with progress p going 0 → 1. Pure, deterministic, no state.
public struct Transition {
    public enum Phase { case `in`, out }
    public var duration: Double
    /// What editors and `info` show: "cut", "fade", "slide", "flash", "overlap",
    /// or a custom transition's name. Never affects pixels.
    public var name: String
    var apply: (AnyView, _ p: Double, _ phase: Phase) -> AnyView

    /// A custom transition. `apply` receives the clip's view, progress 0 → 1 and
    /// the phase (`.in` for the incoming clip, `.out` for the outgoing one).
    public init(_ name: String, duration: Double,
                apply: @escaping (AnyView, _ p: Double, _ phase: Phase) -> AnyView) {
        self.name = name; self.duration = duration; self.apply = apply
    }

    public static let cut = Transition("cut", duration: 0) { v, _, _ in v }

    /// Hold both clips on screen for `d` seconds with no visual blend.
    public static func overlap(_ d: Double) -> Transition {
        Transition("overlap", duration: d) { v, _, _ in v }
    }

    public static func fade(_ d: Double = 0.35) -> Transition {
        Transition("fade", duration: d) { v, p, phase in
            AnyView(v.opacity(phase == .in ? Ease.easeInOut(p) : 1 - Ease.easeInOut(p)))
        }
    }

    /// Push: incoming slides in from `edge`, outgoing slides out the far side.
    public static func slide(_ d: Double = 0.45, from edge: Edge = .trailing,
                             distance: CGFloat = 1920) -> Transition {
        Transition("slide", duration: d) { v, p, phase in
            let e = Ease.easeInOut(p)
            let dir: CGFloat = (edge == .trailing || edge == .bottom) ? 1 : -1
            let off = phase == .in ? (1 - e) * distance * dir : -e * distance * dir
            let vertical = edge == .top || edge == .bottom
            return AnyView(v.offset(x: vertical ? 0 : off, y: vertical ? off : 0))
        }
    }

    /// Hard cut hidden under a 2-ish-frame burst drawn by the incoming clip.
    public static func flash(_ d: Double = 0.14, color: Color = .white) -> Transition {
        Transition("flash", duration: d) { v, p, phase in
            guard phase == .in else { return v }
            return AnyView(v.overlay(color.opacity(pow(1 - p, 2)).ignoresSafeArea()))
        }
    }
}

// MARK: - Clip
// One span on the timeline. Sequential clips (the default) start where the
// previous sequential clip ended, minus their transition's overlap. Clips
// pinned with `at:` float free (overlays, HUDs) and don't move the cursor.
// Content is a pure function of *local* time, 0 ..< duration.
public struct Clip {
    var duration: Double
    var pinnedStart: Double?
    var transition: Transition = .cut
    var content: (Double) -> AnyView
    /// Editor label from `.named(_:)`; nil shows as "File.swift:line".
    var label: String?
    // Where the clip was written, for editors and agents. `#filePath` literals
    // are immortal strings, so recording them allocates nothing per frame.
    let file: String
    let line: Int

    public init<V: View>(_ duration: Double, file: String = #filePath, line: Int = #line,
                         @ViewBuilder _ content: @escaping (Double) -> V) {
        self.duration = duration
        self.content = { AnyView(content($0)) }
        self.file = file
        self.line = line
    }

    public init<V: View>(at start: Double, for duration: Double, file: String = #filePath, line: Int = #line,
                         @ViewBuilder _ content: @escaping (Double) -> V) {
        self.init(duration, file: file, line: line, content)
        self.pinnedStart = start
    }

    /// Cross-transition *into* this clip (from whatever precedes it).
    public func transition(_ tr: Transition) -> Clip {
        var c = self; c.transition = tr; return c
    }

    /// Name the clip for editors, review comments and agents ("Hero", "Outro").
    /// Purely descriptive: never changes timing or pixels.
    public func named(_ label: String) -> Clip {
        var c = self; c.label = label; return c
    }
}

// MARK: - TimelineBuilder

@resultBuilder
public enum TimelineBuilder {
    public static func buildExpression(_ c: Clip) -> [Clip] { [c] }
    public static func buildBlock(_ cs: [Clip]...) -> [Clip] { cs.flatMap { $0 } }
    public static func buildArray(_ cs: [[Clip]]) -> [Clip] { cs.flatMap { $0 } }
    public static func buildOptional(_ c: [Clip]?) -> [Clip] { c ?? [] }
    public static func buildEither(first c: [Clip]) -> [Clip] { c }
    public static func buildEither(second c: [Clip]) -> [Clip] { c }
}

// MARK: - Timeline
// A plain View: feed it the scene's `t`, it shows the right clips with local
// time remapped to each. Later clips stack on top during overlaps. Nest by
// returning another `Timeline(local) { … }` inside a Clip.
public struct Timeline: View {
    struct Placed {
        let start: Double
        let clip: Clip
        var outT: Transition?       // wired from the *next* sequential clip
        var outStart: Double = .infinity
    }

    let t: Double
    let placed: [Placed]
    /// End of the last sequential clip — handy for sizing `defaultDuration`.
    public let duration: Double
    /// Editor label for the whole lane ("Outro"); nil shows as "File.swift:line".
    let label: String?
    let file: String
    let line: Int

    public init(_ t: Double, label: String? = nil, file: String = #filePath, line: Int = #line,
                @TimelineBuilder _ content: () -> [Clip]) {
        self.t = t
        let clips = content()
        var cursor = 0.0, starts: [Double] = [], seq: [Int] = []
        for (i, c) in clips.enumerated() {
            if let s = c.pinnedStart {
                starts.append(s)
            } else {
                let s = max(0, cursor - c.transition.duration)
                starts.append(s)
                cursor = s + c.duration
                seq.append(i)
            }
        }
        var placed = clips.indices.map { Placed(start: starts[$0], clip: clips[$0]) }
        for (k, i) in seq.enumerated() where k + 1 < seq.count {
            let next = seq[k + 1]
            if clips[next].transition.duration > 0 {
                placed[i].outT = clips[next].transition
                placed[i].outStart = starts[next]
            }
        }
        self.placed = placed
        self.duration = cursor
        self.label = label
        self.file = file
        self.line = line
        // Introspection's whole hot-path cost: one task-local read, nil unless probing.
        ProbeCollector.current?.timelineBuilt(self)
    }

    public var body: some View {
        if let probe = ProbeCollector.current, probe.isRendering {
            ProbeReporter(timeline: self, probe: probe)
        } else {
            clips(scopes: nil)
        }
    }

    /// The clips active at `t`. `scopes` (probe renders only) tags each clip's
    /// subtree so a Timeline nested inside it knows its parent.
    func clips(scopes: [ProbeScope]?) -> some View {
        ZStack {
            ForEach(placed.indices, id: \.self) { i in
                let p = placed[i]
                let local = t - p.start
                if local >= 0 && local < p.clip.duration {
                    render(p, local: local, scope: scopes?[i])
                }
            }
        }
    }

    private func render(_ p: Placed, local: Double, scope: ProbeScope?) -> AnyView {
        var v = p.clip.content(local)
        if p.clip.transition.duration > 0, local < p.clip.transition.duration {
            v = p.clip.transition.apply(v, local / p.clip.transition.duration, .in)
        }
        if let outT = p.outT, t >= p.outStart {
            v = outT.apply(v, min(1, (t - p.outStart) / outT.duration), .out)
        }
        if let scope { v = AnyView(v.environment(\.probeScope, scope)) }
        return v
    }
}

// MARK: - Stagger
/// Eased 0…1 progress for element `i` of a cascading group: element i starts
/// at `start + i*step` and ramps over `ramp` seconds. Pure function of t.
public func stagger(_ t: Double, _ i: Int, step: Double = 0.06,
                    ramp: Double = 0.4, start: Double = 0,
                    ease: (Double) -> Double = Ease.easeOut) -> Double {
    let s = start + Double(i) * step
    return ease(Ease.clip(t, s, s + ramp))
}
