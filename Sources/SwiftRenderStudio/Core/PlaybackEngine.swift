import Foundation
import Observation
import QuartzCore
import SwiftRenderKit

// MARK: - Playback engine
//
// Owns the playhead and gets pixels from the active host into the viewer.
//
// Scrubbing: one `frame` request in flight; newer seeks replace the single pending
// slot (the host also answers stale queued requests `superseded`), so a fast drag
// costs at most two renders behind the pointer. 150 ms after the playhead settles,
// the frame is re-requested at full display resolution, lossless ("sharpen on pause").
//
// Playing: the clock is the audio device clock (forward 0.5–2×) or the wall clock.
// Each display-link tick quantizes t onto the playback grid (30 fps by default),
// shows that frame from the cache or holds the nearest earlier one and counts a
// drop, and keeps a host `stream` running ahead of the clock. Credits: a window of 4,
// one returned per frame received while the stream head is < 1 s ahead, so host
// lookahead and Studio memory stay bounded. A stream > 250 ms behind the clock is
// cancelled and restarted ahead of it by ewma(ms) × window.
//
// Quality ladder (auto): budget = 0.8 × 1000 / playback fps. Over budget, step the
// requested width 100% → 50% → 33% → 25% of the viewer, then the fps 30 → 20 → 15.
//
// Generations bump on attach (open, host swap) and `invalidate()` (knobs/props);
// frames from an older generation are dropped on arrival. SwiftUI only observes
// `t`, `isPlaying`, `rate`, throttled `stats`/`cachedRanges` and
// `visibleCommentIDs` (republished only when the set changes) — the pixels go
// straight to a CALayer through `onFrame`.

enum ShuttleKey: Sendable { case j, k, l }

enum PlaybackQuality: String, CaseIterable, Identifiable, Sendable {
    case auto, full, half, third, quarter
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "Auto"
        case .full: return "Full"
        case .half: return "Half"
        case .third: return "Third"
        case .quarter: return "Quarter"
        }
    }
    /// Fixed width scale, nil for auto.
    var fixedScale: Double? {
        switch self {
        case .auto: return nil
        case .full: return 1
        case .half: return 0.5
        case .third: return 1.0 / 3
        case .quarter: return 0.25
        }
    }
}

struct PlaybackStats: Equatable, Sendable {
    /// EWMA of host render+encode ms per frame.
    var msPerFrame: Double = 0
    /// Target playback fps (quality ladder).
    var targetFPS: Int = 30
    /// Measured frames shown per second while playing.
    var shownFPS: Double = 0
    var dropped: Int = 0
    var shown: Int = 0
    var widthScale: Double = 1
    /// "StyleLab ~157 ms/frame → 15 fps preview"
    var note: String?
}

@MainActor @Observable
final class PlaybackEngine {
    // Observed state.
    private(set) var t: Double = 0
    private(set) var isPlaying = false
    private(set) var rate: Double = 1
    /// Set through `setIn`/`setOut`/`setInOut` (clamped to the scene).
    var inOut: ClosedRange<Double>?
    var loop = false
    var quality: PlaybackQuality = .auto { didSet { applyQualityChoice() } }
    private(set) var stats = PlaybackStats()
    private(set) var visibleCommentIDs: Set<String> = []
    private(set) var cachedRanges: [ClosedRange<Double>] = []
    private(set) var duration: Double = 0
    private(set) var fps: Int = 60
    private(set) var generation = 0
    private(set) var hasFrame = false
    private(set) var lastError: String?

