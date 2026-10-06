import Foundation
import SwiftRender
import SwiftRenderKit
import SwiftUI

// MARK: - swift-render serve
//
// Render host for Studio: JSON Lines over stdio, see SwiftRenderKit/HostProtocol.swift.
// A stdin reader thread fills the inbox; this loop (MainActor — ImageRenderer
// needs it) handles control requests in order, renders only the newest pending
// `frame`, then one stream frame per turn so requests stay responsive during
// playback. Score audio is synthesized on a background queue and comes back
// through the inbox, so frames never wait for it.

@MainActor
func runServe(_ args: [String]) async throws {
    let started = Date()
    let protoFD = HostStdio.claimStdout()
    HostCrashLog.install()
    for a in args { fputs("[swift-render serve] ignoring argument \(a)\n", stderr) }

    let output = HostOutput(fd: protoFD)
    let inbox = HostInbox()
    let project = Project.discover()
    let session = HostSession(runners: sceneRunners, project: project,
                              schedule: { work in inbox.post(.main(work)) },
                              emit: { output.send($0) })
    output.send(HostPacket(session.readyMessage()))
    fputs(String(format: "[swift-render serve] ready in %.0f ms · %d scenes · root %@\n",
                 Date().timeIntervalSince(started) * 1000, sceneRunners.count, project?.root.path ?? "(none)"), stderr)
    inbox.startReading(fd: STDIN_FILENO)

    while true {
        let items = await inbox.take(wait: !session.hasStreamWork)
        var batch: [HostRequest] = []
        var eof = false
        for item in items {
            switch item {
            case .request(let r): batch.append(r)
            case .malformed(let id, let message):
                fputs("[swift-render serve] \(message)\n", stderr)
                if let id { output.send(HostPacket(.failure(id, HostError(code: HostError.Code.badParams, message: message)))) }
                else { output.send(HostPacket(.warning(message))) }
            case .eof: eof = true
            case .main(let work): work()
            }
        }
        session.process(batch) { output.send($0) }
        if session.shutdownRequested || eof {
            output.flush()
            exit(0)
        }
        for packet in session.streamStep() { output.send(packet) }
    }
}

// MARK: - Session

/// The host's state machine, free of I/O so tests can drive it in-process:
/// requests in, packets out. Asynchronous results (score audio) are handed to
/// `schedule` to run on the main actor later and reported through `emit`.
@MainActor
final class HostSession {
    typealias Schedule = @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void

    let runners: [String: SceneRunner]
    let project: Project?
    private let schedule: Schedule
    private let emit: (HostPacket) -> Void
    private(set) var shutdownRequested = false

    /// The open scene and everything derived from it.
    private struct Opened {
        var scene: PreparedScene
        var info: SceneInfo
        var audio: AudioSource
        /// Identity of `audio` at this fps/duration; equal keys reuse analysis.
        var audioKey: String
        /// `open`'s explicit duration (otherwise props decide).
        var explicitDuration: Double?
        var audioFile: URL?
        var binaryFrames: Bool
    }

    private struct Stream {
        var id: Int
        var from: Double
        var to: Double
        var fps: Double
        var maxWidth: Int?
        var format: String
        var quality: Double
        var credits: Int
        var next = 0
        var nextT: Double { from + Double(next) / fps }
    }

    private var opened: Opened?
    private var stream: Stream?
    private var audioGeneration = 0
    private var audioDone: (key: String, ready: AudioReady)?
    private lazy var summaries: [SceneSummary] = runners.keys.sorted().map { runners[$0]!.summary(name: $0) }

    static let loudnessRate = 50.0

    init(runners: [String: SceneRunner], project: Project?, schedule: @escaping Schedule,
         emit: @escaping (HostPacket) -> Void) {
        self.runners = runners
        self.project = project
        self.schedule = schedule
        self.emit = emit
    }

    func readyMessage() -> HostMessage { .ready(scenes: summaries, version: swiftRenderVersion) }

    /// Current scene metadata (after `open`).
    var info: SceneInfo? { opened?.info }

    var hasStreamWork: Bool { (stream?.credits ?? 0) > 0 && opened != nil }

    // MARK: Dispatch

