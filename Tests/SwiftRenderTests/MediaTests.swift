import AVFoundation
import Accelerate
import SwiftUI
import XCTest
@testable import SwiftRender

final class SampleTests: XCTestCase {
    private func sineWAV(seconds: Double, hz: Float = 440) throws -> URL {
        let n = Int(seconds * scoreSampleRate)
        let l = (0..<n).map { 0.5 * sin(2 * Float.pi * hz * Float($0) / Float(scoreSampleRate)) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sr-test-\(UUID().uuidString).wav")
        try WAV.write(left: l, right: l, to: url)
        return url
    }

    func testLoadShapeAndVarispeed() throws {
        let url = try sineWAV(seconds: 0.5)
        let b = try SampleLibrary.load(url: url)
        XCTAssertEqual(b.frames, Int(0.5 * scoreSampleRate))
        XCTAssertGreaterThan(vDSP.maximumMagnitude(b.left), 0.45)
        let fast = SampleLibrary.shaped(b, rate: 2, offset: 0, duration: 0)
        XCTAssertEqual(Double(fast.frames), Double(b.frames) / 2, accuracy: 2)
        let trimmed = SampleLibrary.shaped(b, rate: 1, offset: 0.1, duration: 0.2)
        XCTAssertEqual(trimmed.duration, 0.2, accuracy: 0.001)
        XCTAssertEqual(trimmed.left.last ?? 1, 0, accuracy: 0.01, "trims end with a fade")
    }

    func testSampleLandsAtItsTimeInTheScore() throws {
        let url = try sineWAV(seconds: 0.3)
        let score = Score(duration: 2) { sample(url.path, at: 1.0, amp: 0.8) }
        let (l, _) = ScoreSynth.render(score, normalize: false)
        let before = vDSP.maximumMagnitude(Array(l[0..<Int(0.95 * scoreSampleRate)]))
        let after = vDSP.maximumMagnitude(Array(l[Int(1.05 * scoreSampleRate)..<Int(1.25 * scoreSampleRate)]))
        XCTAssertLessThan(before, 1e-4)
        XCTAssertGreaterThan(after, 0.2)
    }

    func testMissingSampleIsSkippedNotFatal() {
        let score = Score(duration: 1) { sample("definitely/not/here.wav", at: 0.2) }
        let (l, r) = ScoreSynth.render(score, normalize: false)
        XCTAssertEqual(l.count, Int(scoreSampleRate))
        XCTAssertEqual(vDSP.maximumMagnitude(l) + vDSP.maximumMagnitude(r), 0)
    }

    func testCrackleIsDeterministic() {
        let a = Voice.crackle(amp: 0.05, dur: 1, seed: 9)
        let b = Voice.crackle(amp: 0.05, dur: 1, seed: 9)
        XCTAssertEqual(a.0, b.0)
        XCTAssertLessThanOrEqual(vDSP.maximumMagnitude(a.0), 0.0501)
    }
}

final class CaptionTests: XCTestCase {
    func testEstimateIsOrderedAndBounded() {
        let cues = CaptionTrack.estimate("Every meeting, on the record. Ask anything you have said, and find it.",
                                         start: 1.0, end: 5.0, maxChars: 24)
        XCTAssertGreaterThan(cues.count, 1)
        let words = cues.flatMap(\.words)
        XCTAssertEqual(words.first?.start ?? 0, 1.0, accuracy: 1e-9)
        XCTAssertEqual(words.last?.end ?? 0, 5.0, accuracy: 1e-6)
        for (a, b) in zip(words, words.dropFirst()) { XCTAssertLessThanOrEqual(a.end, b.start + 1e-9) }
        for c in cues { XCTAssertLessThanOrEqual(c.text.count, 30, "balanced splits stay near maxChars") }
    }

    func testSRTStampsAndNoOverlap() {
        let track = CaptionTrack(cues: CaptionTrack.estimate("One two three four five six seven eight nine ten",
                                                             start: 61.5, end: 64, maxChars: 20))
        let srt = track.srt()
        XCTAssertTrue(srt.hasPrefix("1\n00:01:01,500 --> "))
        for i in track.cues.indices.dropLast() {
            XCTAssertLessThan(track.displayEnd(i), track.cues[i + 1].start)
        }
        XCTAssertTrue(track.vtt().hasPrefix("WEBVTT"))
        XCTAssertNotNil(track.cue(at: 62))
        XCTAssertNil(track.cue(at: 10))
    }

