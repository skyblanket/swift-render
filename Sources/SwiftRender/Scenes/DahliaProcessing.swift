import SwiftUI

/// Spinning dahlia interlude with a shimmer transcript line below — anchors
/// the "polishing your wording" beat in something semantic, not just a spinner.
public struct DahliaProcessing: RenderScene {
    public static let defaultDuration: Double = 4.0

    @MainActor public static func body(at t: Double, duration: Double) -> some View {
        let entry = Ease.easeOut(Ease.clip(t, 0.0, 0.6))
        let exit = Ease.easeIn(Ease.clip(t, duration - 0.4, duration))
        let visibility = entry * (1.0 - exit)
        let shimmer = (t * 0.8).truncatingRemainder(dividingBy: 1.0)

        return ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 38) {
                SpinningDahlia(t: t)
                    .frame(width: 110, height: 110)
                    .scaleEffect(2.6)

                Text("Polishing your wording…")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.55))

                // Shimmer transcript line
                ShimmerText(
                    text: "let's catch up tomorrow at three…",
                    fontSize: 32,
                    progress: shimmer
                )
                .frame(width: 820, height: 44)
            }
            .opacity(visibility)
            .scaleEffect(0.97 + 0.03 * CGFloat(visibility))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Pure function of t. 12 petals, deterministic rotation + bloom.
struct SpinningDahlia: View {
    let t: Double
    private let petalCount = 12
    private let colors: [Color] = [
        .white.opacity(0.9), .white.opacity(0.6),
        .white.opacity(0.4), .white.opacity(0.7),
    ]

    var body: some View {
        let rotation = (t / 1.2) * 360.0
        let bloom: CGFloat = 1.0 + 0.3 * (CGFloat(sin(t / 0.8 * .pi)) * 0.5 + 0.5)

        ZStack {
            ForEach(0..<petalCount, id: \.self) { i in
                let angle = Double(i) * (360.0 / Double(petalCount))
                let colorIndex = i % colors.count
                let delay = Double(i) * 0.05
                Capsule()
                    .fill(colors[colorIndex])
                    .frame(width: 2.5, height: 7 * bloom)
                    .offset(y: -5)
                    .rotationEffect(.degrees(angle + rotation))
                    .opacity(0.4 + 0.6 * sin(rotation / 30 + delay * 10))
            }
            Circle().fill(.white.opacity(0.8)).frame(width: 3, height: 3)
        }
    }
}

/// Faux-shimmer text: gradient sweep across the text.
struct ShimmerText: View {
    let text: String
    let fontSize: CGFloat
    let progress: Double  // 0..1 sweeping across

    var body: some View {
        ZStack {
            Text(text)
                .font(.system(size: fontSize, weight: .regular, design: .serif))
                .foregroundStyle(Color.white.opacity(0.18))
            Text(text)
                .font(.system(size: fontSize, weight: .regular, design: .serif))
                .foregroundStyle(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: max(0, progress - 0.18)),
                            .init(color: .white.opacity(0.55), location: progress),
                            .init(color: .clear, location: min(1, progress + 0.18)),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .blendMode(.plusLighter)
        }
    }
}
