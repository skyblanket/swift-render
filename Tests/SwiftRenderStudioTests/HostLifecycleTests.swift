import XCTest
import SwiftRenderKit
@testable import SwiftRenderStudio

/// Overlapping host lifecycle operations (start, swap, crash restart, shutdown) and
/// opens / knob changes racing a swap. Every `serve` the supervisor launches must end up
/// either active or shut down, and the active host must match the newest build and the
/// current open params.
@MainActor
final class HostLifecycleTests: XCTestCase {
    private let project = Project(root: URL(fileURLWithPath: "/tmp/FakeProject"))
    private let exe = URL(fileURLWithPath: "/x")

    /// Per-generation fake host settings.
    struct Gen {
        var startupDelay = 0.0
        var crashAt: Double?
        var slowOpen: Double?
    }

    /// Every host the factory made, in order.
    final class Spawned {
        var hosts: [(gen: Int, host: RenderHost)] = []
        func of(_ gen: Int) -> [RenderHost] { hosts.filter { $0.gen == gen }.map(\.host) }
    }

    private func supervisor(_ gens: [Int: Gen] = [:]) -> (HostSupervisor, Spawned) {
        let spawned = Spawned()
        let s = HostSupervisor(project: project) { _, gen in
            let g = gens[gen] ?? Gen()
            var o = FakeHostClient.Options()
            o.generation = gen
            o.startupDelay = g.startupDelay
            o.crashAt = g.crashAt
            let fake = FakeHostClient(options: o)
            let host: RenderHost = g.slowOpen.map { SlowOpenHost(fake, openDelay: $0) } ?? fake
            spawned.hosts.append((gen, host))
            return host
        }
        s.backoff = [0.3, 0.3, 0.3]
        return (s, spawned)
    }

