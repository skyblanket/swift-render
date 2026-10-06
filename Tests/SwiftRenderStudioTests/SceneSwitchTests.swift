import XCTest
import SwiftRenderKit
@testable import SwiftRenderStudio

/// Scene switching: the loading state starts at once, no frame of the scene being left is ever
/// presented as the new one, rapid picks open only the newest scene, and each scene keeps its
/// poster, playhead and quality rung.
@MainActor
final class SceneSwitchTests: XCTestCase {
    private func fakeHost(renderMs: Double = 4, openMs: Double = 0) async throws -> FakeHostClient {
        var o = FakeHostClient.Options()
        o.renderMs = renderMs
        o.openMs = openMs
        let host = FakeHostClient(options: o)
        _ = try await host.waitUntilReady(timeout: 2)
        return host
    }

    private func key(_ scene: String) -> String { PlaybackEngine.sceneKey(scene, width: 1920, height: 1080) }

    private func attached(_ engine: PlaybackEngine, _ host: FakeHostClient, scene: String) async throws {
        let info = try await host.open(HostParams(scene: scene, width: 1920, height: 1080, fps: 60))
        engine.attach(host: host, info: info)
        await waitUntil(5, "\(scene) frame") { engine.opening == nil && engine.hasFrame && engine.isRequestIdle }
    }

    func testBeginOpeningDropsTheOldScenesFramesAndShowsNothingOfIt() async throws {
        let host = try await fakeHost(renderMs: 40)
        let engine = PlaybackEngine()
        engine.displayWidth = 320
        try await attached(engine, host, scene: "LaunchFilm")
        var shown: [DecodedFrame] = []
        var covers = 0
        engine.onFrame = { shown.append($0) }
        engine.onCover = { covers += 1 }

        engine.seek(5, precise: true)                     // a LaunchFilm render in flight…
        let gen = engine.generation
        engine.beginOpening(scene: "RepoPromo", key: key("RepoPromo"))   // …when RepoPromo is picked
        XCTAssertEqual(engine.opening, PlaybackEngine.Opening(scene: "RepoPromo", hasPoster: false))
        XCTAssertGreaterThan(engine.generation, gen, "older answers can never be shown")
        XCTAssertNil(engine.host, "nothing renders until the new scene attaches")
        XCTAssertEqual(covers, 1, "the viewer covers the old picture")

        engine.seek(7, precise: true)                     // scrubbing while it opens asks nothing
        await waitUntil(5, "in-flight request settles") { engine.isRequestIdle }
        try await Task.sleep(for: .milliseconds(250))     // a sharpen would have fired by now
        XCTAssertTrue(shown.isEmpty, "no LaunchFilm frame was presented during the switch")
        XCTAssertGreaterThan(engine.staleDropped, 0)
        XCTAssertNotNil(engine.opening)

        // The open lands with its first frame on the reply: the switch ends on it.
        let opened = try await host.openScene(HostParams(scene: "RepoPromo", width: 1920, height: 1080, fps: 60,
                                                         t: Double(frameIndex(engine.t, fps: 60)) / 60, maxWidth: 320,
                                                         format: "bgra8", deferProbe: true))
        XCTAssertTrue(opened.probing)
        let warm = try XCTUnwrap(opened.frame)
        engine.attach(host: host, info: opened.info, warmFrame: warm)
        XCTAssertNil(engine.opening)
        XCTAssertEqual(shown.count, 1)
        XCTAssertTrue(shown.first?.image === warm.image)
        XCTAssertEqual(engine.sceneName, "RepoPromo")
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(shown.count, 1, "a lossless full-size first frame needs no sharpen pass")
    }

