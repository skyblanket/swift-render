import SwiftUI
import SwiftRender

// MARK: - BugRig — procedural top-down insect (beetle/ant hybrid)
//
// Pure function of its inputs: no state, no time source. Drive `gaitPhase`
// from distance travelled (recommended: gaitPhase = distance / (7 * scale))
// so feet do not skate. A frozen gaitPhase = a fully still, naturally
// resting bug.
//
// Local rig space: +x = forward (heading axis), y = lateral, origin at the
// thorax centre. Body length ≈ 110 units at scale 1.0.

public enum BugRig {

    /// Deterministic hash (repo-standard pattern).
    fileprivate static func h(_ x: Double) -> Double {
        let s = sin(x * 127.1 + 311.7) * 43758.5453
        return s - floor(s)
    }

    // Proportions (body length L = 110):
    //   abdomen 55 (50%) · thorax 22 (20%) · head 16.5 (15%) · antennae ~44 (40%)
    fileprivate static let abdomenLen: Double = 55
    fileprivate static let thoraxLen: Double = 22
    fileprivate static let headR: Double = 8.25

    public static func draw(
        _ ctx: inout GraphicsContext,
        x: Double, y: Double,
        heading: Double,
        scale: Double,
        gaitPhase: Double,
        ink: Color, accent: Color,
        dead: Bool, detail: Bool
    ) {
        var c = ctx
        c.translateBy(x: CGFloat(x), y: CGFloat(y))
        c.rotate(by: .radians(heading))
        c.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        if dead { c.scaleBy(x: 1, y: -1) } // belly-up mirror

        // Stroke widths compensate for scale so tiny bugs stay >= ~1px on screen
        // and big bugs stay bold.
        let legLW = max(2.6, 1.4 / scale)
        let antLW = max(1.6, 1.0 / scale)

        if detail {
            drawDetailed(&c, gaitPhase: gaitPhase, ink: ink, accent: accent,
                         dead: dead, legLW: legLW, antLW: antLW)
        } else {
            drawLOD(&c, gaitPhase: gaitPhase, ink: ink, dead: dead, legLW: legLW)
        }
    }

    // MARK: detailed rig

