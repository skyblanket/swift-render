import XCTest
@testable import SwiftRender

final class SpringTests: XCTestCase {
    func testConvergesToTargetInAllDampingRegimes() {
        for df in [0.3, 1.0, 1.8] {
            let s = Spring(response: 0.4, dampingFraction: df)
            XCTAssertEqual(s.value(at: 10, from: 0, to: 1), 1.0, accuracy: 1e-4,
                           "dampingFraction \(df) failed to settle")
        }
    }

    func testStartsAtFrom() {
        let s = Spring(response: 0.5, dampingFraction: 0.7)
        XCTAssertEqual(s.value(at: 0, from: 3, to: 9), 3)
    }

    func testUnderdampedOvershoots() {
        let s = Spring(response: 0.4, dampingFraction: 0.3)
        let peak = stride(from: 0.0, through: 2.0, by: 0.005)
            .map { s.value(at: $0, from: 0, to: 1) }.max() ?? 0
        XCTAssertGreaterThan(peak, 1.05)
    }

    func testCriticallyDampedNeverOvershoots() {
        let s = Spring(response: 0.4, dampingFraction: 1.0)
        for t in stride(from: 0.0, through: 3.0, by: 0.01) {
            XCTAssertLessThanOrEqual(s.value(at: t, from: 0, to: 1), 1.0 + 1e-9)
        }
    }

    func testDeterministicAcrossEvaluations() {
        let s = Spring(stiffness: 170, damping: 18)
        XCTAssertEqual(s.value(at: 0.371, from: 0, to: 1),
                       s.value(at: 0.371, from: 0, to: 1))
    }

    func testSettlingDurationIsFinite() {
        let d = Spring(response: 0.5, dampingFraction: 0.6).settlingDuration()
        XCTAssertGreaterThan(d, 0)
        XCTAssertLessThan(d, 60)
    }
}