    // Unobserved plumbing.
    @ObservationIgnored let cache: FrameCache
    @ObservationIgnored let audio = AudioPlayback()
    @ObservationIgnored var now: () -> Double = { CACurrentMediaTime() }
    /// Pixel width the viewer wants for a sharp image (set by the viewer on layout/zoom).
    @ObservationIgnored var displayWidth = 1920
    /// Where pixels go (FrameLayerView). Called on the main actor.
    @ObservationIgnored var onFrame: ((DecodedFrame) -> Void)?
    @ObservationIgnored var onPlayStateChange: ((Bool) -> Void)?
    /// A frame request got no answer in `hangTimeout` s: the playhead time and the host
    /// that was asked (it may have been swapped out since).
    @ObservationIgnored var onHang: ((Double, RenderHost) -> Void)?
    @ObservationIgnored var hangTimeout = 5.0
    @ObservationIgnored private(set) var currentFrame: DecodedFrame?
    @ObservationIgnored var sceneName = ""
    /// Comment marks for pins (`visibleCommentIDs`) and ↑/↓ edit points.
    @ObservationIgnored var commentMarks: [(id: String, t: Double, end: Double?)] = [] { didSet { updateVisibleComments() } }
    /// Clip boundaries etc. for ↑/↓.
    @ObservationIgnored var editPoints: [Double] = []
    /// Frames that crashed the host in this generation (skipped until the next build).
    @ObservationIgnored var poisoned: Set<Int> = []
    @ObservationIgnored private(set) var host: RenderHost?

    // Scrub pipeline.
    @ObservationIgnored private var scrubInFlight = false
    @ObservationIgnored private var scrubPending: FrameAsk?
    @ObservationIgnored private var sharpenTask: Task<Void, Never>?
    @ObservationIgnored private(set) var framesRequested = 0
    /// Responses that arrived for an older generation and were dropped.
    @ObservationIgnored private(set) var staleDropped = 0
    /// No single-frame request in flight or pending (tests, snapshot).
    var isRequestIdle: Bool { !scrubInFlight && scrubPending == nil }

    // Play state.
    @ObservationIgnored private var anchorT = 0.0
    @ObservationIgnored private var anchorWall = 0.0
    @ObservationIgnored private var lastGridIndex: Int?
    @ObservationIgnored private(set) var streamsStarted = 0
    @ObservationIgnored private var live = PlaybackStats()
    @ObservationIgnored private var lastPublish = 0.0
    @ObservationIgnored private var lastLadderCheck = 0.0
    @ObservationIgnored private var underBudgetSince: Double?
    @ObservationIgnored private var shownWindow: (count: Int, since: Double) = (0, 0)
    @ObservationIgnored private var widthStep = 0
    @ObservationIgnored private var fpsStep = 0

    static let creditWindow = 4
    static let lookahead = 1.0
    static let restartLag = 0.25
    static let ladderScales: [Double] = [1, 0.5, 1.0 / 3, 0.25]
    static let ladderFPS = [30, 20, 15]

    private struct FrameAsk { var t: Double; var width: Int; var format: FrameFormat }

    private final class ActiveStream {
        let handle: HostFrameStream
        let generation: Int
        let sampleFPS: Int
        let width: Int
        let from: Double
        let startedWall: Double
        var head: Double?
        var lastFrameWall: Double
        var owed = 0
        /// The host closed it (`streamEnd`: reached `to`, replaced, or a render error).
        /// Silence after that is not a hang; falling behind restarts it as usual.
        var ended = false
        var task: Task<Void, Never>?
        init(handle: HostFrameStream, generation: Int, sampleFPS: Int, width: Int, from: Double, wall: Double) {
            self.handle = handle; self.generation = generation; self.sampleFPS = sampleFPS
            self.width = width; self.from = from; self.startedWall = wall; self.lastFrameWall = wall
        }
    }

    init(cache: FrameCache = FrameCache()) {
        self.cache = cache
    }

    // MARK: Host / scene

    /// New host or scene: bump the generation, drop old pixels from the cache (the
    /// viewer keeps showing the last frame until a new one lands), re-request `t`.
    func attach(host: RenderHost?, info: SceneInfo?, warmFrame: DecodedFrame? = nil) {
        let wasPlaying = isPlaying
        stopStream()
        self.host = host
        if let info {
            duration = info.duration
            fps = max(1, info.fps)
            sceneName = info.name
            editPoints = Array(Set(info.clips.flatMap { [$0.start, $0.end] })).sorted()
            audio.load(info.audioPath.map { URL(fileURLWithPath: $0) }, at: t)
        }
        bumpGeneration()
        t = min(t, duration)
        if let warmFrame, warmFrame.index == frameIndex(t, fps: fps) {
            cache.put(warmFrame, generation: generation)
            show(warmFrame)
        }
        if wasPlaying {
            reanchor()
        } else {
            requestFrame(FrameAsk(t: t, width: scrubWidth(precise: true), format: .jpeg))
            scheduleSharpen()
        }
    }

