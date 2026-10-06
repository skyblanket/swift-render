//
//  Score.swift — declare a soundtrack next to the Timeline it scores.
//  Cut times and hit times come from the same Swift constants, so audio
//  cannot drift from video. ScoreSynth renders events offline (deterministic)
//  and the recorder muxes the result automatically.
//
import Foundation

// MARK: - Note
/// A pitch. Named bass notes for LLM ergonomics, or raw Hz (`Note(110)`, `55.0`).
public struct Note: ExpressibleByFloatLiteral, ExpressibleByIntegerLiteral, Sendable {
    public var hz: Double
    public init(_ hz: Double) { self.hz = hz }
    public init(floatLiteral v: Double) { self.init(v) }
    public init(integerLiteral v: Int) { self.init(Double(v)) }
    public static let e1 = Note(41.20), g1 = Note(49.00), a1 = Note(55.00)
    public static let b1 = Note(61.74), c2 = Note(65.41), d2 = Note(73.42)
    public static let e2 = Note(82.41), g2 = Note(98.00), a2 = Note(110.0)
    /// Equal-tempered pitch from a MIDI note number (69 = A4 = 440 Hz).
    public static func midi(_ n: Int) -> Note { Note(440.0 * Foundation.pow(2.0, Double(n - 69) / 12.0)) }
}

// MARK: - ScoreEvent
/// One sound at one absolute time (seconds from scene start). Pure data; the
/// synth renders events into a stereo buffer after the video pass, then muxes.
public struct ScoreEvent: Sendable {
    public enum Sound: Sendable {
        case kick, clap, hat, crash, boom, riser
        case bass(Note)
        case drone(Note)
        case whoosh(rising: Bool)
        case pluck(Note), bell(Note), pad(Note), chip(Note), triBass(Note)
        case laser
        /// Clean, noise-free transition marks — the house alternative to whoosh/riser sweeps.
        case tick, rim, thump
        case blip(Note), swell(Note)
        /// An audio file (foley, stem, a clip's soundtrack). Bypasses the kick duck.
        case sample(SampleRef)
        /// A voiceover line rendered by a local TTS engine. Ducks the music bus.
        case speech(SpeechSpec)
        /// Vinyl crackle bed for `duration` seconds.
        case crackle
    }
    public var time: Double
    public var sound: Sound
    public var amp: Double        // relative loudness; defaults tuned per sound
    public var duration: Double   // 0 → the sound's natural length
    public var pan: Double        // -1 hard left … +1 hard right

    public init(_ time: Double, _ sound: Sound, amp: Double,
                duration: Double = 0, pan: Double = 0) {
        self.time = time; self.sound = sound
        self.amp = amp; self.duration = duration; self.pan = pan
    }
}

// MARK: - ScoreBuilder (mirrors TimelineBuilder exactly)
@resultBuilder
public enum ScoreBuilder {
    public static func buildExpression(_ e: [ScoreEvent]) -> [ScoreEvent] { e }
    public static func buildBlock(_ es: [ScoreEvent]...) -> [ScoreEvent] { es.flatMap { $0 } }
    public static func buildArray(_ es: [[ScoreEvent]]) -> [ScoreEvent] { es.flatMap { $0 } }
    public static func buildOptional(_ e: [ScoreEvent]?) -> [ScoreEvent] { e ?? [] }
    public static func buildEither(first e: [ScoreEvent]) -> [ScoreEvent] { e }
    public static func buildEither(second e: [ScoreEvent]) -> [ScoreEvent] { e }
}

// MARK: - Score
/// A soundtrack as a value: declared next to the Timeline it scores, so cut
/// times and hit times come from the same Swift constants.
public struct Score: Sendable {
    public let duration: Double
    public let events: [ScoreEvent]
    public init(duration: Double, @ScoreBuilder _ content: () -> [ScoreEvent]) {
        self.duration = duration
        self.events = content()
            .filter { $0.time >= 0 && $0.time < duration }
            .sorted { $0.time < $1.time }
    }
}

