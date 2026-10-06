import SwiftUI
import XCTest
@testable import SwiftRender
@testable import SwiftRenderScenes
import SwiftRenderKit

// MARK: - Fixtures

/// A Timeline built inside a custom View's body: invisible to the structural
/// tier (bodies aren't evaluated without rendering), so only the render tier finds it.
private struct CardStack: View {
    let t: Double
    var body: some View {
        Timeline(t, label: "cards") {
            Clip(1.0) { _ in Color.red }.named("card A")
            Clip(1.5) { _ in Color.blue }.transition(.fade(0.25))
        }
    }
}

@MainActor
private enum NestedFixture {
    static let duration = 6.0
    static func body(at t: Double) -> some View {
        Timeline(t) {
            Clip(2.0) { l in Color.black.overlay(Text("\(l)")) }.named("intro")
            Clip(3.0) { l in CardStack(t: l) }.transition(.flash())
            Clip(2.0) { _ in Color.white }
            Clip(at: 4.5, for: 9) { _ in Color.clear }     // runs past the end: clamped
        }
    }
    static func make(_ t: Double) -> AnyView { AnyView(body(at: t)) }
}

@MainActor
private enum KnobFixture {
    static func body(at t: Double) -> some View {
        let delay = Knob.double("title.delay", 0.4, in: 0...2)
        return Timeline(t) {
            Clip(1.0) { _ in
                Text(Knob.text("title.text", "HELLO"))
                    .foregroundStyle(Knob.color("title.color", "#C7FF1A"))
                    .opacity(Knob.bool("title.visible", true) ? 1 : 0)
            }
            Clip(1.0 + delay) { _ in Color.black }
        }
    }
    static func make(_ t: Double) -> AnyView { AnyView(body(at: t)) }
}

/// Every local time each clip's content was asked for, by clip name.
@MainActor
private enum CallLog {
    static var calls: [String: [Double]] = [:]
    static func note(_ name: String, _ l: Double) { calls[name, default: []].append(l) }
}

/// Clips whose content is only defined where the scene can show them.
@MainActor
private enum OutOfReachFixture {
    static let duration = 4.0
    static let lines = ["one", "two", "three", "four"]
    static func make(_ t: Double) -> AnyView {
        AnyView(Timeline(t) {
            // "Until the end" HUD: content(.infinity) would trap on Int(_:).
            Clip(at: 0, for: .infinity) { l in
                let _ = CallLog.note("hud", l)
                Text("REC").opacity(Int(l * 4) % 2 == 0 ? 1 : 0.4)
            }.named("hud")
            // Longer than the scene, indexing data by local time.
            Clip(10) { l in
                let _ = CallLog.note("captions", l)
                Text(lines[min(Int(l), lines.count - 1)])
            }.named("captions")
            Clip(at: -2, for: 3) { l in let _ = CallLog.note("early", l); Color.red }.named("early")
            Clip(at: 10, for: 2) { l in let _ = CallLog.note("late", l); Color.blue }.named("late")
            Clip(at: 1, for: .nan) { l in let _ = CallLog.note("nan", l); Color.green }.named("nan")
        })
    }
}

/// Timelines whose clock isn't `t - k`.
@MainActor
private enum RetimedFixture {
    static func twice(_ t: Double) -> AnyView {
        AnyView(Timeline(t * 2) {
            Clip(3.2) { _ in Color.red }.named("headline")
            Clip(3.0) { _ in Color.blue }.transition(.fade(0.4)).named("stats")
        })
    }
    /// Holds the first clip's first frame for 1 s, then plays.
    static func clamped(_ t: Double) -> AnyView {
        AnyView(Timeline(max(0, t - 1)) {
            Clip(2) { _ in Color.red }.named("a")
            Clip(2) { _ in Color.blue }.named("b")
        })
    }
    /// The clamp's kink (1.2) falls between the probe's grid times.
    static func kink(_ t: Double) -> AnyView {
        AnyView(Timeline(max(0, t - 1.2)) {
            Clip(1) { _ in Color.red }.named("k1")
            Clip(1) { _ in Color.blue }.named("k2")
        })
    }
    static func nested(_ t: Double) -> AnyView {
        AnyView(Timeline(t) {
            Clip(2) { _ in Color.black }.named("outer1")
            Clip(4) { l in
                Timeline(max(0, l - 0.5)) {
                    Clip(1) { _ in Color.green }.named("inner1")
                    Clip(1) { _ in Color.yellow }.named("inner2")
                }
            }.named("outer2")
        })
    }
    /// One helper drawn twice at once, the second a second behind.
    static func card(_ t: Double) -> some View {
        Timeline(t) {
            Clip(1) { _ in Color.red }.named("card.a")
            Clip(1) { _ in Color.blue }.named("card.b")
        }
    }
    static func twoCards(_ t: Double) -> AnyView { AnyView(HStack { card(t); card(t - 1) }) }
}

