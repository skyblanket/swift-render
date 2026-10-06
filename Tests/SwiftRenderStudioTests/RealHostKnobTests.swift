import CoreGraphics
import XCTest
import SwiftRenderKit
@testable import SwiftRenderStudio

/// Knob latency against the real `swift-render serve` host on this repo's KnobLab:
/// time from a slider-style `set(…, dragging: true)` to the first viewer frame, which
/// must show the new title color (M1 target: under 50 ms), then a burst of drags to check
/// the pacing and that the release re-probes. Builds the repo, so opt-in:
///
///   SR_STUDIO_REAL_E2E=1 swift test --filter RealHostKnobTests
@MainActor
final class RealHostKnobTests: XCTestCase {
    func testKnobDragReachesViewer() async throws {
        guard ProcessInfo.processInfo.environment["SR_STUDIO_REAL_E2E"] == "1" else {
            throw XCTSkip("set SR_STUDIO_REAL_E2E=1 to build the repo and run the real host")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        var options = LaunchOptions()
        options.scene = "KnobLab"
        let model = ProjectModel(root: root, options: options)
        model.playback.displayWidth = 480
        await model.start()
        await waitUntil(600, "build + host + frame") {
            if case .ready = model.host.state { return model.playback.hasFrame && model.info?.name == "KnobLab" }
            return false
        }
        // `--at` is applied by the snapshot runner once the duration is known; seek like it.
        model.playback.seek(1.5, precise: true)
        await waitUntil(10, "frame at 1.5 s") { model.playback.currentFrame.map { abs($0.t - 1.5) < 0.02 } ?? false }
        let insp = model.inspector
        let color = try XCTUnwrap(model.info?.knobs.first { $0.key == "title.color" })
        let scale = try XCTUnwrap(model.info?.knobs.first { $0.key == "title.scale" })
        XCTAssertNil(model.info?.knobs.first { $0.key == "debug.opacity" }, "guarded knob not probed yet")

        // The first frame after the change is the fast JPEG scrub frame at viewer width; it must
        // already show the new color. The lossless sharpen pass follows ~150 ms later.
        var samples: [Double] = []
        for (hex, channel) in [("#FF0000", 0), ("#0000FF", 2), ("#00FF00", 1), ("#FF0000", 0)] {
            let old = model.playback.currentFrame?.image
            let t0 = Date()
            insp.set(color, .string(hex), dragging: true)
            await waitUntil(5, "a new frame") { model.playback.currentFrame?.image !== old }
            samples.append(Date().timeIntervalSince(t0) * 1000)
            XCTAssertTrue(tinted(model.playback.currentFrame, channel), "\(hex) in the first new frame")
            try await Task.sleep(for: .milliseconds(300))      // let the sharpen pass settle
        }
        let median = samples.sorted()[samples.count / 2]
        print(String(format: "[knobs] set → new pixels on screen: %@ ms (median %.1f)",
                     samples.map { String(format: "%.1f", $0) }.joined(separator: ", "), median))
        XCTAssertLessThan(median, 50, "M1: a knob change reaches the screen in under 50 ms")

        // A 0.5 s drag at ~120 Hz mouse events, then release.
        let before = insp.knobs.sentCount
        let t0 = Date()
        for i in 0...60 {
            insp.set(scale, .number(1 + Double(i) / 60), dragging: true)
            try await Task.sleep(for: .milliseconds(8))
        }
        insp.set(scale, .number(2))
        await insp.knobs.drain()
        let elapsed = Date().timeIntervalSince(t0)
        let sends = insp.knobs.sentCount - before
        print(String(format: "[knobs] 61 drag events over %.2f s → %d setKnobs", elapsed, sends))
        XCTAssertLessThanOrEqual(Double(sends), elapsed * 30 + 3)
        XCTAssertEqual(model.host.info?.knobs.first { $0.key == "title.scale" }?.value, .number(2))

        // Turning the guard on re-probes and reveals the knob behind it.
        let safe = try XCTUnwrap(model.info?.knobs.first { $0.key == "debug.safe" })
        insp.set(safe, .bool(true))
        await insp.knobs.drain()
        XCTAssertNotNil(model.info?.knobs.first { $0.key == "debug.opacity" }, "release re-probed")

        insp.reset(safe); insp.reset(scale); insp.reset(color)
        await insp.knobs.drain()
        XCTAssertEqual(model.knobValues, [:])
        await model.shutdown()
    }
}

/// The frame has a solid patch of pure `channel` color (the headline text).
private func tinted(_ f: DecodedFrame?, _ channel: Int) -> Bool {
    guard let img = f?.image else { return false }
    let w = img.width, h = img.height       // full size: downsampling blends thin strokes into the dark
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let ok = px.withUnsafeMutableBytes { buf -> Bool in
        guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    guard ok else { return false }
    var n = 0
    for i in stride(from: 0, to: px.count, by: 4) {
        let c = (0..<3).map { Int(px[i + $0]) }
        // Loose enough for JPEG chroma subsampling on thin text.
        if c[channel] > 150, c.enumerated().allSatisfy({ $0.offset == channel || $0.element < 100 }) { n += 1 }
    }
    return n >= 100
}