// MARK: - Single events
public func kick(at t: Double, amp: Double = 0.95) -> [ScoreEvent] {
    [ScoreEvent(t, .kick, amp: amp)]
}
public func clap(at t: Double, amp: Double = 0.4, pan: Double = 0.18) -> [ScoreEvent] {
    [ScoreEvent(t, .clap, amp: amp, pan: pan)]
}
public func hat(at t: Double, amp: Double = 0.09, pan: Double = 0) -> [ScoreEvent] {
    [ScoreEvent(t, .hat, amp: amp, pan: pan)]
}
public func crash(at t: Double, amp: Double = 0.3) -> [ScoreEvent] {
    [ScoreEvent(t, .crash, amp: amp)]
}
public func boom(at t: Double, amp: Double = 1.0, duration: Double = 2.6) -> [ScoreEvent] {
    [ScoreEvent(t, .boom, amp: amp, duration: duration)]
}
public func bass(_ note: Note, at t: Double, duration: Double = 0.5,
                 amp: Double = 0.32) -> [ScoreEvent] {
    [ScoreEvent(t, .bass(note), amp: amp, duration: duration)]
}
@available(*, deprecated, message: "House rule: no swish transitions. Use swell(chord, into:), thump, rim, tick or blip — or let the music mark the cut.")
public func riser(at t: Double, duration: Double = 3.4, amp: Double = 0.55) -> [ScoreEvent] {
    [ScoreEvent(t, .riser, amp: amp, duration: duration)]
}
public func drone(_ note: Note = .a1, from t: Double, for d: Double = 7.0,
                  amp: Double = 0.15) -> [ScoreEvent] {
    [ScoreEvent(t, .drone(note), amp: amp, duration: d)]
}
public func pluck(_ note: Note, at t: Double, amp: Double = 0.16, duration: Double = 0.9, pan: Double = 0) -> [ScoreEvent] {
    [ScoreEvent(t, .pluck(note), amp: amp, duration: duration, pan: pan)]
}
public func bell(_ note: Note, at t: Double, amp: Double = 0.13, duration: Double = 1.6, pan: Double = 0) -> [ScoreEvent] {
    [ScoreEvent(t, .bell(note), amp: amp, duration: duration, pan: pan)]
}
public func pad(_ note: Note, at t: Double, amp: Double = 0.04, duration: Double = 2, pan: Double = 0) -> [ScoreEvent] {
    [ScoreEvent(t, .pad(note), amp: amp, duration: duration, pan: pan)]
}
public func chip(_ note: Note, at t: Double, amp: Double = 0.1, duration: Double = 0.18, pan: Double = 0) -> [ScoreEvent] {
    [ScoreEvent(t, .chip(note), amp: amp, duration: duration, pan: pan)]
}
public func triBass(_ note: Note, at t: Double, amp: Double = 0.3, duration: Double = 0.5, pan: Double = 0) -> [ScoreEvent] {
    [ScoreEvent(t, .triBass(note), amp: amp, duration: duration, pan: pan)]
}
// MARK: Transition marks — short, tonal, no noise sweeps.
// House rule: cuts are marked with these (or with the music itself), never with
// `whoosh`/`riser` swishes.