    /// One turn's worth of requests: everything in order, except that only the
    /// last `frame` renders (after the others); earlier ones are superseded.
    func process(_ batch: [HostRequest], send: (HostPacket) -> Void) {
        let lastFrame = batch.lastIndex { $0.method == .frame }
        for (i, r) in batch.enumerated() {
            if r.method == .frame {
                if i != lastFrame {
                    send(HostPacket(.failure(r.id, HostError(code: HostError.Code.superseded,
                                                             message: "a newer frame request replaced this one"))))
                }
                continue
            }
            guard !shutdownRequested else { continue }
            for p in handle(r) { send(p) }
        }
        if let i = lastFrame {
            if shutdownRequested {
                send(HostPacket(.failure(batch[i].id, HostError(code: HostError.Code.superseded, message: "host shutting down"))))
            } else {
                for p in handle(batch[i]) { send(p) }
            }
        }
    }

    /// Answer one request (plus any events it causes, e.g. a replaced stream's end).
    func handle(_ r: HostRequest) -> [HostPacket] {
        let p = r.params ?? HostParams()
        do {
            switch r.method {
            case .list:     return [HostPacket(.response(r.id, HostResult(scenes: summaries)))]
            case .open:     return try open(r.id, p)
            case .frame:    return try frame(r.id, p)
            case .setKnobs: return try setKnobs(r.id, p)
            case .setProps: return try setProps(r.id, p)
            case .stream:   return try startStream(r.id, p)
            case .credit:
                if let id = p.streamID, stream?.id == id { stream!.credits += max(0, p.credits ?? 1) }
                return [ok(r.id)]
            case .cancel:
                if let id = p.streamID, stream?.id == id { stream = nil }
                return [ok(r.id)]
            case .still:    return try still(r.id, p)
            case .check:    return try check(r.id, p)
            case .shutdown:
                shutdownRequested = true
                stream = nil
                return [ok(r.id)]
            }
        } catch let e as HostError {
            fputs("[swift-render serve] \(r.method.rawValue) #\(r.id): \(e.code): \(e.message)\n", stderr)
            return [HostPacket(.failure(r.id, e))]
        } catch {
            fputs("[swift-render serve] \(r.method.rawValue) #\(r.id): \(error)\n", stderr)
            return [HostPacket(.failure(r.id, HostError(code: HostError.Code.internal, message: "\(error)")))]
        }
    }

    // MARK: open

    private func open(_ id: Int, _ p: HostParams) throws -> [HostPacket] {
        let t0 = Date()
        guard let name = p.scene, !name.isEmpty else { throw bad("open needs 'scene'") }
        guard let runner = runners[name] else {
            throw HostError(code: HostError.Code.unknownScene, message: "unknown scene '\(name)' — see 'list'")
        }
        let width = p.width ?? 1920, height = p.height ?? 1080, fps = p.fps ?? 60
        guard (16...16384).contains(width), (16...16384).contains(height) else { throw bad("width/height out of range") }
        guard (1...240).contains(fps) else { throw bad("fps out of range") }
        if let d = p.duration, !(d.isFinite && d > 0) { throw bad("duration must be > 0") }
        var audioFile: URL? = nil
        if let path = p.audioPath {
            let url = resolve(path)
            guard FileManager.default.fileExists(atPath: url.path) else { throw bad("audioPath not found: \(url.path)") }
            audioFile = url
        }

        let previousKnobs = KnobStore.shared.values
        if let k = p.knobs { KnobStore.shared.set(k) } else { KnobStore.shared.load(scene: name, project: project) }
        do {
            let propsURL = try writeProps(scene: name, json: p.propsJSON, runner: runner)
            let duration = p.duration ?? runner.durationFor(propsURL)
            let size = CGSize(width: width, height: height)
            let audio = audioSource(runner: runner, duration: duration, propsURL: propsURL, file: audioFile)
            let key = audioKey(audio, fps: fps, duration: duration)
            let reuse = audioDone.flatMap { $0.key == key ? $0.ready : nil }
            HostCrashLog.note("open \(name)")
            let scene = try preparedScene(name: name, runner: runner, duration: duration, size: size, fps: fps,
                                          postFX: p.postFX ?? true, propsURL: propsURL,
                                          track: runner.reactsToAudio ? reuse?.track ?? .silent : .silent)
            var info = try buildSceneInfo(name: name, runner: runner, duration: duration, size: size, fps: fps,
                                          audio: audio, propsURL: propsURL, audioPath: knownAudioPath(audio),
                                          loudnessRate: Self.loudnessRate, analyzeAudio: false, captions: false,
                                          make: scene.make)
            if let reuse { apply(reuse, to: &info) }

            var out: [HostPacket] = []
            if let s = stream { out.append(HostPacket(.streamEnd(s.id, message: "scene reopened"))); stream = nil }
            opened = Opened(scene: scene, info: info, audio: audio, audioKey: key, explicitDuration: p.duration,
                            audioFile: audioFile, binaryFrames: p.binaryFrames ?? false)
            if reuse == nil { startAudio() }
            fputs(String(format: "[swift-render serve] open %@ %d×%d@%d %.2fs in %.0f ms\n", name, width, height, fps,
                         duration, Date().timeIntervalSince(t0) * 1000), stderr)
            return out + [HostPacket(.response(id, HostResult(info: info)))]
        } catch {
            KnobStore.shared.set(previousKnobs)     // a failed open leaves the previous scene intact
            throw error
        }
    }

