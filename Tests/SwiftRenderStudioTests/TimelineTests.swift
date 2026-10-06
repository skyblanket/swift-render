import CoreGraphics
import XCTest
import SwiftRenderKit
@testable import SwiftRenderStudio

/// Timeline viewport math, layout zones and per-lane hit-testing (no views).
final class TimelineViewportTests: XCTestCase {
    func testZoomLevelRoundTripsAndClamps() {
        var v = TimelineViewport(start: 0, pxPerSecond: 50, width: 1000, duration: 100, fps: 60)
        v.fit(100)
        XCTAssertEqual(v.zoomLevel, 0, accuracy: 1e-9)
        v.setZoomLevel(1, around: 0)
        XCTAssertEqual(v.pxPerSecond, v.maxPxPerSecond, accuracy: 1e-6)
        XCTAssertEqual(v.zoomLevel, 1, accuracy: 1e-9)
        v.setZoomLevel(0.5, around: 500)
        XCTAssertEqual(v.zoomLevel, 0.5, accuracy: 1e-9)
        // Geometric midpoint between fit (10 pt/s) and frame level (1200 pt/s).
        XCTAssertEqual(v.pxPerSecond, (10.0 * 1200).squareRoot(), accuracy: 1e-6)
        v.setZoomLevel(7, around: 0)
        XCTAssertEqual(v.zoomLevel, 1, accuracy: 1e-9)
    }

    func testRevealScrollsMinimally() {
        var v = TimelineViewport(start: 10, pxPerSecond: 100, width: 500, duration: 60, fps: 30)   // 10…15 s
        XCTAssertFalse(v.reveal(11...12, margin: 0))
        XCTAssertTrue(v.reveal(16...17, margin: 0))
        XCTAssertEqual(v.end, 17, accuracy: 1e-9, "right edge lands on the range end")
        XCTAssertTrue(v.reveal(3...4, margin: 0))
        XCTAssertEqual(v.start, 3, accuracy: 1e-9)
        XCTAssertTrue(v.reveal(20...40, margin: 0))
        XCTAssertEqual(v.start, 20, accuracy: 1e-9, "wider than the view: show its start")
        XCTAssertTrue(v.reveal(59.9...60, margin: 0))
        XCTAssertEqual(v.end, 60, accuracy: 1e-9, "clamped to the scene")
    }

    func testSnapToFrames() {
        let v = TimelineViewport(start: 0, pxPerSecond: 100, width: 500, duration: 10, fps: 30)
        XCTAssertEqual(v.snap(1.01), 1.0, accuracy: 1e-12)
        XCTAssertEqual(v.snap(1.02), 31.0 / 30, accuracy: 1e-12)
        XCTAssertEqual(v.snap(-3), 0)
        XCTAssertEqual(v.snap(99), 10)
    }

    func testFrameLevelTicksAreWholeFramesAndLabelledInFrames() {
        let v = TimelineViewport(start: 0, pxPerSecond: 1200, width: 1000, duration: 30, fps: 60)
        let (major, minor) = v.tickSpacing()
        XCTAssertEqual(major * 60, (major * 60).rounded(), accuracy: 1e-9, "major is a whole number of frames")
        XCTAssertEqual(minor, 1.0 / 60, accuracy: 1e-12)
        XCTAssertEqual(TimelineViewport.label(12 + 24.0 / 60, major: major, fps: 60), "00:12:24")
        XCTAssertEqual(TimelineViewport.label(72.4, major: 5, fps: 60), "01:12")
        XCTAssertEqual(TimelineViewport.spanLabel(93, fps: 60), "1:33")
        XCTAssertEqual(TimelineViewport.spanLabel(6.8, fps: 60), "6.8s")
        XCTAssertEqual(TimelineViewport.spanLabel(0.5, fps: 60), "30f")
        // Ticks stay ascending/readable at every zoom for 24/25/30/60 fps.
        for fps in [24, 25, 30, 60] {
            for pps in stride(from: 5.0, through: 20.0 * Double(fps), by: 7) {
                let w = TimelineViewport(start: 0, pxPerSecond: pps, width: 1000, duration: 600, fps: fps)
                let (ma, mi) = w.tickSpacing()
                XCTAssertGreaterThanOrEqual(ma * pps, 90 - 1e-9, "fps \(fps) pps \(pps)")
                XCTAssertLessThanOrEqual(mi, ma)
            }
        }
    }
}