/// Woodblock-style tick: a dry, high click for cuts and typewriter detail.
public func tick(at t: Double, amp: Double = 0.18, pan: Double = 0) -> [ScoreEvent] {
    [ScoreEvent(t, .tick, amp: amp, pan: pan)]
}
/// Rim knock: a short mid-range tap — a snare-side accent without the noise burst.
public func rim(at t: Double, amp: Double = 0.22, pan: Double = 0) -> [ScoreEvent] {
    [ScoreEvent(t, .rim, amp: amp, pan: pan)]
}
/// Soft felt thump: a low, click-free hit that lands a cut without an 808's tail.
public func thump(at t: Double, amp: Double = 0.5, pan: Double = 0) -> [ScoreEvent] {
    [ScoreEvent(t, .thump, amp: amp, pan: pan)]
}
/// Pure sine blip at `note` — a clean UI-style confirmation.
public func blip(_ note: Note, at t: Double, amp: Double = 0.12, duration: Double = 0.14, pan: Double = 0) -> [ScoreEvent] {
    [ScoreEvent(t, .blip(note), amp: amp, duration: duration, pan: pan)]
}
/// Tonal swell: `note` fades in from silence and stops dead at `t + duration` — a pitched
/// build into a downbeat (the noise-free replacement for `riser`).
public func swell(_ note: Note, at t: Double, duration: Double = 1.5, amp: Double = 0.1, pan: Double = 0) -> [ScoreEvent] {
    [ScoreEvent(t, .swell(note), amp: amp, duration: duration, pan: pan)]
}
public func laser(at t: Double, amp: Double = 0.2, duration: Double = 0.2, pan: Double = 0) -> [ScoreEvent] {
    [ScoreEvent(t, .laser, amp: amp, duration: duration, pan: pan)]
}
/// Play an audio file at `t`. `path` resolves against cwd, assets/, and the package
/// root (see AssetPaths). `amp` 1 = the file's own level; `rate` is varispeed;
/// `offset` skips into the file; `duration` > 0 trims (with a short fade).
public func sample(_ path: String, at t: Double, amp: Double = 1, pan: Double = 0,
                   rate: Double = 1, offset: Double = 0, duration: Double = 0) -> [ScoreEvent] {
    [ScoreEvent(t, .sample(SampleRef(path, rate: rate, offset: offset)), amp: amp, duration: duration, pan: pan)]
}
/// Same file at several anchor times — foley on every cut.
public func samples(_ path: String, at times: [Double], amp: Double = 1, pan: Double = 0) -> [ScoreEvent] {
    times.flatMap { sample(path, at: $0, amp: amp, pan: pan) }
}
/// A voiceover line at `t`, synthesized locally and cached (see Speech). The music
/// bus ducks ~6 dB and the clean bus ~4.5 dB under it. `CaptionTrack(score)` turns these into captions.
public func speak(_ text: String, at t: Double, engine: TTSEngine = .say(), amp: Double = 1,
                  pan: Double = 0) -> [ScoreEvent] {
    [ScoreEvent(t, .speech(SpeechSpec(text, engine: engine)), amp: amp, pan: pan)]
}
/// Vinyl crackle bed from `from` to `to` (fades in and out over `fade`).
public func crackle(from: Double, to: Double, amp: Double = 0.04) -> [ScoreEvent] {
    [ScoreEvent(from, .crackle, amp: amp, duration: max(0, to - from))]
}
@available(*, deprecated, message: "House rule: no swish transitions. Use swell(chord, into:), thump, rim, tick or blip — or let the music mark the cut.")
public func whoosh(at t: Double, rising: Bool = true, amp: Double = 0.5,
                   duration: Double = 0.7) -> [ScoreEvent] {
    [ScoreEvent(t, .whoosh(rising: rising), amp: amp, duration: duration)]
}

// MARK: - Anchors — hits placed on times the scene already computed for its
// Timeline cuts. One source of truth; audio cannot drift from video.
public func crashes(at times: [Double], amp: Double = 0.26) -> [ScoreEvent] {
    times.flatMap { crash(at: $0, amp: amp) }
}
public func kicks(at times: [Double], amp: Double = 0.9) -> [ScoreEvent] {
    times.flatMap { kick(at: $0, amp: amp) }
}
public func booms(at times: [Double], amp: Double = 1.0) -> [ScoreEvent] {
    times.flatMap { boom(at: $0, amp: amp) }
}
/// Kick + crash together on every anchor — the default "cut hit".
public func hits(at times: [Double], amp: Double = 0.9) -> [ScoreEvent] {
    times.flatMap { kick(at: $0, amp: amp) + crash(at: $0, amp: amp * 0.3) }
}