    /// Knobs/props changed: same host, new pixels.
    func invalidate() {
        bumpGeneration()
        if isPlaying { reanchor() } else {
            requestFrame(FrameAsk(t: t, width: scrubWidth(precise: true), format: .jpeg))
            scheduleSharpen()
        }
    }

    private func bumpGeneration() {
        generation += 1
        cache.purge(below: generation)
        cachedRanges = []
        lastGridIndex = nil
    }

    func setDuration(_ d: Double, fps: Int) {
        duration = d
        self.fps = max(1, fps)
        t = min(t, d)
    }

    /// Same host, re-probed scene (props/knobs changed): its length and cuts may have moved.
    func adopt(_ info: SceneInfo) {
        if info.duration != duration || info.fps != fps { setDuration(info.duration, fps: info.fps) }
        editPoints = Array(Set(info.clips.flatMap { [$0.start, $0.end] })).sorted()
    }

    // MARK: Transport

    func toggle() { isPlaying ? pause() : play() }

    func play() {
        guard duration > 0 else { return }
        let (lo, hi) = playRange
        if rate > 0 && t >= hi - 0.5 / Double(fps) { t = lo }
        if rate < 0 && t <= lo + 0.5 / Double(fps) { t = hi }
        isPlaying = true
        sharpenTask?.cancel()
        live.dropped = 0; live.shown = 0
        shownWindow = (0, now())
        reanchor()
        onPlayStateChange?(true)
    }

    func pause() {
        guard isPlaying else { return }
        isPlaying = false
        audio.pause()
        stopStream()
        publishStats(force: true)
        onPlayStateChange?(false)
        // Land on an exact frame and sharpen it.
        seek(Double(frameIndex(t, fps: fps)) / Double(fps), precise: true)
    }

    /// Move the playhead. `precise` (clicks, steps) asks at display width; drags at 50%.
    func seek(_ newT: Double, precise: Bool = false) {
        let nt = max(0, min(duration, newT))
        setT(nt)
        if isPlaying { reanchor(); return }
        showBestCached()
        let target = frameIndex(nt, fps: fps)
        if cache.best(generation: generation, frame: target, minWidth: scrubWidth(precise: precise)) == nil {
            requestFrame(FrameAsk(t: nt, width: scrubWidth(precise: precise), format: .jpeg))
        }
        scheduleSharpen()
    }

    func step(frames n: Int) {
        if isPlaying { pause() }
        let idx = max(0, min(frameIndex(duration, fps: fps), frameIndex(t, fps: fps) + n))
        seek(Double(idx) / Double(fps), precise: true)
    }

    func shuttle(_ k: ShuttleKey) {
        switch k {
        case .k:
            pause(); rate = 1
        case .l:
            rate = (isPlaying && rate > 0) ? min(rate * 2, 8) : 1
            isPlaying ? reanchor() : play()
        case .j:
            rate = (isPlaying && rate < 0) ? max(rate * 2, -8) : -1
            isPlaying ? reanchor() : play()
        }
    }

    func setRate(_ r: Double) {
        rate = r == 0 ? 1 : r
        if isPlaying { reanchor() }
    }

    /// ↑/↓: previous/next clip boundary, comment, or in/out point.
    func jumpToEdit(next: Bool) {
        var points = editPoints + commentMarks.flatMap { [$0.t] + ($0.end.map { [$0] } ?? []) } + [0, duration]
        if let io = inOut { points += [io.lowerBound, io.upperBound] }
        let eps = 0.5 / Double(fps)
        let target = next ? points.filter { $0 > t + eps }.min() : points.filter { $0 < t - eps }.max()
        if let target { seek(target, precise: true) }
    }

    func setIn() { setInOut(t...max(t, inOut?.upperBound ?? duration)) }
    func setOut() { setInOut(min(t, inOut?.lowerBound ?? 0)...t) }
    func setInOut(_ r: ClosedRange<Double>?) { inOut = r.map(clampRange) }
    func clearInOut() { inOut = nil }

    private var playRange: (Double, Double) {
        if loop, let io = inOut, io.upperBound > io.lowerBound { return (io.lowerBound, io.upperBound) }
        return (0, duration)
    }

