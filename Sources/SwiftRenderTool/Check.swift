import AppKit
import AVFoundation
import Foundation
import SwiftRender
import SwiftRenderKit

/// Package root, resolved from this source file's location (Sources/SwiftRenderTool/Check.swift).
let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

// MARK: - Stale shader warning

/// Loudly warns when any Shaders/*.metal is newer than the metallib the binary loads —
/// e.g. a shader was edited on a machine without the Metal toolchain.
func warnIfShadersStale() {
    let fm = FileManager.default
    let shaderDir = packageRoot.appendingPathComponent("Sources/SwiftRender/Shaders")
    let bundle = Bundle.main.bundleURL.appendingPathComponent("SwiftRender_SwiftRender.bundle")
    let candidates = [bundle.appendingPathComponent("default.metallib"),
                      bundle.appendingPathComponent("Contents/Resources/default.metallib")]
    guard let lib = candidates.first(where: { fm.fileExists(atPath: $0.path) }),
          let libDate = (try? fm.attributesOfItem(atPath: lib.path))?[.modificationDate] as? Date,
          let files = try? fm.contentsOfDirectory(atPath: shaderDir.path) else { return }
    let stale = files.filter { $0.hasSuffix(".metal") }.filter {
        let d = (try? fm.attributesOfItem(atPath: shaderDir.appendingPathComponent($0).path))?[.modificationDate] as? Date
        return (d ?? .distantPast) > libDate.addingTimeInterval(1)
    }
    if !stale.isEmpty {
        fputs("""
        [swift-render] WARNING: shaders newer than the compiled metallib: \(stale.joined(separator: ", "))
        [swift-render]          edits are NOT in this render. Install the compiler and rebuild:
        [swift-render]          xcodebuild -downloadComponent MetalToolchain && swift build

        """, stderr)
    }
}

// MARK: - Frame analysis

/// Luminance standard deviation of an image (0…1). Near zero = a flat/blank frame.
func luminanceSpread(_ url: URL) -> Double? {
    guard let img = NSImage(contentsOf: url),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    let w = 64, h = 36
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let ok = px.withUnsafeMutableBytes { buf -> Bool in
        guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    guard ok else { return nil }
    var sum = 0.0, sq = 0.0
    for i in 0..<(w * h) {
        let l = (0.299 * Double(px[i * 4]) + 0.587 * Double(px[i * 4 + 1]) + 0.114 * Double(px[i * 4 + 2])) / 255
        sum += l; sq += l * l
    }
    let n = Double(w * h), mean = sum / n
    return max(0, sq / n - mean * mean).squareRoot()
}

// MARK: - Audio analysis

func loadAudioFile(_ url: URL) throws -> (left: [Float], right: [Float], rate: Double) {
    let file = try AVAudioFile(forReading: url)
    let fmt = AVAudioFormat(standardFormatWithSampleRate: file.processingFormat.sampleRate, channels: 2)!
    guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
        throw NSError(domain: "check", code: 1)
    }
    try file.read(into: buf)
    let n = Int(buf.frameLength)
    let ch = Int(buf.format.channelCount)
    guard let data = buf.floatChannelData else { throw NSError(domain: "check", code: 2) }
    let l = Array(UnsafeBufferPointer(start: data[0], count: n))
    let r = ch > 1 ? Array(UnsafeBufferPointer(start: data[1], count: n)) : l
    _ = fmt
    return (l, r, file.processingFormat.sampleRate)
}

func dB(_ x: Double) -> Double { x > 1e-9 ? 20 * log10(x) : -120 }

