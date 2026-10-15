//
//  Captions.swift — captions from the Score's voiceover lines.
//
//  Each `speak(...)` line is rendered (cached) by Speech; its voiced span sets the
//  cue window and words get times proportional to their length, with extra room
//  after punctuation. Long lines split into cues of at most `maxChars`.
//  Use `CaptionView` to burn them in, or `swift-render captions` for SRT/VTT.
//
import Foundation

/// One spoken word with its estimated start and end time.
public struct CaptionWord: Sendable, Hashable {
    /// The word as written.
    public let text: String
    /// Start time in seconds.
    public let start: Double
    /// End time in seconds.
    public let end: Double
}

/// One caption: a run of words shown on screen together.
public struct CaptionCue: Sendable, Hashable {
    /// Start time in seconds.
    public let start: Double
    /// End time of the last word in seconds.
    public let end: Double
    /// The words in this cue, in order.
    public let words: [CaptionWord]
    /// The cue's words joined with spaces.
    public var text: String { words.map(\.text).joined(separator: " ") }
}

/// A list of caption cues, sorted by start time.
public struct CaptionTrack: Sendable {
    /// Cues in start-time order.
    public var cues: [CaptionCue]

    /// Creates a track from `cues`, sorting them by start time.
    public init(cues: [CaptionCue]) { self.cues = cues.sorted { $0.start < $1.start } }

    /// Captions for every `speak(...)` event in `score`.
    public init(_ score: Score, maxChars: Int = 42) {
        var cues: [CaptionCue] = []
        for e in score.events {
            guard case .speech(let spec) = e.sound else { continue }
            var span = (start: 0.0, end: max(0.6, Double(spec.text.count) / 15))
            if let b = try? Speech.buffer(spec) { span = Speech.voicedSpan(b) }
            cues += Self.estimate(spec.text, start: e.time + span.start, end: e.time + span.end, maxChars: maxChars)
        }
        self.init(cues: cues)
    }

    /// Split `text` spoken over [start, end] into timed words and cues.
    public static func estimate(_ text: String, start: Double, end: Double, maxChars: Int = 42) -> [CaptionCue] {
        let tokens = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        guard !tokens.isEmpty, end > start else { return [] }
        func weight(_ w: String) -> Double { Double(max(2, w.filter { $0.isLetter || $0.isNumber }.count)) }
        func pause(_ w: String) -> Double {
            guard let last = w.last else { return 0 }
            if ".!?".contains(last) { return 5 }
            if ",;:—–".contains(last) { return 2.5 }
            return 0.6
        }
        let units = tokens.enumerated().map { i, w in weight(w) + (i < tokens.count - 1 ? pause(w) : 0) }
        let scale = (end - start) / units.reduce(0, +)
        var t = start
        var words: [CaptionWord] = []
        for w in tokens {
            let d = weight(w) * scale
            words.append(CaptionWord(text: w, start: t, end: t + d))
            t += d + pause(w) * scale
        }
        // balanced line breaks: n roughly equal cues, each break nudged to nearby punctuation
        let total = words.reduce(0) { $0 + $1.text.count } + words.count - 1
        let n = max(1, Int((Double(total) / Double(maxChars)).rounded(.up)))
        var breaks: [Int] = []          // index of the last word in each cue but the final one
        if n > 1 {
            var ends: [Int] = []        // char offset where each word ends
            var acc = 0
            for (i, w) in words.enumerated() { acc += w.text.count + (i == 0 ? 0 : 1); ends.append(acc) }
            for k in 1..<n {
                let target = Double(total) * Double(k) / Double(n)
                var best = 0, bestScore = Double.infinity
                for i in 0..<(words.count - 1) where i > (breaks.last ?? -1) {
                    let punct = words[i].text.last.map { ".!?;:,—".contains($0) } ?? false
                    let score = abs(Double(ends[i]) - target) - (punct ? 6 : 0)
                    if score < bestScore { bestScore = score; best = i }
                }
                breaks.append(best)
            }
        }
        var cues: [CaptionCue] = []
        var from = 0
        for b in breaks + [words.count - 1] where b >= from {
            let line = Array(words[from...b])
            cues.append(CaptionCue(start: line[0].start, end: line[line.count - 1].end, words: line))
            from = b + 1
        }
        return cues
    }

    /// The cue on screen at `t`. Cues hold `hold` seconds past their last word
    /// unless the next cue starts first.
    public func cue(at t: Double, hold: Double = 0.35) -> CaptionCue? {
        for (i, c) in cues.enumerated() {
            let next = i + 1 < cues.count ? cues[i + 1].start : .infinity
            if t >= c.start && t < min(c.end + hold, next) { return c }
        }
        return nil
    }

    /// Display end for cue `i`: a short hold past the last word, never past the next cue.
    func displayEnd(_ i: Int, hold: Double = 0.2) -> Double {
        let next = i + 1 < cues.count ? cues[i + 1].start - 0.01 : .infinity
        return max(cues[i].end, min(cues[i].end + hold, next))
    }

    /// The cues as SubRip (.srt) text.
    public func srt() -> String {
        cues.indices.map { i in
            "\(i + 1)\n\(Self.stamp(cues[i].start, ",")) --> \(Self.stamp(displayEnd(i), ","))\n\(cues[i].text)\n"
        }.joined(separator: "\n")
    }

    /// The cues as WebVTT (.vtt) text.
    public func vtt() -> String {
        "WEBVTT\n\n" + cues.indices.map { i in
            "\(Self.stamp(cues[i].start, ".")) --> \(Self.stamp(displayEnd(i), "."))\n\(cues[i].text)\n"
        }.joined(separator: "\n")
    }

    static func stamp(_ t: Double, _ sep: String) -> String {
        let ms = Int((max(0, t) * 1000).rounded())
        return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, sep, ms % 1000)
    }
}