final class TimelineLayoutTests: XCTestCase {
    private func info() -> SceneInfo {
        SceneInfo(name: "S", kind: .render, duration: 20, width: 1920, height: 1080, fps: 30,
                  clips: [
                    ClipInfo(id: "0:0.000:10", label: nil, start: 0, end: 5, depth: 0, pinned: false,
                             transitionIn: "cut", transitionDuration: 0, source: SourceLocation(file: "/x/A.swift", line: 10)),
                    ClipInfo(id: "0:5.000:11", label: "Hero", start: 5, end: 10, depth: 0, pinned: false,
                             transitionIn: "fade", transitionDuration: 0.5, source: nil),
                    ClipInfo(id: "1:6.000:30", label: nil, start: 6, end: 8, depth: 1, pinned: false,
                             transitionIn: "cut", transitionDuration: 0, source: nil, parentID: "0:5.000:11"),
                    ClipInfo(id: "0:0.000:40", label: "HUD", start: 0, end: 20, depth: 0, pinned: true,
                             transitionIn: "cut", transitionDuration: 0, source: nil),
                  ],
                  events: [ScoreEventInfo(lane: "drums", kind: "kick", detail: nil, time: 1, duration: 0.4, amp: 1),
                           ScoreEventInfo(lane: "speech", kind: "speak", detail: "Hello", time: 2, duration: 1, amp: 1)],
                  captions: [CaptionInfo(start: 2, end: 3, text: "Hello")])
    }

    func testSlotsStackInDisplayOrder() {
        let l = TimelineLayout(info: info())
        XCTAssertEqual(l.slots.map(\.key), [.clips, .captions, .score("VOICE"), .score("DRUMS · MARKS"), .audio, .notes])
        var y: CGFloat = 0
        for s in l.slots { XCTAssertEqual(s.y, y); y += s.height }
        XCTAssertEqual(l.contentHeight, y)
        // Three clip rows: main, nest 1, pinned.
        XCTAssertEqual(l.slot(.clips)?.height, 3 * ClipsLane.rowHeight + 2 * ClipsLane.inset)
        XCTAssertEqual(ClipsLane(clips: info().clips).rowLabels, ["main", "nest 1", "pinned"])
    }

    func testZonesAccountForRulerAndVerticalScroll() {
        let l = TimelineLayout(slots: [(.clips, "CLIPS", 40), (.audio, "AUDIO", 40), (.notes, "NOTES", 20)])
        let r = TimelineLayout.rulerHeight
        XCTAssertEqual(l.zone(at: CGPoint(x: 5, y: 3), lanesHeight: 60, scrollY: 0), .ruler(CGPoint(x: 5, y: 3)))
        XCTAssertEqual(l.zone(at: CGPoint(x: 5, y: r + 10), lanesHeight: 60, scrollY: 0), .lane(.clips, CGPoint(x: 5, y: 10)))
        XCTAssertEqual(l.zone(at: CGPoint(x: 5, y: r + 10), lanesHeight: 60, scrollY: 45), .lane(.audio, CGPoint(x: 5, y: 15)))
        XCTAssertEqual(l.zone(at: CGPoint(x: 5, y: r + 59), lanesHeight: 60, scrollY: 40), .lane(.notes, CGPoint(x: 5, y: 19)))
        XCTAssertEqual(l.zone(at: CGPoint(x: 5, y: r + 60), lanesHeight: 60, scrollY: 0), .scroller)
        XCTAssertEqual(l.zone(at: CGPoint(x: 5, y: r + 90), lanesHeight: 200, scrollY: 0), .lane(.notes, CGPoint(x: 5, y: 10)))
        XCTAssertEqual(l.zone(at: CGPoint(x: 5, y: r + 150), lanesHeight: 200, scrollY: 0), .empty)
        XCTAssertEqual(l.maxScroll(lanesHeight: 60), 40)
        XCTAssertEqual(l.maxScroll(lanesHeight: 400), 0)
        XCTAssertEqual(l.columnY(.audio, scrollY: 10), r + 30)
    }

