import XCTest
@testable import SwiftRender

final class AudioAnalyzerTests: XCTestCase {
    /// 2s mono 44.1kHz WAV: first second 80Hz sine (bass), second 6kHz (high).
    private func makeTestWAV() throws -> URL {
        let sr = 44100, n = sr * 2
        var samples = [Int16](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / Double(sr)
            let f = i < sr ? 80.0 : 6000.0
            samples[i] = Int16(sin(2 * .pi * f * t) * 12000)
        }
        var data = Data()
        func put(_ s: String) { data.append(s.data(using: .ascii)!) }
        func put32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func put16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        put("RIFF"); put32(UInt32(36 + n * 2)); put("WAVE")
        put("fmt "); put32(16); put16(1); put16(1)
        put32(UInt32(sr)); put32(UInt32(sr * 2)); put16(2); put16(16)
        put("data"); put32(UInt32(n * 2))
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("analyzer_test.wav")
        try data.write(to: url)
        return url
    }

    func testBandSeparation() throws {
        let track = try AudioAnalyzer.analyze(url: makeTestWAV(), fps: 30)
        XCTAssertGreaterThan(track.band(.bass, at: 0.5), 0.4, "bass sine should read as bass")
        XCTAssertGreaterThan(track.band(.bass, at: 0.5), track.band(.high, at: 0.5))
        XCTAssertGreaterThan(track.band(.high, at: 1.5), 0.4, "6kHz sine should read as high")
        XCTAssertGreaterThan(track.band(.high, at: 1.5), track.band(.bass, at: 1.5))
    }

    func testLevelIsNormalized() throws {
        let track = try AudioAnalyzer.analyze(url: makeTestWAV(), fps: 30)
        for t in stride(from: 0.0, through: 2.0, by: 0.1) {
            let v = track.level(at: t)
            XCTAssertGreaterThanOrEqual(v, 0)
            XCTAssertLessThanOrEqual(v, 1)
        }
        XCTAssertGreaterThan(track.level(at: 0.5), 0.2, "steady tone should have audible level")
    }

    func testQueriesClampOutOfRange() throws {
        let track = try AudioAnalyzer.analyze(url: makeTestWAV(), fps: 30)
        XCTAssertNoThrow(track.level(at: -5))
        XCTAssertNoThrow(track.level(at: 500))
    }

    func testSilentTrackReturnsZero() {
        XCTAssertEqual(AudioTrack.silent.level(at: 1), 0)
        XCTAssertEqual(AudioTrack.silent.band(.bass, at: 1), 0)
        XCTAssertTrue(AudioTrack.silent.isSilent)
    }

    func testMissingFileThrows() {
        XCTAssertThrowsError(try AudioAnalyzer.analyze(
            url: URL(fileURLWithPath: "/nonexistent/nope.wav"), fps: 30))
    }
}