    private func preparedScene(name: String, runner: SceneRunner, duration: Double, size: CGSize, fps: Int,
                               postFX: Bool, propsURL: URL?, track: AudioTrack) throws -> PreparedScene {
        do {
            return try PreparedScene(name: name, runner: runner, duration: duration, size: size, fps: fps,
                                     postFX: postFX, propsURL: propsURL, track: track)
        } catch let e as PropsError {
            throw bad(e.shortDescription)
        }
    }

    // MARK: frames

    private func frame(_ id: Int, _ p: HostParams) throws -> [HostPacket] {
        let o = try requireOpen()
        guard let t = p.t, t.isFinite else { throw bad("frame needs a finite 't'") }
        let format = try frameFormat(p.format, binary: o.binaryFrames)
        let (frame, payload, discovered) = try render(t: t, maxWidth: p.maxWidth, format: format, quality: p.quality)
        return [HostPacket(.response(id, HostResult(frame: frame)), payload: payload)] + discovered
    }

    /// Render + encode one frame. Also reports knobs the probe hadn't seen.
    private func render(t: Double, maxWidth: Int?, format: String,
                        quality: Double?) throws -> (HostFrame, Data?, [HostPacket]) {
        guard let scene = opened?.scene else { throw HostError(code: HostError.Code.noScene, message: "no scene open") }
        let start = DispatchTime.now()
        HostCrashLog.note("frame \(scene.name) t=\(t)")
        KnobStore.shared.beginRecording()
        let image = scene.image(at: t, scale: scene.scale(maxEdge: maxWidth))
        let declared = KnobStore.shared.endRecording()
        guard let image else {
            throw HostError(code: HostError.Code.renderFailed, message: "\(scene.name) produced no image at t=\(t)")
        }
        var data = "", payload: Data? = nil
        if format == "bgra8" {
            guard let raw = FrameEncoding.bgra8(image) else { throw HostError(code: HostError.Code.renderFailed, message: "bgra8 pack failed") }
            payload = raw
        } else {
            guard let bytes = FrameEncoding.encode(image, format: format, quality: quality ?? 0.8) else {
                throw HostError(code: HostError.Code.renderFailed, message: "\(format) encode failed")
            }
            data = bytes.base64EncodedString()
        }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
        let frame = HostFrame(t: t, width: image.width, height: image.height, format: format, data: data,
                              ms: (ms * 100).rounded() / 100, index: Int((t * Double(scene.fps)).rounded()),
                              bytes: payload?.count)
        return (frame, payload, discoveredKnobs(declared))
    }

    private func discoveredKnobs(_ declared: [KnobInfo]) -> [HostPacket] {
        guard var o = opened, !declared.isEmpty else { return [] }
        let known = Set(o.info.knobs.map(\.key))
        let fresh = declared.filter { !known.contains($0.key) }
        guard !fresh.isEmpty else { return [] }
        o.info.knobs = (o.info.knobs + fresh).sorted { $0.key < $1.key }
        opened = o
        return [HostPacket(.infoChanged(o.info))]
    }

