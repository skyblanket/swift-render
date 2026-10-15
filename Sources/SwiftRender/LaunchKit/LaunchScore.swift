import Foundation
import SwiftRenderKit

// MARK: - LaunchScore
//
// The soundtrack for a LaunchPlan: harmony first (a pad chord per bar, a soft
// groove under the middle of the film), cuts marked with the house transition
// marks — `thump` on the three big landings, `rim` on cards and rows, `tick` on
// code and typing, `blip` on numbers, `swell` into the hero and the end card.
// No whoosh, riser or crash. Every hit time comes from the same functions the
// visuals use (`FeatureTriad.landTimes`, `CodeReveal.lineTimes`, …).

/// Builds the soundtrack for a `LaunchPlan` (see above).
public enum LaunchScore {
    /// Shared timing so the visuals and the score agree.
    public enum Cue {
        /// Card i of the triad starts on beat i (+0.1 s so the spring peaks just after).
        public static func triadStart(_ plan: LaunchPlan) -> Double { 0.1 }
        /// The code shot reveals a line every sixth of a beat.
        public static func codeMode(_ plan: LaunchPlan) -> CodeReveal.Mode { .lines(step: plan.beat / 6) }
        /// When the code shot's reveal starts.
        public static let codeStart = 0.35
        /// When the terminal shot's session starts.
        public static let terminalStart = LaunchTerminal.start
        /// The base typing speed; a long session types faster (`terminalSpeed`).
        public static let terminalCPS = LaunchTerminal.cps
        /// Typing speed for this film's terminal shot: fitted so the session finishes
        /// `LaunchTerminal.hold` before the cut. The picture and the keystroke ticks both use it.
        public static func terminalSpeed(_ plan: LaunchPlan, _ p: LaunchProps) -> Double {
            LaunchTerminal.cps(p.terminal ?? [], length: plan.index(of: .terminal).map(plan.length) ?? .infinity)
        }
        /// The hero's specular sweep and name reveal sit on the beat grid (beat 2), so they move
        /// with the tempo — and the blip and bell that mark them move with them.
        public static func heroSweep(_ plan: LaunchPlan) -> Double { plan.beat * 2 - 0.2 }
        /// When the hero's name starts to focus in.
        public static func heroName(_ plan: LaunchPlan) -> Double { plan.beat * 2 - 0.1 }
        /// When the hero's tagline rises.
        public static func heroTagline(_ plan: LaunchPlan) -> Double { plan.beat * 3 + 0.1 }
        /// Stats land one per beat.
        public static func statStagger(_ plan: LaunchPlan) -> Double { plan.beat }
        /// When the first stat starts counting.
        public static let statStart = 0.1
        /// Feature and changelog rows land every half beat.
        public static func rowStagger(_ plan: LaunchPlan) -> Double { plan.beat / 2 }
    }

    /// Chord per bar for each shot (degrees in D, transposed by `music.key`).
    public static func chords(for kind: LaunchShot.Kind, key: Int) -> [Chord] {
        func n(_ midi: Int) -> Note { Note.midi(midi + key) }
        let I = Chord(n(50), [0, 4, 7, 11]), Iadd9 = Chord(n(50), [0, 4, 7, 14])
        let vi = Chord(n(47), [0, 3, 7, 10, 14]), IV = Chord(n(55), [0, 4, 7, 11]), IVadd9 = Chord(n(55), [0, 4, 7, 14])
        let Vsus = Chord(n(57), [0, 5, 7, 10]), iii = Chord(n(54), [0, 3, 7, 10]), ii = Chord(n(52), [0, 3, 7, 10, 14])
        switch kind {
        case .open: return [I]
        case .hero: return [Iadd9, vi]
        case .title: return [IV, Vsus]
        case .triad: return [I, vi]
        case .more: return [IVadd9, iii]
        case .device, .code: return [IV, Vsus]
        case .terminal: return [vi, IV]
        case .stats: return [ii, Vsus]
        case .changelog: return [vi, IVadd9]
        case .platforms: return [Vsus]
        case .end: return [I, Iadd9, I]
        }
    }

