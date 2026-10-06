import CoreGraphics
import CoreText
import Foundation
import SwiftRenderKit

// MARK: - FakeHost
//
// An in-process `RenderHost` that draws gradient + timecode frames with CoreGraphics
// and serves a synthetic `SceneInfo` (nested clips, every score lane, knobs, captions,
// loudness), so UI and playback work never waits on the real `serve` host.
// It mimics the host's semantics that matter to Studio: one render at a time, older
// queued `frame` requests answered `superseded`, streams that render only while they
// hold credit, simulated render cost, and an optional crash at a given time.

final class FakeHostClient: RenderHost, @unchecked Sendable {
    struct Options: Sendable {
        /// Simulated render + encode time per frame (StyleLab gets ×6).
        var renderMs: Double = 4
        /// Shown in the frame so a host swap is visible.
        var generation: Int = 1
        /// Crash (like a scene `fatalError`) when asked to render within half a frame of this time.
        var crashAt: Double? = nil
        /// Called with the crash report instead of a simulated exit (`--fake-serve` aborts).
        var onCrash: (@Sendable (String) -> Void)? = nil
        /// `open` fails with this message (renamed scene, props decode error…).
        var failOpen: String? = nil
        var startupDelay: Double = 0.05
        var projectRoot: URL = URL(fileURLWithPath: "/tmp/FakeProject")
    }

    /// Counters for scheduling tests.
    struct Stats: Sendable, Equatable {
        var frameRequests = 0
        var rendered = 0
        var superseded = 0
        var streamFrames = 0
        var streamsOpened = 0
        var creditsGranted = 0
        /// Most stream frames ever sent but not yet credited back (bounded by the window).
        var maxOutstanding = 0
    }

    static let pidBase: Int32 = 90_000
    private static var pidCounter: Int32 = 0

    let options: Options
    let pid: Int32
    var supportsBinaryFrames: Bool { true }
    let events: AsyncStream<HostMessage>
    private let eventsCont: AsyncStream<HostMessage>.Continuation

    private let lock = NSLock()
    private let wake = DispatchSemaphore(value: 0)
    private var frameInbox: [(params: HostParams, cont: CheckedContinuation<HostReply, Error>)] = []
    private var streams: [Int: StreamState] = [:]
    private var nextStreamID = 1
    private var session: Session?
    private var exited: HostTermination?
    private var exitWaiters: [CheckedContinuation<HostTermination, Never>] = []
    private var _stats = Stats()
    private var knobOverrides: [String: KnobValue] = [:]

    private struct Session {
        var scene: String
        var width: Int, height: Int, fps: Int
        var duration: Double
        var propsJSON: String?
    }

    private struct StreamState {
        var next: Double
        var step: Double
        var to: Double
        var credits: Int
        var outstanding: Int
        var maxWidth: Int
        var format: FrameFormat
        var cont: AsyncThrowingStream<DecodedFrame, Error>.Continuation
    }

    var stats: Stats { lock.lock(); defer { lock.unlock() }; return _stats }

    init(options: Options = Options()) {
        self.options = options
        Self.pidCounter += 1
        pid = Self.pidBase + Self.pidCounter
        (events, eventsCont) = AsyncStream.makeStream(of: HostMessage.self, bufferingPolicy: .bufferingNewest(256))
        let t = Thread { [weak self] in self?.renderLoop() }
        t.name = "studio.fakehost"
        t.qualityOfService = .userInitiated
        t.start()
    }

    // MARK: Catalogue

    static let scenes: [SceneSummary] = [
        SceneSummary(name: "LaunchFilm", kind: .render, defaultDuration: 24, hasSoundtrack: true, hasProps: false),
        SceneSummary(name: "NeverHeard", kind: .audio, defaultDuration: 33, hasSoundtrack: true, hasProps: false),
        SceneSummary(name: "RepoPromo", kind: .render, defaultDuration: 18, hasSoundtrack: true, hasProps: false),
        SceneSummary(name: "StyleLab", kind: .render, defaultDuration: 40, hasSoundtrack: false, hasProps: false),
        SceneSummary(name: "JETRAYChase", kind: .props, defaultDuration: 12, hasSoundtrack: false, hasProps: true),
    ]

