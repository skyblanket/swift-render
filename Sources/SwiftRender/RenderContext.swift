import SwiftUI

/// What a scene is being rendered into — size, frame rate, total duration.
/// The Recorder injects this into the environment, so any view inside a scene
/// can adapt to aspect or fps without a separate scene per format:
///
///     struct Card: View {
///         @Environment(\.renderContext) var ctx
///         var body: some View {
///             if ctx.isVertical { ... } else { ... }
///         }
///     }
public struct RenderContext: Equatable, Sendable {
    /// Canvas size in points.
    public let size: CGSize
    /// Frames per second.
    public let fps: Int
    /// Total scene duration in seconds. 0 when unknown (bare single-frame renders).
    public let duration: Double

    /// Creates a context; `duration` defaults to 0 (unknown).
    public init(size: CGSize, fps: Int, duration: Double = 0) {
        self.size = size
        self.fps = fps
        self.duration = duration
    }

    /// Canvas width in points.
    public var width: CGFloat { size.width }
    /// Canvas height in points.
    public var height: CGFloat { size.height }
    /// Width divided by height; 0 when height is 0.
    public var aspect: CGFloat { size.height == 0 ? 0 : size.width / size.height }
    /// True when the canvas is taller than it is wide.
    public var isVertical: Bool { size.height > size.width }
    /// True when width equals height.
    public var isSquare: Bool { size.height == size.width }
    /// Layout scale relative to the 1920×1080 reference canvas most scenes
    /// are authored against.
    public var referenceScale: CGFloat { min(size.width / 1920, size.height / 1080) }
}

private struct RenderContextKey: EnvironmentKey {
    static let defaultValue = RenderContext(size: CGSize(width: 1920, height: 1080), fps: 60)
}

public extension EnvironmentValues {
    var renderContext: RenderContext {
        get { self[RenderContextKey.self] }
        set { self[RenderContextKey.self] = newValue }
    }
}
