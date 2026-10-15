import AppKit
import AVFoundation
import Foundation
import SwiftRender
import SwiftRenderKit
import SwiftUI

enum AudioSource: Sendable {
    case none
    case file(URL)
    case score(Score)
}

/// `render --progress json` stage lines on stderr (`{"stage":"audio",…}`); off unless the
/// flag is set. The `--jobs` driver turns it off for work it overlaps with the chunks.
enum StageReporter {
    nonisolated(unsafe) static var enabled = false
    static func emit(_ stage: RenderStageLine.Stage, _ detail: String? = nil) {
        guard enabled, let line = try? HostWire.encode(RenderStageLine(stage, detail)) else { return }
        FileHandle.standardError.write(line)
    }
}

/// Resolves an AudioSource into (AudioTrack for reactive scenes, mux URL).
/// Scores synthesize once: samples analyzed in memory, temp WAV only for mux.
struct AudioPlan {
    let track: AudioTrack
    let muxURL: URL?
    private let tempURL: URL?

    func cleanup() { if let tempURL { try? FileManager.default.removeItem(at: tempURL) } }

    static func make(_ source: AudioSource, fps: Int,
                     needsTrack: Bool, needsMux: Bool, announce: Bool = true, tempDir: URL? = nil) throws -> AudioPlan {
        let plan = try resolve(source, fps: fps, needsTrack: needsTrack, needsMux: needsMux, announce: announce,
                               tempDir: tempDir ?? FileManager.default.temporaryDirectory)
        if announce { StageReporter.emit(.render) }
        return plan
    }

    private static func resolve(_ source: AudioSource, fps: Int,
                                needsTrack: Bool, needsMux: Bool, announce: Bool, tempDir: URL) throws -> AudioPlan {
        switch source {
        case .none:
            return AudioPlan(track: .silent, muxURL: nil, tempURL: nil)
        case .file(let url):
            if needsTrack && announce { StageReporter.emit(.audio, "Analyzing \(url.lastPathComponent)") }
            let track = needsTrack ? try AudioAnalyzer.analyze(url: url, fps: fps) : .silent
            return AudioPlan(track: track, muxURL: needsMux ? url : nil, tempURL: nil)
        case .score(let score):
            guard needsTrack || needsMux else {
                return AudioPlan(track: .silent, muxURL: nil, tempURL: nil)
            }
            if announce { StageReporter.emit(.audio, "Synthesizing the score") }
            let (l, r) = ScoreSynth.render(score)
            var track = AudioTrack.silent
            if needsTrack {
                var mono = [Float](repeating: 0, count: l.count)
                for i in 0..<l.count { mono[i] = (l[i] + r[i]) * 0.5 }
                track = try AudioAnalyzer.analyze(samples: mono, sampleRate: scoreSampleRate, fps: fps)
            }
            guard needsMux else { return AudioPlan(track: track, muxURL: nil, tempURL: nil) }
            let tmp = tempDir.appendingPathComponent("sr-score-\(UUID().uuidString).wav")
            try WAV.write(left: l, right: r, to: tmp)
            return AudioPlan(track: track, muxURL: tmp, tempURL: tmp)
        }
    }
}

/// What part of a scene to encode. `duration` is the full scene length the
/// scene body sees; `start`/`end` pick the encoded span (`--range`, `--jobs` chunks).
/// `mux: false` renders picture only but still feeds audio-reactive scenes.
struct RenderSpan {
    var duration: Double
    var start: Double = 0
    var end: Double? = nil
    var mux: Bool = true
    var progress: (@MainActor (Int, Int) -> Void)? = nil
}

