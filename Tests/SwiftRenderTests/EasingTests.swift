import XCTest
@testable import SwiftRender

final class EasingTests: XCTestCase {
    func testClipBounds() {
        XCTAssertEqual(Ease.clip(-1, 0, 1), 0)
        XCTAssertEqual(Ease.clip(2, 0, 1), 1)
        XCTAssertEqual(Ease.clip(0.5, 0, 1), 0.5)
        XCTAssertEqual(Ease.clip(5, 5, 5), 1, "degenerate window clamps high at start")
    }

    func testCurvesHitEndpoints() {
        let curves: [(String, (Double) -> Double)] = [
            ("easeIn", Ease.easeIn), ("easeOut", Ease.easeOut),
            ("easeInOut", Ease.easeInOut), ("expo", Ease.expo),
            ("bounce", Ease.bounce), ("elastic", Ease.elastic),
            ("easeOutBack", { Ease.easeOutBack($0) }),
        ]
        for (name, f) in curves {
            XCTAssertEqual(f(0), 0, accuracy: 1e-9, "\(name)(0)")
            XCTAssertEqual(f(1), 1, accuracy: 1e-9, "\(name)(1)")
        }
    }

    func testEaseOutBackOvershoots() {
        let peak = stride(from: 0.0, through: 1.0, by: 0.01)
            .map { Ease.easeOutBack($0) }.max() ?? 0
        XCTAssertGreaterThan(peak, 1.05)
    }

    func testCubicBezierEndpointsAndSymmetry() {
        let b = Ease.cubicBezier(0.42, 0, 0.58, 1)
        XCTAssertEqual(b(0), 0, accuracy: 1e-6)
        XCTAssertEqual(b(1), 1, accuracy: 1e-6)
        XCTAssertEqual(b(0.5), 0.5, accuracy: 1e-3, "symmetric curve passes through center")
    }

    func testCubicBezierMonotonicX() {
        let b = Ease.cubicBezier(0.9, 0.1, 0.1, 0.9)
        var prev = -1.0
        for x in stride(from: 0.0, through: 1.0, by: 0.02) {
            let y = b(x)
            XCTAssertGreaterThanOrEqual(y, prev - 1e-6)
            prev = y
        }
    }
}
