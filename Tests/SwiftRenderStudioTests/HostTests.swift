import XCTest
import SwiftRenderKit
@testable import SwiftRenderStudio

/// The real `HostClient` over real pipes, against `swift-render-studio --fake-serve`
/// (FakeHost behind the wire protocol in a child process).
final class HostClientProcessTests: XCTestCase {
    private var studioBinary: URL {
        get throws {
            // <bin>/SwiftRenderStudioTests.xctest → <bin>/swift-render-studio
            let bin = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            let exe = bin.appendingPathComponent("swift-render-studio")
            guard FileManager.default.isExecutableFile(atPath: exe.path) else {
                throw XCTSkip("swift-render-studio not built at \(exe.path)")
            }
            return exe
        }
    }

    private func spawn(_ extra: [String] = []) throws -> HostClient {
        let project = Project(root: FileManager.default.temporaryDirectory)
        return try HostClient(executable: try studioBinary, project: project,
                              environment: HostClient.hostEnvironment(project: project),
                              arguments: ["--fake-serve"] + extra)
    }

    func testOpenFramesAndStreamOverPipes() async throws {
        // 60 ms frames: the superseding check below queues requests 15 ms apart behind one
        // in-flight render, which a 4 ms fake frame raced on a loaded machine.
        let host = try spawn(["--fake-render-ms", "60"])
        let ready = try await host.waitUntilReady(timeout: 10)
        XCTAssertEqual(ready.event, "ready")
        XCTAssertEqual(ready.scenes?.map(\.name), FakeHostClient.scenes.map(\.name))

        let info = try await host.open(HostParams(scene: "NeverHeard", width: 1920, height: 1080, fps: 60,
                                                  binaryFrames: true))
        XCTAssertEqual(info.name, "NeverHeard")
        XCTAssertFalse(info.clips.isEmpty)

        let jpeg = try await host.frame(t: 2.5, maxWidth: 480, format: .jpeg)
        XCTAssertEqual(jpeg.index, 150)
        XCTAssertEqual(jpeg.width, 480)
        XCTAssertEqual(jpeg.format, .jpeg)

        let raw = try await host.frame(t: 3, maxWidth: 960, format: .bgra8)
        XCTAssertEqual(raw.format, .bgra8)
        XCTAssertEqual(raw.width, 960)
        XCTAssertEqual(raw.height, 540)

        // Stream: 4 credits → exactly 4 frames until more are granted.
        let s = try await host.openStream(from: 1, to: nil, fps: 30, maxWidth: 320, format: .bgra8, credits: 4)
        var it = s.frames.makeAsyncIterator()
        var got: [Int] = []
        for _ in 0..<4 { if let f = try await it.next() { got.append(f.index) } }
        XCTAssertEqual(got, [60, 62, 64, 66])
        s.credit(2)
        for _ in 0..<2 { if let f = try await it.next() { got.append(f.index) } }
        XCTAssertEqual(got.suffix(2), [68, 70])
        s.cancel()

        // While one frame renders, an older queued request is answered `superseded`
        // and the newest wins. (Spaced so the writes reach the host in order.)
        let a = Task { try await host.frame(t: 1, maxWidth: 1920, format: .png) }
        try await Task.sleep(for: .milliseconds(15))
        let b = Task { try await host.frame(t: 2, maxWidth: 1920, format: .png) }
        try await Task.sleep(for: .milliseconds(15))
        let c = Task { try await host.frame(t: 4, maxWidth: 1920, format: .png) }
        let first = try await a.value
        XCTAssertEqual(first.index, 60, "the in-flight render completes")
        do {
            _ = try await b.value
            XCTFail("the older queued request should be superseded")
        } catch {
            XCTAssertTrue((error as? HostClientError)?.isSuperseded == true, "\(error)")
        }
        let last = try await c.value
        XCTAssertEqual(last.index, 240)

        await host.shutdown()
        let term = await host.waitForExit()
        XCTAssertFalse(term.uncaughtSignal)
        XCTAssertTrue(term.requested)
    }