/// A Timeline built only to read its `.duration`, as that property's doc suggests.
@MainActor
private enum DurationOnlyFixture {
    static func outro(_ t: Double) -> Timeline {
        Timeline(t) {
            Clip(1.5) { _ in Color.red }.named("outro.a")
            Clip(1.5) { _ in Color.blue }.named("outro.b")
        }
    }
    static func make(_ t: Double) -> AnyView {
        let outroLength = outro(0).duration
        return AnyView(Timeline(t) {
            Clip(5) { _ in Color.black }.named("main")
            Clip(outroLength) { l in outro(l) }.named("outro")
        })
    }
}

/// Each clip nests six more, seven deep: 6^7 clips if walked exhaustively.
@MainActor
private enum BranchingFixture {
    static var evaluations = 0
    static func make(_ t: Double, _ n: Int = 0) -> AnyView {
        guard n < 7 else { return AnyView(Color.white) }
        return AnyView(Timeline(t) {
            for _ in 0..<6 { Clip(1) { l in let _ = (evaluations += 1); make(l * 6, n + 1) } }
        })
    }
}

// MARK: - Tests

@MainActor
final class IntrospectionTests: XCTestCase {
    private let size = CGSize(width: 1920, height: 1080)

    private func probe(_ duration: Double, _ make: @escaping @MainActor (Double) -> AnyView) -> SceneStructure {
        SceneProbe.probe(duration: duration, size: size, fps: 60, make: make)
    }

    func testTimelineDemoReportsClipsTransitionsAndSources() {
        let s = probe(TimelineDemo.defaultDuration) { AnyView(TimelineDemo.body(at: $0, duration: TimelineDemo.defaultDuration)) }
        let seq = s.clips.filter { !$0.pinned }
        XCTAssertEqual(seq.map(\.transitionIn), ["cut", "slide", "flash", "fade"])
        XCTAssertEqual(seq.map(\.start), [0, 1.75, 4.01, 5.91])
        XCTAssertEqual(seq.map(\.transitionDuration), [0, 0.45, 0.14, 0.5])
        XCTAssertEqual(seq.last?.end, 9.9)
        XCTAssertEqual(seq.compactMap(\.label), ["Title", "Springs", "Shader", "Outro"])
        let hud = try? XCTUnwrap(s.clips.first { $0.pinned })
        XCTAssertEqual(hud?.label, "HUD")
        XCTAssertEqual(hud?.start, 0)
        XCTAssertEqual(hud?.end, 9.9)
        XCTAssertTrue(s.clips.allSatisfy { $0.depth == 0 && $0.parentID == nil })
        XCTAssertTrue(s.clips.allSatisfy { $0.source?.file.hasSuffix("Scenes/TimelineDemo.swift") == true })
        XCTAssertEqual(Set(s.clips.map(\.id)).count, s.clips.count, "ids are unique")
        for c in s.clips {
            XCTAssertEqual(c.id, ClipInfo.id(depth: c.depth, start: c.start, line: c.source!.line))
        }
    }

    func testNestedTimelineInClipClosureReportsParentOffsetAndDepth() throws {
        let d = RepoPromo.defaultDuration
        let s = probe(d) { AnyView(RepoPromo.body(at: $0, duration: d)) }
        XCTAssertEqual(s.clips.filter { $0.depth == 0 }.count, 9)
        let outro = try XCTUnwrap(s.clips.first { $0.depth == 0 && $0.start == 19.2 })
        let nested = s.clips.filter { $0.depth == 1 }
        XCTAssertEqual(nested.map(\.start), [19.2, 21.26])
        XCTAssertEqual(nested.map(\.end), [21.4, 25.06])
        XCTAssertEqual(nested.map(\.transitionIn), ["cut", "flash"])
        XCTAssertTrue(nested.allSatisfy { $0.parentID == outro.id })
        XCTAssertNotEqual(nested[0].timelineSource, outro.timelineSource, "nested clips name their own Timeline")
        // Tree order: the nested clips follow their parent.
        let i = try XCTUnwrap(s.clips.firstIndex(of: outro))
        XCTAssertEqual(Array(s.clips[(i + 1)...]), nested)
    }

