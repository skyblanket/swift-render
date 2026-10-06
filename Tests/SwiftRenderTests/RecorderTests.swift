import AVFoundation
import AppKit
import CoreImage
import SwiftUI
import XCTest
@testable import SwiftRender

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
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        return try XCTUnwrap(pool)
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

    /// The 0.9 conversion (pooled IOSurface buffer + CGContext copy) must produce
    /// exactly the bytes the old fresh-buffer + CIContext conversion produced.
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

                    var start = Date()
                    let legacy = try XCTUnwrap(Recorder.legacyPixelBuffer(
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
            XCTAssertEqual(c.redComponent, 1, accuracy: 0.06)
            XCTAssertEqual(c.greenComponent, 0.5, accuracy: 0.06)
            XCTAssertEqual(c.blueComponent, 0, accuracy: 0.06)
        }
    }
}
