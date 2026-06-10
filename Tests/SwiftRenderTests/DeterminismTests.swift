import SwiftUI
import XCTest
@testable import SwiftRender

/// The framework's core promise: same t in, same pixels out — every run.
@MainActor
final class DeterminismTests: XCTestCase {
    private func render(_ t: Double, to name: String) throws -> Data {
        let recorder = Recorder(config: .init(fps: 12, size: CGSize(width: 320, height: 180)))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try recorder.renderPNG(at: t, to: url) { tt in
            TextReveal.body(at: tt, duration: 4.0)
        }
        return try Data(contentsOf: url)
    }

    func testSameFrameTwiceIsByteIdentical() throws {
        for t in [0.0, 0.45, 1.3, 3.8] {
            let a = try render(t, to: "det_a.png")
            let b = try render(t, to: "det_b.png")
            XCTAssertEqual(a, b, "frame at t=\(t) differs between renders")
        }
    }

    func testGrainTileIsSeeded() throws {
        // PostFX grain must come from the fixed seed, not SystemRandom —
        // covered implicitly above (renderPNG applies PostFX), but pin the
        // tile itself too so a regression points at the right place.
        let a = try render(0.45, to: "det_c.png")
        let b = try render(0.45, to: "det_d.png")
        XCTAssertEqual(a, b)
    }

    func testDifferentTimesProduceDifferentFrames() throws {
        let a = try render(0.45, to: "det_e.png")
        let b = try render(1.3, to: "det_f.png")
        XCTAssertNotEqual(a, b)
    }
}
