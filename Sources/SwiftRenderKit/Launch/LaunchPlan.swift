import Foundation

// MARK: - LaunchPlan
//
// The shot list for a launch film, computed from props. The scene's Timeline and
// its Score both read `starts`/`cuts` from here, so picture and music cannot
// drift; Studio and the review loop use it to name the shot under a timecode.
// Lengths are whole bars at a tempo whose beats land on whole frames at 60 fps.

/// One shot of the film.
public struct LaunchShot: Codable, Sendable, Equatable, Identifiable {
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
    public var id: String
    public var kind: Kind
    public var bars: Double
    public init(_ kind: Kind, bars: Double) { self.id = kind.rawValue; self.kind = kind; self.bars = bars }
}

public struct LaunchPlan: Sendable, Equatable {
    public let bpm: Double
    public let beat: Double
    public let bar: Double
    public let shots: [LaunchShot]
    /// Start time of each shot (seconds).
    public let starts: [Double]
    public let duration: Double

    /// Hard-cut times (every shot start after the first).
    public var cuts: [Double] { Array(starts.dropFirst()) }

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
        out += order.filter { available[$0] == true }.prefix(2).map { LaunchShot($0, bars: 2) }

        if !p.highlights.isEmpty { out.append(LaunchShot(.stats, bars: 2)) }
        if !p.changelog.isEmpty { out.append(LaunchShot(.changelog, bars: 2)) }
        if !p.platforms.isEmpty || p.swiftVersion != nil || !p.facts.isEmpty { out.append(LaunchShot(.platforms, bars: 1)) }
        out.append(LaunchShot(.end, bars: 3))
        return out
    }

    /// 90, 100 or 120 BPM — the nearest tempo whose beat is a whole number of 60 fps frames
    /// (40, 36, 30) and whose bar is too, so every cut lands exactly on a frame.
    public static func frameExactBPM(_ bpm: Double) -> Double {
        [90.0, 100.0, 120.0].min { abs($0 - bpm) < abs($1 - bpm) } ?? 100
    }

    public func start(_ kind: LaunchShot.Kind) -> Double? {
        shots.firstIndex { $0.kind == kind }.map { starts[$0] }
    }

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
