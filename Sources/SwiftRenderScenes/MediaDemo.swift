import SwiftUI
import SwiftRender

/// MediaDemo — every media feature in one short scene: a frame-accurate
/// `VideoClip` (with its own audio via `sample`), an `ImageClip`, local
/// voiceover with `speak`, and karaoke captions from the same Score.
///
///   swift run swift-render preview  MediaDemo
///   swift run swift-render render   MediaDemo --out out/media-demo.mp4
///   swift run swift-render captions MediaDemo --out out/media-demo.srt
public struct MediaDemo: RenderScene {
    public static let defaultDuration: Double = 9.6

    static let clip = "demo/clip.mp4"
    static let lines: [(Double, String)] = [
        (0.4, "Video, images, voiceover and captions."),
        (3.9, "All of it in one Swift file, rendered on your Mac."),
        (7.1, "Every frame is a function of t."),
    ]

    public static func soundtrack(duration: Double) -> Score? {
        Score(duration: duration) {
            sample(clip, at: 0.3, amp: 0.55)
            chordPad(.minor7(.a3), at: 0, duration: 4.5)
            chordPad(.major7(.f3), at: 4.5, duration: duration - 4.5)
            sample("openear-foley/card_2.wav", at: 0.3, amp: 0.35)
            sample("openear-foley/click_1.wav", at: 4.3, amp: 0.3)
            for (t, text) in lines { speak(text, at: t) }
        }
    }

    /// Built once from the Score; `speak` lines are cached on disk after the first run.
    static let captions = CaptionTrack(soundtrack(duration: defaultDuration)!)

    @MainActor public static func body(at t: Double, duration: Double) -> some View {
        let inP = Ease.easeOut(Ease.clip(t, 0.0, 0.5))
        let swap = Ease.easeInOut(Ease.clip(t, 4.1, 4.6))
        return ZStack {
            Color(white: 0.03)
            HStack(alignment: .center, spacing: 60) {
                VStack(alignment: .leading, spacing: 18) {
                    label("VideoClip · frame-accurate", t)
                    VideoClip(clip, at: max(0, t - 0.3), loop: true)
                        .frame(width: 960, height: 540)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white.opacity(0.12)))
                        .shadow(color: .black.opacity(0.6), radius: 30, y: 16)
                }
                VStack(alignment: .leading, spacing: 18) {
                    label("ImageClip · any file on disk", t)
                    ImageClip("Sources/SwiftRender/Resources/logo-stacked.png")
                        .frame(width: 300, height: 300)
                        .rotationEffect(.degrees(-6 + 12 * swap))
                        .scaleEffect(0.9 + 0.1 * Ease.spring(t, from: 0, to: 1, response: 0.5, dampingFraction: 0.6))
                    Text("speak(\"…\", at: t)\nCaptionTrack(score)\nsample(\"clip.mp4\", at: t)")
                        .font(.system(size: 22, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.top, 12)
                }
            }
            .opacity(inP)
            CaptionView(captions, at: t)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 90)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder @MainActor
    static func label(_ s: String, _ t: Double) -> some View {
        Text(s.uppercased())
            .font(.system(size: 18, weight: .semibold, design: .monospaced))
            .tracking(3)
            .foregroundStyle(.white.opacity(0.45))
    }
}
