import SwiftUI
import SwiftRender

/// An Apple-style product shot in true 3D (SceneKit through `Scene3D`): a rounded titanium
/// slab whose screen is a live SwiftUI view, studio lighting, a slow turntable with a
/// camera dolly, shallow depth of field and a soft contact shadow on a shadow-catcher floor
/// that composites over a SwiftUI backdrop.
public struct Showcase3D: RenderScene {
    public static let defaultDuration: Double = 10.0

    static let beat: Double = 60.0 / 84.0
    static let titleAt: Double = 6.2

    @MainActor
    public static func body(at t: Double, duration: Double) -> some View {
        let accent = Knob.color("accent", "#FF8A3D")
        let fadeIn: Double = Ease.easeOut(Ease.clip(t, 0, 1.2))
        let fadeOut: Double = Ease.easeIn(Ease.clip(t, duration - 0.7, duration))
        return ZStack {
            Timeline(t) {
                Clip(at: 0, for: duration) { l in DeviceShot(t: l, accent: accent) }.named("Device")
                Clip(at: titleAt, for: duration - titleAt) { l in Title(t: l, accent: accent) }.named("Title")
            }
        }
        .opacity(fadeIn * (1 - fadeOut))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    public static func soundtrack(duration: Double) -> Score? {
        var ev: [ScoreEvent] = []
        let bar: Double = beat * 4
        let chords: [Chord] = [.major7(.d3), .add9(.b3.transposed(-12)), .major7(.g3), .sus4(.a3)]
        for (i, ch) in chords.enumerated() {
            ev += chordPad(ch, at: Double(i) * bar * 0.75, duration: bar + 0.6, amp: 0.016)
        }
        ev += melody([(0, Note.midi(78)), (1, .a5), (2, .e5), (4, .d5)], start: 1.4, bpm: 84, amp: 0.03, instrument: .bell)
        ev += arpeggio(Chord.major7(.g4), from: 3.6, to: titleAt - 0.2, step: beat / 2, amp: 0.012, instrument: .pluck)
        ev += swell(Chord.major7(.d4), into: titleAt, duration: 1.6, amp: 0.02)
        ev += thump(at: titleAt, amp: 0.16)
        ev += blip(.a5, at: titleAt + 0.55, amp: 0.035)
        ev += chordPad(.add9(.d3), at: titleAt, duration: duration - titleAt, amp: 0.018)
        return Score(duration: duration) { ev }
    }
}

// MARK: - The 3D shot

private struct DeviceShot: View {
    let t: Double
    let accent: Color

    var body: some View {
        let titleAt = Showcase3D.titleAt
        // A slow eased turn from three-quarter left to almost square-on, then a gentle drift.
        let turn: Double = -40 + 34 * Ease.easeInOut(Ease.clip(t, 0, titleAt)) + 3 * Ease.easeInOut(Ease.clip(t, titleAt, 10))
        let hover: Double = Motion3D.hover(t, amplitude: 0.0015, period: 7)
        let center: Vec3 = [0, 0.081, 0]
        // Aim a little below the device so the floor (and its shadow) stays in frame.
        let aim: Vec3 = center + [0, -0.016, 0]
        // Dolly in on the device, then settle into the end frame: product right, title left.
        let wide = Camera3D.orbit(target: aim, distance: 0.7, azimuth: -16, elevation: 17, fov: 24)
        let close = Camera3D.orbit(target: aim, distance: 0.5, azimuth: 4, elevation: 12, fov: 24)
        var end = Camera3D.orbit(target: aim, distance: 0.56, azimuth: 10, elevation: 12, fov: 24)
        end.target += [-0.066, 0, 0]
        end.position += [-0.066, 0, 0]
        let push = Camera3D.dolly(t, from: wide, to: close, start: 0, end: titleAt + 0.4)
        let cam = Camera3D.spring(t, from: push, to: end, start: titleAt - 0.3, response: 1.6, dampingFraction: 0.9)
            .focused(on: center + [0, hover, 0], fStop: 2.8)

        return Scene3D(camera: cam, environment: .studio(intensity: 1.1, rotation: 20),
                       background: .view { Backdrop() },
                       effects: Effects3D(exposure: 0.0)) {
            Slab3D(width: 0.0716, height: 0.1476, depth: 0.0078, cornerRadius: 0.0112,
                   screen: .screen(.view(width: 390, height: 844, scale: 2.4) { AppScreen(t: t, accent: accent) },
                                   brightness: 1.0, gloss: 0.7),
                   screenInset: 0.0026)
                .material(.metal(Color(red: 0.6, green: 0.58, blue: 0.55), roughness: 0.34))
                .rotation(x: -2, y: turn)
                .position(center + [0, hover, 0])
                .named("device")

            Floor3D(material: .shadowCatcher(opacity: 0.9))
            // Key from behind and above: rims the titanium edge and throws the shadow toward camera.
            Light3D.directional(intensity: 900, temperature: 5400, from: [-0.12, 1.0, -0.22], at: center,
                                shadow: Shadow3D(color: Color.black.opacity(0.85), softness: 16, samples: 32,
                                                 mapSize: 2048, extent: 0.25))
            Light3D.area(intensity: 250, temperature: 6800, width: 0.4, height: 0.4, from: [0.5, 0.3, 0.6], at: center)
        }
    }
}

private struct Backdrop: View {
    var body: some View {
        ZStack {
            Color(red: 0.03, green: 0.031, blue: 0.035)
            RadialGradient(colors: [Color(white: 0.2), Color(white: 0.07), .clear],
                           center: UnitPoint(x: 0.56, y: 0.4), startRadius: 0, endRadius: 900)
            // A soft pool of light on the studio floor, so the contact shadow has something to fall on.
            Ellipse()
                .fill(RadialGradient(colors: [Color(white: 0.26), Color(white: 0.12), .clear],
                                     center: .center, startRadius: 0, endRadius: 700))
                .frame(width: 1900, height: 420)
                .blur(radius: 40)
                .offset(x: 120, y: 360)
        }
    }
}

// MARK: - The screen (an ordinary SwiftUI view, pure in t)

private struct AppScreen: View {
    let t: Double
    let accent: Color