/// Type-erased handle on one registered scene. The registry plugin generates
/// `SceneRunner(MyScene.self)` for every scene; everything else is internal.
@MainActor
public struct SceneRunner {
    let kind: SceneKind
    /// Absolute path of the declaring file (set by the registry plugin).
    var sourcePath: String?
    let defaultDuration: Double
    /// Pretty-printed default-props JSON; nil for prop-less scenes.
    let propsTemplate: (() -> String)?
    /// Scene-declared soundtrack, if any: (duration, propsURL) → Score.
    let soundtrack: (Double, URL?) -> Score?
    /// Scene length for these props (props scenes may size themselves to their data).
    let durationFor: (URL?) -> Double
    /// (recorder, outURL, RenderSpan, audioSource, propsURL)
    let render: (Recorder, URL, RenderSpan, AudioSource, URL?) async throws -> Void
    /// (recorder, outURL, t, duration, audioSource, propsURL)
    let frame: (Recorder, URL, Double, Double, AudioSource, URL?) throws -> Void
    let ownsPostFX: Bool
    /// (duration, audioSource, propsURL) → a time → view function (live preview).
    let makeView: (Double, AudioSource, URL?) throws -> (Double) -> AnyView
    /// (duration, analyzed track, propsURL) → a time → view function. Callers that
    /// already hold the AudioTrack (host, check) skip `makeView`'s re-synthesis;
    /// non-reactive scenes ignore the track.
    let makeViewWithTrack: (Double, AudioTrack, URL?) throws -> (Double) -> AnyView

    /// True when frames depend on the AudioTrack (audio / propsAudio kinds).
    var reactsToAudio: Bool { kind == .audio || kind == .propsAudio }

    /// Wraps a `RenderScene` type.
    public init<S: RenderScene>(_ type: S.Type) {
        kind = .render
        defaultDuration = S.defaultDuration
        propsTemplate = nil
        soundtrack = { d, _ in S.soundtrack(duration: d) }
        durationFor = { _ in S.defaultDuration }
        render = { recorder, out, span, source, _ in
            let dur = span.duration
            let plan = try AudioPlan.make(source, fps: recorder.config.fps, needsTrack: false, needsMux: span.mux)
            defer { plan.cleanup() }
            try await recorder.render(to: out, duration: span.end ?? dur, startTime: span.start, sceneDuration: dur,
                                      audioURL: plan.muxURL, postFX: !S.ownsPostFX, progress: span.progress) { t in
                S.body(at: t, duration: dur)
            }
        }
        frame = { recorder, out, t, dur, _, _ in
            try recorder.renderPNG(at: t, to: out, postFX: !S.ownsPostFX, duration: dur) { tt in
                S.body(at: tt, duration: dur)
            }
        }
        ownsPostFX = S.ownsPostFX
        makeView = { dur, _, _ in { t in AnyView(S.body(at: t, duration: dur)) } }
        makeViewWithTrack = { dur, _, _ in { t in AnyView(S.body(at: t, duration: dur)) } }
    }

    /// Wraps an `AudioReactiveScene` type.
    public init<S: AudioReactiveScene>(_ type: S.Type) {
        kind = .audio
        defaultDuration = S.defaultDuration
        propsTemplate = nil
        soundtrack = { d, _ in S.soundtrack(duration: d) }
        durationFor = { _ in S.defaultDuration }
        render = { recorder, out, span, source, _ in
            let dur = span.duration
            let plan = try AudioPlan.make(source, fps: recorder.config.fps, needsTrack: true, needsMux: span.mux)
            defer { plan.cleanup() }
            try await recorder.render(to: out, duration: span.end ?? dur, startTime: span.start, sceneDuration: dur,
                                      audioURL: plan.muxURL, postFX: !S.ownsPostFX, progress: span.progress) { t in
                S.body(at: t, duration: dur, audio: plan.track)
            }
        }
        frame = { recorder, out, t, dur, source, _ in
            let plan = try AudioPlan.make(source, fps: recorder.config.fps, needsTrack: true, needsMux: false)
            try recorder.renderPNG(at: t, to: out, postFX: !S.ownsPostFX, duration: dur) { tt in
                S.body(at: tt, duration: dur, audio: plan.track)
            }
        }
        ownsPostFX = S.ownsPostFX
        makeView = { dur, source, _ in
            let plan = try AudioPlan.make(source, fps: 60, needsTrack: true, needsMux: false)
            return { t in AnyView(S.body(at: t, duration: dur, audio: plan.track)) }
        }
        makeViewWithTrack = { dur, track, _ in { t in AnyView(S.body(at: t, duration: dur, audio: track)) } }
    }

