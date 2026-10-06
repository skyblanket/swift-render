import CoreGraphics
import Foundation

// MARK: - Timeline viewport
//
// The timeline is never a giant scroll view: lanes draw only [start, start + width/pps]
// from this value, and ScrollCatcher mutates it (⌥-scroll/pinch zoom around the
// cursor, scroll pans). Zoom runs from "fit" (whole scene) to ~20 px per frame.

struct TimelineViewport: Equatable, Sendable {
    /// Scene time at the left edge.
    var start: Double = 0
    var pxPerSecond: Double = 40
    /// Visible width in points.
    var width: CGFloat = 800
    /// Scene length, for clamping.
    var duration: Double = 10
    var fps: Int = 60

    static let maxPxPerFrame: Double = 20

    func x(_ t: Double) -> CGFloat { CGFloat((t - start) * pxPerSecond) }
    func t(_ x: CGFloat) -> Double { start + Double(x) / pxPerSecond }
    var end: Double { t(width) }
    var visibleRange: ClosedRange<Double> { start...max(start, end) }

    /// Whole scene fills the width.
    var fitPxPerSecond: Double { Double(max(width, 1)) / max(duration, 0.001) }
    var minPxPerSecond: Double { fitPxPerSecond }
    var maxPxPerSecond: Double { Self.maxPxPerFrame * Double(max(1, fps)) }
    var isFit: Bool { abs(pxPerSecond - fitPxPerSecond) < 1e-6 && start == 0 }

    /// Zoom by `factor` keeping the time under `x` fixed.
    mutating func zoom(by factor: Double, around x: CGFloat) {
        let anchor = t(x)
        pxPerSecond = min(maxPxPerSecond, max(minPxPerSecond, pxPerSecond * factor))
        start = anchor - Double(x) / pxPerSecond
        clamp()
    }

    mutating func fit(_ duration: Double) {
        self.duration = max(duration, 0.001)
        pxPerSecond = fitPxPerSecond
        start = 0
    }

    /// Positive `dx` moves later in time.
    mutating func pan(by dx: CGFloat) {
        start += Double(dx) / pxPerSecond
        clamp()
    }

    mutating func resize(width w: CGFloat) {
        let wasFit = isFit
        width = max(1, w)
        if wasFit { pxPerSecond = fitPxPerSecond } else {
            pxPerSecond = min(maxPxPerSecond, max(minPxPerSecond, pxPerSecond))
        }
        clamp()
    }

    /// Page-flip so `t` is visible (playback follow). Returns true when it moved.
    @discardableResult
    mutating func follow(_ t: Double) -> Bool {
        let span = end - start
        guard t < start || t > end else { return false }
        start = t > end ? t - span * 0.05 : max(0, t - span * 0.05)
        clamp()
        return true
    }

    mutating func clamp() {
        let span = Double(width) / pxPerSecond
        start = max(0, min(start, max(0, duration - span)))
    }

    /// Ruler tick spacing (seconds): major labels ≥ ~90 pt apart; minor subdivisions.
    func tickSpacing(minLabelGap: CGFloat = 90) -> (major: Double, minor: Double) {
        let frame = 1 / Double(max(1, fps))
        let steps: [Double] = [frame, frame * 2, frame * 5, 0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
        let major = steps.first { $0 * pxPerSecond >= Double(minLabelGap) } ?? 600
        let minor: Double
        switch major {
        case ..<0.1: minor = frame
        case 0.1: minor = frame * 2 > 0.05 ? 0.05 : frame
        case 0.25: minor = 0.05
        case 15, 30: minor = 5
        case 60: minor = 10
        default: minor = major / 5
        }
        return (major, max(minor, frame))
    }

    /// "00:12.40"-style label at a precision suited to `major`.
    static func label(_ t: Double, major: Double) -> String {
        let m = Int(t) / 60
        let s = t - Double(m * 60)
        if major >= 1 { return String(format: "%02d:%02d", m, Int(s.rounded())) }
        return String(format: "%02d:%05.2f", m, s)
    }
}