    private func exited(_ h: RenderHost, within seconds: Double = 2) async -> Bool {
        let fake = (h as? FakeHostClient) ?? (h as? SlowOpenHost)?.inner
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if fake?.hasExited == true { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return fake?.hasExited == true
    }

    /// Everything spawned is either the active host or has exited.
    private func assertNoOrphans(_ s: HostSupervisor, _ spawned: Spawned, file: StaticString = #filePath,
                                 line: UInt = #line) async {
        for (gen, h) in spawned.hosts where h !== s.active {
            let gone = await exited(h)
            XCTAssertTrue(gone, "gen \(gen) host \(h.pid) still running without an owner", file: file, line: line)
        }
    }

    private let launchFilm = HostParams(scene: "LaunchFilm", width: 1920, height: 1080, fps: 60)

    // MARK: Overlapping builds

    func testBuildLandingWhileFirstHostStartsQueuesBehindIt() async throws {
        let (s, spawned) = supervisor([1: Gen(startupDelay: 0.3)])
        let first = Task { await s.start(exe, generation: 1, open: launchFilm) }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(s.hasStarted)
        await s.swap(to: exe, generation: 2)          // what hostBuilt does for the second build
        await first.value
        XCTAssertEqual(s.generation, 2)
        XCTAssertTrue(s.active === spawned.of(2).first)
        XCTAssertEqual(s.state, .ready(pid: s.active!.pid))
        await assertNoOrphans(s, spawned)
        await s.shutdown()
        for (_, h) in spawned.hosts { let gone = await exited(h); XCTAssertTrue(gone) }
    }

    func testOlderSlowerSwapNeverGoesLive() async throws {
        let (s, spawned) = supervisor([2: Gen(startupDelay: 0.4)])
        await s.start(exe, generation: 1, open: launchFilm)
        let g2 = Task { await s.swap(to: exe, generation: 2) }
        try await Task.sleep(for: .milliseconds(50))
        await s.swap(to: exe, generation: 3)
        await g2.value
        XCTAssertEqual(s.generation, 3, "the newest build is live")
        XCTAssertTrue(s.active === spawned.of(3).first)
        await assertNoOrphans(s, spawned)
    }

    func testShutdownDuringSwapInstallsNothing() async throws {
        let (s, spawned) = supervisor([2: Gen(startupDelay: 0.3)])
        var attached: [Int32?] = []
        s.onActiveHost = { h, _, _ in attached.append(h?.pid) }
        await s.start(exe, generation: 1, open: launchFilm)
        let swap = Task { await s.swap(to: exe, generation: 2) }
        try await Task.sleep(for: .milliseconds(50))
        await s.shutdown()                              // window closed mid hot-reload
        await swap.value
        XCTAssertNil(s.active)
        XCTAssertEqual(s.state, .idle)
        XCTAssertEqual(attached.count, 1, "gen 2 was never attached: \(attached)")
        for (gen, h) in spawned.hosts {
            let gone = await exited(h)
            XCTAssertTrue(gone, "gen \(gen) still running after shutdown")
        }
    }

    // MARK: Crashes

    func testBuildDuringCrashBackoffCancelsTheRestart() async throws {
        let (s, spawned) = supervisor([1: Gen(crashAt: 2)])
        s.backoff = [0.4]
        var t = 0.0
        s.currentTime = { t }
        await s.start(exe, generation: 1, open: launchFilm)
        t = 2
        _ = try? await s.active!.frame(t: 2, maxWidth: 320, format: .jpeg)
        await waitUntil(3, "crash") { if case .crashed = s.state { return true }; return false }
        await s.swap(to: exe, generation: 2)            // the fix lands during the 0.4 s backoff
        XCTAssertTrue(s.active === spawned.of(2).first)
        try await Task.sleep(for: .milliseconds(700))   // the backoff has long expired
        XCTAssertEqual(s.restarts, 0, "the restart was cancelled")
        XCTAssertTrue(s.active === spawned.of(2).first, "nothing replaced the fresh build")
        XCTAssertEqual(spawned.hosts.count, 2)
        XCTAssertNil(s.crash, "a new build clears the crash card")
        XCTAssertTrue(s.poisoned.isEmpty)
        await assertNoOrphans(s, spawned)
    }

    func testNewBuildAfterCrashLoopResetsCardPoisonAndRestartBudget() async throws {
        let (s, spawned) = supervisor([1: Gen(crashAt: 2), 2: Gen(crashAt: 5)])
        s.backoff = [0.05, 0.05, 0.05]
        var cleared = 0
        s.onPoisonCleared = { cleared += 1 }
        await s.start(exe, generation: 1, open: launchFilm)
        // Crash gen 1 until the supervisor gives up.
        for _ in 0..<4 {
            await waitUntil(3, "host up or failed") {
                if case .failed = s.state { return true }
                return s.active != nil
            }
            guard let h = s.active else { break }
            _ = try? await h.frame(t: 2, maxWidth: 320, format: .jpeg)
            await waitUntil(3, "crash handled") { s.active !== h }
        }
        await waitUntil(3, "gave up") { if case .failed = s.state { return true }; return false }
        XCTAssertEqual(s.restarts, 3)
        XCTAssertEqual(s.poisoned, [119, 120, 121])
        let clearedBefore = cleared

        await s.swap(to: exe, generation: 2)            // fixed build; no active host → start path
        XCTAssertTrue(s.active === spawned.of(2).first)
        XCTAssertNil(s.crash, "stale crash card cleared")
        XCTAssertTrue(s.poisoned.isEmpty)
        XCTAssertEqual(cleared, clearedBefore + 1)

        // The new build gets its own restarts.
        _ = try? await s.active!.frame(t: 5, maxWidth: 320, format: .jpeg)
        await waitUntil(3, "gen 2 restarted") { s.restarts == 4 && s.active != nil }
        if case .ready = s.state {} else { XCTFail("\(s.state)") }
        await assertNoOrphans(s, spawned)
    }

    func testCrashTimeComesFromTheHostBreadcrumbNotThePlayhead() async throws {
        let (s, _) = supervisor([1: Gen(crashAt: 2)])
        s.currentTime = { 0.9 }                          // playhead well behind a stream running ahead
        var poisoned: Set<Int> = []
        s.onPoison = { poisoned.insert($0) }
        await s.start(exe, generation: 1, open: launchFilm)
        let stream = try await s.active!.openStream(from: 1.9, to: nil, fps: 60, maxWidth: 160, format: .jpeg, credits: 30)
        do { for try await _ in stream.frames {} } catch {}
        await waitUntil(3, "crash card") { s.crash != nil }
        XCTAssertEqual(try XCTUnwrap(s.crash?.t), 2, accuracy: 1e-9)
        XCTAssertEqual(poisoned, [119, 120, 121])
    }

    func testStaleHangTimeoutDoesNotKillTheSuccessor() async throws {
        let (s, spawned) = supervisor()
        await s.start(exe, generation: 1, open: launchFilm)
        let old = try XCTUnwrap(s.active)
        await s.swap(to: exe, generation: 2)
        s.reportHang(at: 3, host: old)                   // a timeout on a request sent to gen 1
        XCTAssertNil(s.crash)
        XCTAssertTrue(s.active === spawned.of(2).first)
        let killed = await exited(s.active!, within: 0.3)
        XCTAssertFalse(killed)
    }

    func testPlaybackStreamStopsShortOfAPoisonedFrame() async throws {
        var o = FakeHostClient.Options()
        o.crashAt = 2
        o.renderMs = 1
        let host = FakeHostClient(options: o)
        _ = try await host.waitUntilReady(timeout: 2)
        let info = try await host.open(launchFilm)
        let engine = PlaybackEngine()
        engine.displayWidth = 160
        engine.poisoned = [119, 120, 121]                // frame 120 crashed this build before
        engine.attach(host: host, info: info)
        engine.seek(1.5, precise: true)
        await waitUntil(5, "idle") { engine.isRequestIdle }
        var clock = 100.0
        engine.now = { clock }
        engine.play()
        for _ in 0..<70 {                                // 1.5 s → 2.67 s of scene time
            clock += 1.0 / 60
            engine.tick()
            try await Task.sleep(for: .milliseconds(6))
        }
        engine.pause()
        XCTAssertFalse(host.hasExited, "the stream rendered through the frame that crashed the host")
        XCTAssertGreaterThan(engine.t, 2.5)
        XCTAssertGreaterThan(engine.liveStats.shown, 10, "playback carried on past the bad frame")
    }

    // MARK: Params racing a swap

    func testSceneOpenedDuringSwapReachesTheNewHost() async throws {
        let (s, spawned) = supervisor([2: Gen(startupDelay: 0.3)])
        var attached: [String] = []
        s.onActiveHost = { h, info, _ in if let h { attached.append("\(h.pid):\(info?.name ?? "-")") } }
        await s.start(exe, generation: 1, open: launchFilm)
        let swap = Task { await s.swap(to: exe, generation: 2) }
        try await Task.sleep(for: .milliseconds(80))
        var p = launchFilm
        p.scene = "RepoPromo"
        _ = try await s.reopen(p)                        // lands on gen 1 while gen 2 starts
        await swap.value
        let b = try XCTUnwrap(spawned.of(2).first)
        XCTAssertTrue(s.active === b)
        XCTAssertEqual(s.info?.name, "RepoPromo")
        let session = try await b.call(.setProps, HostParams()).result.info
        XCTAssertEqual(session?.name, "RepoPromo", "the new host renders the scene the UI shows")
        XCTAssertEqual(attached.last, "\(b.pid):RepoPromo")
    }

    func testKnobsSetDuringSwapReachTheNewHost() async throws {
        let (s, spawned) = supervisor([2: Gen(startupDelay: 0.3)])
        await s.start(exe, generation: 1, open: launchFilm)
        let swap = Task { await s.swap(to: exe, generation: 2) }
        try await Task.sleep(for: .milliseconds(80))
        _ = try await s.apply(.setKnobs, HostParams(knobs: ["logo.scale": .number(1.7)], reprobe: true))
        await swap.value
        let b = try XCTUnwrap(spawned.of(2).first)
        XCTAssertTrue(s.active === b)
        XCTAssertEqual(s.info?.knobs.first { $0.key == "logo.scale" }?.value, .number(1.7))
        let session = try await b.call(.setProps, HostParams()).result.info
        XCTAssertEqual(session?.knobs.first { $0.key == "logo.scale" }?.value, .number(1.7))
    }

    func testLateOpenReplyFromRetiredHostDoesNotReattachPlayback() async throws {
        let (s, spawned) = supervisor([1: Gen(slowOpen: 0)])
        let playback = PlaybackEngine()
        playback.displayWidth = 160
        s.onActiveHost = { h, info, warm in
            if let h, h !== s.active { return }
            playback.attach(host: h, info: info, warmFrame: warm)
        }
        await s.start(exe, generation: 1, open: launchFilm)
        let a = try XCTUnwrap(spawned.of(1).first as? SlowOpenHost)
        a.openDelay = 0.3                                 // A answers its queued open late…
        var p = launchFilm
        p.scene = "RepoPromo"
        let reopen = Task { try await s.reopen(p) }
        try await Task.sleep(for: .milliseconds(20))
        await s.swap(to: exe, generation: 2)              // …after B went live
        let info = try await reopen.value
        let b = try XCTUnwrap(spawned.of(2).first)
        XCTAssertTrue(s.active === b)
        XCTAssertTrue(playback.host === b, "playback stays on the live host")
        XCTAssertEqual(info?.name, "RepoPromo")
        let session = try await b.call(.setProps, HostParams()).result.info
        XCTAssertEqual(session?.name, "RepoPromo")
        let aGone = await exited(a)
        XCTAssertTrue(aGone)
    }

    // MARK: Through ProjectModel

    func testModelBuildsInQuickSuccessionLeaveOneHost() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var o = LaunchOptions()
        o.fakeHost = true
        o.scene = "LaunchFilm"
        let model = ProjectModel(root: root, options: o)
        let spawned = Spawned()
        model.host.makeHost = { _, gen in
            var fo = FakeHostClient.Options()
            fo.generation = gen
            fo.startupDelay = gen == 2 ? 0.3 : 0.02
            let h = FakeHostClient(options: fo)
            spawned.hosts.append((gen, h))
            return h
        }
        await model.start()
        // Two builds 50 ms apart, as an agent edit burst produces.
        model.build.onSuccess?(URL(fileURLWithPath: "/fake-host"), 2)
        try await Task.sleep(for: .milliseconds(50))
        model.build.onSuccess?(URL(fileURLWithPath: "/fake-host"), 3)
        await waitUntil(5, "gen 3 live") { model.host.generation == 3 && model.host.active != nil }
        XCTAssertTrue(model.playback.host === model.host.active)
        await assertNoOrphans(model.host, spawned)
        await model.shutdown()
        for (gen, h) in spawned.hosts {
            let gone = await exited(h)
            XCTAssertTrue(gone, "gen \(gen) still running after the window closed")
        }
    }
}

