import AppKit
import AVFoundation
import Foundation
import SwiftRender

/// Package root, resolved from this source file's location (Sources/SwiftRenderCLI/Check.swift).
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

// MARK: - Scaffold

func scaffoldScene(name: String, kind: String) throws -> URL {
    guard name.range(of: #"^[A-Z][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else {
        throw NSError(domain: "new", code: 1, userInfo: [NSLocalizedDescriptionKey: "scene name must be UpperCamelCase"])
    }
    let url = packageRoot.appendingPathComponent("Sources/SwiftRenderScenes/\(name).swift")
    if FileManager.default.fileExists(atPath: url.path) {
        throw NSError(domain: "new", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(url.path) already exists"])
    }
    let audio = kind == "audio"
    let proto = audio ? "AudioReactiveScene" : "RenderScene"
    let sig = audio ? "at t: Double, duration: Double, audio: AudioTrack" : "at t: Double, duration: Double"
    let src = """
    import SwiftUI

    /// \(name) — one line on what this piece is.
    ///
    ///   swift run swift-render check \(name)             # contact sheet + audio report
    ///   swift run swift-render render \(name) --preview --open
    ///   swift run swift-render render \(name) --out out/\(name.lowercased()).mp4
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
                crashes(at: cuts)
                boom(at: cuts[2], amp: 0.6)
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
                    Clip(duration) { l in card("render it.", l) }.transition(.flash())   // runs to the end; Timeline trims
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
    }
    return lines
}
