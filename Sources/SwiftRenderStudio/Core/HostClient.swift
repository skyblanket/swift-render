import Foundation
import SwiftRenderKit

// MARK: - Real render host client
//
// Spawns `<bin>/<product> serve` and speaks HostProtocol.swift: JSON-line requests on
// stdin; on stdout JSON lines, where a frame header with `bytes` is followed by
// exactly that many raw bytes. Stdout is read by a dedicated thread with blocking
// read(2) into `HostStreamDecoder` (verified at ~0.84 ms per 2 MB frame) — a
// readabilityHandler appending 64 KB chunks is the wrong tool for that.

/// Routes decoded host messages: responses to waiting calls, stream frames to their
/// stream, `ready` to its waiter, everything else to `events`. Thread-safe; separated
/// from process plumbing so framing and routing are unit-testable.
final class HostRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<HostReply, Error>] = [:]
    private var streams: [Int: AsyncThrowingStream<DecodedFrame, Error>.Continuation] = [:]
    private var ready: HostMessage?
    private var readyWaiters: [CheckedContinuation<HostMessage, Error>] = []
    private var closedReason: String?
    let fps: () -> Int
    let events: AsyncStream<HostMessage>
    private let eventsCont: AsyncStream<HostMessage>.Continuation

    init(fps: @escaping () -> Int) {
        self.fps = fps
        (events, eventsCont) = AsyncStream.makeStream(of: HostMessage.self, bufferingPolicy: .bufferingNewest(256))
    }

    func allocateID() -> Int {
        lock.lock(); defer { lock.unlock() }
        let id = nextID; nextID += 1; return id
    }

    func register(_ id: Int, _ c: CheckedContinuation<HostReply, Error>) {
        lock.lock()
        if let why = closedReason { lock.unlock(); c.resume(throwing: HostClientError.exited(why)); return }
        pending[id] = c
        lock.unlock()
    }

    /// Abandon a call (write failed); the continuation is resumed with `error`.
    func fail(_ id: Int, _ error: Error) {
        lock.lock(); let c = pending.removeValue(forKey: id); lock.unlock()
        c?.resume(throwing: error)
    }

    func registerStream(_ id: Int) -> AsyncThrowingStream<DecodedFrame, Error> {
        let (stream, cont) = AsyncThrowingStream.makeStream(of: DecodedFrame.self)
        lock.lock()
        if let why = closedReason { lock.unlock(); cont.finish(throwing: HostClientError.exited(why)); return stream }
        streams[id] = cont
        lock.unlock()
        return stream
    }

    func endStream(_ id: Int, error: Error? = nil) {
        lock.lock(); let c = streams.removeValue(forKey: id); lock.unlock()
        if let error { c?.finish(throwing: error) } else { c?.finish() }
    }

    func waitUntilReady() async throws -> HostMessage {
        try await withCheckedThrowingContinuation { c in
            lock.lock()
            if let r = ready { lock.unlock(); c.resume(returning: r); return }
            if let why = closedReason { lock.unlock(); c.resume(throwing: HostClientError.exited(why)); return }
            readyWaiters.append(c)
            lock.unlock()
        }
    }

    func route(_ msg: HostMessage, payload: Data?) {
        if let id = msg.id {
            lock.lock(); let c = pending.removeValue(forKey: id); lock.unlock()
            guard let c else { return }       // late answer to an abandoned call
            if let e = msg.error { c.resume(throwing: HostClientError.host(e)) }
            else { c.resume(returning: HostReply(result: msg.result ?? HostResult(), payload: payload)) }
            return
        }
        switch msg.event {
        case "ready":
            lock.lock(); ready = msg; let ws = readyWaiters; readyWaiters = []; lock.unlock()
            ws.forEach { $0.resume(returning: msg) }
        case "frame":
            guard let sid = msg.streamID, let f = msg.frame else { return }
            lock.lock(); let c = streams[sid]; lock.unlock()
            guard let c else { return }
            do { c.yield(try FrameDecoder.decode(f, payload: payload, fps: fps())) }
            catch { eventsCont.yield(.init(event: "warning", message: "undecodable stream frame: \(error)")) }
        case "streamEnd":
            // Natural end, replaced by a newer stream/open, or a render error (`message`).
            // Finishing normally lets playback start a fresh stream on its next tick.
            if let sid = msg.streamID { endStream(sid) }
            eventsCont.yield(msg)
        default:
            eventsCont.yield(msg)
        }
    }

    /// The host is gone: fail every waiter and finish every stream.
    func close(_ reason: String) {
        lock.lock()
        guard closedReason == nil else { lock.unlock(); return }
        closedReason = reason
        let ps = pending.values; pending = [:]
        let ss = streams.values; streams = [:]
        let ws = readyWaiters; readyWaiters = []
        lock.unlock()
        let err = HostClientError.exited(reason)
        ps.forEach { $0.resume(throwing: err) }
        ss.forEach { $0.finish(throwing: err) }
        ws.forEach { $0.resume(throwing: err) }
        eventsCont.finish()
    }
}

final class HostClient: RenderHost, @unchecked Sendable {
    let project: Project
    private let child: ChildProcess
    private let router: HostRouter
    private let fpsBox = FPSBox()
    private var shutdownRequested = false
    private let lock = NSLock()

    var pid: Int32 { child.pid }
    var supportsBinaryFrames: Bool { true }
    var events: AsyncStream<HostMessage> { router.events }