    static func info(scene: String, width: Int = 1920, height: Int = 1080, fps: Int = 60,
                     duration: Double? = nil, knobs overrides: [String: KnobValue] = [:],
                     projectRoot: URL = URL(fileURLWithPath: "/tmp/FakeProject"),
                     propsJSON: String? = nil) -> SceneInfo {
        let summary = scenes.first { $0.name == scene }
            ?? SceneSummary(name: scene, kind: .render, defaultDuration: 10, hasSoundtrack: false, hasProps: false)
        let d = duration ?? summary.defaultDuration
        let file = projectRoot.appendingPathComponent("Sources/SwiftRender/Scenes/\(scene).swift").path
        func src(_ line: Int) -> SourceLocation { SourceLocation(file: file, line: line) }

        // Top-level clips: six beats with a fade into the fifth; two nested clips in the third.
        let labels = ["hook", "title", "cards", "pureFn", "springs", "outro"]
        let unit = d / Double(labels.count)
        var clips: [ClipInfo] = labels.enumerated().map { i, label in
            let start = Double(i) * unit
            return ClipInfo(id: "0:\(start):\(40 + i * 12)", label: label, start: start, end: start + unit,
                            depth: 0, pinned: false, transitionIn: i == 4 ? "fade" : "cut",
                            transitionDuration: i == 4 ? 0.4 : 0, source: src(40 + i * 12))
        }
        let cardsStart = 2 * unit
        for j in 0..<3 {
            let s = cardsStart + Double(j) * unit / 3
            clips.append(ClipInfo(id: "1:\(s):\(70 + j * 4)", label: "card\(j)", start: s, end: s + unit / 3,
                                  depth: 1, pinned: false, transitionIn: "slide", transitionDuration: 0.2,
                                  source: src(70 + j * 4)))
        }
        clips.append(ClipInfo(id: "0:0:30", label: "hud", start: 0, end: d, depth: 0, pinned: true,
                              transitionIn: "cut", transitionDuration: 0, source: src(30)))

        var events: [ScoreEventInfo] = []
        var beat = 0.0
        while beat < d {
            events.append(ScoreEventInfo(lane: "drums", kind: Int(beat * 2) % 4 == 0 ? "kick" : "hat",
                                         detail: nil, time: beat, duration: 0.1, amp: 0.8))
            beat += 0.5
        }
        for (i, start) in stride(from: 0.0, to: d, by: unit).enumerated() {
            events.append(ScoreEventInfo(lane: "melodic", kind: "pad", detail: ["Am9", "Fmaj7", "Cmaj7", "G6"][i % 4],
                                         time: start, duration: unit * 0.9, amp: 0.5))
            events.append(ScoreEventInfo(lane: "mark", kind: i % 2 == 0 ? "swell" : "thump", detail: nil,
                                         time: start, duration: 0.3, amp: 0.7))
            events.append(ScoreEventInfo(lane: "melodic", kind: "bell", detail: "E5", time: start + unit * 0.5,
                                         duration: 0.6, amp: 0.4))
        }
        events.append(ScoreEventInfo(lane: "sample", kind: "sample", detail: "card_1.wav", time: cardsStart + 0.2,
                                     duration: 0.8, amp: 0.6))
        events.append(ScoreEventInfo(lane: "fx", kind: "whoosh", detail: nil, time: 4 * unit - 0.3, duration: 0.6, amp: 0.5))

        let lines = ["I wrote four soundtracks this year.", "I have never heard them.",
                     "When I check my music, it's silence.", "So I built an ear."]
        var captions: [CaptionInfo] = []
        for (i, text) in lines.enumerated() {
            let s = 1.0 + Double(i) * d / 4.5
            captions.append(CaptionInfo(start: s, end: s + 2.6, text: text))
            events.append(ScoreEventInfo(lane: "speech", kind: "speak", detail: text, time: s, duration: 2.4, amp: 0.9))
        }

        func knob(_ key: String, _ kind: KnobInfo.Kind, _ def: KnobValue, _ min: Double? = nil, _ max: Double? = nil,
                  line: Int) -> KnobInfo {
            KnobInfo(key: key, kind: kind, defaultValue: def, value: overrides[key] ?? def, min: min, max: max, source: src(line))
        }
        let knobs = [
            knob("title.delay", .double, .number(0.4), 0, 2, line: 52),
            knob("logo.scale", .double, .number(1.0), 0.5, 2, line: 61),
            knob("grain", .bool, .bool(true), line: 88),
            knob("headline", .text, .string("Never heard"), line: 95),
            knob("accent", .color, .string("#FFC75C"), line: 97),
        ]

        let rate = 50.0
        let loudness: [Float] = (0..<Int(d * rate)).map { i in
            let t = Double(i) / rate
            let env = 0.45 + 0.35 * sin(t * 0.7) * sin(t * 0.23 + 1)
            let pulse = 0.25 * max(0, sin(t * .pi * 4))
            let gap = (t.truncatingRemainder(dividingBy: unit) > unit - 0.6) ? 0.1 : 1.0
            return Float(max(0, min(1, (env + pulse) * gap)))
        }

        let props = summary.hasProps
            ? (propsJSON ?? "{\n  \"title\" : \"JETRAY\",\n  \"speed\" : 0.85,\n  \"showGrid\" : true\n}")
            : nil
        return SceneInfo(name: scene, kind: summary.kind, duration: d, width: width, height: height, fps: fps,
                         clips: clips, events: events.sorted { $0.time < $1.time }, knobs: knobs,
                         captions: captions, propsJSON: props, audioPath: nil, loudness: loudness,
                         loudnessRate: rate, sourcePath: file)
    }

