import SwiftUI
import XCTest
@testable import SwiftRender

final class TimelineTests: XCTestCase {
    func testSequentialDurationFold() {
        let tl = Timeline(0) {
            Clip(2.0) { _ in Color.black }
            Clip(3.0) { _ in Color.black }
        }
        XCTAssertEqual(tl.duration, 5.0)
    }

    func testTransitionOverlapShortensTimeline() {
        let tl = Timeline(0) {
            Clip(2.0) { _ in Color.black }
            Clip(3.0) { _ in Color.black }.transition(.fade(0.5))
        }
        XCTAssertEqual(tl.duration, 4.5)
    }

    func testPinnedClipDoesNotMoveCursor() {
        let tl = Timeline(0) {
            Clip(2.0) { _ in Color.black }
            Clip(at: 0, for: 99) { _ in Color.black }
            Clip(3.0) { _ in Color.black }
        }
        XCTAssertEqual(tl.duration, 5.0)
    }

    func testTransitionOnFirstClipClampsToZero() {
        let tl = Timeline(0) {
            Clip(2.0) { _ in Color.black }.transition(.fade(0.5))
        }
        XCTAssertEqual(tl.duration, 2.0, "first clip cannot start before 0")
    }

    func testStaggerBoundsAndOffsets() {
        XCTAssertEqual(stagger(0, 0), 0)
        XCTAssertEqual(stagger(10, 0), 1)
        XCTAssertEqual(stagger(10, 5), 1)
        // element 2 with step 0.1 hasn't started at t = 0.15
        XCTAssertEqual(stagger(0.15, 2, step: 0.1, ramp: 0.3), 0)
        // ...and has finished by its start + ramp
        XCTAssertEqual(stagger(0.2 + 0.3, 2, step: 0.1, ramp: 0.3), 1)
    }
}