    private func clampRange(_ r: ClosedRange<Double>) -> ClosedRange<Double> {
        let lo = max(0, min(duration, r.lowerBound)), hi = max(lo, min(duration, r.upperBound))
        return lo...hi
    }

    // MARK: Display link

    /// Called by the viewer's display link (and manually in tests / snapshot mode).
    func tick() {
        guard isPlaying else { return }
        let wall = now()
        var nt = audio.clock ?? (anchorT + (wall - anchorWall) * rate)
        let (lo, hi) = playRange
        if rate > 0, nt >= hi {
            if loop { setT(lo); reanchor(); return }
            nt = hi; setT(nt); pause(); return
        }
        if rate < 0, nt <= lo {
            if loop { setT(hi); reanchor(); return }
            nt = lo; setT(nt); pause(); return
        }
        setT(nt)

        let sfps = sampleFPS
        let grid = Int((nt * Double(sfps) + 1e-6).rounded(.down))
        if grid != lastGridIndex {
            lastGridIndex = grid
            let target = frameIndex(Double(grid) / Double(sfps), fps: fps)
            if let f = cache.best(generation: generation, frame: target) {
                show(f)
                live.shown += 1
                shownWindow.count += 1
            } else {
                live.dropped += 1
                if let f = cache.nearest(generation: generation, atOrBefore: target, within: fps) { show(f) }
            }
        }

        if rate > 0 { manageStream(at: nt, wall: wall) }
        else if let g = lastGridIndex {        // reverse: coalesced single-frame requests
            stopStream()
            let target = Double(g) / Double(sfps)
            if !cache.contains(generation: generation, frame: frameIndex(target, fps: fps)) {
                requestFrame(FrameAsk(t: target, width: playWidth, format: .jpeg))
            }
        }

        if quality == .auto, wall - lastLadderCheck > 0.5 { lastLadderCheck = wall; runLadder(wall: wall) }
        publishStats(force: false)
    }

    /// Scene frames per scene-second requested from the host at the current rate.
    var sampleFPS: Int {
        let target = Self.ladderFPS[min(fpsStep, Self.ladderFPS.count - 1)]
        return max(1, min(fps, Int((Double(target) / max(1, abs(rate))).rounded())))
    }

    var playWidth: Int {
        let scale = quality.fixedScale ?? Self.ladderScales[min(widthStep, Self.ladderScales.count - 1)]
        return max(160, Int(Double(displayWidth) * scale))
    }

    private func scrubWidth(precise: Bool) -> Int {
        max(160, precise ? displayWidth : displayWidth / 2)
    }

    // MARK: Streaming

    private func reanchor() {
        anchorT = t
        anchorWall = now()
        lastGridIndex = nil
        if !audio.play(from: t, rate: rate) { audio.pause() }
        stopStream()
        if rate > 0 { manageStream(at: t, wall: anchorWall) }
    }

    private func manageStream(at nt: Double, wall: Double) {
        guard let host else { return }
        if let tok = streamToken {
            guard let s = tok.stream else { return }      // still opening

            let stale = s.generation != generation || s.sampleFPS != sampleFPS || s.width != playWidth
            let head = s.head ?? s.from
            let lagging = head < nt - Self.restartLag
            if stale || lagging {
                stopStream()
                let lead = lagging ? max(1 / Double(sampleFPS), live.msPerFrame / 1000 * Double(Self.creditWindow)) : 0
                startStream(host, from: nt + lead)
                return
            }
            if s.owed > 0, head - nt < Self.lookahead {
                s.handle.credit(s.owed)
                s.owed = 0
            }
            if !s.ended, wall - s.lastFrameWall > hangTimeout, head < duration - 1 / Double(fps) {
                stopStream()
                onHang?(nt, host)
            }
            return
        }
        startStream(host, from: firstUncached(from: nt))
    }

    /// First playback-grid time at/after `t` whose frame isn't cached (looping over a
    /// cached range costs no renders).
    private func firstUncached(from t0: Double) -> Double {
        let sfps = Double(sampleFPS)
        var g = (t0 * sfps - 1e-6).rounded(.up)
        let limit = g + sfps * 5
        while g < limit, g / sfps <= duration {
            if !cache.contains(generation: generation, frame: frameIndex(g / sfps, fps: fps)) { break }
            g += 1
        }
        return g / sfps
    }