    func testTimelineInsideCustomViewBodyIsFoundByRenderTier() throws {
        let s = probe(NestedFixture.duration, NestedFixture.make)
        let top = s.clips.filter { $0.depth == 0 }
        XCTAssertEqual(top.map(\.start), [0, 1.86, 4.5, 4.86])
        let middle = try XCTUnwrap(top.first { $0.start == 1.86 })
        let cards = s.clips.filter { $0.depth == 1 }
        XCTAssertEqual(cards.map(\.label), ["card A", nil])
        XCTAssertEqual(cards.map(\.start), [1.86, 2.61])
        XCTAssertEqual(cards.map(\.end), [2.86, 4.11])
        XCTAssertEqual(cards.map(\.transitionIn), ["cut", "fade"])
        XCTAssertTrue(cards.allSatisfy { $0.parentID == middle.id && $0.timelineLabel == "cards" })
        XCTAssertEqual(top.first { $0.pinned }?.end, NestedFixture.duration, "clips are clamped to the scene")
        XCTAssertEqual(top.first?.label, "intro")
    }

    func testProbeIsDeterministic() {
        let a = probe(NestedFixture.duration, NestedFixture.make)
        let b = probe(NestedFixture.duration, NestedFixture.make)
        XCTAssertEqual(a, b)
        let d = RepoPromo.defaultDuration
        let r1 = probe(d) { AnyView(RepoPromo.body(at: $0, duration: d)) }
        let r2 = probe(d) { AnyView(RepoPromo.body(at: $0, duration: d)) }
        XCTAssertEqual(r1, r2)
    }

    /// The collector must never change a pixel: render frames before any probe,
    /// after one, and with the structural collector live — all byte-identical.
    func testProbingHasZeroPixelEffect() throws {
        let recorder = Recorder(config: .init(fps: 30, size: size, scale: 0.5))
        let scenes: [(String, Double, @MainActor (Double) -> AnyView)] = [
            ("TimelineDemo", 9.9, { AnyView(TimelineDemo.body(at: $0, duration: 9.9)) }),
            ("RepoPromo", 25.2, { AnyView(RepoPromo.body(at: $0, duration: 25.2)) }),
            ("Nested", NestedFixture.duration, NestedFixture.make),
        ]
        for (name, duration, make) in scenes {
            let times = [0.1, duration * 0.31, duration * 0.62, duration - 0.2]
            func frames() throws -> [Data] {
                try times.map { try pixelBytes(recorder.renderImage(at: $0, duration: duration, content: make)) }
            }
            let before = try frames()
            _ = probe(duration, make)
            let after = try frames()
            let live = try ProbeCollector.$current.withValue(ProbeCollector()) { try frames() }
            XCTAssertEqual(before, after, "\(name): frames changed after probing")
            XCTAssertEqual(before, live, "\(name): frames changed while the collector was bound")
        }
    }

    func testProbeCost() {
        let d = RepoPromo.defaultDuration
        let start = Date()
        _ = probe(d) { AnyView(RepoPromo.body(at: $0, duration: d)) }
        let ms = Date().timeIntervalSince(start) * 1000
        print(String(format: "[probe] RepoPromo %.1f ms", ms))
        XCTAssertLessThan(ms, 5000)
    }

    /// Outside a probe, Timeline pays one task-local read per init and per body.
    func testHotPathCostWhenNotProbing() {
        let n = 200_000
        var hits = 0
        var start = Date()
        for _ in 0..<n where ProbeCollector.current != nil { hits += 1 }
        let readNS = Date().timeIntervalSince(start) * 1e9 / Double(n)
        XCTAssertEqual(hits, 0)
        start = Date()
        var sum = 0.0
        for i in 0..<n { sum += Knob.double("bench.knob", Double(i & 1)) }
        let knobNS = Date().timeIntervalSince(start) * 1e9 / Double(n)
        XCTAssertEqual(sum, Double(n / 2))
        print(String(format: "[probe] idle task-local read %.1f ns, Knob.double read %.1f ns", readNS, knobNS))
        XCTAssertLessThan(readNS, 1000)
    }

