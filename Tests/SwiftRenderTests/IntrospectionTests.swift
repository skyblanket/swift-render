import SwiftUI
import XCTest
@testable import SwiftRender
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
func pixelBytes(_ image: CGImage) -> Data {
    var d = Data("\(image.width)x\(image.height)/\(image.bytesPerRow)/\(image.bitmapInfo.rawValue)".utf8)
    d.append(image.dataProvider?.data as Data? ?? Data())
    return d
}