    private func startStream(_ host: RenderHost, from t0: Double) {
        let sfps = sampleFPS
        // Align to the playback grid so streamed frames land on the indices tick() asks for.
        var from = ((t0 * Double(sfps) - 1e-6).rounded(.up)) / Double(sfps)
        while poisoned.contains(frameIndex(from, fps: fps)) { from += 1 / Double(sfps) }   // don't re-crash the host
        guard from <= duration else { return }
        let gen = generation, width = playWidth
        var to = loop ? playRange.1 : duration
        // End before the next frame that crashed the host; a stream renders straight through
        // to `to`, and once it ends the lag restart picks up past the bad frame.
        if let bad = poisoned.filter({ Double($0) / Double(fps) > from }).min() {
            to = min(to, Double(bad) / Double(fps) - 1e-4)
        }
        let placeholder = ActiveStreamBox()
        streamsStarted += 1
        let task = Task { [weak self] in
            do {
                let handle = try await host.openStream(from: from, to: to, fps: sfps, maxWidth: width,
                                                       format: host.supportsBinaryFrames ? .bgra8 : .jpeg,
                                                       credits: Self.creditWindow)
                guard let self, !Task.isCancelled else { handle.cancel(); return }
                let s = ActiveStream(handle: handle, generation: gen, sampleFPS: sfps, width: width,
                                     from: from, wall: self.now())
                placeholder.stream = s
                for try await f in handle.frames {
                    guard !Task.isCancelled else { break }
                    self.receivedStreamFrame(f, stream: s)
                }
                s.ended = true
            } catch {
                guard let self, !Task.isCancelled else { return }
                if case HostClientError.exited = error {} else { self.lastError = "\(error)" }
            }
        }
        streamToken = placeholder
        placeholder.task = task
    }

    /// Identifies the stream currently being opened (its handle arrives asynchronously).
    @ObservationIgnored private var streamToken: ActiveStreamBox?
    private final class ActiveStreamBox {
        var stream: ActiveStream?
        var task: Task<Void, Never>?
    }

    private func stopStream() {
        if let tok = streamToken {
            tok.task?.cancel()
            tok.stream?.handle.cancel()
        }
        streamToken = nil
    }

    private func receivedStreamFrame(_ f: DecodedFrame, stream s: ActiveStream) {
        guard s.generation == generation else { staleDropped += 1; return }
        cache.put(f, generation: s.generation)
        noteRender(ms: f.ms)
        s.head = f.t
        s.lastFrameWall = now()
        if f.t - t < Self.lookahead { s.handle.credit(1) } else { s.owed += 1 }
        if !hasFrame { show(f) }
    }

    // MARK: Single frames (scrub, sharpen, reverse)

    private func requestFrame(_ ask: FrameAsk) {
        guard let host else { return }
        if poisoned.contains(frameIndex(ask.t, fps: fps)) { return }
        if scrubInFlight { scrubPending = ask; return }
        scrubInFlight = true
        framesRequested += 1
        let gen = generation, timeout = hangTimeout
        Task { [weak self] in
            var hung = false
            do {
                let f = try await withTimeout(timeout, "frame") {
                    try await host.frame(t: ask.t, maxWidth: ask.width, format: ask.format)
                }
                self?.receivedFrame(f, generation: gen)
            } catch let e as HostClientError {
                switch e {
                case .timeout: hung = true
                case .exited: break                      // the supervisor reports crashes
                case .host(let he) where he.code == "superseded": break
                default: self?.lastError = e.description
                }
            } catch {
                self?.lastError = "\(error)"
            }
            guard let self else { return }
            self.scrubInFlight = false
            if hung { self.onHang?(ask.t, host) }
            if let next = self.scrubPending {
                self.scrubPending = nil
                self.requestFrame(next)
            }
        }
    }