    var body: some View {
        let rings: [(Double, Color)] = [(0.82, accent), (0.64, Color(red: 0.55, green: 0.95, blue: 0.4)),
                                        (0.9, Color(red: 0.35, green: 0.8, blue: 1.0))]
        let fill = Ease.easeOut(Ease.clip(t, 1.0, 4.2))
        return ZStack {
            LinearGradient(colors: [Color(red: 0.07, green: 0.07, blue: 0.09), .black], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Text("9:41").font(.system(size: 17, weight: .semibold))
                    Spacer()
                    Capsule().fill(Color.white.opacity(0.9)).frame(width: 26, height: 12)
                }
                .padding(.top, 18)
                .padding(.horizontal, 10)
                Text("Today").font(.system(size: 40, weight: .bold)).tracking(-0.8).padding(.top, 34)
                ZStack {
                    ForEach(0..<3, id: \.self) { i in
                        let r = CGFloat(118 - i * 34)
                        Circle().stroke(rings[i].1.opacity(0.18), lineWidth: 26).frame(width: r * 2, height: r * 2)
                        Circle().trim(from: 0, to: CGFloat(rings[i].0 * fill))
                            .stroke(rings[i].1, style: StrokeStyle(lineWidth: 26, lineCap: .round))
                            .rotationEffect(.degrees(-90)).frame(width: r * 2, height: r * 2)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                statRow("Move", value: Int(520 * fill), unit: "kcal", color: rings[0].1)
                statRow("Exercise", value: Int(38 * fill), unit: "min", color: rings[1].1)
                statRow("Stand", value: Int(11 * fill), unit: "hrs", color: rings[2].1)
                Spacer()
            }
            .padding(.horizontal, 26)
            .foregroundStyle(.white)
        }
        .frame(width: 390, height: 844)
    }

    private func statRow(_ label: String, value: Int, unit: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.system(size: 19, weight: .medium)).foregroundStyle(.white.opacity(0.7))
            Spacer()
            Text("\(value)").font(.system(size: 30, weight: .bold)).foregroundStyle(color).monospacedDigit()
            Text(unit).font(.system(size: 17, weight: .semibold)).foregroundStyle(color.opacity(0.8))
        }
        .padding(.vertical, 12).padding(.horizontal, 18)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color.white.opacity(0.07)))
    }
}

// MARK: - Title

private struct Title: View {
    let t: Double
    let accent: Color
    @Environment(\.renderContext) private var ctx

    var body: some View {
        let k: CGFloat = ctx.referenceScale
        let p = Ease.easeOut(Ease.clip(t, 0.15, 1.1))
        let q = Ease.easeOut(Ease.clip(t, 0.0, 0.8))
        let r = Ease.easeOut(Ease.clip(t, 0.6, 1.5))
        return VStack(alignment: .leading, spacing: 14 * k) {
            Text("Scene3D").font(.system(size: 28 * k, weight: .semibold)).foregroundStyle(accent)
                .opacity(q)
            Text("Real 3D.\nPure Swift.")
                .font(.system(size: 96 * k, weight: .bold)).tracking(-3.2 * k).lineSpacing(-6 * k)
                .foregroundStyle(.white)
                .opacity(p)
                .offset(y: (1 - p) * 22 * k)
            Text("SceneKit, rendered frame by frame from t.")
                .font(.system(size: 26 * k, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                .opacity(r)
                .padding(.top, 6 * k)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.leading, 190 * k)
    }
}