    // MARK: knobs

    func testKnobsDeclaredWithSourcesAndOverridesApplied() throws {
        let store = KnobStore.shared
        let saved = store.values
        defer { store.set(saved) }

        store.set([:])
        let plain = probe(3) { KnobFixture.make($0) }
        XCTAssertEqual(plain.knobs.map(\.key), ["title.color", "title.delay", "title.text", "title.visible"])
        let delay = try XCTUnwrap(plain.knobs.first { $0.key == "title.delay" })
        XCTAssertEqual(delay.kind, .double)
        XCTAssertEqual(delay.defaultValue, .number(0.4))
        XCTAssertEqual(delay.value, .number(0.4))
        XCTAssertEqual(delay.min, 0)
        XCTAssertEqual(delay.max, 2)
        XCTAssertTrue(delay.source?.file.hasSuffix("IntrospectionTests.swift") == true)
        XCTAssertEqual(plain.clips.map(\.end), [1.0, 2.4])

        store.set(["title.delay": .number(1.1), "title.text": .string("HI"), "title.visible": .bool(false),
                   "title.color": .string("#nope")])
        let tuned = probe(4) { KnobFixture.make($0) }
        let values = Dictionary(uniqueKeysWithValues: tuned.knobs.map { ($0.key, $0.value) })
        XCTAssertEqual(values["title.delay"], .number(1.1))
        XCTAssertEqual(values["title.text"], .string("HI"))
        XCTAssertEqual(values["title.visible"], .bool(false))
        XCTAssertEqual(values["title.color"], .string("#C7FF1A"), "a malformed color override shows the default")
        XCTAssertEqual(tuned.clips.map(\.end), [1.0, 3.1], "structure follows knob overrides")
        XCTAssertEqual(Knob.double("title.delay", 0.4), 1.1)
        XCTAssertEqual(Knob.double("unset.key", 0.1 + 0.2), 0.1 + 0.2, "no override returns the literal bit-for-bit")
        XCTAssertEqual(Knob.bool("title.delay", true), true, "a mistyped override is ignored")
    }

    func testKnobRecordingNestsAndIsOffByDefault() {
        let store = KnobStore.shared
        XCTAssertEqual(store.endRecording(), [], "unbalanced end is harmless")
        _ = Knob.double("outside", 1)
        store.beginRecording()
        _ = Knob.double("outer", 1)
        store.beginRecording()
        _ = Knob.text("inner", "x")
        XCTAssertEqual(store.endRecording().map(\.key), ["inner"])
        XCTAssertEqual(store.endRecording().map(\.key), ["inner", "outer"])
    }

    /// Hand-edited and agent-written knob files hold `2026` for a text knob, `"0.8"` for
    /// a number, `1` for a bool. Those apply; anything else keeps the literal, and the
    /// declared value always shows what the scene actually used.
    func testMistypedKnobOverridesAreCoercedOrVisiblyIgnored() throws {
        let store = KnobStore.shared
        let saved = store.values
        defer { store.set(saved) }
        store.set(["headline": .number(2026), "title.delay": .string(" 0.8 "), "debug.safe": .number(1),
                   "title.scale": .number(1.5), "flag.off": .string("False"), "frac": .number(0.25),
                   "word": .bool(true), "bad.number": .string("abc"), "bad.bool": .number(2),
                   "inf.number": .string("inf")])
        XCTAssertEqual(Knob.text("headline", "x"), "2026", "a whole number reads as written, not 2026.0")
        XCTAssertEqual(Knob.text("frac", "x"), "0.25")
        XCTAssertEqual(Knob.text("word", "x"), "true")
        XCTAssertEqual(Knob.double("title.delay", 0.3), 0.8)
        XCTAssertEqual(Knob.bool("debug.safe", false), true)
        XCTAssertEqual(Knob.bool("flag.off", true), false)
        XCTAssertEqual(Knob.double("bad.number", 0.3), 0.3)
        XCTAssertEqual(Knob.double("inf.number", 0.3), 0.3, "non-finite strings are not numbers")
        XCTAssertEqual(Knob.bool("bad.bool", true), true)

        // End to end: the KnobLab repro from the review, through the probe.
        let d = KnobLab.defaultDuration
        let s = probe(d) { AnyView(KnobLab.body(at: $0, duration: d, props: KnobLab.defaultProps)) }
        let values = Dictionary(uniqueKeysWithValues: s.knobs.map { ($0.key, $0.value) })
        XCTAssertEqual(values["headline"], .string("2026"))
        XCTAssertEqual(values["title.delay"], .number(0.8))
        XCTAssertEqual(values["debug.safe"], .bool(true))
        XCTAssertEqual(values["title.scale"], .number(1.5))
        XCTAssertNotNil(values["debug.opacity"], "debug.safe = 1 switched the overlay on")

        store.set(["title.delay": .string("soon")])
        let ignored = probe(d) { AnyView(KnobLab.body(at: $0, duration: d, props: KnobLab.defaultProps)) }
        XCTAssertEqual(ignored.knobs.first { $0.key == "title.delay" }?.value, .number(0.3),
                       "an unusable override shows the default actually in use")
    }

