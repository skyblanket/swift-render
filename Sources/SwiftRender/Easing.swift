import Foundation
import CoreGraphics

/// Tiny easing helper used inside TimelineView-driven scenes.
/// Maps a global elapsed time into a 0…1 progress for a clip [start, end],
/// then runs an easing curve.
public enum Ease {
    public static func clip(_ t: Double, _ start: Double, _ end: Double) -> Double {
        guard end > start else { return t < start ? 0 : 1 }
        return min(1, max(0, (t - start) / (end - start)))
    }

    public static func easeOut(_ x: Double) -> Double {
        // cubic ease-out
        let p = max(0, min(1, x))
        return 1 - pow(1 - p, 3)
    }

    public static func easeInOut(_ x: Double) -> Double {
        let p = max(0, min(1, x))
        return p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2
    }

    public static func easeIn(_ x: Double) -> Double {
        let p = max(0, min(1, x))
        return p * p * p
    }
}

public extension Double {
    func lerp(_ a: Double, _ b: Double) -> Double { a + (b - a) * self }
}

public extension CGFloat {
    func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * self }
}