    func testClipsHitByRowWithPinnedRowAndOverlap() {
        let lane = ClipsLane(clips: info().clips, names: ["0:0.000:10": "titleCard"])
        let v = TimelineViewport(start: 0, pxPerSecond: 50, width: 1000, duration: 20, fps: 30)
        let row0 = ClipsLane.inset + 5, row1 = row0 + ClipsLane.rowHeight, row2 = row1 + ClipsLane.rowHeight
        XCTAssertEqual(lane.hit(CGPoint(x: v.x(2), y: row0), viewport: v)?.id, "0:0.000:10")
        XCTAssertEqual(lane.hit(CGPoint(x: v.x(2), y: row0), viewport: v)?.title, "titleCard")
        XCTAssertEqual(lane.hit(CGPoint(x: v.x(7), y: row0), viewport: v)?.title, "Hero")
        XCTAssertEqual(lane.hit(CGPoint(x: v.x(7), y: row1), viewport: v)?.id, "1:6.000:30")
        XCTAssertNil(lane.hit(CGPoint(x: v.x(2), y: row1), viewport: v), "nest row is empty at 2 s")
        XCTAssertEqual(lane.hit(CGPoint(x: v.x(15), y: row2), viewport: v)?.title, "HUD")
        XCTAssertNil(lane.hit(CGPoint(x: v.x(15), y: row0), viewport: v))
        // At the 5 s boundary the later clip (drawn on top) wins.
        XCTAssertEqual(lane.hit(CGPoint(x: v.x(5), y: row0), viewport: v)?.id, "0:5.000:11")
        XCTAssertTrue(lane.hit(CGPoint(x: v.x(7), y: row0), viewport: v)?.detail?.contains("fade in 0.50 s") ?? false)
    }

    func testRulerFlagsHitBeforeScrub() {
        let v = TimelineViewport(start: 0, pxPerSecond: 100, width: 1000, duration: 10, fps: 30)
        let r = RulerLane(cached: [], inOut: 2...4, duration: 10)
        XCTAssertEqual(r.hit(CGPoint(x: 202, y: 18), viewport: v)?.id, "in")
        XCTAssertEqual(r.hit(CGPoint(x: 397, y: 18), viewport: v)?.id, "out")
        XCTAssertNil(r.hit(CGPoint(x: 300, y: 18), viewport: v))
        XCTAssertNil(r.hit(CGPoint(x: 202, y: 4), viewport: v), "label row scrubs")
        XCTAssertNil(RulerLane(cached: [], inOut: nil, duration: 10).hit(CGPoint(x: 200, y: 18), viewport: v))
    }
}

final class ScoreLaneTests: XCTestCase {
    func testPackingNeverOverlapsWithinARow() {
        let iv: [(Double, Double)] = [(0, 4), (1, 2), (1.5, 3), (2, 5), (3, 6), (4, 4.5), (10, 11)]
        let (rows, count) = ScoreLane.pack(iv, maxRows: 4)
        XCTAssertEqual(rows.count, iv.count)
        XCTAssertEqual(count, 3)
        for r in 0..<count {
            let mine = zip(iv, rows).filter { $0.1 == r }.map(\.0)
            for (a, b) in zip(mine, mine.dropFirst()) { XCTAssertLessThanOrEqual(a.1, b.0 + 1e-9, "row \(r) overlaps") }
        }
        // Over the cap: shares a row instead of growing.
        XCTAssertEqual(ScoreLane.pack([(0, 5), (0, 5), (0, 5)], maxRows: 2).count, 2)
    }

    func testChordsMergeIntoOneBlock() {
        let pad = { (n: String) in ScoreEventInfo(lane: "melodic", kind: "pad", detail: n, time: 4, duration: 2, amp: 0.5) }
        let lane = ScoreLane(title: "MUSIC", lanes: ["melodic"], style: .blocks(maxRows: 4),
                             events: [pad("C4"), pad("E4"), pad("G4"),
                                      ScoreEventInfo(lane: "melodic", kind: "bell", detail: "E5", time: 4, duration: 1.6, amp: 1)])
        XCTAssertEqual(lane.events.count, 2)
        XCTAssertEqual(lane.events.first { $0.kind == "pad" }?.detail, "C4 E4 G4")
        XCTAssertEqual(lane.rows, 2)
    }