    /// Wraps a `PropsScene` type.
    public init<S: PropsScene>(_ type: S.Type) {
        kind = .props
        defaultDuration = S.defaultDuration
        propsTemplate = { Self.templateJSON(S.defaultProps) }
        soundtrack = { d, url in
            let props = (try? Self.loadProps(S.Props.self, defaults: S.defaultProps, from: url)) ?? S.defaultProps
            return S.soundtrack(duration: d, props: props)
        }
        durationFor = { url in
            let props = (try? Self.loadProps(S.Props.self, defaults: S.defaultProps, from: url)) ?? S.defaultProps
            return S.duration(for: props)
        }
        render = { recorder, out, span, source, propsURL in
            let dur = span.duration
            let props = try Self.loadProps(S.Props.self, defaults: S.defaultProps, from: propsURL)
            let plan = try AudioPlan.make(source, fps: recorder.config.fps, needsTrack: false, needsMux: span.mux)
            defer { plan.cleanup() }
            try await recorder.render(to: out, duration: span.end ?? dur, startTime: span.start, sceneDuration: dur,
                                      audioURL: plan.muxURL, postFX: !S.ownsPostFX, progress: span.progress) { t in
                S.body(at: t, duration: dur, props: props)
            }
        }
        frame = { recorder, out, t, dur, _, propsURL in
            let props = try Self.loadProps(S.Props.self, defaults: S.defaultProps, from: propsURL)
            try recorder.renderPNG(at: t, to: out, postFX: !S.ownsPostFX, duration: dur) { tt in
                S.body(at: tt, duration: dur, props: props)
            }
        }
        ownsPostFX = S.ownsPostFX
        makeView = { dur, _, propsURL in
            let props = try Self.loadProps(S.Props.self, defaults: S.defaultProps, from: propsURL)
            return { t in AnyView(S.body(at: t, duration: dur, props: props)) }
        }
        makeViewWithTrack = { dur, _, propsURL in
            let props = try Self.loadProps(S.Props.self, defaults: S.defaultProps, from: propsURL)
            return { t in AnyView(S.body(at: t, duration: dur, props: props)) }
        }
    }

    /// Wraps a `PropsAudioScene` type.
    public init<S: PropsAudioScene>(_ type: S.Type) {
        kind = .propsAudio
        defaultDuration = S.defaultDuration
        propsTemplate = { Self.templateJSON(S.defaultProps) }
        soundtrack = { d, url in
            let props = (try? Self.loadProps(S.Props.self, defaults: S.defaultProps, from: url)) ?? S.defaultProps
            return S.soundtrack(duration: d, props: props)
        }
        durationFor = { url in
            let props = (try? Self.loadProps(S.Props.self, defaults: S.defaultProps, from: url)) ?? S.defaultProps
            return S.duration(for: props)
        }
        render = { recorder, out, span, source, propsURL in
            let dur = span.duration
            let props = try Self.loadProps(S.Props.self, defaults: S.defaultProps, from: propsURL)
            let plan = try AudioPlan.make(source, fps: recorder.config.fps, needsTrack: true, needsMux: span.mux)
            defer { plan.cleanup() }
            try await recorder.render(to: out, duration: span.end ?? dur, startTime: span.start, sceneDuration: dur,
                                      audioURL: plan.muxURL, postFX: !S.ownsPostFX, progress: span.progress) { t in
                S.body(at: t, duration: dur, props: props, audio: plan.track)
            }
        }
        frame = { recorder, out, t, dur, source, propsURL in
            let props = try Self.loadProps(S.Props.self, defaults: S.defaultProps, from: propsURL)
            let plan = try AudioPlan.make(source, fps: recorder.config.fps, needsTrack: true, needsMux: false)
            try recorder.renderPNG(at: t, to: out, postFX: !S.ownsPostFX, duration: dur) { tt in
                S.body(at: tt, duration: dur, props: props, audio: plan.track)
            }
        }
        ownsPostFX = S.ownsPostFX
        makeView = { dur, source, propsURL in
            let props = try Self.loadProps(S.Props.self, defaults: S.defaultProps, from: propsURL)
            let plan = try AudioPlan.make(source, fps: 60, needsTrack: true, needsMux: false)
            return { t in AnyView(S.body(at: t, duration: dur, props: props, audio: plan.track)) }
        }
        makeViewWithTrack = { dur, track, propsURL in
            let props = try Self.loadProps(S.Props.self, defaults: S.defaultProps, from: propsURL)
            return { t in AnyView(S.body(at: t, duration: dur, props: props, audio: track)) }
        }
    }