    // MARK: probe reach and retiming

    /// The structural tier must only ask a clip for frames the render can reach:
    /// local times in 0 ..< duration, while the clip is inside its parent and the scene.
    func testProbeOnlyEvaluatesClipsWhereTheSceneCanShowThem() throws {
        CallLog.calls = [:]
        let d = OutOfReachFixture.duration
        let s = probe(d, OutOfReachFixture.make)
        let calls = CallLog.calls
        XCTAssertFalse(calls["hud", default: []].isEmpty)
        XCTAssertTrue(calls["hud", default: []].allSatisfy { $0.isFinite && $0 >= 0 && $0 < d }, "\(calls["hud"]!)")
        XCTAssertTrue(calls["captions", default: []].allSatisfy { $0 >= 0 && $0 < d }, "\(calls["captions"]!)")
        XCTAssertTrue(calls["early", default: []].allSatisfy { $0 >= 2 && $0 < 3 }, "\(calls["early"] ?? [])")
        XCTAssertNil(calls["late"], "a clip that starts after the scene is never evaluated")
        XCTAssertNil(calls["nan"], "a NaN-length clip is never drawn, so never evaluated")

        let byName = Dictionary(uniqueKeysWithValues: s.clips.map { ($0.label ?? "", $0) })
        XCTAssertEqual(Set(byName.keys), ["hud", "captions", "early"])
        XCTAssertEqual(byName["hud"].map { [$0.start, $0.end] }, [0, d])
        XCTAssertEqual(byName["captions"].map { [$0.start, $0.end] }, [0, d])
        XCTAssertEqual(byName["early"].map { [$0.start, $0.end] }, [0, 1])

        // And the real render agrees: every frame of the scene draws.
        let recorder = Recorder(config: .init(fps: 10, size: CGSize(width: 160, height: 90), postFX: false))
        for i in 0..<40 { _ = try recorder.renderImage(at: Double(i) / 10, duration: d, content: OutOfReachFixture.make) }
    }