    // MARK: RenderHost

    func waitUntilReady(timeout: Double) async throws -> HostMessage {
        try await Task.sleep(for: .seconds(options.startupDelay))
        if let e = currentExit() { throw HostClientError.exited("exit \(e.status)") }
        return .ready(scenes: Self.scenes, version: "fake-\(options.generation)")
    }

    func call(_ method: HostMethod, _ params: HostParams?) async throws -> HostReply {
        if let e = currentExit() { throw HostClientError.exited("exit \(e.status)") }
        let p = params ?? HostParams()
        switch method {
        case .list:
            return HostReply(result: HostResult(scenes: Self.scenes))
        case .open:
            if let why = options.failOpen { throw HostClientError.host(HostError(code: "unknownScene", message: why)) }
            guard let scene = p.scene, Self.scenes.contains(where: { $0.name == scene }) else {
                throw HostClientError.host(HostError(code: "unknownScene", message: "no scene \(p.scene ?? "nil")"))
            }
            let d = p.duration ?? Self.scenes.first { $0.name == scene }!.defaultDuration
            lock.withLock {
                session = Session(scene: scene, width: p.width ?? 1920, height: p.height ?? 1080, fps: p.fps ?? 60,
                                  duration: d, propsJSON: p.propsJSON)
                knobOverrides = p.knobs ?? [:]
            }
            return HostReply(result: HostResult(info: currentInfo()))
        case .setKnobs:
            lock.withLock { knobOverrides = p.knobs ?? [:] }        // the complete set, like the real host
            return HostReply(result: HostResult(info: currentInfo()))
        case .setProps:
            lock.withLock { session?.propsJSON = p.propsJSON }
            return HostReply(result: HostResult(info: currentInfo()))
        case .frame:
            return try await withCheckedThrowingContinuation { c in
                lock.lock()
                _stats.frameRequests += 1
                frameInbox.append((p, c))
                lock.unlock()
                wake.signal()
            }
        case .still:
            let f = try await frame(t: p.t ?? 0, maxWidth: p.maxWidth ?? 1920, format: .png)
            guard let path = p.path, let data = FrameDecoder.encode(f.image, format: .png) else {
                throw HostClientError.host(HostError(code: "badParams", message: "still needs path"))
            }
            try data.write(to: URL(fileURLWithPath: path))
            return HostReply(result: HostResult(path: path))
        case .check:
            return HostReply(result: HostResult(path: p.path, report: ["frames: no blank samples (fake host)",
                                                                       "audio: none (fake host)"]))
        case .stream, .credit, .cancel:
            throw HostClientError.protocolError("use openStream")
        case .shutdown:
            finish(HostTermination(status: 0, uncaughtSignal: false, stderrTail: "", requested: true))
            return HostReply(result: HostResult())
        }
    }

    func frame(t: Double, maxWidth: Int, format: FrameFormat) async throws -> DecodedFrame {
        let reply = try await call(.frame, HostParams(t: t, maxWidth: maxWidth, format: format.rawValue))
        guard let f = reply.result.frame else { throw HostClientError.protocolError("no frame") }
        return try FrameDecoder.decode(f, payload: reply.payload, fps: fps)
    }

