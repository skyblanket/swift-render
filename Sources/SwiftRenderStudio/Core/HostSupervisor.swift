import Foundation
import Observation
import SwiftRenderKit

// MARK: - Host supervisor
//
// Starts the render host, swaps it blue/green after each successful build, and
// restarts it after crashes.
//
//   build ok (gen N) → spawn B → B ready → open(current params) → frame(t_now)
//   → viewer shows B's frame; all traffic goes to B → A: shutdown (SIGTERM 1 s, SIGKILL 3 s)
//   If B fails to open (scene renamed, props decode error), keep A and report
//   "showing gen N-1 — gen N: <error>".
//
// The linker writes a new file and renames it into place, so the running host A
// keeps its old mapped binary. A crash shows the crash card, poisons t ±1 frame
// for this generation, and restarts with backoff 0.5 / 1 / 2 s (3 attempts).

@MainActor @Observable
final class HostSupervisor {
    enum State: Equatable {
        case idle
        case starting
        case ready(pid: Int32)
        case swapping
        case crashed(HostCrash)
        case failed(String)
    }

    /// Creates a host for an executable (`HostClient`, or `FakeHostClient` in fake mode).
    typealias Factory = @MainActor (_ executable: URL, _ generation: Int) throws -> RenderHost

    let project: Project
    private(set) var state: State = .idle
    @ObservationIgnored private(set) var active: RenderHost?
    /// Build generation the active host was built from.
    private(set) var generation = 0
    private(set) var scenes: [SceneSummary] = []
    private(set) var info: SceneInfo?
    private(set) var hostVersion: String?
    /// Last crash, shown as a card until dismissed or the next good build.
    var crash: HostCrash?
    /// "gen 43: unknownScene: no scene Foo" — the swap that didn't take.
    private(set) var swapError: String?
    private(set) var restarts = 0
    /// Recent host log lines (stderr is separate; these are `log`/`warning` events).
    private(set) var log: [String] = []

    /// Current open params; `reopen` updates them.
    @ObservationIgnored private(set) var openParams = HostParams()
    @ObservationIgnored var makeHost: Factory
    @ObservationIgnored private var executable: URL?
    @ObservationIgnored private var crashAttempts = 0
    /// Frames that crashed a host of the current build: never asked for again (warm
    /// frames included) until a new build swaps in.
    @ObservationIgnored private(set) var poisoned: Set<Int> = []
    /// Playback position, for warm frames and crash locations.
    @ObservationIgnored var currentTime: () -> Double = { 0 }
    @ObservationIgnored var warmWidth: () -> Int = { 960 }
    /// Active host changed (start, swap, restart, reopen): playback re-attaches.
    @ObservationIgnored var onActiveHost: ((RenderHost?, SceneInfo?, DecodedFrame?) -> Void)?
    /// Unsolicited `info` / `audio` events from the active host.
    @ObservationIgnored var onEvent: ((HostMessage) -> Void)?
    /// A crash poisoned this frame index.
    @ObservationIgnored var onPoison: ((Int) -> Void)?

    static let backoff: [Double] = [0.5, 1, 2]

    init(project: Project, makeHost: @escaping Factory) {
        self.project = project
        self.makeHost = makeHost
    }

    static func realFactory(project: Project) -> Factory {
        { exe, _ in try HostClient(executable: exe, project: project, environment: HostClient.hostEnvironment(project: project)) }
    }

    var pid: Int32? { if case .ready(let p) = state { return p }; return active?.pid }

    // MARK: Lifecycle

    /// Start a host from `exe` (first build). `open.scene == nil` only lists scenes.
    func start(_ exe: URL, generation gen: Int, open params: HostParams) async {
        executable = exe
        openParams = params
        state = .starting
        do {
            let (host, info, warm) = try await launch(exe, generation: gen, params: params)
            install(host, generation: gen, info: info, warm: warm)
        } catch {
            state = .failed(Self.describe(error))
        }
    }

    /// Blue/green swap to a freshly built executable.
    func swap(to exe: URL, generation gen: Int) async {
        guard let old = active else {
            await start(exe, generation: gen, open: openParams)
            return
        }
        let previous = state
        state = .swapping
        do {
            let (host, info, warm) = try await launch(exe, generation: gen, params: openParams)
            executable = exe
            crash = nil
            swapError = nil
            crashAttempts = 0
            poisoned = []
            install(host, generation: gen, info: info, warm: warm)
            Task { await old.shutdown() }
        } catch {
            swapError = "gen \(gen): \(Self.describe(error))"
            state = previous == .swapping ? .ready(pid: old.pid) : previous
        }
    }