    /// NaN used to hang the grid and infinity trapped; an empty scene shows no clips.
    func testProbeOfNonFiniteOrEmptyDurationShowsNoClips() {
        for d in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(probe(d, NestedFixture.make), SceneStructure(), "duration \(d)")
        }
        for d in [0.0, -1] {
            XCTAssertEqual(probe(d, NestedFixture.make).clips, [], "duration \(d)")
            XCTAssertEqual(probe(d) { KnobFixture.make($0) }.knobs.count, 4, "knobs are still declared")
        }
    }

    /// Clip times come from each Timeline's fitted clock, not from "local = t - offset
    /// at first sighting": a scaled, clamped or nested-clamped clock reports where its
    /// clips are actually on screen.
    func testRetimedTimelinesReportWhereClipsAreOnScreen() throws {
        func spans(_ s: SceneStructure) -> [String: [Double]] {
            Dictionary(uniqueKeysWithValues: s.clips.map { ($0.label ?? "?", [$0.start, $0.end]) })
        }
        XCTAssertEqual(spans(probe(3, RetimedFixture.twice)), ["headline": [0, 1.6], "stats": [1.4, 2.9]])
        // The first clip is on screen (holding frame 0) from 0, then plays until 3.
        XCTAssertEqual(spans(probe(6, RetimedFixture.clamped)), ["a": [0, 3], "b": [3, 5]])
        XCTAssertEqual(spans(probe(4, RetimedFixture.kink)), ["k1": [0, 2.2], "k2": [2.2, 3.2]])
        let nested = probe(6, RetimedFixture.nested)
        XCTAssertEqual(spans(nested), ["outer1": [0, 2], "outer2": [2, 6], "inner1": [2, 3.5], "inner2": [3.5, 4.5]])
        XCTAssertEqual(nested.clips.filter { $0.depth == 1 }.map(\.label), ["inner1", "inner2"])
        XCTAssertEqual(spans(probe(3, RetimedFixture.twoCards)), ["card.a": [0, 1], "card.b": [1, 2]],
                       "two instances of one call site resolve the same way every run")

        // Pixels agree: during the clamp's hold, clip "a" (red) is what's drawn; at 3.5, "b" (blue).
        let recorder = Recorder(config: .init(fps: 30, size: CGSize(width: 32, height: 32), postFX: false))
        func rgb(_ t: Double) throws -> [UInt8] {
            let img = try recorder.renderImage(at: t, duration: 6, content: RetimedFixture.clamped)
            var px = [UInt8](repeating: 0, count: 4)
            let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.draw(img, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return Array(px[0..<3])
        }
        XCTAssertGreaterThan(try rgb(0.5)[0], 200)
        XCTAssertGreaterThan(try rgb(3.5)[2], 200)
    }

    /// KnobLab drives its root Timeline with `t * speed`; at any speed, `info` must
    /// put Headline and Stats where they play (the review's repro).
    func testKnobLabSpeedPropMovesClips() throws {
        for (speed, headline, stats) in [(1.0, [0, 3.2], [2.8, 5.8]), (2.0, [0, 1.6], [1.4, 2.9]),
                                         (0.5, [0, 6.4], [5.6, 11.6])] {
            var props = KnobLab.defaultProps
            props.speed = speed
            let d = KnobLab.duration(for: props)
            let s = probe(d) { AnyView(KnobLab.body(at: $0, duration: d, props: props)) }
            let byName = Dictionary(uniqueKeysWithValues: s.clips.map { ($0.label ?? "?", [$0.start, $0.end]) })
            XCTAssertEqual(byName["Headline"], headline, "speed \(speed)")
            XCTAssertEqual(byName["Stats"], stats, "speed \(speed)")
        }
    }

    func testTimelineBuiltOnlyForItsDurationIsNotReported() {
        let s = probe(8, DurationOnlyFixture.make)
        XCTAssertEqual(s.clips.map(\.label), ["main", "outro", "outro.a", "outro.b"])
        XCTAssertEqual(s.clips.map(\.start), [0, 5, 5, 6.5])
        XCTAssertEqual(s.clips.map(\.depth), [0, 0, 1, 1])
    }

    /// `maxDepth` bounds depth; the evaluation budget bounds breadth.
    func testStructuralTierHasABreadthBudget() {
        BranchingFixture.evaluations = 0
        let start = Date()
        let s = probe(6) { BranchingFixture.make($0) }
        let seconds = Date().timeIntervalSince(start)
        XCTAssertLessThanOrEqual(BranchingFixture.evaluations, SceneProbe.maxEvaluations + 64 * 8 * 4,
                                 "structural walks plus what the capped render tier draws")
        XCTAssertEqual(s.clips.filter { $0.depth == 0 }.count, 6)
        XCTAssertEqual(s.clips.filter { $0.depth == 1 }.count, 36, "shallow levels are complete")
        XCTAssertLessThan(seconds, 20)
    }

    func testColorParsing() {
        func rgba(_ hex: String) -> [Double]? {
            guard let c = Color(rgbHex: hex), let cg = NSColor(c).usingColorSpace(.sRGB) else { return nil }
            return [cg.redComponent, cg.greenComponent, cg.blueComponent, cg.alphaComponent].map { ($0 * 255).rounded() }
        }
        XCTAssertEqual(rgba("#C7FF1A"), [199, 255, 26, 255])
        XCTAssertEqual(rgba("c7ff1a80"), [199, 255, 26, 128])
        XCTAssertEqual(rgba(" #000000 "), [0, 0, 0, 255])
        for bad in ["", "#", "#12345", "#GGGGGG", "+12345", "#C7FF1A8", "#-1234567"] {
            XCTAssertNil(Color(rgbHex: bad), bad)
        }
    }

    // MARK: transitions and score lanes

    func testTransitionNames() {
        XCTAssertEqual([Transition.cut, .fade(), .slide(), .flash(), .overlap(0.2)].map(\.name),
                       ["cut", "fade", "slide", "flash", "overlap"])
        let wipe = Transition("wipe", duration: 0.3) { v, _, _ in v }
        XCTAssertEqual(wipe.name, "wipe")
        XCTAssertEqual(wipe.duration, 0.3)
    }

    func testScoreEventLanesKindsAndDetails() {
        let line = "introspection never synthesizes \(UUID().uuidString)"
        let score = Score(duration: 30) {
            kick(at: 0); clap(at: 0.1); hat(at: 0.2); crash(at: 0.3); boom(at: 0.4, duration: 1.2)
            tick(at: 1); rim(at: 1.1); thump(at: 1.2); blip(.a4, at: 1.3); swell(.c4, at: 1.4)
            bass(.a1, at: 2); drone(.e1, from: 2.1, for: 3); pluck(.e5, at: 2.2); bell(Note(440), at: 2.3)
            pad(.a3, at: 2.4); chip(.midi(61), at: 2.5); triBass(.g1, at: 2.6)
            sample("does/not/exist.wav", at: 3, duration: 0.5)
            speak(line, at: 4)
            whoosh(at: 5, rising: false); riser(at: 5.1); laser(at: 5.2); crackle(from: 5.3, to: 6.3)
        }
        let info = score.eventInfos
        XCTAssertEqual(info.count, score.events.count)
        let lanes = Dictionary(grouping: info, by: \.lane).mapValues { $0.map(\.kind) }
        XCTAssertEqual(lanes["drums"], ["kick", "clap", "hat", "crash", "boom"])
        XCTAssertEqual(lanes["mark"], ["tick", "rim", "thump", "blip", "swell"])
        XCTAssertEqual(lanes["melodic"], ["bass", "drone", "pluck", "bell", "pad", "chip", "triBass"])
        XCTAssertEqual(lanes["sample"], ["sample"])
        XCTAssertEqual(lanes["speech"], ["speak"])
        XCTAssertEqual(lanes["fx"], ["whoosh", "riser", "laser", "crackle"])

        let byKind = Dictionary(uniqueKeysWithValues: info.map { ($0.kind, $0) })
        XCTAssertEqual(byKind["blip"]?.detail, "A4")
        XCTAssertEqual(byKind["swell"]?.detail, "C4")
        XCTAssertEqual(byKind["bass"]?.detail, "A1")
        XCTAssertEqual(byKind["drone"]?.detail, "E1")
        XCTAssertEqual(byKind["bell"]?.detail, "A4")
        XCTAssertEqual(byKind["chip"]?.detail, "C#4")
        XCTAssertEqual(byKind["triBass"]?.detail, "G1")
        XCTAssertEqual(byKind["sample"]?.detail, "does/not/exist.wav")
        XCTAssertEqual(byKind["speak"]?.detail, line)
        XCTAssertEqual(byKind["whoosh"]?.detail, "falling")
        XCTAssertNil(byKind["kick"]?.detail)

        XCTAssertEqual(byKind["kick"]?.duration, 0.4)
        XCTAssertEqual(byKind["boom"]?.duration, 1.2)
        XCTAssertEqual(byKind["drone"]?.duration, 3)
        XCTAssertEqual(byKind["crackle"]?.duration ?? 0, 1.0, accuracy: 1e-9)
        XCTAssertEqual(byKind["sample"]?.duration, 0, "a missing file plays nothing")
        XCTAssertEqual(byKind["speak"]?.duration ?? 0, Double(line.count) / 15, accuracy: 1e-9,
                       "uncached speech is estimated, never synthesized")
        XCTAssertFalse(FileManager.default.fileExists(atPath: Speech.cachedURL(SpeechSpec(line)).path))
        XCTAssertEqual(byKind["hat"]?.amp, 0.09)
    }
}

/// Raw pixel bytes plus layout, for byte-exact comparisons.
private func pixelBytes(_ image: CGImage) -> Data {
    var d = Data("\(image.width)x\(image.height)/\(image.bytesPerRow)/\(image.bitmapInfo.rawValue)".utf8)
    d.append(image.dataProvider?.data as Data? ?? Data())
    return d
}
