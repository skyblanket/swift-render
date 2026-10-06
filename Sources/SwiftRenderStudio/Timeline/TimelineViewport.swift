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
    /// Seconds across the visible width.
    var span: Double { Double(width) / pxPerSecond }

    /// Whole scene fills the width.
    var fitPxPerSecond: Double { Double(max(width, 1)) / max(duration, 0.001) }
    var minPxPerSecond: Double { fitPxPerSecond }
    var maxPxPerSecond: Double { max(minPxPerSecond, Self.maxPxPerFrame * Double(max(1, fps))) }
    var isFit: Bool { abs(pxPerSecond - fitPxPerSecond) < 1e-6 && start == 0 }

    /// Zoom by `factor` keeping the time under `x` fixed.
    mutating func zoom(by factor: Double, around x: CGFloat) {
        zoom(to: pxPerSecond * factor, around: x)
    }

    /// Zoom to an absolute scale (clamped to fit…frame level), keeping the time under `x` fixed.
    mutating func zoom(to pps: Double, around x: CGFloat) {
        let anchor = t(x)
        pxPerSecond = min(maxPxPerSecond, max(minPxPerSecond, pps))
        start = anchor - Double(x) / pxPerSecond
        clamp()
    }

    /// Zoom as 0 (fit) … 1 (frame level) on a log scale, for the zoom slider.
    var zoomLevel: Double {
        let lo = log(minPxPerSecond), hi = log(maxPxPerSecond)
        guard hi - lo > 1e-9 else { return 0 }
        return min(1, max(0, (log(pxPerSecond) - lo) / (hi - lo)))
    }

    mutating func setZoomLevel(_ level: Double, around x: CGFloat) {
        let lo = log(minPxPerSecond), hi = log(maxPxPerSecond)
        zoom(to: exp(lo + min(1, max(0, level)) * (hi - lo)), around: x)
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

    /// Scroll the least amount that shows all of `range` (or its start, when wider
    /// than the view), with `margin` points of air. Returns true when it moved.
    @discardableResult
    mutating func reveal(_ range: ClosedRange<Double>, margin: CGFloat = 24) -> Bool {
        let pad = Double(margin) / pxPerSecond
        let old = start
        let lo = range.lowerBound - pad, hi = range.upperBound + pad
        if lo < start || (hi > end && hi - lo > span) { start = lo } else if hi > end { start = hi - span }
        clamp()
        return start != old
    }

    /// Nearest frame boundary (drags snap to frames, like the transport).
    func snap(_ t: Double) -> Double {
        let f = Double(max(1, fps))
        return min(max(0, (t * f).rounded() / f), max(0, duration))
    }

    mutating func clamp() {
        start = max(0, min(start, max(0, duration - span)))
    }

    /// Ruler tick spacing (seconds): major labels ≥ ~90 pt apart; minor subdivisions.
    func tickSpacing(minLabelGap: CGFloat = 90) -> (major: Double, minor: Double) {
        let frame = 1 / Double(max(1, fps))
        // Below a quarter second, majors are whole frames so labels read as mm:ss:ff.
        let frameSteps = [1.0, 2, 5, 10].map { $0 * frame }.filter { $0 < 0.25 - 1e-9 }
        let steps: [Double] = frameSteps + [0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
        let major = steps.first { $0 * pxPerSecond >= Double(minLabelGap) } ?? 600
        let minor: Double
        switch major {
        case ..<(0.25 - 1e-9): minor = frame
        case 0.25: minor = 0.05
        case 15, 30: minor = 5
        case 60: minor = 10
        default: minor = major / 5
        }
        return (major, max(minor, frame))
    }

    /// "0:12" or "0:12.40", at a precision suited to `major`.
    static func label(_ t: Double, major: Double) -> String {
        let m = Int(t) / 60
        let s = t - Double(m * 60)
        if major >= 1 { return String(format: "%d:%02d", m, Int(s.rounded())) }
        return String(format: "%d:%05.2f", m, s)
    }

    /// Like `label(_:major:)`, but frame-level majors read "0:12:24" (m:ss:ff).
    static func label(_ t: Double, major: Double, fps: Int) -> String {
        let f = max(1, fps)
        guard major < 0.25 - 1e-9 else { return label(t, major: major) }
        let frames = Int((t * Double(f)).rounded())
        return String(format: "%d:%02d:%02d", frames / f / 60, (frames / f) % 60, frames % f)
    }

    /// Compact span for the header: "1:33", "12.5s", "40f".
    static func spanLabel(_ seconds: Double, fps: Int) -> String {
        if seconds >= 60 { return String(format: "%d:%02d", Int(seconds) / 60, Int(seconds.rounded()) % 60) }
        if seconds >= 1 { return String(format: seconds >= 10 ? "%.0fs" : "%.1fs", seconds) }
        return "\(Int((seconds * Double(max(1, fps))).rounded()))f"
    }
}
