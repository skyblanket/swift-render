import SwiftUI

/// AudioBars — reference scene for the audio-reactive + props APIs together.
///
/// The bar field, title glow, and bass thump are all driven by the pre-analyzed
/// `AudioTrack`; layout and styling come from JSON props:
///
///   swift run swift-render props AudioBars > /tmp/bars.json
///   swift run swift-render render AudioBars --audio out/jri.wav \
///       --props /tmp/bars.json --out out/bars.mp4
public struct AudioBars: PropsAudioScene {
    public struct Props: Codable {
        public var title = "SWIFT-RENDER"
        public var subtitle = "AUDIO-REACTIVE. FRAME-DETERMINISTIC."
        public var barCount = 56
        public var accentHex = "#C7FF1A"
        public var bassPunch = 0.5
    }

    public static let defaultDuration = 15.0
    public static var defaultProps: Props { Props() }

    @MainActor
    public static func body(at t: Double, duration: Double, props: Props, audio: AudioTrack) -> some View {
        let level = audio.level(at: t)
        let bass = audio.band(.bass, at: t)
        let high = audio.band(.high, at: t)
        let accent = Color(hex: props.accentHex)
        let inP = Ease.easeOut(Ease.clip(t, 0, 0.6))
        let exit = Ease.easeIn(Ease.clip(t, duration - 0.5, duration))

        return ZStack {
            Color.black.ignoresSafeArea()

            // bass halo behind everything
            RadialGradient(colors: [accent.opacity(0.10 + 0.25 * bass), .clear],
                           center: .center, startRadius: 0, endRadius: 900)
                .ignoresSafeArea()

            // mirrored bar field
            HStack(alignment: .center, spacing: 8) {
                ForEach(0..<props.barCount, id: \.self) { i in
                    let phase = Double(i) / Double(max(1, props.barCount)) * 0.18
                    let v = audio.level(at: max(0, t - phase))
                    let h = 24 + 600 * v
                    Capsule()
                        .fill(accent.opacity(0.30 + 0.70 * high))
                        .frame(width: 14, height: h)
                }
            }
            .opacity(inP)

            VStack(spacing: 14) {
                Text(props.title)
                    .font(.system(size: 120, weight: .black))
                    .fontWidth(.condensed)
                    .foregroundStyle(.white.opacity(0.35 + 0.65 * level))
                Text(props.subtitle)
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .tracking(8)
                    .foregroundStyle(accent.opacity(0.85))
            }
            .shadow(color: .black.opacity(0.7), radius: 16)
            .opacity(inP)
        }
        .scaleEffect(1 + props.bassPunch * 0.08 * bass)
        .opacity(1 - exit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension Color {
    /// "#RRGGBB" → Color. Invalid input falls back to white.
    init(hex: String) {
        var v: UInt64 = 0
        guard Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&v) else {
            self = .white
            return
        }
        self.init(red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }
}
