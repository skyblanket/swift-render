import XCTest
import SwiftRenderKit
@testable import SwiftRenderStudio

/// Waits (polling) for a main-actor condition.
@MainActor
func waitUntil(_ seconds: Double = 5, _ what: String = "condition", file: StaticString = #filePath,
               line: UInt = #line, _ cond: () -> Bool) async {
    let deadline = Date().addingTimeInterval(seconds)
    while !cond() {
        if Date() > deadline { XCTFail("timed out waiting for \(what)", file: file, line: line); return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

/// Scheduling policy of PlaybackEngine against FakeHost: scrub coalescing, stale
/// generations, credit-bounded streams, drop counting and the quality ladder.
@MainActor
final class PlaybackTests: XCTestCase {
    private func makeEngine(renderMs: Double = 4, scene: String = "LaunchFilm") async throws
        -> (PlaybackEngine, FakeHostClient) {
        var o = FakeHostClient.Options()
        o.renderMs = renderMs
        let host = FakeHostClient(options: o)
        _ = try await host.waitUntilReady(timeout: 2)
        let info = try await host.open(HostParams(scene: scene, width: 1920, height: 1080, fps: 60))
        let engine = PlaybackEngine()
        engine.displayWidth = 320
        engine.attach(host: host, info: info)
        await waitUntil(5, "first frame") { engine.hasFrame && engine.isRequestIdle }
        return (engine, host)
    }

    func testScrubDragIsCoalesced() async throws {
        let (engine, host) = try await makeEngine(renderMs: 15)
        let before = engine.framesRequested
        // A fast drag: 120 pointer moves, no waiting between them.
        for i in 0..<120 { engine.seek(Double(i) * 0.1) }
        await waitUntil(5, "scrub idle") { engine.isRequestIdle }
        try await Task.sleep(for: .milliseconds(250))          // sharpen-on-pause lands
        await waitUntil(5, "sharpen idle") { engine.isRequestIdle }

        let sent = engine.framesRequested - before
        XCTAssertLessThanOrEqual(sent, 4, "one in flight + latest pending + sharpen, not 120")
        XCTAssertLessThanOrEqual(host.stats.rendered, sent + 2)
        // The viewer ends on exactly the frame under the playhead, at display width.
        XCTAssertEqual(engine.currentFrame?.index, frameIndex(11.9, fps: 60))
        XCTAssertEqual(engine.currentFrame?.width, 320)
    }

    func testFramesFromOlderGenerationAreDropped() async throws {
        let (engine, _) = try await makeEngine(renderMs: 40)
        let gen = engine.generation
        engine.seek(5, precise: true)         // in flight against `gen`
        engine.invalidate()                   // knobs changed while it renders
        XCTAssertEqual(engine.generation, gen + 1)
        await waitUntil(5, "requests settle") { engine.isRequestIdle && engine.staleDropped > 0 }
        await waitUntil(5, "fresh frame") { engine.cache.contains(generation: gen + 1, frame: frameIndex(5, fps: 60)) }
        XCTAssertFalse(engine.cache.contains(generation: gen, frame: frameIndex(5, fps: 60)), "old pixels purged")
    }

    func testPlaybackStreamIsCreditBoundedAndShowsFrames() async throws {
        let (engine, host) = try await makeEngine(renderMs: 2)
        var clock = 100.0
        engine.now = { clock }
        engine.play()
        // Simulated 60 Hz display link for 2 s of scene time.
        for _ in 0..<120 {
            clock += 1.0 / 60
            engine.tick()
            try await Task.sleep(for: .milliseconds(8))
        }
        engine.pause()
        let s = host.stats
        XCTAssertGreaterThanOrEqual(s.streamsOpened, 1)
        XCTAssertGreaterThan(s.streamFrames, 20)
        XCTAssertLessThanOrEqual(s.maxOutstanding, PlaybackEngine.creditWindow, "host never runs past the window")
        XCTAssertGreaterThan(engine.liveStats.shown, 20)
        XCTAssertEqual(engine.t, 2, accuracy: 0.05)
    }

    func testSlowSceneCountsDropsAndStepsDownTheLadder() async throws {
        let (engine, _) = try await makeEngine(renderMs: 30, scene: "StyleLab")     // ×6 → ~180 ms/frame
        var clock = 0.0
        engine.now = { clock }
        engine.play()
        XCTAssertEqual(engine.sampleFPS, 60, "plays at the scene's fps")
        var steppedAt: Double?
        for _ in 0..<180 {
            clock += 1.0 / 60
            engine.tick()
            if engine.rung > 0 { steppedAt = clock; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let live = engine.liveStats
        XCTAssertGreaterThan(engine.rung, 0, "sustained drops step the ladder down")
        XCTAssertGreaterThanOrEqual(steppedAt ?? 0, 1, "not in the first second after play")
        XCTAssertEqual(engine.sampleFPS, 30, "fps goes first")
        XCTAssertEqual(engine.playWidth, 320, "width is kept on the first step")
        engine.pause()
        XCTAssertGreaterThan(live.dropped, 0)
        XCTAssertGreaterThan(live.msPerFrame, 100)
        XCTAssertNotNil(live.note)
    }

    func testLightSceneStaysAtFullQuality() async throws {
        let (engine, _) = try await makeEngine(renderMs: 2)
        var clock = 0.0
        engine.now = { clock }
        engine.play()
        // A light scene keeps 60 fps at full width.
        for _ in 0..<120 {
            clock += 1.0 / 60
            engine.tick()
            try await Task.sleep(for: .milliseconds(8))
        }
        XCTAssertEqual(engine.rung, 0, "a light scene stays at full quality")
        engine.pause()
    }

    func testLadderStepsBackUpWhenHeadroomReturns() async throws {
        let (engine, _) = try await makeEngine(renderMs: 30, scene: "StyleLab")
        var clock = 0.0
        engine.now = { clock }
        engine.play()
        for _ in 0..<180 where engine.rung == 0 {
            clock += 1.0 / 60
            engine.tick()
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThan(engine.rung, 0)
        engine.pause()

        // Same scene, now cheap (a release host, a quiet machine): back to full quality soon.
        var o = FakeHostClient.Options()
        o.renderMs = 0.3
        let fast = FakeHostClient(options: o)
        _ = try await fast.waitUntilReady(timeout: 2)
        let info = try await fast.open(HostParams(scene: "StyleLab", width: 1920, height: 1080, fps: 60))
        engine.attach(host: fast, info: info)
        engine.seek(10, precise: true)
        await waitUntil(5, "frame") { engine.isRequestIdle }
        engine.play()
        for _ in 0..<240 where engine.rung > 0 {
            clock += 1.0 / 60
            engine.tick()
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(engine.rung, 0, "steps back up once nothing drops and the stream is ahead")
        engine.pause()
    }

    func testReplayingACachedRangeRendersNothing() async throws {
        let (engine, host) = try await makeEngine(renderMs: 1)
        var clock = 0.0
        engine.now = { clock }
        engine.seek(3, precise: true)
        await waitUntil(5, "frame") { engine.isRequestIdle }
        engine.play()
        for _ in 0..<60 {
            clock += 1.0 / 60
            engine.tick()
            try await Task.sleep(for: .milliseconds(8))
        }
        engine.pause()
        await waitUntil(5, "idle") { engine.isRequestIdle }
        try await Task.sleep(for: .milliseconds(250))
        await waitUntil(5, "sharpened") { engine.isRequestIdle }
        // Scrub away and back, then play the same second again.
        engine.seek(1)
        await waitUntil(5, "scrub") { engine.isRequestIdle }
        engine.seek(3, precise: true)
        await waitUntil(5, "back") { engine.isRequestIdle }
        let rendered = host.stats.streamFrames
        let dropped = engine.liveStats.dropped
        engine.play()
        for _ in 0..<30 {
            clock += 1.0 / 60
            engine.tick()
            try await Task.sleep(for: .milliseconds(8))
        }
        XCTAssertEqual(engine.liveStats.dropped, 0, "every frame of the replay comes from the cache (was \(dropped))")
        XCTAssertGreaterThanOrEqual(engine.liveStats.shown, 25)
        engine.pause()
        XCTAssertLessThan(host.stats.streamFrames - rendered, 70, "the stream starts past the cached second")
    }

    func testJumpToEditAndInOut() async throws {
        let (engine, _) = try await makeEngine()
        engine.seek(0, precise: true)
        engine.jumpToEdit(next: true)
        XCTAssertEqual(engine.t, 4, accuracy: 1e-9)          // LaunchFilm fake: six 4 s clips
        engine.seek(10, precise: true)
        engine.setIn()
        engine.seek(12, precise: true)
        engine.setOut()
        XCTAssertEqual(engine.inOut, 10...12)
        engine.jumpToEdit(next: false)
        XCTAssertEqual(engine.t, 10.666, accuracy: 0.01)      // card1 boundary (nested clips count)
        engine.step(frames: -1)
        XCTAssertEqual(frameIndex(engine.t, fps: 60), 639)
    }

    func testVisibleCommentsTrackPlayhead() async throws {
        let (engine, _) = try await makeEngine()
        engine.commentMarks = [(id: "a", t: 2, end: nil), (id: "b", t: 5, end: 8)]
        engine.seek(2.1)
        XCTAssertEqual(engine.visibleCommentIDs, ["a"])
        engine.seek(7)
        XCTAssertEqual(engine.visibleCommentIDs, ["b"])
        engine.seek(9)
        XCTAssertEqual(engine.visibleCommentIDs, [])
    }
}

final class FrameCacheTests: XCTestCase {
    private func frame(_ index: Int, width: Int) -> DecodedFrame {
        let h = width * 9 / 16
        let img = FakeFrameArt.draw(t: Double(index) / 60, width: width, height: h, scene: "C", duration: 10, generation: 1)
        return DecodedFrame(t: Double(index) / 60, index: index, width: width, height: h, image: img, ms: 1, format: .jpeg)
    }

    func testBestWidthNearestAndPurge() {
        let c = FrameCache()
        c.put(frame(10, width: 160), generation: 1)
        c.put(frame(10, width: 640), generation: 1)
        c.put(frame(14, width: 160), generation: 1)
        XCTAssertEqual(c.best(generation: 1, frame: 10)?.width, 640)
        XCTAssertNil(c.best(generation: 1, frame: 10, minWidth: 1000))
        XCTAssertEqual(c.nearest(generation: 1, atOrBefore: 13, within: 5)?.index, 10)
        XCTAssertNil(c.nearest(generation: 1, atOrBefore: 13, within: 2))
        XCTAssertNil(c.best(generation: 2, frame: 10))
        c.purge(below: 2)
        XCTAssertEqual(c.count, 0)
        XCTAssertEqual(c.bytes, 0)
    }

    func testLRUEvictsOldestUnderBudget() {
        let one = frame(0, width: 160).byteCost
        let c = FrameCache(budgetBytes: one * 3)
        for i in 0..<3 { c.put(frame(i, width: 160), generation: 1) }
        _ = c.best(generation: 1, frame: 0)                 // touch 0: frame 1 is now oldest
        c.put(frame(3, width: 160), generation: 1)
        XCTAssertTrue(c.contains(generation: 1, frame: 0))
        XCTAssertFalse(c.contains(generation: 1, frame: 1))
        XCTAssertLessThanOrEqual(c.bytes, one * 3)
    }

    func testCachedRangesBridgeSmallGaps() {
        let c = FrameCache()
        for i in stride(from: 0, through: 60, by: 2) { c.put(frame(i, width: 64), generation: 1) }   // 30 fps of 60
        c.put(frame(120, width: 64), generation: 1)
        let r = c.cachedRanges(generation: 1, fps: 60, tolerance: 2)
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r[0].lowerBound, 0)
        XCTAssertEqual(r[0].upperBound, 61.0 / 60, accuracy: 1e-9)
    }
}
