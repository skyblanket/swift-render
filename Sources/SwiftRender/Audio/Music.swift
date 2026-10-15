//
//  Music.swift — music-theory helpers for Score: note names, chords, scales,
//  and one-line pads / strums / arpeggios / melodies on the melodic voices.
//
import Foundation

// MARK: - Note names (C2 … C7) and transposition

public extension Note {
    static let c3 = Note.midi(48), d3 = Note.midi(50), e3 = Note.midi(52), f3 = Note.midi(53)
    static let g3 = Note.midi(55), a3 = Note.midi(57), b3 = Note.midi(59)
    static let c4 = Note.midi(60), d4 = Note.midi(62), e4 = Note.midi(64), f4 = Note.midi(65)
    static let g4 = Note.midi(67), a4 = Note.midi(69), b4 = Note.midi(71)
    static let c5 = Note.midi(72), d5 = Note.midi(74), e5 = Note.midi(76), f5 = Note.midi(77)
    static let g5 = Note.midi(79), a5 = Note.midi(81), b5 = Note.midi(83), c6 = Note.midi(84)

    /// Shift by semitones (12 = up an octave).
    func transposed(_ semitones: Int) -> Note { Note(hz * Foundation.pow(2.0, Double(semitones) / 12.0)) }
}

// MARK: - Chords

/// A chord: a root note plus semitone intervals above it.
public struct Chord: Sendable {
    /// The chord's root note.
    public var root: Note
    /// Semitone offsets from the root (0 is the root itself).
    public var intervals: [Int]
    /// Creates a chord from a root and semitone intervals.
    public init(_ root: Note, _ intervals: [Int]) { self.root = root; self.intervals = intervals }

    /// The chord's notes, from the root upward.
    public var notes: [Note] { intervals.map { root.transposed($0) } }

    /// Major triad.
    public static func major(_ r: Note) -> Chord  { Chord(r, [0, 4, 7]) }
    /// Minor triad.
    public static func minor(_ r: Note) -> Chord  { Chord(r, [0, 3, 7]) }
    /// Major seventh chord.
    public static func major7(_ r: Note) -> Chord { Chord(r, [0, 4, 7, 11]) }
    /// Minor seventh chord.
    public static func minor7(_ r: Note) -> Chord { Chord(r, [0, 3, 7, 10]) }
    /// Dominant seventh chord.
    public static func dom7(_ r: Note) -> Chord   { Chord(r, [0, 4, 7, 10]) }
    /// Minor ninth chord.
    public static func minor9(_ r: Note) -> Chord { Chord(r, [0, 3, 7, 10, 14]) }
    /// Major triad with an added ninth.
    public static func add9(_ r: Note) -> Chord   { Chord(r, [0, 4, 7, 14]) }
    /// Suspended second chord.
    public static func sus2(_ r: Note) -> Chord   { Chord(r, [0, 2, 7]) }
    /// Suspended fourth chord.
    public static func sus4(_ r: Note) -> Chord   { Chord(r, [0, 5, 7]) }

    /// Same chord, an octave (or n semitones) higher/lower.
    public func transposed(_ semitones: Int) -> Chord { Chord(root.transposed(semitones), intervals) }
}

// MARK: - Scales

/// Musical scales, for picking notes by degree.
public enum Scale: Sendable {
    case major, minor, dorian, majorPentatonic, minorPentatonic, blues

    var steps: [Int] {
        switch self {
        case .major:           return [0, 2, 4, 5, 7, 9, 11]
        case .minor:           return [0, 2, 3, 5, 7, 8, 10]
        case .dorian:          return [0, 2, 3, 5, 7, 9, 10]
        case .majorPentatonic: return [0, 2, 4, 7, 9]
        case .minorPentatonic: return [0, 3, 5, 7, 10]
        case .blues:           return [0, 3, 5, 6, 7, 10]
        }
    }

    /// Scale degree `i` (0-based, may exceed one octave or go negative) from `root`.
    public func degree(_ i: Int, root: Note) -> Note {
        let n = steps.count
        let octave = Int(floor(Double(i) / Double(n)))
        let idx = ((i % n) + n) % n
        return root.transposed(octave * 12 + steps[idx])
    }
}

