import XCTest
@testable import SwiftRenderStudio

final class ViewportTests: XCTestCase {
    func testXAndTAreInverse() {
        var v = TimelineViewport(start: 2, pxPerSecond: 100, width: 800, duration: 30, fps: 60)
        XCTAssertEqual(v.x(2), 0)
        XCTAssertEqual(v.x(3.5), 150)
        XCTAssertEqual(v.t(150), 3.5, accuracy: 1e-9)
        v.pan(by: 100)
        XCTAssertEqual(v.start, 3, accuracy: 1e-9)
    }
}