    static func loadProps<P: Codable>(_: P.Type, defaults: P, from url: URL?) throws -> P {
        guard let url else { return defaults }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw PropsError.unreadable(url, error.localizedDescription) }
        do { return try JSONDecoder().decode(P.self, from: data) }
        catch let e as DecodingError { throw PropsError.decode(url, describe(e)) }
    }

    private static func templateJSON<P: Codable>(_ value: P) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? enc.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private static func describe(_ e: DecodingError) -> String {
        func path(_ c: [CodingKey]) -> String { c.map(\.stringValue).joined(separator: ".") }
        switch e {
        case .keyNotFound(let k, let ctx): return "missing key '\(k.stringValue)' at \(path(ctx.codingPath))"
        case .typeMismatch(let t, let ctx): return "expected \(t) at \(path(ctx.codingPath))"
        case .valueNotFound(let t, let ctx): return "null for \(t) at \(path(ctx.codingPath))"
        case .dataCorrupted(let ctx): return "invalid JSON: \(ctx.debugDescription)"
        @unknown default: return String(describing: e)
        }
    }
}

enum PropsError: Error, CustomStringConvertible {
    case unreadable(URL, String)
    case decode(URL, String)
    var description: String {
        switch self {
        case .unreadable(let u, let why): return "cannot read props \(u.path): \(why)"
        case .decode(let u, let why):     return "props decode failed for \(u.path): \(why)"
        }
    }
}


extension SceneRunner {
    /// Registry plugin hook: remember where the scene is declared.
    public func source(_ path: String) -> SceneRunner {
        var r = self; r.sourcePath = path; return r
    }

    func summary(name: String) -> SceneSummary {
        SceneSummary(name: name, kind: kind, defaultDuration: defaultDuration,
                     hasSoundtrack: soundtrack(defaultDuration, nil) != nil, hasProps: propsTemplate != nil,
                     sourcePath: sourcePath)
    }
}

// MARK: - Prepared scene

/// One scene resolved for rasterizing single frames: the host's open scene and
/// `check`'s thumbnails. Same `RenderFrame` wrapper as the recorder, and a fresh
/// ImageRenderer per frame (reusing one leaks @State/onAppear between frames).
@MainActor
struct PreparedScene {
    let name: String
    let runner: SceneRunner
    let duration: Double
    let size: CGSize
    let fps: Int
    /// Effective global PostFX (requested and the scene doesn't own it).
    let postFX: Bool
    let propsURL: URL?
    private(set) var make: (Double) -> AnyView

    init(name: String, runner: SceneRunner, duration: Double, size: CGSize, fps: Int,
         postFX: Bool, propsURL: URL?, track: AudioTrack) throws {
        self.name = name; self.runner = runner; self.duration = duration
        self.size = size; self.fps = fps
        self.postFX = postFX && !runner.ownsPostFX
        self.propsURL = propsURL
        self.make = try runner.makeViewWithTrack(duration, track, propsURL)
    }

    /// Swap in a newly analyzed track (only reactive scenes look at it).
    mutating func setTrack(_ track: AudioTrack) throws {
        make = try runner.makeViewWithTrack(duration, track, propsURL)
    }

    /// Raster scale that caps the longest edge at `maxEdge` pixels (never upscales).
    func scale(maxEdge: Int?) -> CGFloat {
        guard let maxEdge, maxEdge > 0 else { return 1 }
        return min(1, CGFloat(maxEdge) / max(size.width, size.height))
    }

    /// Layout at full `size`, rasterized at `scale`: RGBA8 premultiplied, sRGB.
    func image(at t: Double, scale: CGFloat) -> CGImage? {
        autoreleasepool {
            let make = self.make
            let root = RenderFrame(size: size, fps: fps, duration: duration, t: t, postFX: postFX) { make(t) }
            let renderer = ImageRenderer(content: root)
            renderer.scale = scale
            return renderer.cgImage
        }
    }
}
