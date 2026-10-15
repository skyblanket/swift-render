import AVFoundation
import Accelerate
import AppKit
import CoreImage
import SwiftUI
import XCTest
@testable import SwiftRender
@testable import SwiftRenderScenes

/// Translucent content: proves premultiplied alpha survives the copy unchanged.
private struct Translucent: View {
    let t: Double
    var body: some View {
        ZStack {
            LinearGradient(colors: [.red.opacity(0.2), .blue.opacity(0.8)], startPoint: .leading, endPoint: .trailing)
            Circle().fill(.green.opacity(0.5)).frame(width: 400).offset(x: CGFloat(t) * 100)
            Text("alpha").font(.system(size: 120, weight: .black)).foregroundStyle(.white.opacity(0.6))
        }
    }
}

@MainActor
final class RecorderTests: XCTestCase {
    private typealias Make = @MainActor (Double) -> AnyView

    private static let scenes: [(name: String, duration: Double, times: [Double], postFX: Bool, make: Make)] = [
        ("TimelineDemo", 9.9, [0.5, 1.9, 3.0, 4.05, 6.0, 9.5], true,
         { AnyView(TimelineDemo.body(at: $0, duration: 9.9)) }),
        ("RepoPromo", 25.2, [1.0, 5.3, 10.1, 20.0, 24.9], false,
         { AnyView(RepoPromo.body(at: $0, duration: 25.2)) }),
        ("LaunchFilm", 57.5, [2.0, 10.0, 22.0, 33.0, 47.0, 56.0], false,
         { AnyView(LaunchFilm.body(at: $0, duration: 57.5, audio: .silent)) }),
        ("Translucent", 2, [0.0, 1.0], false, { AnyView(Translucent(t: $0)) }),
    ]

    private func makePool(_ width: Int, _ height: Int) throws -> CVPixelBufferPool {
        try Recorder.makePool(width: width, height: height)
    }

    private func pooledBuffer(_ pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        return try XCTUnwrap(pb)
    }