    func testRevisitShowsItsPosterAndRestoresThePlayhead() async throws {
        let host = try await fakeHost()
        let engine = PlaybackEngine()
        engine.displayWidth = 320
        try await attached(engine, host, scene: "LaunchFilm")
        engine.seek(4, precise: true)
        try await Task.sleep(for: .milliseconds(300))      // past the sharpen pass
        await waitUntil(5, "frame at 4 s") { engine.isRequestIdle && engine.currentFrame?.index == 240 }
        let poster = try XCTUnwrap(engine.currentFrame)

        engine.beginOpening(scene: "RepoPromo", key: key("RepoPromo"))
        try await attached(engine, host, scene: "RepoPromo")
        engine.seek(1, precise: true)

        var shown: [DecodedFrame] = []
        engine.onFrame = { shown.append($0) }
        engine.beginOpening(scene: "LaunchFilm", key: key("LaunchFilm"))
        XCTAssertEqual(engine.opening?.hasPoster, true)
        XCTAssertTrue(engine.currentFrame?.image === poster.image, "LaunchFilm's last frame, shown under the veil")
        XCTAssertEqual(engine.t, 4, accuracy: 1e-9, "its playhead comes back")
        XCTAssertNotNil(engine.opening, "a poster doesn't end the switch")
        try await attached(engine, host, scene: "LaunchFilm")
        XCTAssertEqual(engine.currentFrame?.index, 240)
        XCTAssertGreaterThanOrEqual(shown.count, 2)
    }

    func testRapidPicksOpenOnlyTheNewestSceneWithoutFlicker() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("switch-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var o = LaunchOptions()
        o.fakeHost = true
        o.scene = "LaunchFilm"
        o.fakeOpenMs = 80
        let model = ProjectModel(root: root, options: o)
        model.playback.displayWidth = 320
        await model.start()
        await waitUntil(10, "first scene") { model.info?.name == "LaunchFilm" && model.playback.hasFrame && model.playback.opening == nil }
        let host = try XCTUnwrap(model.host.active as? FakeHostClient)
        let opensBefore = host.stats.opens

        // Every frame presented from here on, with the scene the engine was attached to.
        var presented: [String] = []
        model.playback.onFrame = { [weak model] _ in presented.append(model?.playback.sceneName ?? "?") }

        // Five picks, 15 ms apart: faster than one open.
        let picks = ["NeverHeard", "RepoPromo", "StyleLab", "JETRAYChase", "RepoPromo"]
        var tasks: [Task<Void, Never>] = []
        for p in picks {
            tasks.append(Task { await model.select(scene: p) })
            try await Task.sleep(for: .milliseconds(15))
        }
        for t in tasks { await t.value }

        XCTAssertEqual(model.selectedScene, "RepoPromo")
        XCTAssertNil(model.playback.opening)
        XCTAssertEqual(model.info?.name, "RepoPromo")
        XCTAssertEqual(model.playback.sceneName, "RepoPromo")
        let opened = Array(host.stats.opened.dropFirst(opensBefore))
        XCTAssertEqual(opened.first, "NeverHeard", "the first pick was already in flight")
        XCTAssertEqual(opened.last, "RepoPromo")
        XCTAssertLessThanOrEqual(opened.count, 2, "picks made meanwhile replaced each other: \(opened)")
        XCTAssertGreaterThanOrEqual(host.stats.superseded, 3, "queued opens were answered superseded, never run")
        XCTAssertEqual(Set(presented), ["RepoPromo"], "no intermediate scene ever reached the screen: \(presented)")

        // The deferred probe lands as an info event for the scene that is open.
        await waitUntil(5, "probe info") { !model.host.probing && !(model.info?.clips.isEmpty ?? true) }
        XCTAssertFalse(model.isSceneLoading)
        await model.shutdown()
    }

    func testFailedOpenEndsTheLoadingStateWithAnError() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("switch-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var o = LaunchOptions()
        o.fakeHost = true
        o.scene = "LaunchFilm"
        let model = ProjectModel(root: root, options: o)
        await model.start()
        await waitUntil(10, "first scene") { model.playback.hasFrame && model.playback.opening == nil }
        await model.select(scene: "NoSuchScene")
        XCTAssertNil(model.playback.opening)
        XCTAssertEqual(model.openFailure?.scene, "NoSuchScene")
        await model.select(scene: "RepoPromo")
        XCTAssertNil(model.openFailure)
        await waitUntil(5, "RepoPromo") { model.playback.sceneName == "RepoPromo" && model.playback.opening == nil }
        await model.shutdown()
    }