    private func frameFormat(_ requested: String?, binary: Bool) throws -> String {
        let f = requested ?? "jpeg"
        guard ["jpeg", "png", "bgra8"].contains(f) else { throw bad("format must be jpeg, png or bgra8") }
        if f == "bgra8", !binary { throw bad("bgra8 frames need binaryFrames: true on open") }
        return f
    }

    // MARK: streams

    private func startStream(_ id: Int, _ p: HostParams) throws -> [HostPacket] {
        let o = try requireOpen()
        let format = try frameFormat(p.format, binary: o.binaryFrames)
        let fps = Double(p.fps ?? o.scene.fps)
        guard fps > 0 else { throw bad("fps must be > 0") }
        let from = max(0, p.from ?? 0)
        let to = min(p.to ?? o.scene.duration, o.scene.duration)
        var out: [HostPacket] = []
        if let old = stream { out.append(HostPacket(.streamEnd(old.id, message: "replaced by stream \(id)"))) }
        stream = Stream(id: id, from: from, to: to, fps: fps, maxWidth: p.maxWidth, format: format,
                        quality: p.quality ?? 0.8, credits: max(0, p.credits ?? 4))
        out.append(ok(id))
        if from >= to - 1e-9 {
            stream = nil
            out.append(HostPacket(.streamEnd(id)))
        }
        return out
    }

    /// Render the active stream's next frame if it has credit.
    func streamStep() -> [HostPacket] {
        guard var s = stream, s.credits > 0, opened != nil else { return [] }
        do {
            let (frame, payload, discovered) = try render(t: s.nextT, maxWidth: s.maxWidth, format: s.format,
                                                          quality: s.quality)
            s.next += 1
            s.credits -= 1
            var out = [HostPacket(.streamFrame(s.id, frame), payload: payload)] + discovered
            if s.nextT >= s.to - 1e-9 {
                stream = nil
                out.append(HostPacket(.streamEnd(s.id)))
            } else {
                stream = s
            }
            return out
        } catch {
            stream = nil
            let message = (error as? HostError)?.message ?? "\(error)"
            fputs("[swift-render serve] stream #\(s.id) stopped: \(message)\n", stderr)
            return [HostPacket(.streamEnd(s.id, message: message))]
        }
    }

    // MARK: knobs & props

    private func setKnobs(_ id: Int, _ p: HostParams) throws -> [HostPacket] {
        var o = try requireOpen()
        let values = p.knobs ?? [:]
        if p.persist == true {
            guard let project else { throw bad("no project root to persist knobs into") }
            try KnobFile.save(values, to: project.knobsURL(scene: o.scene.name))
        }
        KnobStore.shared.set(values)
        if p.reprobe == false {
            // Mid-drag: report the new values without re-running the probe.
            o.info.knobs = o.info.knobs.map { k in var k = k; k.value = values[k.key] ?? k.defaultValue; return k }
            opened = o
        } else {
            reprobe(&o)
            opened = o
            refreshAudio()                          // a soundtrack may read knobs too
        }
        return [HostPacket(.response(id, HostResult(info: opened!.info)))]
    }

    private func setProps(_ id: Int, _ p: HostParams) throws -> [HostPacket] {
        var o = try requireOpen()
        let runner = o.scene.runner
        guard runner.propsTemplate != nil else { throw bad("\(o.scene.name) takes no props") }
        let propsURL = try writeProps(scene: o.scene.name, json: p.propsJSON, runner: runner)
        let duration = o.explicitDuration ?? runner.durationFor(propsURL)
        let track = runner.reactsToAudio ? audioDone?.ready.track ?? .silent : .silent
        o.scene = try preparedScene(name: o.scene.name, runner: runner, duration: duration, size: o.scene.size,
                                    fps: o.scene.fps, postFX: o.scene.postFX,
                                    propsURL: propsURL, track: track)
        o.info.duration = duration
        o.info.propsJSON = p.propsJSON ?? runner.propsTemplate?()
        if p.reprobe != false { reprobe(&o) }
        opened = o
        if var s = stream { s.to = min(s.to, duration); stream = s }
        refreshAudio()
        return [HostPacket(.response(id, HostResult(info: opened!.info)))]
    }