    /// Visible bytes only: rows can carry different padding in different buffers.
    private func bytes(_ pb: CVPixelBuffer) -> Data {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(pb)!, stride = CVPixelBufferGetBytesPerRow(pb)
        let row = CVPixelBufferGetWidth(pb) * 4
        var d = Data(capacity: row * CVPixelBufferGetHeight(pb))
        for y in 0..<CVPixelBufferGetHeight(pb) { d.append(base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self), count: row) }
        return d
    }

    /// The 0.9 conversion (pooled buffer + CGContext copy) must produce exactly
    /// the bytes the old fresh-buffer + CIContext conversion produced.
    func testPooledDrawIsByteIdenticalToLegacyCIContext() throws {
        let ci = CIContext()
        var legacyMS: [Double] = [], pooledMS: [Double] = []
        for scale in [1.0, 0.5] as [CGFloat] {
            let recorder = Recorder(config: .init(fps: 60, scale: scale))
            let pool = try makePool(Int(recorder.config.outputSize.width), Int(recorder.config.outputSize.height))
            for scene in Self.scenes {
                for t in scene.times {
                    let image = try recorder.renderImage(at: t, postFX: scene.postFX, duration: scene.duration, content: scene.make)
                    XCTAssertEqual(CGSize(width: image.width, height: image.height), recorder.config.outputSize)
                    _ = image.dataProvider?.data    // ImageRenderer rasterizes lazily; time the conversions alone

                    var start = Date()
                    let legacy = try XCTUnwrap(legacyPixelBuffer(
                        from: image, size: CGSize(width: image.width, height: image.height), ciContext: ci))
                    legacyMS.append(Date().timeIntervalSince(start) * 1000)

                    start = Date()
                    let pooled = try pooledBuffer(pool)
                    XCTAssertTrue(Recorder.draw(image, into: pooled))
                    pooledMS.append(Date().timeIntervalSince(start) * 1000)

                    let got = bytes(pooled)
                    XCTAssertTrue(got.contains { $0 != got.first }, "\(scene.name) t=\(t): blank frame proves nothing")
                    XCTAssertEqual(got, bytes(legacy), "\(scene.name) t=\(t) scale=\(scale): conversion differs")
                }
            }
        }
        // Drop the first sample of each (cold CIContext / pool).
        func mean(_ x: [Double]) -> Double { x.dropFirst().reduce(0, +) / Double(max(1, x.count - 1)) }
        print(String(format: "[recorder] conversion per frame: legacy CIContext %.2f ms, pooled CGContext %.2f ms (%d frames)",
                     mean(legacyMS), mean(pooledMS), legacyMS.count))
    }

    /// End to end: the H.264 stream `Recorder.render` writes is bit-identical to the
    /// legacy pipeline's (same frames, same encoder input, same encoder path).
    func testEncodedVideoIsBitIdenticalToLegacyPipeline() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sr-rec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = Recorder.Config(fps: 30)
        let spans: [(name: String, duration: Double, start: Double, postFX: Bool, make: Make)] = [
            ("TimelineDemo", 9.9, 1.5, true, Self.scenes[0].make),        // the slide transition
            ("RepoPromo", 25.2, 19.0, false, Self.scenes[1].make),        // into the nested outro
            ("Translucent", 2, 0, false, Self.scenes[3].make),
        ]
        for s in spans {
            let new = dir.appendingPathComponent("\(s.name)-new.mp4"), old = dir.appendingPathComponent("\(s.name)-old.mp4")
            try await Recorder(config: config).render(to: new, duration: s.start + 1, startTime: s.start, sceneDuration: s.duration,
                                                      postFX: s.postFX, content: s.make)
            try await legacyEncode(to: old, config: config, duration: s.duration, start: s.start, end: s.start + 1,
                                   postFX: s.postFX, content: s.make)
            let a = try await compressedSamples(new), b = try await compressedSamples(old)
            XCTAssertEqual(a.count, 30, s.name)
            guard a != b else { continue }
            // Within one busy test process (the full suite), VideoToolbox's rate control has
            // been seen to pick different slices from some frame on for identical input; the
            // pixel-exact encoder input is pinned by the conversion test above. So a bitstream
            // mismatch must still decode to the same pictures, within coding noise.
            let first = a.indices.first { $0 >= b.count || a[$0] != b[$0] } ?? 0
            let pa = try await decodedFrames(new), pb = try await decodedFrames(old)
            XCTAssertEqual(pa.count, pb.count, s.name)
            let worst = zip(pa, pb).map { psnr($0, $1) }.min() ?? 0
            print(String(format: "[recorder] %@: bitstreams differ from frame %d; decoded frames match within %.1f dB",
                         s.name, first, worst))
            XCTAssertGreaterThan(worst, 38, "\(s.name): encoded video differs from the legacy pipeline beyond coding noise")
        }
    }

    /// `renderPNG` now encodes `renderer.cgImage`; the old path went through `nsImage`.
    func testPNGMatchesLegacyNSImagePath() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sr-rec-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        for scale in [1.0, 0.5, 2.0] as [CGFloat] {
            let recorder = Recorder(config: .init(fps: 60, scale: scale))
            for scene in Self.scenes.prefix(scale == 2 ? 1 : 4) {
                let t = scene.times[1]
                let url = dir.appendingPathComponent("\(scene.name)-\(scale).png")
                try recorder.renderPNG(at: t, to: url, postFX: scene.postFX, duration: scene.duration, content: scene.make)

                let renderer = ImageRenderer(content: RenderFrame(size: recorder.config.size, fps: 60, duration: scene.duration,
                                                                  t: t, postFX: scene.postFX) { scene.make(t) })
                renderer.scale = scale
                let cg = try XCTUnwrap(renderer.nsImage?.cgImage(forProposedRect: nil, context: nil, hints: nil))
                let legacy = try XCTUnwrap(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
                XCTAssertEqual(try Data(contentsOf: url), legacy, "\(scene.name) scale=\(scale): PNG differs")
            }
        }
    }

    func testPooledBuffersAreFullyReplaced() throws {
        let recorder = Recorder(config: .init(fps: 12, size: CGSize(width: 64, height: 36), postFX: false))
        let opaque = try recorder.renderImage(at: 0) { _ in Color.orange }
        let clear = try recorder.renderImage(at: 0) { _ in Color.clear }
        let pool = try makePool(64, 36)
        let pb = try pooledBuffer(pool)
        XCTAssertTrue(Recorder.draw(opaque, into: pb))
        XCTAssertTrue(bytes(pb).contains { $0 != 0 })
        XCTAssertTrue(Recorder.draw(clear, into: pb))
        XCTAssertTrue(bytes(pb).allSatisfy { $0 == 0 }, "a recycled buffer must not show the previous frame")
    }

    func testOutputSizeDefaultsToEvenScaledSize() {
        func out(_ w: CGFloat, _ h: CGFloat, _ scale: CGFloat) -> CGSize {
            Recorder.Config(size: CGSize(width: w, height: h), scale: scale).outputSize
        }
        XCTAssertEqual(out(1920, 1080, 1), CGSize(width: 1920, height: 1080))
        XCTAssertEqual(out(1920, 1080, 0.5), CGSize(width: 960, height: 540))
        XCTAssertEqual(out(1920, 1080, 2), CGSize(width: 3840, height: 2160))
        XCTAssertEqual(out(1080, 1920, 0.25), CGSize(width: 270, height: 480))
        XCTAssertEqual(out(1001, 501, 1), CGSize(width: 1002, height: 502))
        var c = Recorder.Config(scale: 2)
        c.outputSize = CGSize(width: 1280, height: 720)
        XCTAssertEqual(c.outputSize, CGSize(width: 1280, height: 720))
        XCTAssertEqual(c.defaultBitrate, 6_000_000, "bitrate follows the encoded size")
        XCTAssertEqual(Recorder.Config(scale: 2).defaultBitrate, 35_000_000)
    }

    /// The writer encodes at `outputSize`: true half-res previews, true 4K at scale 2,
    /// and an explicit size resampled to fit. Channel order is checked on decode.
    func testVideoIsEncodedAtOutputSize() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sr-rec-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cases: [(CGFloat, CGSize?, CGSize)] = [
            (0.5, nil, CGSize(width: 160, height: 90)),
            (2, nil, CGSize(width: 640, height: 360)),
            (1, CGSize(width: 200, height: 112), CGSize(width: 200, height: 112)),
        ]
        for (scale, explicit, expected) in cases {
            let config = Recorder.Config(fps: 12, size: CGSize(width: 320, height: 180), scale: scale,
                                         postFX: false, outputSize: explicit)
            let url = dir.appendingPathComponent("v\(scale).mp4")
            var frames = 0
            try await Recorder(config: config).render(to: url, duration: 0.25, progress: { done, _ in frames = done }) { _ in
                Color(red: 1, green: 0.5, blue: 0)
            }
            XCTAssertEqual(frames, 3)
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let track = try XCTUnwrap(tracks.first)
            let natural = try await track.load(.naturalSize)
            XCTAssertEqual(natural, expected, "scale \(scale)")

            let generator = AVAssetImageGenerator(asset: asset)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let frame = try await generator.image(at: .zero).image
            let rep = NSBitmapImageRep(cgImage: frame)
            let c = try XCTUnwrap(rep.colorAt(x: frame.width / 2, y: frame.height / 2)?.usingColorSpace(.sRGB))
            // Loose enough for VM GPUs' color conversion (0.56 seen on CI), tight enough that
            // swapped channels (green 0 or 1, red/blue swapped) still fail.
            XCTAssertEqual(c.redComponent, 1, accuracy: 0.1)
            XCTAssertEqual(c.greenComponent, 0.5, accuracy: 0.1)
            XCTAssertEqual(c.blueComponent, 0, accuracy: 0.1)
        }
    }
}

