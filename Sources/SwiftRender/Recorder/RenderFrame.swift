import SwiftUI

/// One scene frame exactly as the recorder sees it: fixed canvas size, the
/// render context in the environment, and the global PostFX pass. Shared by the
/// recorder, PNG frames and the live preview so all three always match.
public struct RenderFrame<Content: View>: View {
    let size: CGSize
    let fps: Int
    let duration: Double
    let t: Double
    let postFX: Bool
    let content: Content

    /// Wraps `content` for scene time `t` at `size`; `postFX` toggles the global grain/vignette pass.
    public init(size: CGSize, fps: Int, duration: Double, t: Double, postFX: Bool,
                @ViewBuilder content: () -> Content) {
        self.size = size; self.fps = fps; self.duration = duration
        self.t = t; self.postFX = postFX; self.content = content()
    }

    /// The content framed to `size` with the render context and PostFX applied.
    public var body: some View {
        ZStack { content }
            .frame(width: size.width, height: size.height)
            .environment(\.renderContext, RenderContext(size: size, fps: fps, duration: duration))
            .modifier(PostFX(time: t, enabled: postFX))
    }
}