    func testCrashIsDetectedWithParseableReport() async throws {
        let host = try spawn(["--fake-crash-at", "2"])
        _ = try await host.waitUntilReady(timeout: 10)
        _ = try await host.open(HostParams(scene: "LaunchFilm", fps: 60))
        do {
            _ = try await host.frame(t: 2, maxWidth: 320, format: .jpeg)
            XCTFail("the host should have crashed")
        } catch {
            XCTAssertNotNil(error as? HostClientError)
        }
        let term = await host.waitForExit()
        XCTAssertTrue(term.uncaughtSignal)
        XCTAssertFalse(term.requested)
        let crash = RuntimeDiagnostics.parse(stderr: term.stderrTail, projectRoot: FileManager.default.temporaryDirectory,
                                             signal: term.status)
        XCTAssertEqual(crash.message, "Fatal error: Index out of range")
        XCTAssertEqual(crash.location?.line, 212)
    }
}

/// Blue/green swaps, failed swaps and crash restarts, against in-process FakeHost.
@MainActor
final class HostSupervisorTests: XCTestCase {
    private let project = Project(root: URL(fileURLWithPath: "/tmp/FakeProject"))

    private func supervisor(failOpenFor: Set<Int> = [], crashAt: Double? = nil) -> HostSupervisor {
        HostSupervisor(project: project) { _, gen in
            var o = FakeHostClient.Options()
            o.generation = gen
            o.failOpen = failOpenFor.contains(gen) ? "unknownScene: no scene LaunchFilm" : nil
            o.crashAt = crashAt
            o.startupDelay = 0
            return FakeHostClient(options: o)
        }
    }

    func testSwapReplacesHostAndShutsDownTheOld() async throws {
        let s = supervisor()
        var attached: [Int32] = []
        s.onActiveHost = { h, _, _ in if let h { attached.append(h.pid) } }
        await s.start(URL(fileURLWithPath: "/x"), generation: 1, open: HostParams(scene: "LaunchFilm", fps: 60))
        let first = try XCTUnwrap(s.active as? FakeHostClient)
        XCTAssertEqual(s.info?.name, "LaunchFilm")

        await s.swap(to: URL(fileURLWithPath: "/x"), generation: 2)
        let second = try XCTUnwrap(s.active as? FakeHostClient)
        XCTAssertFalse(first === second)
        XCTAssertEqual(s.generation, 2)
        XCTAssertEqual(s.state, .ready(pid: second.pid))
        XCTAssertEqual(attached, [first.pid, second.pid])
        let old = await first.waitForExit()
        XCTAssertTrue(old.requested, "old host got shutdown")
    }

    func testFailedSwapKeepsTheRunningHost() async throws {
        let s = supervisor(failOpenFor: [2])
        await s.start(URL(fileURLWithPath: "/x"), generation: 1, open: HostParams(scene: "LaunchFilm", fps: 60))
        let first = try XCTUnwrap(s.active as? FakeHostClient)
        await s.swap(to: URL(fileURLWithPath: "/x"), generation: 2)
        XCTAssertTrue(s.active === first)
        XCTAssertEqual(s.generation, 1)
        XCTAssertEqual(s.state, .ready(pid: first.pid))
        XCTAssertTrue(s.swapError?.hasPrefix("gen 2:") == true, s.swapError ?? "nil")
    }

    func testCrashShowsCardPoisonsFrameAndRestarts() async throws {
        let s = supervisor(crashAt: 2)
        var t = 0.0
        s.currentTime = { t }
        var poisoned: Set<Int> = []
        s.onPoison = { poisoned.insert($0) }
        await s.start(URL(fileURLWithPath: "/x"), generation: 1, open: HostParams(scene: "LaunchFilm", fps: 60))
        let first = try XCTUnwrap(s.active)
        t = 2
        _ = try? await first.frame(t: 2, maxWidth: 320, format: .jpeg)
        await waitUntil(3, "crash card") { s.crash != nil }
        XCTAssertEqual(s.crash?.message, "Fatal error: Index out of range")
        XCTAssertEqual(s.crash?.location?.line, 212)
        XCTAssertEqual(poisoned, [119, 120, 121])
        await waitUntil(5, "restart") { s.restarts == 1 && s.active != nil }
        XCTAssertFalse(s.active === first)
        if case .ready = s.state {} else { XCTFail("\(s.state)") }
        XCTAssertNotNil(s.crash, "card stays until dismissed or the next good build")
    }
}
