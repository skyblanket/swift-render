import SwiftUI
import SwiftRenderKit

// MARK: - Scene introspection
//
// Lets an editor or agent see a scene's structure — clips (with source
// locations), knobs, score events — without parsing Swift. A probe renders the
// scene at a handful of times with a collector switched on; Timeline reports
// the clips it places. Collection never changes a pixel.
//
// STUB CONTRACT — `SceneProbe.probe` and `Score.eventInfos` signatures are fixed;
// the engine work implements Timeline reporting (nested offsets, labels, source
// locations) behind them.

public struct SceneStructure: Sendable, Equatable {
    public var clips: [ClipInfo]
    public var knobs: [KnobInfo]
    public init(clips: [ClipInfo] = [], knobs: [KnobInfo] = []) { self.clips = clips; self.knobs = knobs }
}

@MainActor
public enum SceneProbe {
    /// Evaluate `make(t)` at probe times (clip midpoints and a coarse grid) with
    /// collection enabled. `make` returns the scene body for absolute time `t`.
    public static func probe(duration: Double, size: CGSize, fps: Int,
                             make: @escaping @MainActor (Double) -> AnyView) -> SceneStructure {
        KnobStore.shared.beginRecording()
        let renderer = ImageRenderer(content: RenderFrame(size: size, fps: fps, duration: duration,
                                                          t: 0, postFX: false) { make(0) })
        renderer.scale = 16.0 / max(1, size.width)
        _ = renderer.cgImage
        return SceneStructure(clips: [], knobs: KnobStore.shared.endRecording())
    }
}

public extension Score {
    /// Score events flattened for an editor lane. (Stub: coarse kinds only.)
    var eventInfos: [ScoreEventInfo] {
        events.map { e in
            ScoreEventInfo(lane: "fx", kind: String(describing: e.sound).components(separatedBy: "(").first ?? "event",
                           detail: nil, time: e.time, duration: e.duration, amp: e.amp)
        }
    }
}
