import SwiftUI

/// Black glossy album sleeve — uses the ported `sleeveShader` Metal program
/// from OpenEar's MembershipShaders.metal. Square card with anisotropic
/// gloss, vignette, and card-stock grain. mouseNorm is fixed since we don't
/// have hover in capture context.
struct SleeveView: View {
    var size: CGFloat = 400
    var seed: Float = 7
    var mouseNorm: CGPoint = CGPoint(x: 0.32, y: 0.28)
    var glossiness: Double = 1.0
    var cornerRadius: CGFloat = 14

    var body: some View {
        Rectangle()
            .fill(.black)
            .colorEffect(
                ShaderLibrary.bundle(.module).sleeveShader(
                    .float2(size, size),
                    .float(seed),
                    .float2(Float(mouseNorm.x), Float(mouseNorm.y)),
                    .float(Float(glossiness))
                )
            )
            .frame(width: size, height: size)
            .overlay {
                // Cover label — keeps it brand-recognizable
                VStack(spacing: 6) {
                    Spacer()
                    Text("OPENEAR")
                        .font(.system(size: size * 0.10, weight: .semibold))
                        .tracking(size * 0.02)
                        .foregroundStyle(.white.opacity(0.85))
                    Text("Side A · Local")
                        .font(.system(size: size * 0.045, weight: .regular))
                        .foregroundStyle(.white.opacity(0.45))
                    Spacer()
                }
                .padding(.horizontal, size * 0.12)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.7), radius: 26, x: 0, y: 18)
    }
}
