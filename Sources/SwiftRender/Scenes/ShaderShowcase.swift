import SwiftUI

/// Demo reel cycling through the Cookbook shaders. Each shader gets a 5-second
/// slot, applied to a centered hero shape, with a label and a brief crossfade.
/// 30s total. Use this as a portfolio / proof-of-life for swift-render.
public struct ShaderShowcase: RenderScene {
    public static let defaultDuration: Double = 30.0

    private struct Slot {
        let name: String
        let start: Double
        let duration: Double
        var end: Double { start + duration }
    }

    private static let slots: [Slot] = [
        Slot(name: "rimGlow",            start:  0,  duration: 5),
        Slot(name: "foilHolographic",    start:  5,  duration: 5),
        Slot(name: "plasmaField",        start: 10,  duration: 5),
        Slot(name: "audioBars",          start: 15,  duration: 5),
        Slot(name: "caustics",           start: 20,  duration: 5),
        Slot(name: "chromaticAberration",start: 25,  duration: 5),
    ]

    @MainActor public static func body(at t: Double, duration: Double) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ForEach(Array(slots.enumerated()), id: \.offset) { _, slot in
                let local = t - slot.start
                let inP  = Ease.easeOut(Ease.clip(local, 0.0, 0.5))
                let outP = Ease.easeIn(Ease.clip(local, slot.duration - 0.5, slot.duration))
                let opacity = inP * (1.0 - outP)
                let active = local >= -0.05 && local <= slot.duration + 0.05
                if active {
                    slotView(name: slot.name, localT: local)
                        .opacity(opacity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    @MainActor
    private static func slotView(name: String, localT: Double) -> some View {
        VStack(spacing: 32) {
            heroShape(for: name, t: localT)

            VStack(spacing: 4) {
                Text(name)
                    .font(.system(size: 28, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white)
                Text("Cookbook.metal")
                    .font(.system(size: 14, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.45))
            }
        }
    }

    @ViewBuilder
    @MainActor
    private static func heroShape(for name: String, t: Double) -> some View {
        switch name {
        case "rimGlow":
            RoundedRectangle(cornerRadius: 60, style: .continuous)
                .fill(Color(white: 0.08))
                .frame(width: 520, height: 520)
                .colorEffect(
                    ShaderLibrary.bundle(.module).rimGlow(
                        .float2(520, 520),
                        .color(Color(red: 1.0, green: 0.4, blue: 0.6)),
                        .float(1.2),
                        .float(Float(t))
                    )
                )
        case "foilHolographic":
            RoundedRectangle(cornerRadius: 40, style: .continuous)
                .fill(Color(white: 0.05))
                .frame(width: 640, height: 400)
                .colorEffect(
                    ShaderLibrary.bundle(.module).foilHolographic(
                        .float2(640, 400),
                        .float(3.0),
                        .float(1.0)
                    )
                )
        case "plasmaField":
            Rectangle()
                .fill(.black)
                .frame(width: 640, height: 400)
                .colorEffect(
                    ShaderLibrary.bundle(.module).plasmaField(
                        .float2(640, 400),
                        .float(Float(t)),
                        .float(1.4)
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        case "audioBars":
            Rectangle()
                .fill(.black)
                .frame(width: 640, height: 400)
                .colorEffect(
                    ShaderLibrary.bundle(.module).audioBars(
                        .float2(640, 400),
                        .float(Float(0.5 + 0.4 * sin(t * 2.0))),
                        .float(36.0),
                        .float(Float(t))
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        case "caustics":
            Rectangle()
                .fill(.black)
                .frame(width: 640, height: 400)
                .colorEffect(
                    ShaderLibrary.bundle(.module).caustics(
                        .float2(640, 400),
                        .float(Float(t)),
                        .float(0.9)
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        case "chromaticAberration":
            ZStack {
                Text("ABERRATION")
                    .font(.system(size: 84, weight: .heavy, design: .monospaced))
                    .foregroundStyle(Color.white)
            }
            .frame(width: 700, height: 400)
            .colorEffect(
                ShaderLibrary.bundle(.module).chromaticAberration(
                    .float2(700, 400),
                    .float(1.0)
                )
            )
        default:
            EmptyView()
        }
    }
}