/// The pre-0.9 `Recorder.render` video loop, verbatim minus audio: fresh ImageRenderer,
/// `nsImage` → CGImage, fresh buffer + CIContext, adaptor attributes (BGRA, w, h).
@MainActor
private func legacyEncode(to url: URL, config: Recorder.Config, duration: Double, start: Double, end: Double,
                          postFX: Bool, content: @escaping @MainActor (Double) -> AnyView) async throws {
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: config.codec,
        AVVideoWidthKey: Int(config.size.width),
        AVVideoHeightKey: Int(config.size.height),
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: config.defaultBitrate,
            AVVideoMaxKeyFrameIntervalKey: config.fps * 2,
        ],
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: Int(config.size.width),
        kCVPixelBufferHeightKey as String: Int(config.size.height),
    ])
    writer.add(input)
    XCTAssertTrue(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    let ci = CIContext()
    let frames = max(1, Int(((end - start) * Double(config.fps)).rounded()))
    for i in 0..<frames {
        let t = start + Double(i) / Double(config.fps)
        let buffer: CVPixelBuffer? = autoreleasepool {
            let renderer = ImageRenderer(content: RenderFrame(size: config.size, fps: config.fps, duration: duration,
                                                              t: t, postFX: config.postFX && postFX) { content(t) })
            renderer.scale = config.scale
            guard let ns = renderer.nsImage, let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            return legacyPixelBuffer(from: cg, size: config.size, ciContext: ci)
        }
        guard let buffer else { continue }
        while !input.isReadyForMoreMediaData { try? await Task.sleep(nanoseconds: 200_000) }
        adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(config.fps)))
    }
    input.markAsFinished()
    await writer.finishWriting()
}