    func testTransportIsIgnoredAndTheOldSoundtrackUnloadedWhileOpening() async throws {
        let host = try await fakeHost()
        let engine = PlaybackEngine()
        engine.displayWidth = 320
        try await attached(engine, host, scene: "LaunchFilm")
        engine.seek(3, precise: true)
        engine.beginOpening(scene: "RepoPromo", key: key("RepoPromo"))
        XCTAssertFalse(engine.audio.hasAudio, "LaunchFilm's soundtrack can't play under RepoPromo's name")
        XCTAssertTrue(engine.pictureIsStale)
        let t = engine.t
        engine.play()
        XCTAssertFalse(engine.isPlaying, "nothing to play until RepoPromo's first frame lands")
        engine.shuttle(.l)
        XCTAssertFalse(engine.isPlaying)
        engine.seek(7, precise: true)
        engine.step(frames: 5)
        XCTAssertEqual(engine.t, t, "the playhead holds until the scene attaches")
        try await attached(engine, host, scene: "RepoPromo")
        XCTAssertFalse(engine.pictureIsStale)
        engine.play()
        XCTAssertTrue(engine.isPlaying)
        engine.pause()
    }

    func testSafeFrameStepsOffCrashedFrames() {
        XCTAssertEqual(safeFrame(10, avoiding: []), 10)
        XCTAssertEqual(safeFrame(120, avoiding: [119, 120, 121]), 122, "later first")
        XCTAssertEqual(safeFrame(120, last: 121, avoiding: [119, 120, 121]), 118, "earlier at the end")
        XCTAssertEqual(safeFrame(0, avoiding: [0, 1]), 2)
        XCTAssertNil(safeFrame(1, last: 2, avoiding: [0, 1, 2]))
    }

    /// A crash poisons frames of the scene that crashed only; and a switch whose target frame
    /// crashed (here, inside `open` itself) ends on the nearest safe frame instead of
    /// waiting forever under "Opening …".
    func testSwitchOntoACrashedFrameEndsOnTheNearestSafeFrame() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("switch-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var o = LaunchOptions()
        o.fakeHost = true
        o.scene = "LaunchFilm"
        o.fakeCrashAt = 2
        o.fakeCrashScene = "RepoPromo"
        let model = ProjectModel(root: root, options: o)
        model.playback.displayWidth = 320
        model.host.backoff = [0.05, 0.05, 0.05]
        await model.start()
        await waitUntil(10, "first scene") { model.playback.hasFrame && model.playback.opening == nil }
        model.playback.seek(2, precise: true)
        await waitUntil(5, "LaunchFilm at 2 s") { model.playback.currentFrame?.index == 120 && model.playback.isRequestIdle }

        // RepoPromo opens at the same playhead and its first frame kills the host.
        let pick = Task { await model.select(scene: "RepoPromo") }
        await waitUntil(10, "crash") { model.host.crash != nil }
        XCTAssertEqual(model.host.poisoned(scene: "RepoPromo"), [119, 120, 121])
        XCTAssertTrue(model.host.poisoned(scene: "LaunchFilm").isEmpty, "a crash in RepoPromo says nothing about LaunchFilm")
        await waitUntil(10, "RepoPromo shows a frame") { model.playback.opening == nil && model.playback.sceneName == "RepoPromo" }
        await pick.value
        XCTAssertFalse(model.isSceneLoading || model.playback.pictureIsStale, "the switch ended")
        XCTAssertEqual(frameIndex(model.playback.t, fps: 60), 122, "stepped past the frames that crashed")
        XCTAssertEqual(model.playback.currentFrame?.index, 122)
        XCTAssertEqual(model.info?.name, "RepoPromo")

        // Back to LaunchFilm: frame 120 there never crashed, so it is asked for and shown.
        model.playback.seek(2, precise: true)
        await model.select(scene: "LaunchFilm")
        await waitUntil(5, "LaunchFilm frame 120") { model.playback.opening == nil && model.playback.currentFrame?.index == 120 }
        XCTAssertEqual(model.playback.sceneName, "LaunchFilm")
        await model.shutdown()
    }

