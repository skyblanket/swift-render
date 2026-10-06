import Foundation
import SwiftRender
import SwiftRenderKit
import SwiftUI

// MARK: - Scene info (shared by `info`, `serve` and the MCP server)

/// Probe a scene into editor/agent metadata: clips, knobs, score events,
/// captions, loudness and the audio file to play in sync.
/// `audioPath` is the file the caller will play (score WAV or --audio file).
@MainActor
func buildSceneInfo(name: String, runner: SceneRunner, duration: Double, size: CGSize, fps: Int,
                    audio: AudioSource, propsURL: URL?, audioPath: String?,
                    loudnessRate: Double = 50) throws -> SceneInfo {
    let make = try runner.makeView(duration, audio, propsURL)
    let structure = SceneProbe.probe(duration: duration, size: size, fps: fps, make: make)

    var events: [ScoreEventInfo] = []
    var captions: [CaptionInfo] = []
    var loudness: [Float] = []
    switch audio {
    case .score(let score):
        events = score.eventInfos
        captions = CaptionTrack(score).cues.map { CaptionInfo(start: $0.start, end: $0.end, text: $0.text) }
        let (l, r) = ScoreSynth.render(score)
        var mono = [Float](repeating: 0, count: l.count)
        for i in 0..<l.count { mono[i] = (l[i] + r[i]) * 0.5 }
        if let track = try? AudioAnalyzer.analyze(samples: mono, sampleRate: scoreSampleRate, fps: Int(loudnessRate)) {
            loudness = envelope(track, duration: duration, rate: loudnessRate)
        }
    case .file(let url):
        if let track = try? AudioAnalyzer.analyze(url: url, fps: Int(loudnessRate)) {
            loudness = envelope(track, duration: duration, rate: loudnessRate)
        }
    case .none:
        break
    }

    var propsJSON: String? = nil
    if runner.propsTemplate != nil {
        if let propsURL, let text = try? String(contentsOf: propsURL, encoding: .utf8) { propsJSON = text }
        else { propsJSON = runner.propsTemplate?() }
    }

    return SceneInfo(name: name, kind: runner.kind, duration: duration,
                     width: Int(size.width), height: Int(size.height), fps: fps,
                     clips: structure.clips, events: events, knobs: structure.knobs, captions: captions,
                     propsJSON: propsJSON, audioPath: audioPath,
                     loudness: loudness, loudnessRate: loudnessRate, sourcePath: runner.sourcePath)
}

private func envelope(_ track: AudioTrack, duration: Double, rate: Double) -> [Float] {
    let n = max(0, Int((duration * rate).rounded(.up)))
    return (0..<n).map { Float(track.level(at: Double($0) / rate)) }
}

// MARK: - swift-render info <Scene> [--json] [--duration s] [--fps n] [--aspect a] [--props f] [--audio f]

@MainActor
func runInfo(_ args: [String]) throws {
    guard let name = args.first, !name.hasPrefix("-") else {
        fputs("usage: swift-render info <Scene> [--json] [--duration s] [--fps n] [--aspect 16:9|9:16|1:1] [--props file] [--audio file]\n", stderr)
        exit(64)
    }
    guard let runner = sceneRunners[name] else {
        fputs("Unknown scene: \(name)\n", stderr); exit(1)
    }
    var json = false, duration: Double? = nil, fps = 60, aspect = AspectPreset.landscape16x9
    var props: String? = nil, audioFile: String? = nil
    var i = 1
    while i < args.count {
        let k = args[i], v = i + 1 < args.count ? args[i + 1] : ""
        switch k {
        case "--json": json = true; i += 1
        case "--duration": duration = Double(v); i += 2
        case "--fps": fps = Int(v) ?? fps; i += 2
        case "--aspect": aspect = AspectPreset(rawValue: v) ?? aspect; i += 2
        case "--props": props = v; i += 2
        case "--audio": audioFile = v; i += 2
        default: fputs("Unknown option: \(k)\n", stderr); exit(64)
        }
    }
    let project = Project.discover()
    KnobStore.shared.load(scene: name, project: project)
    let dur = duration ?? runner.defaultDuration
    let audio: AudioSource
    if let audioFile { audio = .file(URL(fileURLWithPath: audioFile)) }
    else if let score = runner.soundtrack(dur) { audio = .score(score) }
    else { audio = .none }

    let info = try buildSceneInfo(name: name, runner: runner, duration: dur, size: aspect.size, fps: fps,
                                  audio: audio, propsURL: props.map { URL(fileURLWithPath: $0) },
                                  audioPath: audioFile)
    if json {
        var slim = info
        slim.loudness = []      // keep agent-facing JSON small; serve carries the envelope
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try enc.encode(slim), as: UTF8.self))
        return
    }
    print(String(format: "%@ · %@ · %.2fs · %d×%d @ %dfps", name, info.kind.rawValue, info.duration,
                 info.width, info.height, info.fps))
    if let src = info.sourcePath { print("source  \(src)") }
    if info.clips.isEmpty { print("clips   (none reported — scene doesn't use Timeline)") }
    for c in info.clips {
        let indent = String(repeating: "  ", count: c.depth)
        let label = c.label ?? c.source.map { "\(($0.file as NSString).lastPathComponent):\($0.line)" } ?? c.id
        print(String(format: "clip    %@%6.2f–%6.2f  %@  (%@)", indent, c.start, c.end, label, c.transitionIn))
    }
    for k in info.knobs { print("knob    \(k.key) = \(k.value)  (default \(k.defaultValue))") }
    if !info.events.isEmpty {
        let kinds = Dictionary(grouping: info.events, by: \.kind).map { "\($0.key)×\($0.value.count)" }.sorted()
        print("score   \(info.events.count) events: \(kinds.joined(separator: " "))")
    }
    for c in info.captions { print(String(format: "caption %6.2f–%6.2f  %@", c.start, c.end, c.text)) }
}