// MARK: - Patterns (from inclusive, to exclusive; bpm 100 → 0.6s beat)
/// Kick every beat, clap on the backbeat — the KineticType groove.
public func fourOnFloor(from: Double, to: Double, bpm: Double = 100,
                        amp: Double = 0.95, claps: Bool = true) -> [ScoreEvent] {
    let beat = 60.0 / bpm
    var out: [ScoreEvent] = []; var t = from; var i = 0
    while t < to - 1e-9 {
        out += kick(at: t, amp: amp)
        if claps && i % 2 == 1 { out += clap(at: t) }
        t += beat; i += 1
    }
    return out
}

/// Closed hats on quarter-beats, alternating accent and L/R pan.
public func hatSixteenths(from: Double, to: Double, bpm: Double = 100,
                          amp: Double = 0.085) -> [ScoreEvent] {
    let step = 60.0 / bpm / 4
    var out: [ScoreEvent] = []; var t = from; var i = 0
    while t < to - 1e-9 {
        out += hat(at: t, amp: i % 2 == 0 ? amp : amp * 0.6,
                   pan: i % 2 == 0 ? -0.5 : 0.5)
        t += step; i += 1
    }
    return out
}

/// One bass note per beat, cycling `notes`. Pairs with fourOnFloor.
public func bassline(_ notes: [Note], from: Double, to: Double, bpm: Double = 100,
                     amp: Double = 0.32) -> [ScoreEvent] {
    guard !notes.isEmpty else { return [] }
    let beat = 60.0 / bpm
    var out: [ScoreEvent] = []; var t = from; var i = 0
    while t < to - 1e-9 {
        out += bass(notes[i % notes.count], at: t + 0.02, duration: beat * 0.85, amp: amp)
        t += beat; i += 1
    }
    return out
}

/// Escape hatch: place anything on a custom grid.
public func every(_ interval: Double, from: Double, to: Double,
                  _ make: (Double) -> [ScoreEvent]) -> [ScoreEvent] {
    var out: [ScoreEvent] = []; var t = from
    while t < to - 1e-9 { out += make(t); t += interval }
    return out
}


// MARK: - ScoreSynth — events → stereo PCM via the Voice bank

public enum ScoreSynth {
    /// Deterministic seed per event so noise voices never depend on order.
    private static func seed(_ index: Int, _ time: Double) -> UInt32 {
        UInt32((index &* 31 &+ Int(time * 1000)) & 0x7FFF_FFFF)
    }