    private func reprobe(_ o: inout Opened) {
        HostCrashLog.note("probe \(o.scene.name)")
        let s = o.scene
        let structure = SceneProbe.probe(duration: s.duration, size: s.size, fps: s.fps, make: s.make)
        o.info.clips = structure.clips
        o.info.knobs = structure.knobs
    }

    /// Validates props JSON by decoding it, then moves it to
    /// `.swift-render/cache/props-<scene>.json`. nil JSON = scene defaults.
    private func writeProps(scene name: String, json: String?, runner: SceneRunner) throws -> URL? {
        guard let json else { return nil }
        guard runner.propsTemplate != nil else { throw bad("\(name) takes no props") }
        let dir = try cacheDir()
        let final = dir.appendingPathComponent("props-\(name).json")
        let pending = dir.appendingPathComponent(".props-\(name)-\(UUID().uuidString).json")
        try json.write(to: pending, atomically: false, encoding: .utf8)
        do {
            _ = try runner.makeViewWithTrack(runner.defaultDuration, .silent, pending)
        } catch let e as PropsError {
            try? FileManager.default.removeItem(at: pending)
            throw bad(e.shortDescription)
        }
        guard rename(pending.path, final.path) == 0 else {
            try? FileManager.default.removeItem(at: pending)
            throw HostError(code: HostError.Code.internal, message: "cannot write \(final.path)")
        }
        return final
    }

    // MARK: still & check

    private func still(_ id: Int, _ p: HostParams) throws -> [HostPacket] {
        let o = try requireOpen()
        guard let t = p.t, t.isFinite else { throw bad("still needs a finite 't'") }
        guard let path = p.path, !path.isEmpty else { throw bad("still needs 'path'") }
        let format = p.format ?? "png"
        guard format == "png" || format == "jpeg" else { throw bad("still format must be png or jpeg") }
        HostCrashLog.note("still \(o.scene.name) t=\(t)")
        guard let image = o.scene.image(at: t, scale: o.scene.scale(maxEdge: p.maxWidth)),
              let data = FrameEncoding.encode(image, format: format, quality: p.quality ?? 0.92) else {
            throw HostError(code: HostError.Code.renderFailed, message: "\(o.scene.name) produced no image at t=\(t)")
        }
        let url = resolve(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return [HostPacket(.response(id, HostResult(path: url.path)))]
    }

    private func check(_ id: Int, _ p: HostParams) throws -> [HostPacket] {
        let o = try requireOpen()
        let out = resolve(p.path ?? "out/check-\(o.scene.name).png")
        var scene = o.scene
        let audio: CheckAudio
        switch o.audio {
        case .none: audio = .none
        case .file(let url): audio = .file(url)
        case .score(let score):
            // The cache holds exactly the synthesized samples; synthesize now only if the job hasn't run.
            let samples = try AudioCache.load(score, in: try audioCacheDir())
            audio = .score(score, left: samples.left, right: samples.right)
            if scene.runner.reactsToAudio, audioDone?.key != o.audioKey {
                let track = try AudioAnalyzer.analyze(samples: samples.mono, sampleRate: scoreSampleRate, fps: scene.fps)
                try scene.setTrack(track)
            }
        }
        let result = try runCheck(scene, audio: audio, contact: out)
        return [HostPacket(.response(id, HostResult(path: result.contact.path, report: result.report)))]
    }

    // MARK: audio

    private func audioSource(runner: SceneRunner, duration: Double, propsURL: URL?, file: URL?) -> AudioSource {
        if let file { return .file(file) }
        if let score = runner.soundtrack(duration, propsURL) { return .score(score) }
        return .none
    }

    private func audioKey(_ audio: AudioSource, fps: Int, duration: Double) -> String {
        switch audio {
        case .none: return "none"
        case .file(let url):
            let mtime = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date)?
                .timeIntervalSince1970 ?? 0
            return "file|\(url.path)|\(mtime)|\(fps)|\(duration)"
        case .score(let score): return "score|\(AudioCache.fingerprint(score))|\(fps)|\(duration)"
        }
    }