    private func receivedFrame(_ f: DecodedFrame, generation gen: Int) {
        guard gen == generation else { staleDropped += 1; return }
        cache.put(f, generation: gen)
        noteRender(ms: f.ms)
        lastError = nil
        if !isPlaying || rate < 0 { showBestCached() }
        if isPlaying { updateCachedRanges(force: false) } else { publishStats(force: true) }   // paused: no ticks publish
    }

    private func scheduleSharpen() {
        sharpenTask?.cancel()
        let format: FrameFormat = (host?.supportsBinaryFrames ?? false) ? .bgra8 : .png
        sharpenTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled, !self.isPlaying else { return }
            let target = frameIndex(self.t, fps: self.fps)
            if let have = self.cache.best(generation: self.generation, frame: target),
               have.width >= min(self.displayWidth, have.width + 1), have.format != .jpeg { return }
            self.requestFrame(FrameAsk(t: Double(target) / Double(self.fps), width: self.displayWidth, format: format))
        }
    }

    /// Paused display: the widest copy of the playhead's frame, else hold the nearest earlier.
    private func showBestCached() {
        let target = frameIndex(t, fps: fps)
        if let f = cache.best(generation: generation, frame: target)
            ?? cache.nearest(generation: generation, atOrBefore: target, within: fps * 2) {
            show(f)
        }
    }

    private func show(_ f: DecodedFrame) {
        if let c = currentFrame, c.index == f.index, c.width == f.width, c.image === f.image { return }
        currentFrame = f
        if !hasFrame { hasFrame = true }
        onFrame?(f)
    }

    private func setT(_ nt: Double) {
        t = nt
        updateVisibleComments()
    }

    // MARK: Stats & quality ladder

    private func noteRender(ms: Double) {
        live.msPerFrame = live.msPerFrame == 0 ? ms : live.msPerFrame * 0.8 + ms * 0.2
    }

    private func applyQualityChoice() {
        widthStep = 0; fpsStep = 0
        live.note = nil
        if isPlaying { reanchor() }
    }

    private func runLadder(wall: Double) {
        let budget = 0.8 * 1000 / Double(Self.ladderFPS[fpsStep])
        let ms = live.msPerFrame
        guard ms > 0 else { return }
        if ms > budget {
            underBudgetSince = nil
            if widthStep < Self.ladderScales.count - 1 { widthStep += 1 }
            else if fpsStep < Self.ladderFPS.count - 1 { fpsStep += 1 }
            else { return }
            live.note = "\(sceneName) ~\(Int(ms.rounded())) ms/frame → \(Self.ladderFPS[fpsStep]) fps preview"
        } else if ms < budget * 0.5, widthStep > 0 || fpsStep > 0 {
            if underBudgetSince == nil { underBudgetSince = wall }
            if wall - underBudgetSince! > 2 {
                if fpsStep > 0 { fpsStep -= 1 } else { widthStep -= 1 }
                underBudgetSince = nil
                if widthStep == 0 && fpsStep == 0 { live.note = nil }
            }
        }
    }

    private func publishStats(force: Bool) {
        let wall = now()
        guard force || wall - lastPublish > 0.25 else { return }
        let elapsed = wall - shownWindow.since
        if elapsed > 0.5 {
            live.shownFPS = Double(shownWindow.count) / elapsed
            shownWindow = (0, wall)
        }
        live.targetFPS = Self.ladderFPS[fpsStep]
        live.widthScale = quality.fixedScale ?? Self.ladderScales[widthStep]
        lastPublish = wall
        if stats != live { stats = live }
        updateCachedRanges(force: false)
    }

    @ObservationIgnored private var lastRangesUpdate = 0.0
    private func updateCachedRanges(force: Bool) {
        let wall = now()
        guard force || wall - lastRangesUpdate > 0.5 else { return }
        lastRangesUpdate = wall
        let r = cache.cachedRanges(generation: generation, fps: fps, tolerance: max(2, fps / 10))
        if r != cachedRanges { cachedRanges = r }
    }

    private func updateVisibleComments() {
        let ids = Set(commentMarks.filter { t >= $0.t - 0.25 && t <= ($0.end ?? $0.t) + 0.25 }.map(\.id))
        if ids != visibleCommentIDs { visibleCommentIDs = ids }
    }

    /// Exposed for tests: the live (unthrottled) stats.
    var liveStats: PlaybackStats { live }
}