/// A compact, human- and LLM-readable audio report.
func audioReport(left: [Float], right: [Float], rate: Double, events: [ScoreEvent]?) -> [String] {
    var lines: [String] = []
    let n = left.count
    guard n > 0 else { return ["audio: none"] }
    var peak: Float = 0, clips = 0, sq = 0.0
    for i in 0..<n {
        let a = max(abs(left[i]), abs(right[i]))
        peak = max(peak, a)
        if a >= 0.999 { clips += 1 }
        sq += Double(left[i] * left[i] + right[i] * right[i]) * 0.5
    }
    let rms = (sq / Double(n)).squareRoot()
    lines.append(String(format: "audio: %.2fs · peak %.1f dBFS · RMS %.1f dBFS · clipped samples %d",
                        Double(n) / rate, dB(Double(peak)), dB(rms), clips))

    // loudness lane, one glyph per 0.5 s
    let win = Int(rate * 0.5)
    var lane = "", silences: [(Double, Double)] = []
    let blocks = Array("▁▂▃▄▅▆▇█")
    var silentStart: Double? = nil
    var i = 0
    while i < n {
        let e = min(n, i + win)
        var s = 0.0
        for j in i..<e { s += Double(left[j] * left[j] + right[j] * right[j]) * 0.5 }
        let level = dB((s / Double(e - i)).squareRoot())
        let k = Int(max(0, min(7, (level + 48) / 48 * 8)))
        lane.append(level < -60 ? " " : blocks[k])
        let t = Double(i) / rate
        if level < -45 { if silentStart == nil { silentStart = t } }
        else if let s0 = silentStart { if t - s0 >= 0.5 { silences.append((s0, t)) }; silentStart = nil }
        i = e
    }
    lines.append("loudness (0.5s/char): |\(lane)|")
    let inner = silences.filter { $0.0 > 0.01 }
    if !inner.isEmpty {
        lines.append("silences: " + inner.map { String(format: "%.1f–%.1fs", $0.0, $0.1) }.joined(separator: ", "))
    }
    if clips > 0 { lines.append("⚠︎ clipping — lower amps or hits") }
    if dB(rms) < -26 { lines.append("⚠︎ quiet mix (RMS < -26 dBFS) — the score is mostly sparse/transient") }

    if let events {
        var counts: [String: Int] = [:]
        var pitched = Set<String>()
        for e in events {
            switch e.sound {
            case .sample: counts["sample", default: 0] += 1
            case .speech: counts["speech", default: 0] += 1
            default:
                let d = String(describing: e.sound)
                let kind = String(d.prefix(while: { $0 != "(" }))
                counts[kind, default: 0] += 1
                if d.contains("(") { pitched.insert(d) }
            }
        }
        lines.append("events: " + counts.sorted { $0.value > $1.value }.map { "\($0.key)×\($0.value)" }.joined(separator: " "))
        let perc = (counts["hat"] ?? 0) + (counts["kick"] ?? 0) + (counts["clap"] ?? 0)
        lines.append("variety: \(pitched.count) distinct pitched events")
        if events.count > 40, Double(perc) / Double(events.count) > 0.75 {
            lines.append("⚠︎ mostly percussion loops — consider pads/plucks/bells for movement")
        }
        let sweeps = (counts["whoosh"] ?? 0) + (counts["riser"] ?? 0)
        if sweeps > 0 {
            lines.append("⚠︎ \(sweeps) noise sweep(s) (whoosh/riser) — house rule: no swish transitions; "
                         + "use swell/tick/rim/thump/blip or let the music mark the cut")
        }
    }
    return lines
}

// MARK: - Contact sheet + check (CLI `contact`/`check`, host `check`)

/// The audio a check reports on. Score samples are passed in so callers that
/// already synthesized (the host's cache, the CLI's track analysis) don't again.
enum CheckAudio {
    case none
    case file(URL)
    case score(Score, left: [Float], right: [Float])
}

struct ContactSheetResult {
    /// Sample time and luminance spread (nil = unreadable) per cell.
    var samples: [(t: Double, spread: Double?)]
    /// Seconds between samples.
    var step: Double
    var msPerThumb: Double
}

struct CheckResult {
    var contact: URL
    var report: [String]
    var reportURL: URL
}

