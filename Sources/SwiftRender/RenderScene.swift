import SwiftUI

/// A scene is a pure function of time `t` (seconds since scene start).
/// Total scene duration is supplied so the body can compute exit fades, etc.
public protocol RenderScene {
    associatedtype Body: View
    static var defaultDuration: Double { get }
    @MainActor static func body(at t: Double, duration: Double) -> Body
}

/// Aspect-ratio presets.
public enum AspectPreset: String, CaseIterable {
    case landscape16x9 = "16:9"
    case vertical9x16 = "9:16"
    case square1x1 = "1:1"

    public var size: CGSize {
        switch self {
        case .landscape16x9: return CGSize(width: 1920, height: 1080)
        case .vertical9x16: return CGSize(width: 1080, height: 1920)
        case .square1x1: return CGSize(width: 1080, height: 1080)
        }
    }
}
