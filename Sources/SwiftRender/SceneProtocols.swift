import SwiftUI

/// Marker for scenes that take no parameters (used as a Props default).
public struct NoProps: Codable, Sendable { public init() {} }

/// (A) A scene that is a pure function of time AND a pre-analyzed audio track.
/// Analysis happens once before the render loop; `audio` is an immutable value,
/// so `body` remains deterministic frame-for-frame.
public protocol AudioReactiveScene {
    static var ownsPostFX: Bool { get }
    associatedtype Body: View
    static var defaultDuration: Double { get }
    @MainActor static func body(at t: Double, duration: Double, audio: AudioTrack) -> Body
}

/// (B) A scene parameterized by a Codable props payload (`--props file.json`).
/// `defaultProps` doubles as documentation: `swift-render props <Scene>` prints
/// it as a JSON template for AI/data pipelines.
public protocol PropsScene {
    static var ownsPostFX: Bool { get }
    associatedtype Props: Codable
    associatedtype Body: View
    static var defaultDuration: Double { get }
    static var defaultProps: Props { get }
    @MainActor static func body(at t: Double, duration: Double, props: Props) -> Body
}

/// Both at once. Conform to exactly ONE of the four scene protocols —
/// conforming to two makes `SceneRunner(X.self)` ambiguous (by design).
public protocol PropsAudioScene {
    static var ownsPostFX: Bool { get }
    associatedtype Props: Codable
    associatedtype Body: View
    static var defaultDuration: Double { get }
    static var defaultProps: Props { get }
    @MainActor static func body(at t: Double, duration: Double, props: Props, audio: AudioTrack) -> Body
}

public extension AudioReactiveScene {
    static var ownsPostFX: Bool { false }
}

public extension PropsScene {
    static var ownsPostFX: Bool { false }
}

public extension PropsAudioScene {
    static var ownsPostFX: Bool { false }
}
