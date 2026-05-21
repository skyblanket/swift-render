import SwiftUI

/// Ported from OpenEar's `VinylDiscView`, simplified to be driven entirely
/// by an external spin angle (deterministic — capture-safe). All hover/
/// spring state stripped; rotation is a pure function of the caller's t.
struct VinylDiscView: View {
    var labelColor: Color = Color(red: 0.45, green: 0.12, blue: 0.11)
    var accentColor: Color = .white
    var size: CGFloat = 200
    var seed: Float = 3
    var title: String = "Untitled"
    var date: String = ""
    var mouseNorm: CGPoint = CGPoint(x: 0.5, y: 0.5)
    /// Driven externally by the parent scene's `t` clock.
    var externalSpinAngle: Double

    var body: some View {
        ZStack {
            // ── Shader disc with world-space lighting ──
            Rectangle()
                .fill(.black)
                .frame(width: size, height: size)
                .colorEffect(
                    ShaderLibrary.bundle(.module).spinningVinyl(
                        .float2(size, size),
                        .float(0.0),                   // shaderTime — unused
                        .float(seed),
                        .color(labelColor),
                        .color(accentColor),
                        .float2(Float(mouseNorm.x), Float(mouseNorm.y)),
                        .float(1.0),                   // hoverActive — always full color
                        .float(Float(externalSpinAngle * .pi / 180.0))
                    )
                )
                .clipShape(Circle())

            if size > 60 {
                VinylLabelView(size: size, title: title, date: date)
                    .opacity(1.0)
                    .rotationEffect(.degrees(externalSpinAngle))
            }
        }
        .drawingGroup()
        .frame(width: size, height: size)
    }
}
