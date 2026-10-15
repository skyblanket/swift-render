import Foundation

// MARK: - LaunchPlan
//
// The shot list for a launch film, computed from props. The scene's Timeline and
// its Score both read `starts`/`cuts` from here, so picture and music cannot
// drift; Studio and the review loop use it to name the shot under a timecode.
// Lengths are whole bars at a tempo whose beats land on whole frames at 60 fps.

/// One shot of the film.
public struct LaunchShot: Codable, Sendable, Equatable, Identifiable {
    /// The kinds of shot a launch film can contain.
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// Stage light comes up; "Introducing".
        case open
        /// App icon (or generated mark), name, tagline.
        case hero
        /// The tagline as a two-line keynote headline.
        case title
        /// Three (or four) feature cards.
        case triad
        /// Features 4–6 as a list (when there are five or more).
        case more
        /// The app on a device (first screenshot).
        case device
        /// A Swift snippet, highlighted and revealed line by line.
        case code
        /// A typed shell session.
        case terminal
        /// Up to three counted-up numbers.
        case stats
        /// "What's new in x.y".
        case changelog
        /// Platform badges + facts.
        case platforms
        /// Lockup, call to action, URL.
        case end
    }
    /// Shot id (the kind's raw value), matched by `ShotOverride.id`.
    public var id: String
    /// What the shot shows.
    public var kind: Kind
    /// Length in bars.
    public var bars: Double
    /// Creates a shot of `kind` lasting `bars`.
    public init(_ kind: Kind, bars: Double) { self.id = kind.rawValue; self.kind = kind; self.bars = bars }
}

/// The launch film's shot list and timing, computed from props.
public struct LaunchPlan: Sendable, Equatable {
    /// Tempo in beats per minute (always 90, 100 or 120).
    public let bpm: Double
    /// Length of one beat, in seconds.
    public let beat: Double
    /// Length of one 4-beat bar, in seconds.
    public let bar: Double
    /// Shots in order, after overrides.
    public let shots: [LaunchShot]
    /// Start time of each shot (seconds).
    public let starts: [Double]
    /// Total film length in seconds, snapped to the 60 fps grid.
    public let duration: Double

    /// Hard-cut times (every shot start after the first).
    public var cuts: [Double] { Array(starts.dropFirst()) }

    /// Plans the film for `props`, applying its shot overrides.
    public init(_ props: LaunchProps) {
        bpm = Self.frameExactBPM(props.music.bpm)
        beat = 60 / bpm
        bar = beat * 4
        var list = Self.defaultShots(props)
        for o in props.shots {
            guard let i = list.firstIndex(where: { $0.id == o.id }) else { continue }
            if o.hidden == true, list[i].kind != .end, list[i].kind != .hero { list.remove(at: i); continue }
            if let b = o.bars { list[i].bars = min(8, max(list[i].kind == .end ? 2 : 1, (b * 2).rounded() / 2)) }
        }
        shots = list
        // Accumulate in bars and snap to the 60 fps grid, so 21 × 2.4 s is 50.4 s, not 50.399….
        let framesPerBar = 4 * 60 / bpm * 60
        let snap = { (bars: Double) -> Double in (bars * framesPerBar).rounded() / 60 }
        var b = 0.0, s: [Double] = []
        for shot in list { s.append(snap(b)); b += shot.bars }
        starts = s
        duration = snap(b)
    }

    /// The default shot list: everything the props can fill, nothing they can't.
    static func defaultShots(_ p: LaunchProps) -> [LaunchShot] {
        var out: [LaunchShot] = [LaunchShot(.open, bars: 1), LaunchShot(.hero, bars: 2)]
        if !p.tagline.isEmpty { out.append(LaunchShot(.title, bars: p.subtitle == nil ? 1 : 2)) }
        if !p.features.isEmpty { out.append(LaunchShot(.triad, bars: 2)) }
        // Four features fit one row; five or six spill into a "more" list.
        if p.features.count >= 5 { out.append(LaunchShot(.more, bars: 2)) }

        // At most two "deep" shots, ordered by what matters for this kind of project.
        let hasDevice = !p.screenshots.isEmpty
        let hasCode = !(p.code?.source.isEmpty ?? true)
        let hasTerminal = !(p.terminal ?? []).isEmpty
        let order: [LaunchShot.Kind]
        switch p.kind {
        case .app: order = [.device, .code, .terminal]
        case .cli: order = [.terminal, .code, .device]
        case .library, .framework, .plugin: order = [.code, .terminal, .device]
        }
        let available: [LaunchShot.Kind: Bool] = [.device: hasDevice, .code: hasCode, .terminal: hasTerminal]
        let bar = 240 / frameExactBPM(p.music.bpm)
        out += order.filter { available[$0] == true }.prefix(2).map {
            // The terminal shot is as long as its session needs (2–4 bars), so it never cuts mid-keystroke.
            LaunchShot($0, bars: $0 == .terminal ? LaunchTerminal.bars(p.terminal ?? [], bar: bar) : 2)
        }

        if !p.highlights.isEmpty { out.append(LaunchShot(.stats, bars: 2)) }
        if !p.changelog.isEmpty { out.append(LaunchShot(.changelog, bars: 2)) }
        // A lone platform badge is a thin shot; the end card's footnote carries it instead.
        let platformsWorthAShot = !p.facts.isEmpty || p.platforms.count >= 2 || (p.kind != .app && p.swiftVersion != nil)
        if platformsWorthAShot { out.append(LaunchShot(.platforms, bars: 1)) }
        out.append(LaunchShot(.end, bars: 3))
        return out
    }