    /// Environment every host gets: login PATH, project root, and the Swift runtime
    /// backtracer (off by default on macOS) so crashes come with a parseable report.
    static func hostEnvironment(project: Project, extra: [String: String] = [:]) -> [String: String] {
        var env = ToolPaths.environment
        env["SWIFT_RENDER_ROOT"] = project.root.path
        env["SWIFT_BACKTRACE"] = "enable=yes,interactive=no,color=no"
        return env.merging(extra) { $1 }
    }

    init(executable: URL, project: Project, environment: [String: String], arguments: [String] = ["serve"]) throws {
        self.project = project
        let box = fpsBox
        router = HostRouter(fps: { box.value })
        child = ChildProcess(executable, arguments, cwd: project.root, env: environment,
                             qos: .userInteractive, rawStdout: true)
        try child.run()
        startReader()
        let router = router, child = child
        Task.detached {
            let t = await child.waitForExit()
            router.close(t.uncaughtSignal ? "signal \(t.status)" : "exit \(t.status)")
        }
    }

    private func startReader() {
        let fd = child.stdoutHandle.fileDescriptor
        let router = router
        let thread = Thread {
            var decoder = HostStreamDecoder()
            let cap = 1 << 20
            let buf = UnsafeMutableRawPointer.allocate(byteCount: cap, alignment: 16)
            defer { buf.deallocate() }
            while true {
                let n = read(fd, buf, cap)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                do {
                    for (msg, payload) in try decoder.feed(Data(bytes: buf, count: n)) {
                        router.route(msg, payload: payload)
                    }
                } catch {
                    router.close("protocol error: \(error)")
                    break
                }
            }
            router.close("stdout closed")
        }
        thread.name = "studio.host.stdout"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func waitUntilReady(timeout: Double) async throws -> HostMessage {
        try await withTimeout(timeout, "ready") { try await self.router.waitUntilReady() }
    }

    func call(_ method: HostMethod, _ params: HostParams?) async throws -> HostReply {
        let id = router.allocateID()
        return try await send(id: id, method, params)
    }

    private func send(id: Int, _ method: HostMethod, _ params: HostParams?) async throws -> HostReply {
        if method == .open, let fps = params?.fps { fpsBox.value = fps }
        let line = try HostWire.encode(HostRequest(id: id, method: method, params: params))
        let router = router
        return try await withCheckedThrowingContinuation { c in
            router.register(id, c)
            child.write(line) { err in if let err { router.fail(id, HostClientError.exited("stdin: \(err)")) } }
        }
    }

    private func sendNoReply(_ method: HostMethod, _ params: HostParams?) {
        let id = router.allocateID()
        Task { _ = try? await send(id: id, method, params) }
    }

    func frame(t: Double, maxWidth: Int, format: FrameFormat) async throws -> DecodedFrame {
        let reply = try await call(.frame, HostParams(t: t, maxWidth: maxWidth, format: format.rawValue))
        guard let f = reply.result.frame else { throw HostClientError.protocolError("frame result without frame") }
        return try FrameDecoder.decode(f, payload: reply.payload, fps: fpsBox.value)
    }

    func openStream(from: Double, to: Double?, fps: Int, maxWidth: Int, format: FrameFormat,
                    credits: Int) async throws -> HostFrameStream {
        let id = router.allocateID()
        // Register before sending: the first frames may beat the response.
        let frames = router.registerStream(id)
        do {
            _ = try await send(id: id, .stream, HostParams(maxWidth: maxWidth, format: format.rawValue,
                                                            from: from, to: to, credits: credits))
        } catch {
            router.endStream(id, error: error)
            throw error
        }
        let router = router
        return HostFrameStream(id: id, frames: frames,
                               grant: { [weak self] n in self?.sendNoReply(.credit, HostParams(credits: n, streamID: id)) },
                               stop: { [weak self] in
                                   self?.sendNoReply(.cancel, HostParams(streamID: id))
                                   router.endStream(id)
                               })
    }

    func shutdown() async {
        lock.withLock { shutdownRequested = true }
        _ = try? await withTimeout(1, "shutdown") { try await self.call(.shutdown, nil) }
        child.closeStdin()
        if await child.waitForExit(timeout: .seconds(1)) != nil { return }
        await child.terminate(grace: .seconds(1))
    }

    func kill() {
        lock.lock(); shutdownRequested = true; lock.unlock()
        child.kill()
    }

    func waitForExit() async -> HostTermination {
        let t = await child.waitForExit()
        let requested = lock.withLock { shutdownRequested }
        return HostTermination(status: t.status, uncaughtSignal: t.uncaughtSignal,
                               stderrTail: child.stderrTail, requested: requested)
    }

    private final class FPSBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _v = 30
        var value: Int {
            get { lock.lock(); defer { lock.unlock() }; return _v }
            set { lock.lock(); _v = newValue; lock.unlock() }
        }
    }
}

/// Races `body` against a deadline. The losing body keeps running; callers only use
/// this where an abandoned result is harmless.
func withTimeout<T: Sendable>(_ seconds: Double, _ what: String,
                              _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
        let once = ResumeOnce(c)
        Task { do { once.resume(.success(try await body())) } catch { once.resume(.failure(error)) } }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            once.resume(.failure(HostClientError.timeout(what)))
        }
    }
}

private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var c: CheckedContinuation<T, Error>?
    init(_ c: CheckedContinuation<T, Error>) { self.c = c }
    func resume(_ r: Result<T, Error>) {
        lock.lock(); let cc = c; c = nil; lock.unlock()
        cc?.resume(with: r)
    }
}