    func openStream(from: Double, to: Double?, fps streamFPS: Int, maxWidth: Int, format: FrameFormat,
                    credits: Int) async throws -> HostFrameStream {
        if let e = currentExit() { throw HostClientError.exited("exit \(e.status)") }
        let (frames, cont) = AsyncThrowingStream.makeStream(of: DecodedFrame.self)
        let id: Int = lock.withLock {
            let id = nextStreamID; nextStreamID += 1
            let end = min(to ?? .infinity, session?.duration ?? 0)
            streams[id] = StreamState(next: from, step: 1 / Double(max(1, streamFPS)), to: end, credits: credits,
                                      outstanding: 0, maxWidth: maxWidth, format: format, cont: cont)
            _stats.streamsOpened += 1
            return id
        }
        wake.signal()
        return HostFrameStream(id: id, frames: frames, grant: { [weak self] n in
            guard let self else { return }
            self.lock.lock()
            if self.streams[id] != nil {
                self.streams[id]!.credits += n
                self.streams[id]!.outstanding = max(0, self.streams[id]!.outstanding - n)
                self._stats.creditsGranted += n
            }
            self.lock.unlock()
            self.wake.signal()
        }, stop: { [weak self] in
            guard let self else { return }
            self.lock.lock(); let s = self.streams.removeValue(forKey: id); self.lock.unlock()
            s?.cont.finish()
        })
    }

    func shutdown() async {
        finish(HostTermination(status: 0, uncaughtSignal: false, stderrTail: "", requested: true))
    }

    func kill() {
        finish(HostTermination(status: 9, uncaughtSignal: true, stderrTail: "", requested: true))
    }

    func waitForExit() async -> HostTermination {
        await withCheckedContinuation { c in
            lock.lock()
            if let e = exited { lock.unlock(); c.resume(returning: e); return }
            exitWaiters.append(c)
            lock.unlock()
        }
    }

    // MARK: Internals

    private var fps: Int { lock.lock(); defer { lock.unlock() }; return session?.fps ?? 60 }
    /// The open scene's fps (a `stream` without `fps` runs at it, like the real host).
    var sessionFPS: Int { fps }

    private func currentExit() -> HostTermination? { lock.lock(); defer { lock.unlock() }; return exited }
    /// The session ended (shutdown, kill or crash).
    var hasExited: Bool { currentExit() != nil }

    private func currentInfo() -> SceneInfo? {
        lock.lock(); let s = session, k = knobOverrides; lock.unlock()
        guard let s else { return nil }
        return Self.info(scene: s.scene, width: s.width, height: s.height, fps: s.fps, duration: s.duration,
                         knobs: k, projectRoot: options.projectRoot, propsJSON: s.propsJSON)
    }

    private func finish(_ t: HostTermination) {
        lock.lock()
        guard exited == nil else { lock.unlock(); return }
        exited = t
        let inbox = frameInbox; frameInbox = []
        let ss = streams.values; streams = [:]
        let ws = exitWaiters; exitWaiters = []
        lock.unlock()
        let err = HostClientError.exited(t.uncaughtSignal ? "signal \(t.status)" : "exit \(t.status)")
        inbox.forEach { $0.cont.resume(throwing: err) }
        ss.forEach { $0.cont.finish(throwing: err) }
        ws.forEach { $0.resume(returning: t) }
        eventsCont.finish()
        wake.signal()
    }

    private enum Work {
        case frame(HostParams, CheckedContinuation<HostReply, Error>)
        case stream(Int, StreamState)
    }

