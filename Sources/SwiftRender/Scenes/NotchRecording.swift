import SwiftUI

/// OpenEar Notch / Dynamic-Island recording overlay. Now anchored to a faint
/// Mac menu-bar strip across the top of frame so the notch reads as "this lives there."
public struct NotchRecording: RenderScene {
    public static let defaultDuration: Double = 6.0

    @MainActor public static func body(at t: Double, duration: Double) -> some View {
        let entry = Ease.easeOut(Ease.clip(t, 0.0, 0.7))
        let exit = Ease.easeIn(Ease.clip(t, duration - 0.5, duration))
        let visibility = entry * (1.0 - exit)
        let level = NotchSignal.syntheticLevel(t)

        return ZStack {
            // Dim desktop gradient
            LinearGradient(
                colors: [Color(white: 0.04), Color(white: 0.02), .black],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Faint menu bar strip — anchors the notch to "this is on a Mac"
                Rectangle()
                    .fill(Color.white.opacity(0.025))
                    .frame(height: 28)
                    .overlay(
                        Rectangle().fill(Color.white.opacity(0.05))
                            .frame(height: 0.5),
                        alignment: .bottom
                    )
                    .overlay(alignment: .leading) {
                        HStack(spacing: 14) {
                            Circle().fill(Color.white.opacity(0.18)).frame(width: 8, height: 8)
                            Text("OpenEar")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.7))
                        }
                        .padding(.leading, 22)
                    }

                Spacer()
            }
            .ignoresSafeArea()

            VStack {
                notchPill(level: level, t: t)
                    .scaleEffect(0.96 + 0.04 * CGFloat(visibility))
                    .opacity(visibility)
                    .offset(y: CGFloat(1 - visibility) * -16)
                    .padding(.top, 32)

                Spacer()

                // Caption beneath
                let captionP = Ease.easeOut(Ease.clip(t, 1.5, 2.5))
                Text("Listening on device. Nothing leaves your Mac.")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .opacity(captionP * visibility)
                    .padding(.bottom, 120)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    @ViewBuilder
    @MainActor
    private static func notchPill(level: Float, t: Double) -> some View {
        HStack(spacing: 14) {
            BreathingDot(level: level, t: t)
                .frame(width: 22, height: 22)

            Text("Listening…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.85))
                .tracking(0.3)

            Rectangle().fill(Color.white.opacity(0.15)).frame(width: 1, height: 14)

            Waveform(level: level, t: t, barCount: 20, height: 18)
                .frame(width: 130, height: 18)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(
            Capsule(style: .continuous)
                .fill(Color.black)
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.85), radius: 8, x: 0, y: 4)
                .shadow(color: .black.opacity(0.55), radius: 28, x: 0, y: 18)
                .shadow(color: Color.red.opacity(0.10), radius: 36, x: 0, y: 0)
        )
    }
}

enum NotchSignal {
    static func syntheticLevel(_ t: Double) -> Float {
        let base = sin(t * 4.2) * sin(t * 1.7)
        let mid  = sin(t * 11.0) * 0.5
        let hi   = sin(t * 23.0) * 0.25
        let env  = max(0, base + mid + hi) * 0.55 + 0.10
        return Float(min(1.0, env))
    }
}

/// Pure function of (level, t). No internal state.
struct BreathingDot: View {
    let level: Float
    let t: Double

    var body: some View {
        let breathe = CGFloat(sin(t * 2.5) * 0.5 + 0.5)
        let l = CGFloat(level)
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            .red.opacity(0.8 * Double(level + 0.4)),
                            .red.opacity(0.4 * Double(level + 0.2)),
                            .red.opacity(0.1),
                            .clear
                        ],
                        center: .center,
                        startRadius: 1,
                        endRadius: 10 + l * 6
                    )
                )
                .frame(width: 20, height: 20)
                .scaleEffect(1 + breathe * 0.15 + l * 0.3)

            Circle()
                .fill(.red.opacity(0.5 + Double(level) * 0.3))
                .frame(width: 8, height: 8)
                .blur(radius: 2)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [.white.opacity(0.3), .red, .red],
                        center: .center,
                        startRadius: 0,
                        endRadius: 3
                    )
                )
                .frame(width: 5, height: 5)
                .shadow(color: .red.opacity(0.8), radius: 3)
        }
    }
}

/// Audio bars. Pure function of (level, t, barIdx).
struct Waveform: View {
    let level: Float
    let t: Double
    let barCount: Int
    let height: CGFloat
    var spacing: CGFloat = 3
    var minHeight: CGFloat = 2
    var color: Color = Color.white

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: spacing) {
                ForEach(0..<barCount, id: \.self) { idx in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(barColor(idx))
                        .frame(width: barWidth(geo), height: barHeight(idx, geo))
                }
            }
        }
    }

    private func barWidth(_ geo: GeometryProxy) -> CGFloat {
        let total = spacing * CGFloat(barCount - 1)
        return (geo.size.width - total) / CGFloat(barCount)
    }

    private func barHeight(_ idx: Int, _ geo: GeometryProxy) -> CGFloat {
        let center = Double(barCount - 1) / 2.0
        let distance = abs(Double(idx) - center)
        let p1 = t * 3.5 - distance * 0.32
        let w1 = sin(p1) * 0.5 + 0.5
        let p2 = t * 6.2 + distance * 0.22
        let w2 = sin(p2) * 0.5 + 0.5
        let bias = sin(Double(idx) * 0.7 + t * 1.3) * 0.18 + 0.5
        let lvl = max(0.5, Double(level))
        let envelope = (w1 * 0.55 + w2 * 0.45) * bias * lvl
        let h = max(0.2, min(1.0, envelope * 1.6))
        return max(minHeight, CGFloat(h) * geo.size.height)
    }

    private func barColor(_ idx: Int) -> Color {
        let center = barCount / 2
        let distance = abs(idx - center)
        let opacity = 1.0 - (Double(distance) / Double(center)) * 0.20
        return color.opacity(opacity)
    }
}
