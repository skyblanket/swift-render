import SwiftUI

/// Animated particle field over a plasma background. Pure function of t.
/// 200 deterministic particles with sine motion, layered over the
/// plasmaField shader from the Cookbook.
public struct ParticleField: RenderScene {
    public static let defaultDuration: Double = 5.0
    public static let particleCount = 220

    @MainActor public static func body(at t: Double, duration: Double) -> some View {
        let exit = Ease.easeIn(Ease.clip(t, duration - 0.5, duration))
        let visibility = 1.0 - exit

        return ZStack {
            // Plasma background via shader
            Rectangle()
                .fill(.black)
                .colorEffect(
                    ShaderLibrary.bundle(.module).plasmaField(
                        .float2(1920, 1080),
                        .float(Float(t)),
                        .float(1.4)
                    )
                )
                .opacity(0.55)

            Canvas { ctx, size in
                for i in 0..<particleCount {
                    let fi = Double(i)
                    let baseX = fract(sin(fi * 12.9898) * 43758.5453) * size.width
                    let baseY = fract(sin(fi * 78.233) * 43758.5453) * size.height
                    let driftX = sin(t * 0.6 + fi * 0.17) * 40
                    let driftY = cos(t * 0.5 + fi * 0.21) * 36
                    let x = baseX + driftX
                    let y = baseY + driftY
                    let r = 1.5 + 2.0 * fract(sin(fi * 33.7) * 99.0)
                    let alpha = 0.35 + 0.4 * (sin(t * 1.2 + fi) * 0.5 + 0.5)
                    let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                    ctx.fill(Path(ellipseIn: rect), with: .color(Color.white.opacity(alpha)))
                }
            }
            .blendMode(.screen)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .opacity(visibility)
    }

    private static func fract(_ x: Double) -> Double { x - floor(x) }
}