    func testHouseRuleAndLabels() {
        let events = [ScoreEventInfo(lane: "fx", kind: "whoosh", detail: "rising", time: 1, duration: 0.7, amp: 1),
                      ScoreEventInfo(lane: "fx", kind: "laser", detail: nil, time: 3, duration: 0.2, amp: 1),
                      ScoreEventInfo(lane: "sample", kind: "sample", detail: "assets/sfx/key_3.wav", time: 2, duration: 1, amp: 1)]
        let fx = ScoreLanes.renderer(title: "FX", events: events)
        XCTAssertEqual(fx.warnings, 1)
        XCTAssertEqual(fx.label(fx.events[0]), "⚠ whoosh rising")
        let v = TimelineViewport(start: 0, pxPerSecond: 100, width: 1000, duration: 10, fps: 30)
        let h = fx.hit(CGPoint(x: v.x(1.3), y: 10), viewport: v)
        XCTAssertTrue(h?.detail?.contains("House rule") ?? false)
        let samples = ScoreLanes.renderer(title: "SAMPLES", events: events)
        XCTAssertEqual(samples.label(samples.events[0]), "key_3")
    }

    func testDrumHitsByProximity() {
        let lane = ScoreLanes.renderer(title: "DRUMS · MARKS", events: [
            ScoreEventInfo(lane: "drums", kind: "kick", detail: nil, time: 1, duration: 0.4, amp: 1),
            ScoreEventInfo(lane: "mark", kind: "tick", detail: nil, time: 1.2, duration: 0.07, amp: 1),
        ])
        let v = TimelineViewport(start: 0, pxPerSecond: 100, width: 1000, duration: 10, fps: 30)
        XCTAssertEqual(lane.hit(CGPoint(x: 102, y: 20), viewport: v)?.title, "kick")
        XCTAssertEqual(lane.hit(CGPoint(x: 119, y: 5), viewport: v)?.title, "tick")
        XCTAssertNil(lane.hit(CGPoint(x: 160, y: 5), viewport: v))
    }
}

final class ClipLabelTests: XCTestCase {
    func testAutoLabelFromSourceLine() {
        XCTAssertEqual(ClipLabels.autoLabel(line: "    Clip(2.4) { l in typedSignature(l) }"), "typedSignature")
        XCTAssertEqual(ClipLabels.autoLabel(line: "Clip(3.8) { l in lockup(l) }.transition(.flash())"), "lockup")
        XCTAssertEqual(ClipLabels.autoLabel(line: "Clip(at: 0, for: duration) { local in progressHUD(local, total: duration) }"), "progressHUD")
        XCTAssertEqual(ClipLabels.autoLabel(line: "Clip(2) { TitleCard() }"), "TitleCard")
        XCTAssertNil(ClipLabels.autoLabel(line: "Clip(2) {"))
        XCTAssertNil(ClipLabels.autoLabel(line: "let x = in foo(1)"))
    }

    @MainActor
    func testLabelPrecedenceReadsTheSourceFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sr-cliplabels-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Film.swift")
        try "Timeline(t) {\n    Clip(2) { l in hook(l) }\n    Clip(2) {\n".write(to: file, atomically: true, encoding: .utf8)
        func clip(_ id: String, _ label: String?, line: Int) -> ClipInfo {
            ClipInfo(id: id, label: label, start: 0, end: 1, depth: 0, pinned: false, transitionIn: "cut",
                     transitionDuration: 0, source: SourceLocation(file: file.path, line: line))
        }
        let clips = [clip("a", nil, line: 2), clip("b", "Named", line: 2), clip("c", nil, line: 3)]
        let names = ClipLabels().labels(for: clips, generation: 1)
        XCTAssertEqual(names["a"], "hook")
        XCTAssertEqual(names["b"], "Named")
        XCTAssertEqual(names["c"], "Clip · Film.swift:3")
    }
}

final class CommentsLaneTests: XCTestCase {
    private func comment(_ t: Double, _ end: Double?, id: String) -> ReviewComment {
        ReviewComment(id: id, t: t, end: end, body: "note \(id)", author: ReviewAuthor(name: "Sky"))
    }