    func testSayVoiceoverAndCaptions() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/say") else { throw XCTSkip("no say") }
        let spec = SpeechSpec("Testing one two three.", engine: .say())
        let buffer: SampleBuffer
        do { buffer = try Speech.buffer(spec) } catch { throw XCTSkip("say unavailable: \(error)") }
        XCTAssertGreaterThan(buffer.duration, 0.4)
        let span = Speech.voicedSpan(buffer)
        XCTAssertLessThan(span.start, span.end)
        let score = Score(duration: 4) { speak("Testing one two three.", at: 0.5) }
        let track = CaptionTrack(score)
        XCTAssertEqual(track.cues.first?.text, "Testing one two three.")
        XCTAssertGreaterThanOrEqual(track.cues.first?.start ?? 0, 0.5)
    }
}

@MainActor
final class VideoClipTests: XCTestCase {
    func testFramesAreTimeAccurate() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sr-clip-\(UUID().uuidString).mp4")
        let recorder = Recorder(config: .init(fps: 30, size: CGSize(width: 64, height: 64), postFX: false))
        try await recorder.render(to: url, duration: 1.0, postFX: false) { t in
            (t < 0.5 ? Color.red : Color.blue).frame(width: 64, height: 64)
        }
        XCTAssertEqual(MediaLibrary.duration(url.path), 1.0, accuracy: 0.05)
        func rgb(_ cg: CGImage?) -> (Double, Double) {
            guard let cg else { return (0, 0) }
            var px = [UInt8](repeating: 0, count: 4)
            let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return (Double(px[0]), Double(px[2]))
        }
        let early = rgb(MediaLibrary.frame(url.path, at: 0.2))
        let late = rgb(MediaLibrary.frame(url.path, at: 0.8))
        XCTAssertGreaterThan(early.0, early.1 + 100, "t=0.2 is red")
        XCTAssertGreaterThan(late.1, late.0 + 100, "t=0.8 is blue")
    }
}

@MainActor
final class AssemblerTests: XCTestCase {
    /// Two range renders stitched by MP4Assembler must equal one render: same frame
    /// count, same duration, first frame of chunk 2 at exactly its start time.
    func testRangeChunksStitchFrameExact() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sr-asm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let rec = Recorder(config: .init(fps: 30, size: CGSize(width: 64, height: 36), postFX: false))
        let a = dir.appendingPathComponent("a.mp4"), b = dir.appendingPathComponent("b.mp4")
        let out = dir.appendingPathComponent("out.mp4")
        let view: @MainActor (Double) -> Color = { t in Color(white: t / 1.0) }
        try await rec.render(to: a, duration: 0.5, startTime: 0, sceneDuration: 1.0, content: view)
        try await rec.render(to: b, duration: 1.0, startTime: 0.5, sceneDuration: 1.0, content: view)
        try await MP4Assembler.assemble(video: [a, b], audio: nil, to: out)

        let asset = AVURLAsset(url: out)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 1.0, accuracy: 1e-6)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var pts: [Double] = []
        while let sb = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sb) > 0 { pts.append(CMSampleBufferGetPresentationTimeStamp(sb).seconds) }
        }
        XCTAssertEqual(pts.count, 30)
        XCTAssertEqual(pts.sorted()[15], 0.5, accuracy: 1e-6, "chunk 2 starts exactly at 0.5 s")
        XCTAssertEqual(pts.sorted().first ?? -1, 0, accuracy: 1e-6)
    }
}

final class VisionTrackTests: XCTestCase {
    func testJointLookupInterpolatesAndRespectsConfidence() {
        let frames = [
            VisionFrame(time: 0, body: ["leftWrist": VisionPoint(x: 0.0, y: 0.5, confidence: 0.9)]),
            VisionFrame(time: 0.1, body: ["leftWrist": VisionPoint(x: 1.0, y: 0.5, confidence: 0.9)]),
            VisionFrame(time: 0.2, body: ["leftWrist": VisionPoint(x: 1.0, y: 0.5, confidence: 0.05)]),
        ]
        let track = VisionTrack(fps: 10, frames: frames)
        XCTAssertEqual(track.joint("leftWrist", at: 0.05)?.x ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertNil(track.joint("leftWrist", at: 0.2), "low-confidence joints are dropped")
        XCTAssertNil(track.joint("nose", at: 0.05))
        XCTAssertEqual(track.frame(at: 99)?.time, 0.2, "clamps past the end")
        XCTAssertTrue(track.frames[0].hasPerson)
    }

    func testOrientationFromTransform() {
        XCTAssertEqual(VisionTrack.orientation(.identity), .up)
        XCTAssertEqual(VisionTrack.orientation(CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0)), .right)
    }

    func testDemoClipAnalyzesWithoutAPerson() {
        let track = VisionTrack.load("demo/clip.mp4", fps: 10, masks: false)
        XCTAssertGreaterThan(track.frames.count, 30)
        XCTAssertFalse(track.frames.contains { $0.hasPerson }, "the demo clip is typography only")
    }
}