    /// Open another scene / params on the active host.
    @discardableResult
    func reopen(_ p: HostParams) async throws -> SceneInfo? {
        openParams = p
        guard let host = active, p.scene != nil else { return nil }
        let info = try await host.open(p)
        self.info = info
        onActiveHost?(host, info, nil)
        return info
    }

    /// Re-probe after a knob/props change (the engine invalidates its frames).
    func apply(_ method: HostMethod, _ p: HostParams) async throws -> SceneInfo? {
        guard let host = active else { return nil }
        let reply = try await host.call(method, p)
        if let i = reply.result.info { info = i }
        if method == .setKnobs { openParams.knobs = p.knobs }       // the complete set, like the host
        if method == .setProps { openParams.propsJSON = p.propsJSON }
        return reply.result.info
    }

    func shutdown() async {
        let h = active
        active = nil
        state = .idle
        await h?.shutdown()
    }

    /// The viewer saw no answer for too long: kill and restart (counts as a crash).
    func reportHang(at t: Double) {
        guard let h = active else { return }
        crash = HostCrash(message: "Scene is slow or hung at \(ReviewComment.format(t))", location: nil,
                          symbol: nil, report: "", t: t, signal: nil)
        h.kill()
    }

    // MARK: Internals

    private func launch(_ exe: URL, generation gen: Int, params: HostParams) async throws
        -> (RenderHost, SceneInfo?, DecodedFrame?) {
        let host = try makeHost(exe, gen)
        do {
            let ready = try await host.waitUntilReady(timeout: 20)
            scenes = ready.scenes ?? scenes
            hostVersion = ready.version
            var info: SceneInfo?
            var warm: DecodedFrame?
            if params.scene != nil {
                info = try await host.open(params)
                let t = min(currentTime(), info?.duration ?? 0)
                if !poisoned.contains(frameIndex(t, fps: info?.fps ?? 60)) {
                    warm = try? await withTimeout(5, "warm frame") { [w = warmWidth()] in
                        try await host.frame(t: t, maxWidth: w, format: .jpeg)
                    }
                }
            }
            return (host, info, warm)
        } catch {
            await host.shutdown()
            throw error
        }
    }

    private func install(_ host: RenderHost, generation gen: Int, info: SceneInfo?, warm: DecodedFrame?) {
        active = host
        generation = gen
        if let info { self.info = info }
        state = .ready(pid: host.pid)
        onActiveHost?(host, info ?? self.info, warm)
        watch(host)
    }

    private func watch(_ host: RenderHost) {
        Task { [weak self] in
            for await msg in host.events {
                guard let self, self.active === host else { continue }
                if let m = msg.message, msg.event == "log" || msg.event == "warning" {
                    self.log.append(m)
                    if self.log.count > 500 { self.log.removeFirst(self.log.count - 500) }
                }
                if msg.event == "info", let i = msg.info { self.info = i }
                self.onEvent?(msg)
            }
        }
        Task { [weak self] in
            let term = await host.waitForExit()
            guard let self, self.active === host else { return }
            if term.requested && self.crash == nil { return }
            await self.handleExit(term, host: host)
        }
    }

    private func handleExit(_ term: HostTermination, host: RenderHost) async {
        let t = currentTime()
        var c = RuntimeDiagnostics.parse(stderr: term.stderrTail, projectRoot: project.root,
                                         signal: term.uncaughtSignal ? term.status : nil)
        if let hang = crash, hang.report.isEmpty, term.requested { c.message = hang.message }   // our own kill
        else if !term.uncaughtSignal { c.message = "Host exited (status \(term.status))" + (term.stderrTail.isEmpty ? "" : ": \(lastLine(term.stderrTail))") }
        c.t = t
        crash = c
        state = .crashed(c)
        let fps = info?.fps ?? openParams.fps ?? 60
        let f = frameIndex(t, fps: fps)
        for p in (f - 1)...(f + 1) { poisoned.insert(p); onPoison?(p) }
        active = nil
        onActiveHost?(nil, info, nil)

        guard crashAttempts < Self.backoff.count, let exe = executable else {
            state = .failed("Host keeps crashing — fix the scene and rebuild")
            return
        }
        let delay = Self.backoff[crashAttempts]
        crashAttempts += 1
        try? await Task.sleep(for: .seconds(delay))
        restarts += 1
        do {
            let (h, info, warm) = try await launch(exe, generation: generation, params: openParams)
            install(h, generation: generation, info: info, warm: warm)
        } catch {
            state = .failed(Self.describe(error))
        }
    }

    private func lastLine(_ s: String) -> String {
        s.split(separator: "\n").last.map(String.init) ?? ""
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? HostClientError { return e.description }
        return "\(error)"
    }
}
