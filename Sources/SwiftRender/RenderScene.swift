import SwiftUI

/// A scene is a pure function of time `t` (seconds since scene start).
/// Total scene duration is supplied so the body can compute exit fades, etc.
public protocol RenderScene {
    associatedtype Body: View
    static var defaultDuration: Double { get }
    /// Return true when the scene applies its own `PostFX` modifier; the
    /// recorder then skips its global pass instead of doubling grain/vignette.
    static var ownsPostFX: Bool { get }
    /// Declare the soundtrack next to the Timeline it scores. Return nil
    /// (the default) for silent scenes or when using an external --audio file.
    static func soundtrack(duration: Double) -> Score?
    @MainActor static func body(at t: Double, duration: Double) -> Body
}

public extension RenderScene {
    static var ownsPostFX: Bool { false }
    static func soundtrack(duration: Double) -> Score? { nil }
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