    func testHitPartsForPointsAndRanges() {
        let lane = CommentsLane(comments: [comment(2, nil, id: "p"), comment(5, 8, id: "r")])
        let v = TimelineViewport(start: 0, pxPerSecond: 100, width: 1000, duration: 10, fps: 30)
        let mid = lane.height / 2
        XCTAssertEqual(lane.hit(CGPoint(x: 203, y: mid), viewport: v)?.part, .body)
        XCTAssertEqual(lane.hit(CGPoint(x: 203, y: mid), viewport: v)?.id, "p")
        XCTAssertEqual(lane.hit(CGPoint(x: 501, y: mid), viewport: v)?.part, .startHandle)
        XCTAssertEqual(lane.hit(CGPoint(x: 650, y: mid), viewport: v)?.part, .body)
        XCTAssertEqual(lane.hit(CGPoint(x: 797, y: mid), viewport: v)?.part, .endHandle)
        XCTAssertNil(lane.hit(CGPoint(x: 350, y: mid), viewport: v))
        XCTAssertTrue(lane.hit(CGPoint(x: 650, y: mid), viewport: v)?.title.hasPrefix("#2") ?? false)
    }

    func testRetimeMathSnapsAndClamps() {
        // Move a point: snapped to 1/30 s, inside the scene.
        let p = RetimeMath.apply(.body, t: 2, end: nil, delta: 0.51, duration: 10, fps: 30)
        XCTAssertEqual(p.t, 2.5, accuracy: 1e-9)
        XCTAssertNil(p.end)
        XCTAssertEqual(RetimeMath.apply(.body, t: 2, end: nil, delta: -5, duration: 10, fps: 30).t, 0)
        // Move a range: keeps its length, stops at the scene end.
        let r = RetimeMath.apply(.body, t: 5, end: 8, delta: 4, duration: 10, fps: 30)
        XCTAssertEqual(r.t, 7, accuracy: 1e-9)
        XCTAssertEqual(r.end!, 10, accuracy: 1e-9)
        // Ends can't cross: at least one frame long.
        let s = RetimeMath.apply(.startHandle, t: 5, end: 8, delta: 10, duration: 10, fps: 30)
        XCTAssertEqual(s.t, 8 - 1.0 / 30, accuracy: 1e-9)
        XCTAssertEqual(s.end, 8)
        let e = RetimeMath.apply(.endHandle, t: 5, end: 8, delta: -10, duration: 10, fps: 30)
        XCTAssertEqual(e.t, 5)
        XCTAssertEqual(e.end!, 5 + 1.0 / 30, accuracy: 1e-9)
    }
}

final class AudioOverviewTests: XCTestCase {
    func testSilencesMatchCheckThresholds() {
        let rate = 1000.0
        // 0–1 s loud, 1–2.2 s silent, 2.2–3 s loud, 3–3.4 s silent (too short), 3.4–4 s loud.
        var ms = [Float](repeating: 0.25, count: 4000)
        for i in 1000..<2200 { ms[i] = 0 }
        for i in 3000..<3400 { ms[i] = 0 }
        let s = AudioOverview.silences(meanSquare: ms, sampleRate: rate)
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].lowerBound, 1.0, accuracy: 1e-9)
        XCTAssertEqual(s[0].upperBound, 2.0, accuracy: 1e-9)       // window-quantized, like `check`
        // A silent start isn't reported (scenes often open quietly).
        var lead = [Float](repeating: 0, count: 2000)
        lead += [Float](repeating: 0.25, count: 1000)
        XCTAssertTrue(AudioOverview.silences(meanSquare: lead, sampleRate: rate).isEmpty)
    }

    func testScrollRouting() {
        typealias R = ScrollRouting
        XCTAssertEqual(R.route(dx: 0, dy: 5, precise: true, option: true, command: false, shift: false, canScrollVertically: true),
                       .zoom(pow(1.01, 5)))
        XCTAssertEqual(R.route(dx: 8, dy: 1, precise: true, option: false, command: false, shift: false, canScrollVertically: true),
                       .pan(-8))
        XCTAssertEqual(R.route(dx: 0, dy: 4, precise: true, option: false, command: false, shift: false, canScrollVertically: true),
                       .vertical(-4))
        XCTAssertEqual(R.route(dx: 0, dy: 4, precise: true, option: false, command: false, shift: false, canScrollVertically: false),
                       .pan(-4), "no overflow: the wheel travels in time")
        XCTAssertEqual(R.route(dx: 0, dy: 1, precise: false, option: false, command: false, shift: true, canScrollVertically: true),
                       .pan(-10), "⇧-wheel pans, line deltas scaled")
        XCTAssertNil(R.route(dx: 0, dy: 0, precise: true, option: false, command: false, shift: false, canScrollVertically: true))
    }
}