    /// 90, 100 or 120 BPM — the nearest tempo whose beat is a whole number of 60 fps frames
    /// (40, 36, 30) and whose bar is too, so every cut lands exactly on a frame.
    public static func frameExactBPM(_ bpm: Double) -> Double {
        [90.0, 100.0, 120.0].min { abs($0 - bpm) < abs($1 - bpm) } ?? 100
    }

    /// Start time (seconds) of the first shot of `kind`, or nil if the film has none.
    public func start(_ kind: LaunchShot.Kind) -> Double? {
        shots.firstIndex { $0.kind == kind }.map { starts[$0] }
    }

    /// Index of the first shot of `kind`, or nil.
    public func index(of kind: LaunchShot.Kind) -> Int? { shots.firstIndex { $0.kind == kind } }

    /// Seconds a shot lasts.
    public func length(_ i: Int) -> Double { shots[i].bars * bar }

    /// The shot under `t` and the time inside it.
    public func shot(at t: Double) -> (shot: LaunchShot, index: Int, local: Double)? {
        guard t >= 0, t < duration else { return nil }
        let i = (starts.lastIndex { $0 <= t }) ?? 0
        return (shots[i], i, t - starts[i])
    }
}

// MARK: - LaunchTerminal

/// Timing of the terminal shot's typed session, shared by the plan (how long the shot is),
/// the picture (`TerminalCard.session`) and the score (keystroke ticks), so all three agree.
/// Lines starting with "$ " are typed; the rest print 0.3 s after the command before them finishes.
public enum LaunchTerminal {
    /// When the first command starts typing (seconds into the shot).
    public static let start = 0.4
    /// Typing speed when the session fits the shot.
    public static let cps = 26.0
    /// The fastest the film types to fit a long session into the longest terminal shot.
    public static let maxCPS = 60.0
    /// How long the finished session stays on screen before the cut.
    public static let hold = 1.2

    /// How a terminal line is styled: typed command, output, ✓ success, ✗ failure or # comment.
    public enum Kind: Sendable, Equatable { case command, output, success, failure, comment }

    /// One scheduled line of the terminal session.
    public struct Line: Sendable, Equatable {
        /// Line text, without the "$ " prompt for commands.
        public var text: String
        /// How the line is styled.
        public var kind: Kind
        /// Seconds into the shot.
        public var at: Double
    }

    /// Times each transcript line: commands type at `cps`, other lines print shortly after.
    public static func schedule(_ transcript: [String], start: Double = start, cps: Double = cps) -> [Line] {
        var t = start, out: [Line] = []
        for raw in transcript {
            if raw.hasPrefix("$ ") {
                if !out.isEmpty { t += 0.45 }
                let cmd = String(raw.dropFirst(2))
                out.append(Line(text: cmd, kind: .command, at: t))
                t += Double(cmd.count) / cps + 0.3
            } else {
                let kind: Kind = raw.hasPrefix("✓") ? .success : raw.hasPrefix("✗") ? .failure : raw.hasPrefix("#") ? .comment : .output
                out.append(Line(text: raw, kind: kind, at: t))
                t += 0.14
            }
        }
        return out
    }

    /// When the session is complete: the last command fully typed, or the last line printed.
    public static func end(_ transcript: [String], start: Double = start, cps: Double = cps) -> Double {
        guard let last = schedule(transcript, start: start, cps: cps).last else { return start }
        return last.kind == .command ? last.at + Double(last.text.count) / cps : last.at
    }

    /// Bars the terminal shot needs to show the session at `cps` plus `hold`: 2–4, in half bars.
    public static func bars(_ transcript: [String], bar: Double) -> Double {
        let need = (end(transcript) + hold) / bar
        return min(4, max(2, (need * 2).rounded(.up) / 2))
    }

    /// The typing speed that finishes the session `hold` before a shot of `length` seconds ends
    /// (never slower than `cps`, never faster than `maxCPS`).
    public static func cps(_ transcript: [String], length: Double) -> Double {
        guard length.isFinite else { return cps }
        let typed = Double(transcript.filter { $0.hasPrefix("$ ") }.reduce(0) { $0 + $1.count - 2 })
        let fixed = end(transcript, cps: .infinity)          // gaps and output lines, no typing
        let room = length - hold - fixed
        guard typed > 0, end(transcript) > length - hold else { return cps }
        return room > 0 ? min(maxCPS, max(cps, typed / room)) : maxCPS
    }
}
