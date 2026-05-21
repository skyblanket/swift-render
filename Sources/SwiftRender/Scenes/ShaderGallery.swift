import SwiftUI

/// Gallery reel cycling through Cookbook Vol. 2 shaders. Each shader gets
/// a 5-second full-frame slot with a corner label. 30s total.
public struct ShaderGallery: RenderScene {
    public static let defaultDuration: Double = 30.0

    private struct Slot {
        let name: String
        let start: Double
        let duration: Double
    }

    private static let slots: [Slot] = [
        Slot(name: "liquidMetal",  start:  0, duration: 5),
        Slot(name: "kaleidoscope", start:  5, duration: 5),
        Slot(name: "truchet",      start: 10, duration: 5),
        Slot(name: "galaxy",       start: 15, duration: 5),
        Slot(name: "neonGrid",     start: 20, duration: 5),
        Slot(name: "smokeFlow",    start: 25, duration: 5),
    ]

    @MainActor public static func body(at t: Double, duration: Double) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ForEach(Array(slots.enumerated()), id: \.offset) { _, slot in
                let local = t - slot.start
                let inP  = Ease.easeOut(Ease.clip(local, 0.0, 0.4))
                let outP = Ease.easeIn(Ease.clip(local, slot.duration - 0.4, slot.duration))
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
        ZStack(alignment: .bottomLeading) {
            shader(name: name, t: localT)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 36, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.white)
                Text("Cookbook2.metal · ShaderLibrary.bundle(.module).\(name)")
                    .font(.system(size: 14, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.65))
            }
            .padding(40)
            .shadow(color: .black.opacity(0.7), radius: 8, x: 0, y: 2)
        }
    }

    @ViewBuilder
    @MainActor
    private static func shader(name: String, t: Double) -> some View {
        switch name {
        case "liquidMetal":
            Rectangle().fill(.black).colorEffect(
                ShaderLibrary.bundle(.module).liquidMetal(.float2(1920, 1080), .float(Float(t)))
            )
        case "kaleidoscope":
            Rectangle().fill(.black).colorEffect(
                ShaderLibrary.bundle(.module).kaleidoscope(
                    .float2(1920, 1080), .float(Float(t)), .float(8.0)
                )
            )
        case "truchet":
            Rectangle().fill(.black).colorEffect(
                ShaderLibrary.bundle(.module).truchet(
                    .float2(1920, 1080), .float(Float(t)), .float(12.0)
                )
            )
        case "galaxy":
            Rectangle().fill(.black).colorEffect(
                ShaderLibrary.bundle(.module).galaxy(.float2(1920, 1080), .float(Float(t)))
            )
        case "neonGrid":
            Rectangle().fill(.black).colorEffect(
                ShaderLibrary.bundle(.module).neonGrid(.float2(1920, 1080), .float(Float(t)))
            )
        case "smokeFlow":
            Rectangle().fill(.black).colorEffect(
                ShaderLibrary.bundle(.module).smokeFlow(.float2(1920, 1080), .float(Float(t)))
            )
        default:
            EmptyView()
        }
    }
}
