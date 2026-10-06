import SwiftUI
import SwiftRender

/// Rotoscope — Apple Vision on live action: the person is cut out with the
/// segmentation mask, re-rendered through a `Stylize` look, and traced with the
/// tracked skeleton and fading wrist trails. Point it at any clip of one person:
///
///   echo '{"clip": "me.mov", "style": "ascii"}' > roto.json
///   swift run swift-render render Rotoscope --props roto.json --jobs auto --out out/roto.mp4
///
/// Vision runs once per clip and is cached (`~/Library/Caches/swift-render/vision`),
/// so every frame — and every `--jobs` process — reads the same results.
public struct Rotoscope: PropsScene {
    public struct Props: Codable, Sendable {
        public var clip: String
        /// Any `Stylize.Style` name: ascii, halftone, dither, pixel, cmyk, led, …
        public var style: String
    }
    public static let defaultProps = Props(clip: "demo/clip.mp4", style: "ascii")
    public static let defaultDuration: Double = 8.0
    public static var ownsPostFX: Bool { true }

    static let W: Double = 1920, H: Double = 1080
    static let volt = Color(red: 0.78, green: 1.0, blue: 0.10)

    public static func soundtrack(duration: Double) -> Score? {
        Score(duration: duration) {
            chordPad(.minor9(.a3), at: 0, duration: duration / 2 + 0.4, amp: 0.025)
            chordPad(.major7(.f3), at: duration / 2, duration: duration / 2, amp: 0.025)
            arpeggio(.minor7(.a4), from: 0.5, to: duration - 0.8, step: 0.25, amp: 0.05, pattern: .upDown)
            thump(at: 0.1, amp: 0.4)
        }
    }

    static func style(_ name: String) -> Stylize.Style {
        Stylize.Style.allCases.first { String(describing: $0).lowercased() == name.lowercased() } ?? .ascii
    }

    @MainActor
    public static func body(at t: Double, duration: Double, props: Props) -> some View {
        let track = VisionTrack.load(props.clip, fps: 30)
        let clipLen: Double = max(0.1, MediaLibrary.duration(props.clip))
        let ct: Double = t.truncatingRemainder(dividingBy: clipLen)
        let pose: VisionFrame? = track.frame(at: ct)
        let person: Bool = pose?.hasPerson ?? false
        let full = CGSize(width: W, height: H)

        let cutout = ZStack {
            Color.black
            VideoClip(props.clip, at: ct)
                .mask {
                    if person, let m = track.mask(at: ct) {
                        Image(decorative: m, scale: 1).resizable().luminanceToAlpha()
                    } else {
                        Rectangle()
                    }
                }
        }
        .frame(width: W, height: H)
        let grid = PixelGrid.sample(cutout, size: full, cols: 320) ?? PixelGrid(cols: 1, rows: 1, data: [0, 0, 0, 255])
        let fade: Double = Ease.clip(t, 0, 0.4) * (1 - Ease.clip(t, duration - 0.6, duration))

        return ZStack {
            Color(red: 0.03, green: 0.03, blue: 0.04)
            Stylize.view(style(props.style), grid: grid, size: full, t: t)
            trails(track, ct)
            PoseOverlay(pose, color: volt, lineWidth: 5)
            pip(props.clip, ct, pose)
            caption(person, props)
            Color.black.opacity(1 - fade)
        }
        .frame(width: W, height: H)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    /// Fading trails behind both wrists — a pure lookup of the last 0.6 s of joints.
    @MainActor
    static func trails(_ track: VisionTrack, _ ct: Double) -> some View {
        Canvas { ctx, size in
            for joint in ["leftWrist", "rightWrist"] {
                for k in 0..<18 {
                    let a: Double = ct - Double(k) * 0.035, b: Double = ct - Double(k + 1) * 0.035
                    guard a > 0, b > 0, let p = track.joint(joint, at: a), let q = track.joint(joint, at: b) else { continue }
                    var seg = Path(); seg.move(to: p.at(size)); seg.addLine(to: q.at(size))
                    let fadeOut: Double = 1 - Double(k) / 18
                    ctx.stroke(seg, with: .color(volt.opacity(0.85 * fadeOut)),
                               style: StrokeStyle(lineWidth: 16 * fadeOut + 2, lineCap: .round))
                }
            }
        }
    }

    @ViewBuilder @MainActor
    static func pip(_ clip: String, _ ct: Double, _ pose: VisionFrame?) -> some View {
        ZStack {
            VideoClip(clip, at: ct)
            PoseOverlay(pose, color: volt, lineWidth: 2.5)
        }
        .frame(width: 400, height: 225)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.35), lineWidth: 2))
        .frame(width: W, height: H, alignment: .topTrailing)
        .offset(x: -48, y: 48)
    }

    @ViewBuilder @MainActor
    static func caption(_ person: Bool, _ props: Props) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("APPLE VISION  ·  BODY + HANDS + PERSON MASK")
                .font(.system(size: 22, weight: .semibold, design: .monospaced)).foregroundStyle(volt)
            Text(person ? "re-rendered as \(props.style)" : "no person in \(props.clip) — pass your own clip with --props")
                .font(.system(size: 22, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.8))
        }
        .padding(.horizontal, 22).padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.75)))
        .frame(width: W, height: H, alignment: .bottomLeading)
        .offset(x: 48, y: -48)
    }
}