    /// Render a score to stereo Float samples (44.1 kHz). `normalize: false`
    /// skips the final peak normalization (stems, external mixing, calibration).
    public static func render(_ score: Score, normalize: Bool = true) -> (left: [Float], right: [Float]) {
        var mixer = Mixer(duration: score.duration)
        let lines = score.events.compactMap { e -> SpeechSpec? in
            if case .speech(let s) = e.sound { return s }; return nil
        }
        if !lines.isEmpty {
            do { try Speech.prepare(lines) } catch { warnOnce("\(error)") }
        }
        for (i, e) in score.events.enumerated() {
            let a = Float(e.amp)
            let d = Float(e.duration)
            let pan = Float(e.pan)
            switch e.sound {
            case .kick:
                mixer.addKick(Voice.kick(amp: a), at: e.time, pan: pan)
            case .clap:
                mixer.add(Voice.clap(amp: a, seed: 20 + seed(i, e.time) % 7), at: e.time, pan: pan)
            case .hat:
                mixer.add(Voice.hat(amp: a, seed: 40 + seed(i, e.time) % 9), at: e.time, pan: pan)
            case .crash:
                mixer.add(Voice.crash(amp: a, seed: 50 + seed(i, e.time) % 11), at: e.time, pan: pan)
            case .boom:
                mixer.add(Voice.boom(amp: a, dur: d > 0 ? d : 2.6), at: e.time, pan: pan, clean: true)
            case .bass(let note):
                mixer.add(Voice.bassNote(Float(note.hz), amp: a, dur: d > 0 ? d : 0.5), at: e.time, pan: pan)
            case .riser:
                mixer.add(Voice.riser(amp: a, dur: d > 0 ? d : 3.4), at: e.time, pan: pan)
            case .drone(let note):
                mixer.add(Voice.drone(amp: a, dur: d > 0 ? d : 7.0, f: Float(note.hz)), at: e.time, pan: pan)
            case .pluck(let n):
                mixer.add(Voice.pluck(Float(n.hz), amp: a, dur: d > 0 ? d : 0.9), at: e.time, pan: pan)
            case .bell(let n):
                mixer.add(Voice.bell(Float(n.hz), amp: a, dur: d > 0 ? d : 1.6), at: e.time, pan: pan)
            case .pad(let n):
                mixer.add(Voice.pad(Float(n.hz), amp: a, dur: d > 0 ? d : 2), at: e.time, pan: pan)
            case .chip(let n):
                mixer.add(Voice.chip(Float(n.hz), amp: a, dur: d > 0 ? d : 0.18), at: e.time, pan: pan)
            case .triBass(let n):
                mixer.add(Voice.triBass(Float(n.hz), amp: a, dur: d > 0 ? d : 0.5), at: e.time, pan: pan)
            case .tick:
                mixer.add(Voice.tick(amp: a), at: e.time, pan: pan)
            case .rim:
                mixer.add(Voice.rim(amp: a), at: e.time, pan: pan)
            case .thump:
                mixer.add(Voice.thump(amp: a), at: e.time, pan: pan, clean: true)
            case .blip(let n):
                mixer.add(Voice.blip(Float(n.hz), amp: a, dur: d > 0 ? d : 0.14), at: e.time, pan: pan)
            case .swell(let n):
                mixer.add(Voice.swell(Float(n.hz), amp: a, dur: d > 0 ? d : 1.5), at: e.time, pan: pan)
            case .laser:
                mixer.add(Voice.laser(amp: a, dur: d > 0 ? d : 0.2), at: e.time, pan: pan)
            case .whoosh(let rising):
                mixer.add(Voice.whoosh(amp: a, dur: d > 0 ? d : 0.7, rising: rising, seed: 10 + seed(i, e.time) % 13), at: e.time, pan: pan)
            case .sample(let ref):
                do {
                    let b = SampleLibrary.shaped(try SampleLibrary.load(ref.path), rate: ref.rate,
                                                 offset: ref.offset, duration: e.duration)
                    mixer.addStereo(b.left, b.right, at: e.time, gain: a, pan: pan, clean: true)
                } catch { warnOnce("\(error)") }
            case .speech(let spec):
                do {
                    let b = try Speech.buffer(spec)
                    mixer.addVoice(b.left, b.right, at: e.time, gain: a, pan: pan)
                } catch { warnOnce("\(error)") }
            case .crackle:
                let (l, r) = Voice.crackle(amp: a, dur: d > 0 ? d : 4, seed: 70 + seed(i, e.time) % 17)
                mixer.addStereo(l, r, at: e.time, gain: 1, pan: pan, clean: true)
            }
        }
        return mixer.master(normalize: normalize)
    }

    private static let warned = LockedCache<String, Bool>()
    static func warnOnce(_ message: String) {
        _ = warned.value(message) {
            fputs("[swift-render] WARN: \(message)\n", stderr)
            return true
        }
    }

    /// Render and write a 16-bit stereo WAV.
    public static func writeWAV(_ score: Score, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let (l, r) = render(score)
        try WAV.write(left: l, right: r, to: url)
    }

    /// Mono mixdown for in-memory FFT analysis (audio-reactive scenes).
    public static func monoMix(_ score: Score) -> [Float] {
        let (l, r) = render(score)
        var mono = [Float](repeating: 0, count: l.count)
        for i in 0..<l.count { mono[i] = (l[i] + r[i]) * 0.5 }
        return mono
    }
}
