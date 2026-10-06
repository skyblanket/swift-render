import CoreGraphics
import XCTest
import SwiftRenderKit
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

    func testZoomKeepsTimeUnderCursorFixed() {
        var v = TimelineViewport(start: 4, pxPerSecond: 50, width: 1000, duration: 60, fps: 60)
        let cursor: CGFloat = 300
        let anchor = v.t(cursor)
        v.zoom(by: 3, around: cursor)
        XCTAssertEqual(v.pxPerSecond, 150, accuracy: 1e-9)
        XCTAssertEqual(v.t(cursor), anchor, accuracy: 1e-9)
        v.zoom(by: 1 / 3, around: cursor)
        XCTAssertEqual(v.t(cursor), anchor, accuracy: 1e-9)
    }

    func testZoomIsClampedBetweenFitAndFrameLevel() {
        var v = TimelineViewport(start: 0, pxPerSecond: 50, width: 600, duration: 30, fps: 60)
        v.zoom(by: 1e6, around: 100)
        XCTAssertEqual(v.pxPerSecond, TimelineViewport.maxPxPerFrame * 60)
        v.zoom(by: 1e-6, around: 100)
        XCTAssertEqual(v.pxPerSecond, 600.0 / 30, accuracy: 1e-9)
        XCTAssertEqual(v.start, 0)
        XCTAssertTrue(v.isFit)
    }

    func testPanClampsToScene() {
        var v = TimelineViewport(start: 0, pxPerSecond: 100, width: 500, duration: 20, fps: 30)
        v.pan(by: -1000)
        XCTAssertEqual(v.start, 0)
        v.pan(by: 1e6)
        XCTAssertEqual(v.start, 15, accuracy: 1e-9)    // 20 s − 500 pt / 100 pt/s
        XCTAssertEqual(v.end, 20, accuracy: 1e-9)
    }

    func testResizeStaysFitWhenFit() {
        var v = TimelineViewport(width: 400, duration: 10, fps: 60)
        v.fit(10)
        v.resize(width: 1000)
        XCTAssertTrue(v.isFit)
        XCTAssertEqual(v.pxPerSecond, 100, accuracy: 1e-9)
    }

    func testFollowPageFlips() {
        var v = TimelineViewport(start: 0, pxPerSecond: 100, width: 500, duration: 60, fps: 60)
        XCTAssertFalse(v.follow(3))
        XCTAssertTrue(v.follow(7))
        XCTAssertLessThanOrEqual(v.start, 7)
        XCTAssertGreaterThan(v.end, 7)
    }

    func testTickSpacingIsReadableAtEveryZoom() {
        for pps in [2.0, 10, 40, 100, 400, 1200] {
            let v = TimelineViewport(start: 0, pxPerSecond: pps, width: 1000, duration: 600, fps: 60)
            let (major, minor) = v.tickSpacing()
            XCTAssertGreaterThanOrEqual(major * pps, 90, "labels collide at \(pps) pt/s")
            XCTAssertLessThanOrEqual(minor, major)
            XCTAssertGreaterThanOrEqual(minor, 1.0 / 60 - 1e-12)
        }
        XCTAssertEqual(TimelineViewport.label(72.4, major: 5), "01:12")
        XCTAssertEqual(TimelineViewport.label(12.4, major: 0.5), "00:12.40")
    }
}

final class RegionMathTests: XCTestCase {
    let canvas = CGRect(x: 100, y: 50, width: 960, height: 540)

    func testNormalizeIsCanvasRelativeTopLeft() {
        let r = RegionMath.normalize(CGRect(x: 420, y: 110, width: 200, height: 110), in: canvas)
        XCTAssertEqual(r.x, 0.3333, accuracy: 1e-4)
        XCTAssertEqual(r.y, 0.1111, accuracy: 1e-4)
        XCTAssertEqual(r.w, 0.2083, accuracy: 1e-4)
        XCTAssertEqual(r.h, 0.2037, accuracy: 1e-4)
        let pts = RegionMath.scenePoints(r, sceneSize: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(pts, CGRect(x: 640, y: 120, width: 400, height: 220))
    }

    func testReversedDragAndClamping() {
        // Dragged up-left, starting outside the canvas.
        let reversed = CGRect(x: 1200, y: 700, width: -400, height: -300)
        let r = RegionMath.normalize(reversed, in: canvas)
        XCTAssertEqual(r.x + r.w, 1, accuracy: 1e-9)       // clamped at the right edge
        XCTAssertEqual(r.y + r.h, 1, accuracy: 1e-9)
        XCTAssertGreaterThan(r.w, 0)
        XCTAssertGreaterThan(r.h, 0)
        let outside = RegionMath.normalize(CGRect(x: 0, y: 0, width: 50, height: 20), in: canvas)
        XCTAssertEqual(outside, ReviewRegion(x: 0, y: 0, w: 0, h: 0))
    }

    func testPointPinRoundTrips() {
        let p = RegionMath.point(CGPoint(x: 580, y: 320), in: canvas)
        XCTAssertTrue(RegionMath.isPoint(p))
        XCTAssertEqual(p.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(p.y, 0.5, accuracy: 1e-9)
        XCTAssertTrue(RegionMath.describe(p, sceneSize: CGSize(width: 1920, height: 1080)).contains("960,540"))
    }

    func testRectInvertsNormalize() {
        let view = CGRect(x: 300, y: 200, width: 240, height: 135)
        let back = RegionMath.rect(RegionMath.normalize(view, in: canvas), in: canvas)
        XCTAssertEqual(back.minX, view.minX, accuracy: 0.1)
        XCTAssertEqual(back.minY, view.minY, accuracy: 0.1)
        XCTAssertEqual(back.width, view.width, accuracy: 0.1)
        XCTAssertEqual(back.height, view.height, accuracy: 0.1)
    }

    func testCanvasFitAndPixelWidth() {
        let fit = ViewerGeometry.canvasRect(container: CGSize(width: 1000, height: 1000),
                                            content: CGSize(width: 1920, height: 1080), zoom: .fit)
        XCTAssertEqual(fit.width, 1000, accuracy: 1e-9)
        XCTAssertEqual(fit.height, 562.5, accuracy: 1e-9)
        XCTAssertEqual(fit.midY, 500, accuracy: 1e-9)
        let full = ViewerGeometry.canvasRect(container: CGSize(width: 1000, height: 600),
                                             content: CGSize(width: 1920, height: 1080), zoom: .p100)
        XCTAssertEqual(full.width, 1920)
        XCTAssertEqual(full.minX, -460)
        XCTAssertEqual(ViewerGeometry.pixelWidth(canvas: fit, backingScale: 2, sceneWidth: 1920), 1920)
        XCTAssertEqual(ViewerGeometry.pixelWidth(canvas: fit, backingScale: 1, sceneWidth: 1920), 1000)
    }
}