    fileprivate static func drawDetailed(
        _ c: inout GraphicsContext,
        gaitPhase: Double, ink: Color, accent: Color,
        dead: Bool, legLW: Double, antLW: Double
    ) {
        let inkShade = GraphicsContext.Shading.color(ink)
        let legStyle = StrokeStyle(lineWidth: legLW, lineCap: .round, lineJoin: .round)
        let antStyle = StrokeStyle(lineWidth: antLW, lineCap: .round, lineJoin: .round)

        // ---- legs first (under the body plates) ----
        // Hips on the thorax, three per side.
        let hipX: [Double] = [10, 0, -9]
        // Rest foot positions (front angled forward, mid out, rear swept back)
        // — a clear front/mid/rear fan so the leg count reads instantly.
        let restFoot: [(Double, Double)] = [(34, 27), (3, 41), (-24, 36)]
        let amp = 0.45 * thoraxLen // ±10 → ~0.9× thorax length total excursion

        for side in [-1.0, 1.0] {
            for i in 0..<3 {
                let hip = CGPoint(x: hipX[i], y: side * 8.5)
                var path = Path()
                if dead {
                    // Curled tight: femur juts out past the silhouette, tibia
                    // hairpins back inward so each leg reads as a hook with the
                    // foot pointing up/inward. Kept OUTSIDE the body fill so the
                    // curl stays visible.
                    let outX: Double = [4.0, -1.0, -6.0][i]
                    let lat: Double = [26.0, 28.0, 28.0][i]
                    let knee = CGPoint(x: hip.x + outX, y: side * lat)
                    let foot = CGPoint(x: knee.x - 13,
                                       y: side * (lat - 9))
                    path.move(to: hip)
                    path.addLine(to: knee)
                    path.addLine(to: foot)
                } else {
                    // Alternating tripod: {FL, MR, RL} = +sin, {FR, ML, RR} = -sin.
                    let tripod: Double = ((i + (side > 0 ? 1 : 0)) % 2 == 0) ? 1 : -1
                    let swing = tripod * sin(gaitPhase)
                    // Foot moving forward ⇒ swing leg ⇒ implied lift = lateral pull-in.
                    let lift = max(0, tripod * cos(gaitPhase))
                    var foot = CGPoint(x: restFoot[i].0 + swing * amp,
                                       y: side * restFoot[i].1)
                    foot.y -= CGFloat(side * lift * 4.0)
                    // Knee bows OUTWARD from the hip→foot chord.
                    let mid = CGPoint(x: hip.x + (foot.x - hip.x) * 0.52,
                                      y: hip.y + (foot.y - hip.y) * 0.52)
                    let dx = Double(foot.x - hip.x), dy = Double(foot.y - hip.y)
                    let dl = max(0.001, (dx * dx + dy * dy).squareRoot())
                    var nx = -dy / dl, ny = dx / dl
                    if ny * side < 0 { nx = -nx; ny = -ny } // pick the away-from-body normal
                    let bow = 13.0 - lift * 2.5
                    let knee = CGPoint(x: mid.x + nx * bow, y: mid.y + ny * bow)
                    path.move(to: hip)
                    path.addLine(to: knee)
                    path.addLine(to: foot)
                }
                c.stroke(path, with: inkShade, style: legStyle)
            }
        }

        // ---- antennae (from the head, sweeping forward) ----
        for side in [-1.0, 1.0] {
            let base = CGPoint(x: 22.5, y: side * 3)
            var elbow: CGPoint
            var tip: CGPoint
            if dead {
                // Drooped straight: limp lines falling back beside the head,
                // clearly not alive.
                elbow = CGPoint(x: 25, y: side * 13)
                tip = CGPoint(x: 18, y: side * 26)
                var p = Path()
                p.move(to: base)
                p.addLine(to: elbow)
                p.addLine(to: tip)
                c.stroke(p, with: inkShade, style: antStyle)
            } else {
                // Sway + twitch driven purely by gaitPhase → frozen phase = still.
                // Tight forward V, well clear of the front legs.
                let sway = sin(gaitPhase * 0.8 + side * 1.3)
                let twitch = 0.2 * sin(gaitPhase * 6.7 + side * 4.1)
                elbow = CGPoint(x: 37, y: side * (7 + sway * 1.5))
                tip = CGPoint(x: 58, y: side * (13.5 + sway * 3 + twitch * 2.5))
                var p = Path()
                p.move(to: base)
                p.addLine(to: elbow)
                p.addQuadCurve(to: tip,
                               control: CGPoint(x: 48, y: side * (7.5 + sway * 2)))
                c.stroke(p, with: inkShade, style: antStyle)
            }
        }

        // ---- body plates (filled, drawn over leg roots) ----
        // Waist connector so the three segments read as one animal.
        var waist = Path()
        waist.addRoundedRect(in: CGRect(x: -38, y: -4.5, width: 58, height: 9),
                             cornerSize: CGSize(width: 4.5, height: 4.5))
        c.fill(waist, with: inkShade)

        // Abdomen — largest, rear, slightly tapered tail.
        var abdomen = Path(ellipseIn: CGRect(x: -34.5 - abdomenLen / 2, y: -16,
                                             width: abdomenLen, height: 32))
        // Tail taper hint.
        abdomen.addEllipse(in: CGRect(x: -66, y: -6, width: 14, height: 12))
        c.fill(abdomen, with: inkShade)

        // Thorax — small, centre.
        let thorax = Path(ellipseIn: CGRect(x: -thoraxLen / 2, y: -10.5,
                                            width: thoraxLen, height: 21))
        c.fill(thorax, with: inkShade)

        // Head — small circle, front, slightly narrower than thorax.
        let head = Path(ellipseIn: CGRect(x: 17.5 - headR, y: -headR,
                                          width: headR * 2, height: headR * 2))
        c.fill(head, with: inkShade)

        // ---- specimen marking ----
        if !dead {
            let a = GraphicsContext.Shading.color(accent)
            c.fill(Path(ellipseIn: CGRect(x: -33, y: -8, width: 7, height: 7)), with: a)
            c.fill(Path(ellipseIn: CGRect(x: -44, y: 2, width: 5, height: 5)), with: a)
        }
    }

    // MARK: cheap LOD (tiny / far bugs)