    /// One render at a time, newest frame request first, then streams with credit.
    private func renderLoop() {
        while true {
            lock.lock()
            if exited != nil { lock.unlock(); return }
            var work: Work?
            if let newest = frameInbox.last {
                let older = frameInbox.dropLast()
                frameInbox = []
                _stats.superseded += older.count
                lock.unlock()
                for o in older {
                    o.cont.resume(throwing: HostClientError.host(HostError(code: "superseded", message: "newer frame queued")))
                }
                lock.lock()
                work = .frame(newest.params, newest.cont)
            } else if let entry = streams.first(where: { $0.value.credits > 0 && $0.value.next <= $0.value.to }) {
                let id = entry.key, s = entry.value
                streams[id]!.credits -= 1
                streams[id]!.outstanding += 1
                streams[id]!.next += s.step
                _stats.maxOutstanding = max(_stats.maxOutstanding, streams[id]!.outstanding)
                work = .stream(id, s)
            }
            let sess = session
            lock.unlock()

            guard let work else { wake.wait(); continue }
            switch work {
            case .frame(let p, let c):
                let t = p.t ?? 0
                if crashes(at: t, fps: sess?.fps ?? 60) { crash(t: t, scene: sess?.scene ?? "Scene"); c.resume(throwing: HostClientError.exited("signal 5")); return }
                let fmt = FrameFormat(rawValue: p.format ?? "jpeg") ?? .jpeg
                let (frame, payload) = render(t: t, maxWidth: p.maxWidth ?? 960, format: fmt, session: sess)
                lock.lock(); _stats.rendered += 1; lock.unlock()
                c.resume(returning: HostReply(result: HostResult(frame: frame), payload: payload))
            case .stream(let id, let s):
                let t = s.next
                if crashes(at: t, fps: sess?.fps ?? 60) { crash(t: t, scene: sess?.scene ?? "Scene"); return }
                let (frame, payload) = render(t: t, maxWidth: s.maxWidth, format: s.format, session: sess)
                lock.lock()
                _stats.rendered += 1; _stats.streamFrames += 1
                let live = streams[id] != nil
                lock.unlock()
                if live, let d = try? FrameDecoder.decode(frame, payload: payload, fps: sess?.fps ?? 60) {
                    s.cont.yield(d)
                }
            }
        }
    }

    private func crashes(at t: Double, fps: Int) -> Bool {
        guard let c = options.crashAt else { return false }
        return abs(t - c) <= 0.5 / Double(fps)
    }

    private func crash(t: Double, scene: String) {
        let file = options.projectRoot.appendingPathComponent("Sources/SwiftRender/Scenes/\(scene).swift").path
        let tail = """
        Swift/ContiguousArrayBuffer.swift:691: Fatal error: Index out of range
        [swift-render serve] fatal SIGTRAP while: frame \(scene) t=\(t)

        💣 Program crashed: System trap at 0x000000019a4c1234

        Thread 0 "main" crashed:

        0      0x000000019a4c1234 _assertionFailure(_:_:file:line:flags:) + 176 in libswiftCore.dylib
        1 [ra] 0x0000000100a3f2c8 \(scene).panel(_:_:) + 432 in swift-render at \(file):212:14
        2 [ra] 0x0000000100a3e010 \(scene).body(at:) + 88 in swift-render at \(file):180:9
        """
        options.onCrash?(tail + "\n")
        finish(HostTermination(status: 5, uncaughtSignal: true, stderrTail: tail, requested: false))
    }

    /// Draws one synthetic frame and packages it exactly as the wire would.
    private func render(t: Double, maxWidth: Int, format: FrameFormat, session: Session?) -> (HostFrame, Data?) {
        let start = DispatchTime.now()
        let sw = session?.width ?? 1920, sh = session?.height ?? 1080
        let w = max(16, min(maxWidth, sw))
        let h = max(9, Int((Double(w) * Double(sh) / Double(sw)).rounded()))
        let img = FakeFrameArt.draw(t: t, width: w, height: h, scene: session?.scene ?? "—",
                                    duration: session?.duration ?? 10, generation: options.generation)
        let cost = options.renderMs * (session?.scene == "StyleLab" ? 6 : 1)
        let spent = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
        if cost > spent { usleep(useconds_t((cost - spent) * 1000)) }
        let fps = session?.fps ?? 60
        let ms = max(cost, spent)
        switch format {
        case .bgra8:
            let bytes = FrameDecoder.bgra8Bytes(img) ?? Data()
            return (HostFrame(t: t, width: w, height: h, format: "bgra8", data: "", ms: ms,
                              index: frameIndex(t, fps: fps), bytes: bytes.count), bytes)
        case .jpeg, .png:
            let data = FrameDecoder.encode(img, format: format) ?? Data()
            return (HostFrame(t: t, width: w, height: h, format: format.rawValue, data: data.base64EncodedString(),
                              ms: ms, index: frameIndex(t, fps: fps)), nil)
        }
    }
}

/// The synthetic picture: a slowly turning gradient, a moving orb, and big timecode.
enum FakeFrameArt {
    static func draw(t: Double, width w: Int, height h: Int, scene: String, duration: Double, generation: Int) -> CGImage {
        let cs = FrameDecoder.sRGB
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        let W = CGFloat(w), H = CGFloat(h), u = W / 1920
        let phase = t / max(duration, 0.001)

        // Background gradient, hue drifting with t.
        let hue = 0.62 + 0.18 * sin(t * 0.35)
        let top = hsb(hue, 0.55, 0.20), bottom = hsb(hue + 0.12, 0.65, 0.07)
        let grad = CGGradient(colorsSpace: cs, colors: [top, bottom] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: H), end: CGPoint(x: W * 0.4, y: 0), options: [])