    /// Lines spoken over each shot when `voiceover` is on: `voiceoverLines[id]`, else generated.
    public static func voiceoverLines(_ plan: LaunchPlan, _ p: LaunchProps) -> [(time: Double, text: String)] {
        guard p.voiceover else { return [] }
        var out: [(Double, String)] = []
        for (i, shot) in plan.shots.enumerated() {
            let custom = p.voiceoverLines?[shot.id]
            let line: String?
            switch shot.kind {
            case .hero: line = custom ?? "Introducing \(p.name)."
            case .title: line = custom ?? p.tagline
            case .triad:
                let f = p.features.prefix(FeatureTriad.shown(p.features.count)).map(\.title)
                line = custom ?? (f.count >= 3 ? f.dropLast().map { "\($0)." }.joined(separator: " ") + " And \(f.last!.lowercased())." : nil)
            case .end: line = custom ?? "\(p.name). Available now."
            default: line = custom
            }
            if let line, !line.isEmpty { out.append((plan.starts[i] + 0.3, line)) }
        }
        return out
    }

    /// The full score for `plan`: harmony, groove (unless the mood is calm), cue hits and any voiceover.
    public static func make(_ plan: LaunchPlan, _ p: LaunchProps, duration: Double? = nil) -> Score {
        let beat = plan.beat, bar = plan.bar
        let key = p.music.key
        let groove = p.music.mood != .calm
        var ev: [ScoreEvent] = []

        for (i, shot) in plan.shots.enumerated() {
            let s0 = plan.starts[i], len = plan.length(i)
            let bars = max(1, Int(shot.bars.rounded(.up)))
            let chords = Self.chords(for: shot.kind, key: key)
            let hasDrums = groove && ![.open, .hero, .platforms, .end].contains(shot.kind)

            // Harmony: one pad chord per bar, a bass root, a light arpeggio once the groove is in.
            for b in 0..<bars {
                let t = s0 + Double(b) * bar
                guard t < s0 + len - 0.01 else { break }
                let chord = chords[b % chords.count]
                let barLen = min(bar, s0 + len - t)
                ev += chordPad(chord, at: t, duration: barLen + 0.35, amp: 0.024)
                let root = chord.root.transposed(-12)
                if shot.kind != .open {
                    ev += triBass(root, at: t, amp: 0.2, duration: beat * 1.6)
                    if barLen > beat * 2.5 { ev += triBass(chord.notes[2].transposed(-12), at: t + beat * 2.5, amp: 0.15, duration: beat) }
                }
                if hasDrums {
                    ev += kick(at: t, amp: 0.34)
                    ev += kick(at: t + beat * 2, amp: 0.28)
                    if Motion.hash(i * 31 + b) > 0.5 { ev += kick(at: t + beat * 3.5, amp: 0.16) }
                    for x in [1.0, 3.0] where x * beat < barLen { ev += clap(at: t + x * beat, amp: 0.12, pan: 0.15) }
                    let hatBars = p.music.mood == .driving || b % 2 == 1
                    if hatBars {
                        for s in stride(from: 0.5, to: 4.0, by: 1.0) where s * beat < barLen {
                            ev += hat(at: t + s * beat, amp: 0.028, pan: s < 2 ? -0.25 : 0.25)
                        }
                    }
                    let tones = chord.notes.map { $0.transposed(12) }
                    for e in 0..<8 where Double(e) * beat / 2 < barLen && Motion.hash(i * 97 + b * 8 + e) > 0.28 {
                        let n = tones[(e * 2 + b) % tones.count]
                        ev += pluck(n, at: t + Double(e) * beat / 2, amp: 0.034, duration: 0.55, pan: Double(e % 3 - 1) * 0.25)
                    }
                }
            }

            // Marks
            switch shot.kind {
            case .open:
                ev += bell(Note.midi(74 + key), at: s0 + beat * 2, amp: 0.05, duration: 2.2, pan: -0.2)
                ev += bell(Note.midi(81 + key), at: s0 + beat * 3, amp: 0.035, duration: 2.0, pan: 0.2)
            case .hero:
                ev += swell(Chord(Note.midi(62 + key), [0, 4, 7, 14]), into: s0, duration: bar * 0.5, amp: 0.05)
                ev += thump(at: s0, amp: 0.5)
                ev += strum(chords[0], at: s0, amp: 0.06)
                ev += blip(Note.midi(86 + key), at: s0 + Cue.heroSweep(plan), amp: 0.05)          // the specular sweep
                ev += bell(Note.midi(78 + key), at: s0 + Cue.heroName(plan), amp: 0.06, pan: 0.15) // the name
            case .title:
                ev += rim(at: s0, amp: 0.2)
            case .triad:
                for k in 0..<FeatureTriad.shown(p.features.count) {
                    ev += rim(at: s0 + Double(k) * beat, amp: 0.22, pan: [-0.3, -0.1, 0.1, 0.3][k])
                }
            case .more:
                ev += rim(at: s0, amp: 0.16)
                for (k, rt) in FeatureList.rowTimes(count: min(4, max(0, p.features.count - FeatureTriad.shown(p.features.count))), start: 0.1,
                                                    stagger: Cue.rowStagger(plan)).enumerated() {
                    ev += rim(at: s0 + rt, amp: 0.11, pan: k % 2 == 0 ? -0.2 : 0.2)
                }
            case .device:
                ev += thump(at: s0, amp: 0.45)
            case .code:
                ev += rim(at: s0, amp: 0.16)
                if let code = p.code?.source {
                    for (k, lt) in CodeReveal.lineTimes(code, mode: Cue.codeMode(plan), start: Cue.codeStart).enumerated()
                    where !code.components(separatedBy: "\n")[k].trimmingCharacters(in: .whitespaces).isEmpty {
                        ev += tick(at: s0 + lt, amp: 0.055, pan: (Motion.hash(k + 7) - 0.5) * 0.6)
                    }
                }
            case .terminal:
                ev += rim(at: s0, amp: 0.16)
                let cps = Cue.terminalSpeed(plan, p)
                let lines = TerminalCard.session(p.terminal ?? [], start: Cue.terminalStart, cps: cps)
                for (k, kt) in TerminalCard.keystrokeTimes(lines, cps: cps, every: max(2, Int(cps / 13))).enumerated() where kt < len {
                    ev += tick(at: s0 + kt, amp: 0.045 + 0.02 * Motion.hash(k), pan: (Motion.hash(k + 3) - 0.5) * 0.5)
                }
                for l in lines where l.kind == .success && l.at < len { ev += blip(Note.midi(81 + key), at: s0 + l.at, amp: 0.08) }
            case .stats:
                let tones = chords[0].notes.map { $0.transposed(24) }
                for (k, lt) in StatRow.landTimes(count: p.highlights.count, start: Cue.statStart,
                                                 stagger: Cue.statStagger(plan)).enumerated() {
                    ev += blip(tones[min(k, tones.count - 1)], at: s0 + lt, amp: 0.08, pan: [-0.3, 0, 0.3][k])
                }
            case .changelog:
                for (k, rt) in ChangelogList.rowTimes(count: min(5, p.changelog.count), start: 0.25,
                                                      stagger: Cue.rowStagger(plan)).enumerated() {
                    ev += rim(at: s0 + rt, amp: 0.11, pan: k % 2 == 0 ? -0.2 : 0.2)
                }
            case .platforms:
                ev += rim(at: s0, amp: 0.14)
                if i + 1 < plan.shots.count {
                    ev += swell(chords[0].transposed(12), into: plan.starts[i + 1], duration: min(len, bar), amp: 0.05)
                }
            case .end:
                ev += thump(at: s0, amp: 0.55)
                ev += strum(chords[0], at: s0, amp: 0.07)
                let m = [74, 78, 81, 85, 86].map { Note.midi($0 + key) }
                for (k, n) in m.enumerated() {
                    ev += bell(n, at: s0 + 1.2 + Double(k) * beat / 2, amp: 0.07, duration: 2.0, pan: Double(k - 2) * 0.18)
                }
                ev += bell(Note.midi(90 + key), at: s0 + bar * 2, amp: 0.045, duration: 2.6)
            }
        }

        for line in voiceoverLines(plan, p) { ev += speak(line.text, at: line.time) }
        return Score(duration: duration ?? plan.duration) { ev }
    }
}