    fileprivate static func drawLOD(
        _ c: inout GraphicsContext,
        gaitPhase: Double, ink: Color, dead: Bool, legLW: Double
    ) {
        let inkShade = GraphicsContext.Shading.color(ink)
        let style = StrokeStyle(lineWidth: legLW, lineCap: .round)

        // 6 short leg ticks, still tripod-animated.
        let hipX: [Double] = [14, 0, -14]
        let lean: [Double] = [7, 0, -7]
        for side in [-1.0, 1.0] {
            for i in 0..<3 {
                var p = Path()
                let hip = CGPoint(x: hipX[i], y: side * 12)
                if dead {
                    let tip = CGPoint(x: hipX[i] - 5, y: side * 19)
                    p.move(to: hip)
                    p.addLine(to: tip)
                } else {
                    let tripod: Double = ((i + (side > 0 ? 1 : 0)) % 2 == 0) ? 1 : -1
                    let swing = tripod * sin(gaitPhase)
                    let tip = CGPoint(x: hipX[i] + lean[i] + swing * 8, y: side * 22)
                    p.move(to: hip)
                    p.addLine(to: tip)
                }
                c.stroke(p, with: inkShade, style: style)
            }
        }

        // Single body ellipse proxy (whole animal).
        let body = Path(ellipseIn: CGRect(x: -60, y: -15, width: 106, height: 30))
        c.fill(body, with: inkShade)
    }
}

// MARK: - BugTest — rig review scene

public struct BugTest: RenderScene {
    public static let defaultDuration: Double = 4.0

    @MainActor public static func body(at t: Double, duration: Double) -> some View {
        ZStack {
            Color.white
            Canvas { ctx, size in
                let w = size.width, hgt = size.height
                let ink = Color.black
                let accent = Color(red: 0.85, green: 0.15, blue: 0.1)
                let gray = Color(white: 0.55)

                // (a) big detailed bug walking a slow circle, heading tangent,
                //     gaitPhase proportional to distance travelled.
                let cx = 0.30 * w, cy = 0.52 * hgt, R = 0.30 * hgt
                let omega = 0.55
                let theta = -Double.pi / 2 + omega * t
                let bx = cx + R * cos(theta)
                let by = cy + R * sin(theta)
                let scaleA = 1.5
                let dist = R * omega * t
                let phaseA = dist / (7.0 * scaleA)
                BugRig.draw(&ctx, x: bx, y: by, heading: theta + .pi / 2,
                            scale: scaleA, gaitPhase: phaseA,
                            ink: ink, accent: accent, dead: false, detail: true)
                ctx.draw(Text("walk — tripod gait").font(.system(size: 22)).foregroundColor(gray),
                         at: CGPoint(x: cx, y: cy))

                // (b) dead bug, static.
                BugRig.draw(&ctx, x: 0.68 * w, y: 0.24 * hgt, heading: -0.45,
                            scale: 1.15, gaitPhase: 0,
                            ink: ink, accent: accent, dead: true, detail: true)
                ctx.draw(Text("dead").font(.system(size: 22)).foregroundColor(gray),
                         at: CGPoint(x: 0.68 * w, y: 0.24 * hgt + 110))

                // (d) detailed bug standing still (frozen phase) — rest pose.
                BugRig.draw(&ctx, x: 0.87 * w, y: 0.48 * hgt, heading: -.pi / 2,
                            scale: 1.25, gaitPhase: 0,
                            ink: ink, accent: accent, dead: false, detail: true)
                ctx.draw(Text("rest").font(.system(size: 22)).foregroundColor(gray),
                         at: CGPoint(x: 0.87 * w, y: 0.48 * hgt + 130))

                // (c) a row of 5 tiny LOD bugs marching right.
                let scaleC = 0.24
                let speed = 46.0
                for i in 0..<5 {
                    let off = BugRig.h(Double(i)) * .pi * 2
                    let x0 = 0.56 * w + Double(i) * 0.065 * w
                    let xi = x0 + speed * t
                    let phase = (speed * t) / (7.0 * scaleC) + off
                    BugRig.draw(&ctx, x: xi, y: 0.82 * hgt, heading: 0,
                                scale: scaleC, gaitPhase: phase,
                                ink: ink, accent: accent, dead: false, detail: false)
                }
                ctx.draw(Text("LOD swarm").font(.system(size: 22)).foregroundColor(gray),
                         at: CGPoint(x: 0.70 * w, y: 0.82 * hgt + 46))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension BugRig {
    /// Exposed for callers that need a deterministic per-bug hash.
    public static func hash01(_ x: Double) -> Double { h(x) }
}