/// FakeHost whose `open` can be slowed, and whose shutdown waits for an in-flight open —
/// the real `serve` answers requests in order, so a queued `open` is answered before the
/// `shutdown` that follows it.
final class SlowOpenHost: RenderHost, @unchecked Sendable {
    let inner: FakeHostClient
    private let lock = NSLock()
    private var _openDelay: Double
    private var opening = 0
    var openDelay: Double {
        get { lock.withLock { _openDelay } }
        set { lock.withLock { _openDelay = newValue } }
    }

    init(_ inner: FakeHostClient, openDelay: Double) {
        self.inner = inner
        _openDelay = openDelay
    }

    var pid: Int32 { inner.pid }
    var supportsBinaryFrames: Bool { inner.supportsBinaryFrames }
    var events: AsyncStream<HostMessage> { inner.events }
    func waitUntilReady(timeout: Double) async throws -> HostMessage { try await inner.waitUntilReady(timeout: timeout) }

    func call(_ method: HostMethod, _ params: HostParams?) async throws -> HostReply {
        guard method == .open else { return try await inner.call(method, params) }
        lock.withLock { opening += 1 }
        defer { lock.withLock { opening -= 1 } }
        let d = openDelay
        if d > 0 { try await Task.sleep(for: .seconds(d)) }
        return try await inner.call(method, params)
    }

    func frame(t: Double, maxWidth: Int, format: FrameFormat) async throws -> DecodedFrame {
        try await inner.frame(t: t, maxWidth: maxWidth, format: format)
    }

    func openStream(from: Double, to: Double?, fps: Int, maxWidth: Int, format: FrameFormat,
                    credits: Int) async throws -> HostFrameStream {
        try await inner.openStream(from: from, to: to, fps: fps, maxWidth: maxWidth, format: format, credits: credits)
    }

    func shutdown() async {
        while lock.withLock({ opening > 0 }) { try? await Task.sleep(for: .milliseconds(5)) }
        await inner.shutdown()
    }

    func kill() { inner.kill() }
    func waitForExit() async -> HostTermination { await inner.waitForExit() }
}
