import SwiftUI

/// Vintage Otonomy label — Philips-inspired layout with proper text wrapping.
struct VinylLabelView: View {
    var size: CGFloat
    var title: String = "Untitled"
    var date: String = ""

    private var labelDiameter: CGFloat { size * 0.50 }
    private var r: CGFloat { labelDiameter / 2 }
    private var f: CGFloat { max(r * 0.09, 2) }

    // Aged ink — slightly transparent, pressed into paper
    private var textColor: Color { Color(red: 0.88, green: 0.83, blue: 0.76) }

    var body: some View {
        ZStack {
            // ── Outer arc text (tight inside label edge) ──
            CircularText(
                text: "ALL RIGHTS RESERVED \u{00B7} OTONOMY INC \u{00B7} \(date.uppercased()) \u{00B7} OT-GBL.01 \u{00B7} RECORDED & MASTERED \u{00B7} DIGITAL TRANSCRIPTION \u{00B7}",
                radius: r * 0.72,
                fontSize: f * 0.48,
                color: textColor
            )
            .opacity(0.35)

            // ── Inner arc (bottom half) ──
            CircularText(
                text: "OPEN EAR \u{00B7} PCM WAV \u{00B7} 16KHZ \u{00B7} MONO \u{00B7} OPEN EAR \u{00B7} PCM WAV \u{00B7} 16KHZ \u{00B7} MONO \u{00B7}",
                radius: r * 0.72,
                fontSize: f * 0.42,
                startAngle: .degrees(-90),
                clockwise: false,
                color: textColor
            )
            .opacity(0.25)

            // ── Main content ──
            VStack(spacing: f * 3.0) {
                // === TOP HALF (above hole) ===
                VStack(spacing: f * 0.3) {
                    // Code line (like "G 03553 L" / "GBL.5559")
                    HStack {
                        Text("OE \u{00B7} 2026")
                            .font(.system(size: f * 0.55, weight: .regular))
                        Spacer()
                        Text("GBL.001")
                            .font(.system(size: f * 0.55, weight: .regular))
                    }
                    .padding(.horizontal, r * 0.25)
                    .opacity(0.5)

                    // OTONOMY — main logo
                    Text("OTONOMY")
                        .font(.custom("Impact", size: f * 1.9))
                        .tracking(1.5)
                        .scaleEffect(x: 0.85, y: 1.0)
                        .opacity(0.82)

                    // Side info row (like "BIEM/NCB" / "1" / codes)
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("OPEN EAR")
                                .font(.system(size: f * 0.5, weight: .bold))
                                .padding(.horizontal, 2)
                                .padding(.vertical, 0.5)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 1)
                                        .stroke(textColor.opacity(0.3), lineWidth: 0.5)
                                )
                            Text("Stereo")
                                .font(.system(size: f * 0.4, weight: .regular))
                                .italic()
                                .opacity(0.5)
                        }
                        Spacer()
                        // Side number
                        Text("1")
                            .font(.system(size: f * 1.4, weight: .light, design: .serif))
                        Spacer()
                        VStack(alignment: .trailing, spacing: 0) {
                            Text("48kHz")
                                .font(.system(size: f * 0.45, weight: .regular))
                                .opacity(0.5)
                            Text("WAV")
                                .font(.system(size: f * 0.45, weight: .regular))
                                .opacity(0.5)
                        }
                    }
                    .padding(.horizontal, r * 0.22)
                }

                // === BOTTOM HALF (below hole) ===
                VStack(spacing: f * 0.25) {
                    // Divider
                    Rectangle()
                        .fill(textColor.opacity(0.2))
                        .frame(height: 0.5)
                        .padding(.horizontal, r * 0.2)

                    // Session title — bold, wrapped, centered
                    Text(title.uppercased())
                        .font(.system(size: f * 0.7, weight: .bold, design: .serif))
                        .tracking(0.2)
                        .lineLimit(3)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.4)
                        .padding(.horizontal, r * 0.18)
                        .opacity(0.75)

                    // Bottom credit line
                    Text("Transcribed by OpenEar")
                        .font(.system(size: f * 0.4, weight: .regular))
                        .italic()
                        .opacity(0.35)
                }
            }
        }
        .foregroundStyle(textColor)
        .frame(width: labelDiameter, height: labelDiameter)
        .clipShape(Circle())
        .compositingGroup()
        .blendMode(.hardLight)
        .opacity(0.9)
        .allowsHitTesting(false)
    }
}

/// Renders text along a circular arc using Canvas for performance.
struct CircularText: View {
    let text: String
    let radius: CGFloat
    let fontSize: CGFloat
    var startAngle: Angle = .degrees(-90)
    var clockwise: Bool = true
    var color: Color = .white

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let step = 360.0 / max(Double(text.count), 1)

            for (index, char) in text.enumerated() {
                let offset = step * Double(index)
                let angle = clockwise ? startAngle + .degrees(offset) : startAngle - .degrees(offset)
                let x = center.x + cos(angle.radians) * radius
                let y = center.y + sin(angle.radians) * radius

                context.drawLayer { layerCtx in
                    layerCtx.translateBy(x: x, y: y)
                    layerCtx.rotate(by: angle + .degrees(clockwise ? 90 : -90))
                    let resolved = layerCtx.resolve(
                        Text(String(char))
                            .font(.system(size: fontSize, weight: .regular))
                            .foregroundStyle(color)
                    )
                    layerCtx.draw(resolved, at: .zero)
                }
            }
        }
        .frame(width: radius * 2.4, height: radius * 2.4)
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