    /// The file to play, when it already exists (external file or a cache hit).
    private func knownAudioPath(_ audio: AudioSource) -> String? {
        switch audio {
        case .none: return nil
        case .file(let url): return url.path
        case .score(let score): return (try? audioCacheDir()).flatMap { AudioCache.existing(score, in: $0)?.path }
        }
    }

    private func apply(_ ready: AudioReady, to info: inout SceneInfo) {
        info.audioPath = ready.path
        info.loudness = ready.loudness
        info.loudnessRate = Self.loudnessRate
        if !ready.captions.isEmpty { info.captions = ready.captions }
    }

    /// Re-derive the soundtrack (knobs/props may change it); restart synthesis if it changed.
    private func refreshAudio() {
        guard var o = opened else { return }
        let audio = audioSource(runner: o.scene.runner, duration: o.scene.duration, propsURL: o.scene.propsURL,
                                file: o.audioFile)
        let key = audioKey(audio, fps: o.scene.fps, duration: o.scene.duration)
        guard key != o.audioKey else { return }
        o.audio = audio
        o.audioKey = key
        if case .score(let score) = audio { o.info.events = score.eventInfos } else { o.info.events = [] }
        o.info.audioPath = knownAudioPath(audio)
        o.info.loudness = []
        o.info.captions = []
        opened = o
        startAudio()
    }

    /// Synthesize/load + analyze off the main thread; the result returns via `schedule`.
    private func startAudio() {
        guard let o = opened else { return }
        audioGeneration += 1
        if case .none = o.audio { return }
        let generation = audioGeneration, key = o.audioKey, audio = o.audio
        let fps = o.scene.fps, duration = o.scene.duration, name = o.scene.name
        let dir: URL
        do { dir = try audioCacheDir() } catch {
            emit(HostPacket(.warning("audio: \(error.localizedDescription)"))); return
        }
        let schedule = self.schedule, rate = Self.loudnessRate
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try AudioCache.prepare(audio, fps: fps, duration: duration,
                                                         loudnessRate: rate, cacheDir: dir) }
            schedule { [weak self] in self?.audioFinished(result, generation: generation, key: key, scene: name) }
        }
    }

    private func audioFinished(_ result: Result<AudioReady, Error>, generation: Int, key: String, scene name: String) {
        guard generation == audioGeneration, var o = opened, o.audioKey == key else { return }
        switch result {
        case .success(let ready):
            audioDone = (key, ready)
            let captionsChanged = !ready.captions.isEmpty && ready.captions != o.info.captions
            apply(ready, to: &o.info)
            if o.scene.runner.reactsToAudio { try? o.scene.setTrack(ready.track) }
            opened = o
            fputs(String(format: "[swift-render serve] audio %@ ready in %.2fs (%@) → %@\n", name, ready.seconds,
                         ready.cacheHit ? "cache hit" : "synthesized", ready.path ?? "-"), stderr)
            emit(HostPacket(.audio(path: ready.path, loudness: ready.loudness)))
            if captionsChanged { emit(HostPacket(.infoChanged(o.info))) }
        case .failure(let error):
            fputs("[swift-render serve] audio \(name) failed: \(error)\n", stderr)
            emit(HostPacket(.warning("audio: \(error)")))
        }
    }

    // MARK: helpers

    private func requireOpen() throws -> Opened {
        guard let o = opened else { throw HostError(code: HostError.Code.noScene, message: "no scene open — send 'open' first") }
        return o
    }

    private func ok(_ id: Int) -> HostPacket { HostPacket(.response(id, HostResult())) }

    private func bad(_ message: String) -> HostError { HostError(code: HostError.Code.badParams, message: message) }

    /// Relative paths resolve against the project root (else the working directory).
    private func resolve(_ path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded) }
        let base = project?.root ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        return base.appendingPathComponent(expanded).standardizedFileURL
    }

    private func cacheDir() throws -> URL {
        if let project {
            try project.ensureDotDir()
            return project.cacheDir
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("swift-render-host", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func audioCacheDir() throws -> URL {
        if let project { try project.ensureDotDir() }
        return AudioCache.directory(for: project)
    }
}

extension PropsError {
    /// The decode problem without the (temporary) file path.
    var shortDescription: String {
        switch self {
        case .unreadable(_, let why): return "cannot read props: \(why)"
        case .decode(_, let why):     return "props: \(why)"
        }
    }
}