// MARK: - Melodic voice selector

/// The melodic voice that phrase helpers such as `strum` and `arpeggio` play.
public enum Instrument: Sendable {
    case pluck, bell, chip, pad, triBass

    func event(_ note: Note, at t: Double, amp: Double, duration: Double, pan: Double) -> [ScoreEvent] {
        switch self {
        case .pluck:   return SwiftRender.pluck(note, at: t, amp: amp, duration: duration, pan: pan)
        case .bell:    return SwiftRender.bell(note, at: t, amp: amp, duration: duration, pan: pan)
        case .chip:    return SwiftRender.chip(note, at: t, amp: amp, duration: duration, pan: pan)
        case .pad:     return SwiftRender.pad(note, at: t, amp: amp, duration: duration, pan: pan)
        case .triBass: return SwiftRender.triBass(note, at: t, amp: amp, duration: duration, pan: pan)
        }
    }

    var defaultDuration: Double {
        switch self {
        case .pluck: return 0.9
        case .bell: return 1.6
        case .chip: return 0.18
        case .pad: return 2
        case .triBass: return 0.5
        }
    }
}

// MARK: - Phrase helpers

/// A sustained chord on the pad voice, notes spread across the stereo field.
public func chordPad(_ chord: Chord, at t: Double, duration: Double, amp: Double = 0.03) -> [ScoreEvent] {
    let n = chord.notes.count
    return chord.notes.enumerated().flatMap { i, note in
        pad(note, at: t, amp: amp, duration: duration, pan: n > 1 ? (Double(i) / Double(n - 1) - 0.5) * 0.7 : 0)
    }
}

/// All chord notes struck almost together (a guitar/piano strum).
public func strum(_ chord: Chord, at t: Double, amp: Double = 0.08, spread: Double = 0.014,
                  instrument: Instrument = .pluck) -> [ScoreEvent] {
    chord.notes.enumerated().flatMap { i, note in
        instrument.event(note, at: t + Double(i) * spread, amp: amp, duration: instrument.defaultDuration,
                         pan: (Double(i) - Double(chord.notes.count - 1) / 2) * 0.2)
    }
}

/// Order in which `arpeggio` steps through a chord's notes.
public enum ArpPattern: Sendable { case up, down, upDown }

/// Chord notes cycled every `step` seconds from `from` to `to`.
public func arpeggio(_ chord: Chord, from: Double, to: Double, step: Double, amp: Double = 0.09,
                     pattern: ArpPattern = .up, instrument: Instrument = .pluck) -> [ScoreEvent] {
    let up = chord.notes
    let seq: [Note]
    switch pattern {
    case .up: seq = up
    case .down: seq = up.reversed()
    case .upDown: seq = up + up.dropFirst().dropLast().reversed()
    }
    guard !seq.isEmpty, step > 0 else { return [] }
    var out: [ScoreEvent] = []
    var t = from, i = 0
    while t < to - 1e-9 {
        out += instrument.event(seq[i % seq.count], at: t, amp: amp, duration: min(instrument.defaultDuration, step * 3),
                                pan: Double(i % 3 - 1) * 0.2)
        t += step; i += 1
    }
    return out
}

/// A melody written in beats: `[(beat, note)]`, placed from `start` at `bpm`.
public func melody(_ notes: [(Double, Note)], start: Double, bpm: Double, amp: Double = 0.12,
                   instrument: Instrument = .bell) -> [ScoreEvent] {
    let beat = 60.0 / bpm
    return notes.flatMap { b, note in
        instrument.event(note, at: start + b * beat, amp: amp, duration: instrument.defaultDuration, pan: 0)
    }
}

/// A chord that swells in from silence and stops on `t` — a pitched build into a cut.
/// Use instead of `riser`/`whoosh`: it carries the harmony and has no noise sweep.
public func swell(_ chord: Chord, into t: Double, duration: Double = 1.5, amp: Double = 0.06) -> [ScoreEvent] {
    let n = chord.notes.count
    return chord.notes.enumerated().flatMap { i, note in
        swell(note, at: t - duration, duration: duration, amp: amp,
              pan: n > 1 ? (Double(i) / Double(n - 1) - 0.5) * 0.6 : 0)
    }
}