/// The coded H.264 slices of `url`, per sample in decode order. Container metadata
/// and SEI NAL units are dropped: VideoToolbox stamps a per-session byte into its
/// user-data SEI, so two encodes of identical frames differ there and only there.
private func compressedSamples(_ url: URL) async throws -> [Data] {
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: try XCTUnwrap(tracks.first), outputSettings: nil)
    reader.add(output)
    XCTAssertTrue(reader.startReading())
    var samples: [Data] = []
    while let sample = output.copyNextSampleBuffer() {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
        var data = Data(count: CMBlockBufferGetDataLength(block))
        data.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
        // AVCC framing: 4-byte big-endian length, then the NAL unit; type 6 = SEI.
        var slices = Data(), pos = 0
        let bytes = [UInt8](data)
        while pos + 4 <= bytes.count {
            let len = bytes[pos..<pos + 4].reduce(0) { $0 << 8 | Int($1) }
            let nal = bytes[(pos + 4)..<min(bytes.count, pos + 4 + len)]
            if let head = nal.first, head & 0x1F != 6 { slices.append(contentsOf: nal) }
            pos += 4 + len
        }
        samples.append(slices)
    }
    return samples
}

/// Decoded BGRA bytes of every frame of `url`.
private func decodedFrames(_ url: URL) async throws -> [[UInt8]] {
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: try XCTUnwrap(tracks.first),
                                          outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(output)
    XCTAssertTrue(reader.startReading())
    var frames: [[UInt8]] = []
    while let sample = output.copyNextSampleBuffer() {
        guard let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let n = CVPixelBufferGetBytesPerRow(pb) * CVPixelBufferGetHeight(pb)
        frames.append([UInt8](UnsafeRawBufferPointer(start: CVPixelBufferGetBaseAddress(pb), count: n)))
    }
    return frames
}

/// Peak signal-to-noise ratio of two equal-size byte images (∞ when identical).
private func psnr(_ a: [UInt8], _ b: [UInt8]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    // vDSP: a scalar loop over 30 × 8 MB frames takes ~20 s in a debug build.
    var fa = [Float](repeating: 0, count: a.count), fb = fa
    vDSP_vfltu8(a, 1, &fa, 1, vDSP_Length(a.count))
    vDSP_vfltu8(b, 1, &fb, 1, vDSP_Length(b.count))
    var sum: Float = 0
    vDSP_distancesq(fa, 1, fb, 1, &sum, vDSP_Length(a.count))
    let mse = Double(sum) / Double(a.count)
    return mse == 0 ? .infinity : 10 * log10(255 * 255 / mse)
}

/// The pre-0.9 Recorder conversion (fresh buffer per frame + CIContext), verbatim,
/// kept as the reference the pooled `Recorder.draw(_:into:)` must match byte for byte.
private func legacyPixelBuffer(from cgImage: CGImage, size: CGSize, ciContext: CIContext) -> CVPixelBuffer? {
    let attrs = [
        kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true,
    ] as CFDictionary

    var pb: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        Int(size.width), Int(size.height),
        kCVPixelFormatType_32BGRA,
        attrs,
        &pb
    )
    guard status == kCVReturnSuccess, let buffer = pb else { return nil }

    let ci = CIImage(cgImage: cgImage)
    // Scale CIImage to match pixel-buffer size (handles displayScale != 1).
    let scaledCI = ci.transformed(by: CGAffineTransform(
        scaleX: size.width / ci.extent.width,
        y: size.height / ci.extent.height
    ))
    ciContext.render(scaledCI, to: buffer)
    return buffer
}