        // Grid.
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.05))
        ctx.setLineWidth(max(1, u))
        for i in 1..<12 { let x = W * CGFloat(i) / 12; ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: H)) }
        for i in 1..<7 { let y = H * CGFloat(i) / 7; ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: W, y: y)) }
        ctx.strokePath()

        // Orb on a Lissajous path — motion makes dropped frames visible.
        let ox = W * (0.5 + 0.36 * CGFloat(sin(t * 1.3))), oy = H * (0.5 + 0.30 * CGFloat(sin(t * 1.9 + 0.7)))
        let r = 120 * u
        let orb = CGGradient(colorsSpace: cs, colors: [hsb(0.11, 0.70, 1.0, 0.95), hsb(0.05, 0.9, 0.9, 0)] as CFArray,
                             locations: [0, 1])!
        ctx.drawRadialGradient(orb, startCenter: CGPoint(x: ox, y: oy), startRadius: 0,
                               endCenter: CGPoint(x: ox, y: oy), endRadius: r, options: [])

        // Text.
        text(ctx, scene.uppercased(), size: 34 * u, weight: .semibold, color: CGColor(gray: 1, alpha: 0.55),
             at: CGPoint(x: W / 2, y: H * 0.62), center: true, tracking: 6 * u)
        let tc = String(format: "%02d:%05.2f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
        text(ctx, tc, size: 210 * u, weight: .bold, color: CGColor(gray: 1, alpha: 0.96),
             at: CGPoint(x: W / 2, y: H * 0.42), center: true, mono: true)
        text(ctx, "f\(frameIndex(t, fps: 60))  ·  gen \(generation)  ·  FakeHost", size: 26 * u, weight: .medium,
             color: CGColor(gray: 1, alpha: 0.5), at: CGPoint(x: W / 2, y: H * 0.30), center: true, mono: true)

        // Progress rail.
        let rail = CGRect(x: W * 0.1, y: H * 0.12, width: W * 0.8, height: max(2, 6 * u))
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.12)); ctx.fill(rail)
        ctx.setFillColor(hsb(0.11, 0.7, 1.0)); ctx.fill(CGRect(x: rail.minX, y: rail.minY, width: rail.width * CGFloat(phase), height: rail.height))
        return ctx.makeImage()!
    }

    private static func hsb(_ h: Double, _ s: Double, _ b: Double, _ a: Double = 1) -> CGColor {
        let hh = (h.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * 6
        let c = b * s, x = c * (1 - abs(hh.truncatingRemainder(dividingBy: 2) - 1)), m = b - c
        let (r, g, bl): (Double, Double, Double)
        switch Int(hh) {
        case 0: (r, g, bl) = (c, x, 0)
        case 1: (r, g, bl) = (x, c, 0)
        case 2: (r, g, bl) = (0, c, x)
        case 3: (r, g, bl) = (0, x, c)
        case 4: (r, g, bl) = (x, 0, c)
        default: (r, g, bl) = (c, 0, x)
        }
        return CGColor(srgbRed: r + m, green: g + m, blue: bl + m, alpha: a)
    }

    private enum Weight { case medium, semibold, bold }

    private static func text(_ ctx: CGContext, _ s: String, size: CGFloat, weight: Weight, color: CGColor,
                             at p: CGPoint, center: Bool, mono: Bool = false, tracking: CGFloat = 0) {
        let name: CFString
        switch (mono, weight) {
        case (true, .bold): name = "Menlo-Bold" as CFString
        case (true, _): name = "Menlo-Regular" as CFString
        case (false, .bold): name = "HelveticaNeue-Bold" as CFString
        case (false, .semibold): name = "HelveticaNeue-Medium" as CFString
        case (false, .medium): name = "HelveticaNeue" as CFString
        }
        let font = CTFontCreateWithName(name, size, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            NSAttributedString.Key(kCTKernAttributeName as String): tracking,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        ctx.textPosition = CGPoint(x: center ? p.x - CGFloat(width) / 2 : p.x, y: p.y - size * 0.35)
        CTLineDraw(line, ctx)
    }
}