/// The real input path (TimelineInput → ReviewController → ReviewStore) on a temp project.
@MainActor
final class TimelineInputTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("sr-timeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    private func makeModel() -> (ProjectModel, TimelineState, TimelineInput) {
        var o = LaunchOptions()
        o.fakeHost = true
        let model = ProjectModel(root: dir, options: o)
        model.playback.setDuration(20, fps: 30)
        model.ui.viewport = TimelineViewport(start: 0, pxPerSecond: 50, width: 1000, duration: 20, fps: 30)
        model.review.load(scene: "Demo")
        let state = TimelineState()
        let layout = TimelineLayout(info: nil)
        state.lanesHeight = 400
        return (model, state, TimelineInput(model: model, state: state, layout: layout, lanesHeight: 400))
    }

    private func notesY(_ input: TimelineInput) -> CGFloat {
        TimelineLayout.rulerHeight + input.layout.slot(.notes)!.y + CommentsLane(comments: []).height / 2
    }

    func testDraggingAMarkerRetimesThroughTheStore() async throws {
        let (model, state, input) = makeModel()
        let c = try await model.review.add(t: 4, end: nil, region: nil, body: "late hit")
        let y = notesY(input)
        let start = CGPoint(x: 200, y: y)                   // 4 s at 50 pt/s
        input.changed(start: start, location: start)
        input.changed(start: start, location: CGPoint(x: 260, y: y))
        XCTAssertEqual(state.retime?.t ?? -1, 5.2, accuracy: 1e-9, "preview follows the drag")
        XCTAssertEqual(model.review.comments.first?.t, 4, "nothing written until release")
        input.ended(start: start, location: CGPoint(x: 260, y: y))
        XCTAssertNil(state.retime)
        let stored = try ReviewStore(project: Project.open(dir)).load(scene: "Demo").comments.first { $0.id == c.id }
        XCTAssertEqual(stored?.t ?? -1, 5.2, accuracy: 1e-9)
        XCTAssertNil(stored?.end)
        XCTAssertEqual(model.review.selection, c.id)
    }

    func testClickingAMarkerSelectsAndSeeks() async throws {
        let (model, state, input) = makeModel()
        let c = try await model.review.add(t: 6, end: 9, region: nil, body: "range")
        model.review.selection = nil
        let p = CGPoint(x: 400, y: notesY(input))           // range body at 8 s
        input.changed(start: p, location: p)
        input.ended(start: p, location: p)
        XCTAssertEqual(model.review.selection, c.id)
        XCTAssertEqual(model.ui.inspectorTab, .comments)
        XCTAssertEqual(model.playback.t, 6, accuracy: 1e-9)
        XCTAssertNil(state.drag)
        XCTAssertEqual(model.review.comments.first?.t, 6, "a click doesn't retime")
    }

    func testRulerDragScrubsAndFlagsMoveInOut() {
        let (model, _, input) = makeModel()
        let a = CGPoint(x: 100, y: 6)
        input.changed(start: a, location: a)
        input.changed(start: a, location: CGPoint(x: 300, y: 6))
        input.ended(start: a, location: CGPoint(x: 300, y: 6))
        XCTAssertEqual(model.playback.t, 6, accuracy: 1e-9)

        model.playback.setInOut(2...10)
        let flag = CGPoint(x: 500, y: 18)                   // the out flag at 10 s
        input.changed(start: flag, location: flag)
        input.changed(start: flag, location: CGPoint(x: 600, y: 18))
        input.ended(start: flag, location: CGPoint(x: 600, y: 18))
        XCTAssertEqual(model.playback.inOut?.upperBound ?? -1, 12, accuracy: 1e-9)
        XCTAssertEqual(model.playback.inOut?.lowerBound ?? -1, 2, accuracy: 1e-9)
    }

    func testHoverResolvesLaneAndItem() async throws {
        let (model, state, input) = makeModel()
        _ = try await model.review.add(t: 4, end: nil, region: nil, body: "hover me")
        input.hover(at: CGPoint(x: 201, y: notesY(input)))
        XCTAssertEqual(state.hover?.key, .notes)
        XCTAssertEqual(state.hover?.hit?.kind, .comment)
        XCTAssertEqual(state.hover?.hit?.title, "#1 · hover me")
        input.hoverEnded()
        XCTAssertNil(state.hover)
    }
}