    func testPanelsHideTheOldScenesDataAtOnceAndAfterAFailedOpen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("switch-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var o = LaunchOptions()
        o.fakeHost = true
        o.scene = "LaunchFilm"
        o.fakeOpenMs = 60
        let model = ProjectModel(root: root, options: o)
        await model.start()
        await waitUntil(10, "first scene") { model.playback.hasFrame && model.playback.opening == nil }
        XCTAssertFalse(model.sceneDataIsStale)
        let pick = Task { await model.select(scene: "RepoPromo") }
        await waitUntil(2, "pick registered") { model.selectedScene == "RepoPromo" }
        XCTAssertTrue(model.sceneDataIsStale, "LaunchFilm's lanes and knobs are hidden from the first moment")
        await pick.value
        XCTAssertFalse(model.sceneDataIsStale)
        await model.select(scene: "NoSuchScene")
        XCTAssertTrue(model.sceneDataIsStale, "a failed open leaves RepoPromo's data hidden, not shown under its name")
        XCTAssertFalse(model.isSceneLoading)
        await model.shutdown()
    }

    func testLadderIsPerSceneAndStartsSharpWhenTheSceneIsLight() async throws {
        let host = try await fakeHost(renderMs: 30)
        let engine = PlaybackEngine()
        engine.displayWidth = 320
        try await attached(engine, host, scene: "StyleLab")          // ×6: ~180 ms per frame
        var clock = 0.0
        engine.now = { clock }
        engine.play()
        XCTAssertGreaterThan(engine.rung, 0, "a first frame far over budget starts below full size")
        for _ in 0..<60 { clock += 1.0 / 60; engine.tick(); try await Task.sleep(for: .milliseconds(5)) }
        let heavy = engine.rung
        engine.pause()

        engine.beginOpening(scene: "RepoPromo", key: key("RepoPromo"))
        try await attached(engine, host, scene: "RepoPromo")
        XCTAssertEqual(engine.rung, 0, "a new scene doesn't inherit StyleLab's step-down")
        XCTAssertEqual(engine.playWidth, 320)

        engine.beginOpening(scene: "StyleLab", key: key("StyleLab"))
        try await attached(engine, host, scene: "StyleLab")
        XCTAssertEqual(engine.rung, heavy, "StyleLab's rung is remembered")
    }

    func testAutoLadderKeepsHalfSizeBeforeDroppingFrameRate() {
        let rungs = PlaybackEngine.ladder
        XCTAssertEqual(rungs.first?.scale, 1)
        let firstFPSDrop = rungs.firstIndex { $0.fps < 30 }!
        let firstBelowHalf = rungs.firstIndex { $0.scale < 0.5 }!
        XCTAssertLessThan(firstFPSDrop, firstBelowHalf, "fps drops before the picture goes below 50%")
    }

    func testGrowingCanvasResharpensAPausedFrame() async throws {
        let host = try await fakeHost()
        let engine = PlaybackEngine()
        engine.displayWidth = 320
        try await attached(engine, host, scene: "LaunchFilm")
        XCTAssertEqual(engine.currentFrame?.width, 320)
        engine.displayWidth = 960                       // window made bigger
        await waitUntil(5, "re-sharpened") { engine.currentFrame?.width == 960 && engine.isRequestIdle }
        XCTAssertNotEqual(engine.currentFrame?.format, .jpeg)
    }

    func testPortraitAsksForItsLongestEdge() async throws {
        let canvas = CGRect(x: 0, y: 0, width: 300, height: 533)
        XCTAssertEqual(ViewerGeometry.pixelEdge(canvas: canvas, backingScale: 2, sceneSize: CGSize(width: 1080, height: 1920)), 1066)
        XCTAssertEqual(ViewerGeometry.pixelEdge(canvas: CGRect(x: 0, y: 0, width: 1600, height: 900), backingScale: 2,
                                                sceneSize: CGSize(width: 1920, height: 1080)), 1920, "capped at native")

        let host = try await fakeHost()
        let info = try await host.open(HostParams(scene: "RepoPromo", width: 1080, height: 1920, fps: 60))
        let engine = PlaybackEngine()
        engine.displayWidth = 1066
        engine.attach(host: host, info: info)
        await waitUntil(5, "portrait frame") { engine.hasFrame && engine.isRequestIdle }
        XCTAssertEqual(engine.currentFrame?.height, 1066, "the edge, not the width, is what maxWidth caps")
        XCTAssertEqual(engine.currentFrame?.width, 600)
    }
}
