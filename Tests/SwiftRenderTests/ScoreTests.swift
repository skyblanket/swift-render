import XCTest
@testable import SwiftRender

final class ScoreTests: XCTestCase {
    func testPatternsPlaceEventsOnTheGrid() {
        let groove = fourOnFloor(from: 0, to: 2.4, bpm: 100)   // 0.6s beat
        XCTAssertEqual(groove.filter { if case .kick = $0.sound { return true }; return false }.count, 4)
        let hats = hatSixteenths(from: 0, to: 0.6, bpm: 100)
        XCTAssertEqual(hats.count, 4)
        let line = bassline([.a1, .c2], from: 0, to: 1.2, bpm: 100)
        XCTAssertEqual(line.count, 2)
    }

    func testScoreSortsAndClipsEvents() {
        let score = Score(duration: 2.0) {
            kick(at: 1.5)
            kick(at: 0.5)
            kick(at: 5.0)   // past duration — dropped
        }
        XCTAssertEqual(score.events.count, 2)
        XCTAssertEqual(score.events[0].time, 0.5)
    }

    func testSynthIsDeterministic() {
        let score = Score(duration: 2.0) {
            kick(at: 0.2)
            clap(at: 0.8)
            bass(.a1, at: 1.0)
            crash(at: 1.4)
        }
        let a = ScoreSynth.render(score)
        let b = ScoreSynth.render(score)
        XCTAssertEqual(a.left, b.left)
        XCTAssertEqual(a.right, b.right)
    }

    func testKickLandsWhereItWasPlaced() {
        let score = Score(duration: 2.0) { kick(at: 1.0) }
        let (l, _) = ScoreSynth.render(score)
        let sr = Int(scoreSampleRate)
        func rms(_ range: Range<Int>) -> Float {
            let seg = Array(l[range])
            return sqrt(seg.map { $0 * $0 }.reduce(0, +) / Float(seg.count))
        }
        let before = rms(Int(0.4 * Double(sr))..<Int(0.9 * Double(sr)))
        let after = rms(Int(1.0 * Double(sr))..<Int(1.3 * Double(sr)))
        XCTAssertGreaterThan(after, before * 10, "kick energy must appear at its onset")
    }

    func testWAVRoundTripsThroughAnalyzer() throws {
        let score = Score(duration: 2.0) {
            bass(.a1, at: 0.1, duration: 1.6, amp: 0.8)   // 55 Hz — pure bass band
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("score_rt.wav")
        try ScoreSynth.writeWAV(score, to: url)
        let track = try AudioAnalyzer.analyze(url: url, fps: 30)
        XCTAssertGreaterThan(track.band(.bass, at: 0.9), track.band(.high, at: 0.9))
    }

    func testInMemoryAnalysisMatchesScore() throws {
        let score = Score(duration: 2.0) { kick(at: 1.0) }
        let mono = ScoreSynth.monoMix(score)
        let track = try AudioAnalyzer.analyze(samples: mono, sampleRate: scoreSampleRate, fps: 30)
        XCTAssertGreaterThan(track.band(.bass, at: 1.05), track.band(.bass, at: 0.5))
    }
}
