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
// keeps its old mapped binary. A crash shows the crash card, poisons the crashing
// frame ±1 for this generation (the host's `fatal … while: frame X t=…` breadcrumb,
// else the playhead), and restarts with backoff 0.5 / 1 / 2 s (3 attempts).
//
// Lifecycle operations (start, swap, crash restart) run one at a time on a serial
// chain, and each re-checks after every await whether it is still wanted: a newer
// build queued behind it, a shutdown, or (for a restart) any start/swap/install since
// the crash makes it shut down the host it just launched instead of installing it.
// Install always retires whatever host is active at that moment, so no `serve`
// process is ever left without an owner. Opens, knob and props changes that land
// while a host is launching are replayed on it before it goes live.

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
    /// A new build went live: its poison set starts empty.
    @ObservationIgnored var onPoisonCleared: (() -> Void)?

    static let defaultBackoff: [Double] = [0.5, 1, 2]
    /// Crash-restart delays; one restart per entry until the next good build (tests shorten it).
    @ObservationIgnored var backoff = HostSupervisor.defaultBackoff

    // Lifecycle serialization (see the header).
    /// Tail of the serial chain of start / swap / restart operations.
    @ObservationIgnored private var lifecycle: Task<Void, Never>?
    /// Bumped by every build request, install and shutdown: a crash restart scheduled
    /// before one of those is moot.
    @ObservationIgnored private var epoch = 0
    /// Newest build generation asked for; an older one still queued or launching is dropped.
    @ObservationIgnored private var newestBuild = 0
    /// `shutdown()` ran: nothing is ever installed again.
    @ObservationIgnored private(set) var closed = false
    @ObservationIgnored private var restartTask: Task<Void, Never>?
    /// `start` was called; later builds go through `swap`, which queues behind it.
    @ObservationIgnored private(set) var hasStarted = false

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
        hasStarted = true
        openParams = params
        await requestBuild(exe, generation: gen)
    }

    /// Blue/green swap to a freshly built executable (a start when no host is running,
    /// e.g. after a crash). Queues behind any start / swap / restart still in flight.
    func swap(to exe: URL, generation gen: Int) async {
        await requestBuild(exe, generation: gen)
    }

    private func requestBuild(_ exe: URL, generation gen: Int) async {
        guard !closed else { return }
        newestBuild = max(newestBuild, gen)
        epoch += 1                       // a pending crash restart would replace this build's host
        restartTask?.cancel()
        restartTask = nil
        await serialized { [weak self] in await self?.transition(exe, generation: gen) }
    }

    /// Runs `op` after every lifecycle operation queued before it.
    private func serialized(_ op: @escaping @MainActor () async -> Void) async {
        let previous = lifecycle
        let task = Task { @MainActor in
            await previous?.value
            await op()
        }
        lifecycle = task
        await task.value
    }

    private func transition(_ exe: URL, generation gen: Int) async {
        // A newer build is queued behind this one: let that one go live instead.
        guard !closed, gen == newestBuild else { return }
        state = active == nil ? .starting : .swapping
        do {
            let launched = try await launch(exe, generation: gen)
            guard !closed, gen == newestBuild else {
                await launched.host.shutdown()
                settleState()
                return
            }
            executable = exe
            install(launched, generation: gen, newBuild: true)
        } catch {
            guard !closed else { return }
            if let a = active {
                swapError = "gen \(gen): \(Self.describe(error))"
                state = .ready(pid: a.pid)
            } else if case .crashed = state {
                // The old build crashed meanwhile; its pending restart brings it back.
                swapError = "gen \(gen): \(Self.describe(error))"
            } else {
                state = .failed(Self.describe(error))
            }
        }
    }

    private func settleState() {
        if let a = active { state = .ready(pid: a.pid) }
        else if state == .starting || state == .swapping { state = .idle }
    }

    /// Open another scene / params on the active host.
    @discardableResult
    func reopen(_ p: HostParams) async throws -> SceneInfo? {
        openParams = p                                       // a host launching now replays these
        guard let host = active, p.scene != nil else { return nil }
        do {
            let info = try await host.open(p)
            // Swapped out while this was in flight: the new host opened with `openParams`
            // before it went live, and its info is current. Never re-attach the retired one.
            guard host === active else { return active == nil ? nil : self.info }
            self.info = info
            onActiveHost?(host, info, nil)
            return info
        } catch {
            if host !== active, active != nil { return self.info }
            throw error
        }
    }

    /// Re-probe after a knob/props change (the engine invalidates its frames).
    func apply(_ method: HostMethod, _ p: HostParams) async throws -> SceneInfo? {
        let before = openParams
        // Recorded first, so a host launching (or restarting) right now picks them up too.
        if method == .setKnobs { openParams.knobs = p.knobs }       // the complete set, like the host
        if method == .setProps { openParams.propsJSON = p.propsJSON }
        guard let host = active else { return nil }
        do {
            let reply = try await host.call(method, p)
            guard host === active else { return active == nil ? nil : info }
            if let i = reply.result.info { info = i }
            return reply.result.info
        } catch {
            if host !== active, active != nil { return info }
            // Not applied (bad props JSON…): the next host shouldn't open with it either.
            if method == .setKnobs, openParams.knobs == p.knobs { openParams.knobs = before.knobs }
            if method == .setProps, openParams.propsJSON == p.propsJSON { openParams.propsJSON = before.propsJSON }
            throw error
        }
    }

    /// Window closing: stop the active host. A host still launching is shut down
    /// instead of installed, and no crash restart runs afterwards.
    func shutdown() async {
        closed = true
        epoch += 1
        restartTask?.cancel()
        restartTask = nil
        let h = active
        active = nil
        state = .idle
        await h?.shutdown()
    }

    /// The viewer saw no answer for too long: kill and restart (counts as a crash).
    /// `host`: the host the request went to — a stale timeout from a host that has
    /// since been swapped out must not kill its successor.
    func reportHang(at t: Double, host: RenderHost? = nil) {
        guard let h = active, host == nil || host === h else { return }
        crash = HostCrash(message: "Scene is slow or hung at \(ReviewComment.format(t))", location: nil,
                          symbol: nil, report: "", t: t, signal: nil)
        h.kill()
    }

    // MARK: Internals

    private struct Launched {
        var host: RenderHost
        var ready: HostMessage
        var info: SceneInfo?
        var warm: DecodedFrame?
    }

    private struct Closed: Error {}

    private func launch(_ exe: URL, generation gen: Int) async throws -> Launched {
        var used = openParams
        let host = try makeHost(exe, gen)
        do {
            let ready = try await host.waitUntilReady(timeout: 20)
            if closed { throw Closed() }
            var info: SceneInfo?
            var warm: DecodedFrame?
            if used.scene != nil {
                info = try await host.open(used)
                if closed { throw Closed() }
                let t = min(currentTime(), info?.duration ?? 0)
                if !poisoned.contains(frameIndex(t, fps: info?.fps ?? 60)) {
                    warm = try? await withTimeout(5, "warm frame") { [w = warmWidth()] in
                        try await host.frame(t: t, maxWidth: w, format: .jpeg)
                    }
                }
            }
            // A scene pick, aspect, knob or props change landed while this host started (the
            // old host took it, or nobody did): replay it here before going live.
            while openParams != used {
                used = openParams
                warm = nil
                if used.scene != nil { info = try await host.open(used) }
                if closed { throw Closed() }
            }
            return Launched(host: host, ready: ready, info: info, warm: warm)
        } catch {
            await host.shutdown()
            throw error
        }
    }

    /// Makes `launched` the active host and retires whatever was active until now.
    /// `newBuild`: a fresh generation — the crash card, restart budget and poison set
    /// belonged to the old build.
    private func install(_ launched: Launched, generation gen: Int, newBuild: Bool) {
        let host = launched.host
        let old = active
        if newBuild {
            crash = nil
            swapError = nil
            crashAttempts = 0
            poisoned = []
            onPoisonCleared?()
        }
        restartTask?.cancel()
        restartTask = nil
        epoch += 1
        scenes = launched.ready.scenes ?? scenes
        hostVersion = launched.ready.version
        active = host
        generation = gen
        if let info = launched.info { self.info = info }
        state = .ready(pid: host.pid)
        onActiveHost?(host, launched.info ?? self.info, launched.warm)
        watch(host)
        if let old, old !== host { Task { await old.shutdown() } }
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
            self.handleExit(term, host: host)
        }
    }

    private func handleExit(_ term: HostTermination, host: RenderHost) {
        var c = RuntimeDiagnostics.parse(stderr: term.stderrTail, projectRoot: project.root,
                                         signal: term.uncaughtSignal ? term.status : nil)
        // The host's breadcrumb names the frame that died. While playing, the stream runs
        // up to a second ahead of the playhead, so the playhead is only a fallback.
        var t = c.t ?? currentTime()
        if let hang = crash, hang.report.isEmpty, term.requested {           // our own kill
            c.message = hang.message
            t = hang.t ?? t
        } else if !term.uncaughtSignal {
            c.message = "Host exited (status \(term.status))" + (term.stderrTail.isEmpty ? "" : ": \(lastLine(term.stderrTail))")
        }
        c.t = t
        crash = c
        state = .crashed(c)
        let fps = info?.fps ?? openParams.fps ?? 60
        let f = frameIndex(t, fps: fps)
        for p in (f - 1)...(f + 1) { poisoned.insert(p); onPoison?(p) }
        active = nil
        onActiveHost?(nil, info, nil)

        guard crashAttempts < backoff.count, executable != nil else {
            state = .failed("Host keeps crashing — fix the scene and rebuild")
            return
        }
        let delay = backoff[crashAttempts]
        crashAttempts += 1
        let token = epoch
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            await self.serialized { [weak self] in await self?.restart(token: token) }
        }
    }

    /// The crash restart — unless a build, install or shutdown happened since the crash.
    private func restart(token: Int) async {
        guard !closed, epoch == token, active == nil, let exe = executable else { return }
        restarts += 1
        do {
            let launched = try await launch(exe, generation: generation)
            guard !closed, epoch == token, active == nil else {
                await launched.host.shutdown()
                return
            }
            install(launched, generation: generation, newBuild: false)
        } catch {
            guard !closed, epoch == token, active == nil else { return }
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