/// Renders `cols×rows` 384-px-wide thumbnails into a labelled grid PNG at `out`.
/// Layout stays at the scene's full size; ImageRenderer downscales.
@MainActor
func renderContactSheet(_ scene: PreparedScene, cols: Int, rows: Int, to out: URL) throws -> ContactSheetResult {
    let n = cols * rows
    // Sample each cell's midpoint: endpoints land on beat-grid cuts and fades,
    // which are exactly the frames that don't represent the shot.
    let step = scene.duration / Double(max(1, n))
    let scale = 384.0 / scene.size.width
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("sr-contact-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }
    var cells: [(t: Double, url: URL)] = []
    let t0 = Date()
    for i in 0..<n {
        let t = (Double(i) + 0.5) * step
        HostCrashLog.note("check \(scene.name) t=\(t)")
        guard let image = scene.image(at: t, scale: scale), let png = FrameEncoding.encode(image, format: "png") else {
            throw NSError(domain: "check", code: 3, userInfo: [NSLocalizedDescriptionKey: "frame at t=\(t) produced no image"])
        }
        let cell = tmpDir.appendingPathComponent(String(format: "c%03d.png", i))
        try png.write(to: cell)
        cells.append((t, cell))
    }
    let perFrame = Date().timeIntervalSince(t0) / Double(max(1, n))
    try composeContactSheet(cells: cells, columns: cols, to: out)
    return ContactSheetResult(samples: cells.map { ($0.t, luminanceSpread($0.url)) }, step: step,
                              msPerThumb: perFrame * 1000)
}

/// `check`: contact sheet, blank-frame scan and audio report; also writes the
/// report next to the sheet as `<name>.txt`.
@MainActor
func runCheck(_ scene: PreparedScene, audio: CheckAudio, cols: Int = 4, rows: Int = 4,
              contact out: URL) throws -> CheckResult {
    let sheet = try renderContactSheet(scene, cols: cols, rows: rows, to: out)
    let duration = scene.duration
    var report: [String] = []
    report.append(String(format: "scene %@ · %.2fs · %d×%d @ %dfps · %d frames · %.0f ms/thumb",
                         scene.name, duration, Int(scene.size.width), Int(scene.size.height), scene.fps,
                         Int(duration * Double(scene.fps)), sheet.msPerThumb))
    let flat = sheet.samples.compactMap { s -> Double? in
        guard let sd = s.spread else { return nil }
        return sd < 0.015 ? s.t : nil
    }
    if flat.isEmpty { report.append("frames: no blank samples") }
    else {
        let edge = flat.allSatisfy { $0 < sheet.step || $0 > duration - sheet.step }
        report.append("frames: flat/blank at " + flat.map { String(format: "%.2fs", $0) }.joined(separator: ", ")
                      + (edge ? " (start/end fades — fine)" : "  ⚠︎ check these"))
    }
    switch audio {
    case .score(let score, let l, let r):
        report += audioReport(left: l, right: r, rate: scoreSampleRate, events: score.events)
        report += mediaReport(score)
    case .file(let url):
        let a = try loadAudioFile(url)
        report += audioReport(left: a.left, right: a.right, rate: a.rate, events: nil)
    case .none:
        report.append("audio: none — add `soundtrack(duration:)` or pass --audio")
    }
    let txt = out.deletingPathExtension().appendingPathExtension("txt")
    try (report.joined(separator: "\n") + "\n").write(to: txt, atomically: true, encoding: .utf8)
    return CheckResult(contact: out, report: report, reportURL: txt)
}

// MARK: - Scaffold

func scaffoldScene(name: String, kind: String) throws -> URL {
    guard name.range(of: #"^[A-Z][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else {
        throw NSError(domain: "new", code: 1, userInfo: [NSLocalizedDescriptionKey: "scene name must be UpperCamelCase"])
    }
    // Project-aware: swift-render.json's scenesDir (e.g. a Launch/ package's
    // Sources/LaunchScenes), else this repo's demo target. Scenes never live in
    // the SwiftRender module itself, so the template always imports it.
    let project = Project.discover()
    let root = project?.root ?? packageRoot
    let dir = project?.config.scenesDir ?? "Sources/SwiftRenderScenes"
    let cli = project?.config.product ?? "swift-render"     // `launch` in a Launch/ package
    let url = root.appendingPathComponent(dir).appendingPathComponent("\(name).swift")
    if FileManager.default.fileExists(atPath: url.path) {
        throw NSError(domain: "new", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(url.path) already exists"])
    }
    let audio = kind == "audio"
    let proto = audio ? "AudioReactiveScene" : "RenderScene"
    let sig = audio ? "at t: Double, duration: Double, audio: AudioTrack" : "at t: Double, duration: Double"
    let src = """
    import SwiftRender
    import SwiftUI

    /// \(name) — one line on what this piece is.
    ///
    ///   swift run \(cli) check \(name)             # contact sheet + audio report
    ///   swift run \(cli) render \(name) --preview --open
    ///   swift run \(cli) render \(name) --out out/\(name.lowercased()).mp4
    public struct \(name): \(proto) {
        public static let defaultDuration: Double = 8.0

        static let bpm = 110.0
        static let beat = 60.0 / bpm
        static let bar = beat * 4
        /// Cut times — the Timeline and the Score both read these, so A/V can't drift.
        static let cuts: [Double] = [bar, bar * 2, bar * 3]

        public static func soundtrack(duration: Double) -> Score? {
            Score(duration: duration) {
                chordPad(.minor7(.a3), at: 0, duration: bar * 2)
                chordPad(.major7(.f3), at: bar * 2, duration: duration - bar * 2)
                arpeggio(.minor7(.a4), from: bar, to: bar * 2, step: beat / 2)
                cuts.flatMap { thump(at: $0, amp: 0.45) }   // hard cuts on the bar
                swell(.a3, at: cuts[2] - 1.5, duration: 1.5)
            }
        }

        @MainActor public static func body(\(sig)) -> some View {
            let fade = Ease.easeIn(Ease.clip(t, duration - 0.5, duration))
            return ZStack {
                Color.black.ignoresSafeArea()
                Timeline(t) {
                    Clip(bar) { l in card("\(name.uppercased())", l) }
                    Clip(bar) { l in card("every frame", l) }.transition(.fade(0.3))
                    Clip(bar) { l in card("is a function of t", l) }.transition(.slide(0.4, from: .trailing))
                    Clip(duration) { l in card("render it.", l) }.transition(.fade(0.5))   // runs to the end; Timeline trims
                }
            }
            .opacity(1 - fade)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }

        @ViewBuilder @MainActor
        static func card(_ text: String, _ t: Double) -> some View {
            let s = Ease.spring(t, from: 1.2, to: 1.0, response: 0.4, dampingFraction: 0.65)
            Text(text)
                .font(.system(size: 140, weight: .black)).fontWidth(.condensed)
                .foregroundStyle(.white)
                .scaleEffect(s)
                .opacity(Ease.easeOut(Ease.clip(t, 0, 0.25)))
        }
    }

    """
    try src.write(to: url, atomically: true, encoding: .utf8)
    return url
}

/// Samples and voiceover: missing files, speech coverage, caption cues.
func mediaReport(_ score: Score) -> [String] {
    var lines: [String] = []
    let refs = Set(score.events.compactMap { e -> String? in
        if case .sample(let r) = e.sound { return r.path }; return nil
    })
    if !refs.isEmpty {
        let missing = refs.filter { AssetPaths.resolve($0) == nil }.sorted()
        lines.append("samples: \(refs.count) files" + (missing.isEmpty ? " · all found" : " · ⚠︎ missing: " + missing.joined(separator: ", ")))
    }
    let speech = score.events.compactMap { e -> SpeechSpec? in
        if case .speech(let s) = e.sound { return s }; return nil
    }
    if !speech.isEmpty {
        let secs = speech.reduce(0.0) { $0 + ((try? Speech.buffer($1).duration) ?? 0) }
        let cues = CaptionTrack(score).cues.count
        lines.append(String(format: "voiceover: %d lines · %.1fs of speech · %d caption cues (swift-render captions)",
                            speech.count, secs, cues))
        lines += voiceBalanceReport(score)
    }
    return lines
}

// MARK: - Voice vs music

/// How far the voiceover sits above the (ducked) music while someone is speaking.
/// Renders the full mix and a voice-only stem un-normalized; music = mix − voice.
func voiceBalanceReport(_ score: Score) -> [String] {
    let speechEvents = score.events.filter { if case .speech = $0.sound { return true }; return false }
    guard !speechEvents.isEmpty, speechEvents.count < score.events.count else { return [] }
    let mix = ScoreSynth.render(score, normalize: false)
    let voiceOnly = Score(duration: score.duration) { speechEvents }
    let voice = ScoreSynth.render(voiceOnly, normalize: false)
    let n = min(mix.left.count, voice.left.count)
    let win = Int(scoreSampleRate * 0.5)
    var windows: [(t: Double, v: Double, m: Double)] = []
    var i = 0
    while i + win <= n {
        var v = 0.0, m = 0.0
        for j in i..<(i + win) {
            let vl = Double(voice.left[j]), vr = Double(voice.right[j])
            let ml = Double(mix.left[j]) - vl, mr = Double(mix.right[j]) - vr
            v += (vl * vl + vr * vr) * 0.5; m += (ml * ml + mr * mr) * 0.5
        }
        windows.append((Double(i) / scoreSampleRate, dB((v / Double(win)).squareRoot()), dB((m / Double(win)).squareRoot())))
        i += win
    }
    // Judge only windows where the voice is really talking (within 10 dB of its typical
    // level) — half-second windows that catch a line's tail would read as "buried".
    let voiced = windows.filter { $0.v > -60 }.map(\.v).sorted()
    guard !voiced.isEmpty else { return [] }
    let typical = voiced[voiced.count / 2]
    let speaking = windows.filter { $0.v > typical - 10 && $0.m > -90 }
    let gaps = speaking.map { $0.v - $0.m }
    let buried = speaking.filter { $0.v - $0.m < 6 }.map(\.t)
    guard !gaps.isEmpty else { return [] }
    let sorted = gaps.sorted()
    let median = sorted[sorted.count / 2], low = sorted[max(0, sorted.count / 10)]
    var line = String(format: "voice vs music: voice sits %+.1f dB above the music (median while speaking; 10th pct %+.1f dB)",
                      median, low)
    if low < 6 { line += "  ⚠︎ voice may be buried in places — lower pads/drums under speech" }
    else if median > 30 { line += "  · music bed is very quiet under speech" }
    var out = [line]
    if low < 6 && !buried.isEmpty {
        var spans: [(Double, Double)] = []
        for t in buried {
            if let last = spans.last, t - last.1 < 0.01 { spans[spans.count - 1].1 = t + 0.5 }
            else { spans.append((t, t + 0.5)) }
        }
        out.append("  buried (< 6 dB) at: " + spans.prefix(8).map { String(format: "%.1f–%.1fs", $0.0, $0.1) }
            .joined(separator: ", ") + (spans.count > 8 ? ", …" : ""))
    }
    return out
}

// MARK: - Smoke test

/// Renders one small frame of every registered scene and checks every soundtrack
/// for noise sweeps. Exit status 1 on any failure — run in CI.
@MainActor
func runSmoke(scale: Double) -> Bool {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sr-smoke-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let recorder = Recorder(config: Recorder.Config(fps: 30, size: AspectPreset.landscape16x9.size, scale: scale))
    var failures: [String] = []
    let started = Date()
    for name in sceneRunners.keys.sorted() {
        let runner = sceneRunners[name]!
        let t0 = Date()
        let duration = runner.durationFor(nil)
        let score = runner.soundtrack(duration, nil)
        do {
            try runner.frame(recorder, tmp.appendingPathComponent("\(name).png"), duration * 0.5, duration,
                             score.map { .score($0) } ?? .none, nil)
            let sweeps = (score?.events ?? []).filter {
                switch $0.sound { case .whoosh, .riser: return true; default: return false }
            }.count
            if sweeps > 0 { failures.append("\(name): \(sweeps) whoosh/riser event(s) — house rule: no swish transitions") }
            let padded = name.padding(toLength: 24, withPad: " ", startingAt: 0)
            print(String(format: "  ok  %@ %5.0f ms", padded, Date().timeIntervalSince(t0) * 1000))
        } catch {
            failures.append("\(name): \(error)")
            print("  FAIL \(name): \(error)")
        }
    }
    print(String(format: "[swift-render] smoke: %d scenes in %.1fs, %d failure(s)",
                 sceneRunners.count, Date().timeIntervalSince(started), failures.count))
    for f in failures { fputs("  ✗ \(f)\n", stderr) }
    return failures.isEmpty
}
