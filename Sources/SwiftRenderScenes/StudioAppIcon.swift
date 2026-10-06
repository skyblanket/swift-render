import SwiftRender
import SwiftUI

/// swift-render Studio's app icon, made with swift-render: `scripts/package-studio.sh`
/// renders frame t=2.6 at 1024×1024 and turns it into AppIcon.icns. Pure function of t:
/// over 4 s the playhead sweeps the timeline while the viewer's light follows it.
///
/// Layout follows the macOS icon grid: an 824-pt continuous squircle centred on a
/// transparent 1024 canvas, with room for the drop shadow.
public struct StudioAppIcon: RenderScene {
    public static let defaultDuration: Double = 4.0
    /// No grain or vignette: the canvas outside the squircle must stay transparent.
    public static let ownsPostFX = true

    static let amber = Color(red: 1.0, green: 0.78, blue: 0.36)
    static let playhead = Color(red: 1.0, green: 0.27, blue: 0.23)

    @MainActor public static func body(at t: Double, duration: Double) -> some View {
        let p = Ease.easeInOut(Ease.clip(t, 0.3, duration - 0.3))
        let headX = -250 + 500 * p

        return ZStack {
            // Body: graphite squircle with a lit top edge.
            RoundedRectangle(cornerRadius: 186, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.20), Color(white: 0.075)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: 186, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.04)],
                                                     startPoint: .top, endPoint: .bottom), lineWidth: 3)
                )
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.45), radius: 22, y: 14)

            VStack(spacing: 46) {
                viewer(headX: headX)
                timeline(headX: headX)
            }
            .offset(y: 8)
        }
        .frame(width: 1024, height: 1024)
    }

    /// The "viewer": a dusk gradient lit where the playhead is, with the swift-render chevron.
    @MainActor static func viewer(headX: Double) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.16, green: 0.10, blue: 0.30),
                                              Color(red: 0.05, green: 0.04, blue: 0.09)],
                                     startPoint: .top, endPoint: .bottom))
            RadialGradient(colors: [amber.opacity(0.95), Color(red: 1.0, green: 0.42, blue: 0.22).opacity(0.55), .clear],
                           center: UnitPoint(x: 0.5 + headX / 1100, y: 1.05), startRadius: 10, endRadius: 330)
                .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
            // Play chevron.
            Image(systemName: "play.fill")
                .font(.system(size: 120, weight: .black))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
                .offset(x: 8)
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 2.5)
        }
        .frame(width: 620, height: 350)
    }

    /// Three lanes of clips (amber, teal, violet, the Studio lane colours) and a red playhead.
    @MainActor static func timeline(headX: Double) -> some View {
        let lanes: [(Color, [(Double, Double)])] = [
            (amber, [(0, 190), (206, 380), (396, 620)]),
            (Color(red: 0.45, green: 0.85, blue: 0.80), [(40, 150), (166, 300), (316, 470), (486, 580)]),
            (Color(red: 0.70, green: 0.55, blue: 1.0), [(0, 250), (266, 520)]),
        ]
        return ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(0..<lanes.count, id: \.self) { i in
                    ZStack(alignment: .leading) {
                        ForEach(0..<lanes[i].1.count, id: \.self) { j in
                            let (a, b) = lanes[i].1[j]
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(lanes[i].0.opacity(0.92))
                                .frame(width: b - a, height: 40)
                                .offset(x: a)
                        }
                    }
                    .frame(width: 620, height: 40, alignment: .leading)
                }
            }
            // Playhead: cap + line.
            VStack(spacing: 0) {
                Triangle().fill(playhead).frame(width: 34, height: 24)
                Rectangle().fill(playhead).frame(width: 7, height: 168)
            }
            .shadow(color: playhead.opacity(0.6), radius: 10)
            .offset(x: 310 + headX - 17, y: -26)
        }
        .frame(width: 620, height: 152, alignment: .topLeading)
    }

    struct Triangle: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
            p.closeSubpath()
            return p
        }
    }
}
