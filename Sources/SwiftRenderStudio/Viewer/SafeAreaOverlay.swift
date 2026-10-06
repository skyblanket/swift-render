import SwiftUI

// MARK: - Guides (G cycles)
//
// Safe areas (action 93%, title 90%), thirds + center, and 9:16 social zones
// (top 14% and bottom 20% shaded — where platform UI covers the frame).

enum GuideMode: String, CaseIterable, Identifiable, Sendable {
    case off, safe, thirds, social
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return "No guides"
        case .safe: return "Safe areas"
        case .thirds: return "Thirds"
        case .social: return "Social zones"
        }
    }
    var next: GuideMode {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

struct SafeAreaOverlay: View {
    var mode: GuideMode
    /// Canvas rect in this view's coordinates.
    var canvas: CGRect

    var body: some View {
        Canvas { ctx, _ in
            let c = canvas
            let dash = StrokeStyle(lineWidth: 1, dash: [4, 3])
            switch mode {
            case .off:
                break
            case .safe:
                for (pct, label, style) in [(0.93, "ACTION SAFE 93%", dash), (0.90, "TITLE SAFE 90%", StrokeStyle(lineWidth: 1))] {
                    let r = c.insetBy(dx: c.width * (1 - pct) / 2, dy: c.height * (1 - pct) / 2)
                    ctx.stroke(Path(r), with: .color(.white.opacity(0.45)), style: style)
                    ctx.draw(Text(label).font(.system(size: 8.5, weight: .semibold)).foregroundStyle(.white.opacity(0.55)),
                             at: CGPoint(x: r.minX + 4, y: r.minY + 4), anchor: .topLeading)
                }
                cross(&ctx, at: CGPoint(x: c.midX, y: c.midY))
            case .thirds:
                var p = Path()
                for i in 1...2 {
                    let x = c.minX + c.width * CGFloat(i) / 3, y = c.minY + c.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: c.minY)); p.addLine(to: CGPoint(x: x, y: c.maxY))
                    p.move(to: CGPoint(x: c.minX, y: y)); p.addLine(to: CGPoint(x: c.maxX, y: y))
                }
                ctx.stroke(p, with: .color(.white.opacity(0.4)), lineWidth: 1)
                cross(&ctx, at: CGPoint(x: c.midX, y: c.midY))
            case .social:
                let top = CGRect(x: c.minX, y: c.minY, width: c.width, height: c.height * 0.14)
                let bottom = CGRect(x: c.minX, y: c.maxY - c.height * 0.20, width: c.width, height: c.height * 0.20)
                ctx.fill(Path(top), with: .color(.black.opacity(0.45)))
                ctx.fill(Path(bottom), with: .color(.black.opacity(0.45)))
                ctx.draw(Text("PLATFORM UI").font(.system(size: 8.5, weight: .semibold)).foregroundStyle(.white.opacity(0.6)),
                         at: CGPoint(x: top.midX, y: top.midY))
                ctx.draw(Text("CAPTIONS · ACTIONS").font(.system(size: 8.5, weight: .semibold)).foregroundStyle(.white.opacity(0.6)),
                         at: CGPoint(x: bottom.midX, y: bottom.midY))
            }
        }
        .allowsHitTesting(false)
    }

    private func cross(_ ctx: inout GraphicsContext, at p: CGPoint) {
        var path = Path()
        path.move(to: CGPoint(x: p.x - 8, y: p.y)); path.addLine(to: CGPoint(x: p.x + 8, y: p.y))
        path.move(to: CGPoint(x: p.x, y: p.y - 8)); path.addLine(to: CGPoint(x: p.x, y: p.y + 8))
        ctx.stroke(path, with: .color(.white.opacity(0.6)), lineWidth: 1)
    }
}
