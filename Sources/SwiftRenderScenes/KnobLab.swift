import SwiftRender
import SwiftUI

public struct KnobLabStat: Codable, Sendable {
    public var label: String
    public var value: Double
    public var unit: String
    public init(label: String, value: Double, unit: String) { self.label = label; self.value = value; self.unit = unit }
}

public struct KnobLabProps: Codable, Sendable {
    public var title: String
    public var subtitle: String
    /// "#RRGGBB": the stat numbers and the rule.
    public var accent: String
    /// Playback speed of the whole piece; also sets its length.
    public var speed: Double
    public var showGrid: Bool
    public var stats: [KnobLabStat]
}

/// KnobLab — Studio's inspector dogfood: every knob kind plus a props payload.
///
/// Knobs tune the headline card (delay, scale, tracking, color, copy); props
/// drive the stats card and the length (`6 / speed` seconds). `debug.safe` is
/// a knob whose companion `debug.opacity` is only read while it's on, so the
/// probe can't see it until then: Studio lists it as "not reached yet".
///
///   swift run swift-render-studio . --scene KnobLab --tab knobs
///   swift run swift-render render KnobLab --props my-variant.json
public struct KnobLab: PropsScene {
    public static let defaultDuration: Double = 6
    public static var defaultProps: KnobLabProps {
        KnobLabProps(title: "Inspector", subtitle: "Knobs · Props · Info", accent: "#FFC75C", speed: 1,
                     showGrid: true,
                     stats: [KnobLabStat(label: "knob drag", value: 38, unit: "ms"),
                             KnobLabStat(label: "rebuilds", value: 0, unit: ""),
                             KnobLabStat(label: "hot reload", value: 2.2, unit: "s")])
    }

    public static func duration(for props: KnobLabProps) -> Double { 6 / min(4, max(0.25, props.speed)) }

    @MainActor public static func body(at t: Double, duration: Double, props: KnobLabProps) -> some View {
        let local = t * min(4, max(0.25, props.speed))
        let accent = Color(rgbHex: props.accent) ?? .orange
        return ZStack {
            Color(red: 0.03, green: 0.03, blue: 0.035).ignoresSafeArea()
            if props.showGrid { grid(local) }
            Timeline(local) {
                Clip(3.2) { l in headline(l) }.named("Headline")
                Clip(3.0) { l in stats(l, props: props, accent: accent) }
                    .transition(.fade(0.4))
                    .named("Stats")
            }
            if Knob.bool("debug.safe", false) {
                let o = Knob.double("debug.opacity", 0.5, in: 0...1)
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.red.opacity(o), style: StrokeStyle(lineWidth: 3, dash: [14, 10]))
                    .padding(96)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @MainActor static func grid(_ t: Double) -> some View {
        let a = 0.07 * Ease.easeOut(Ease.clip(t, 0, 0.8))
        return Canvas { ctx, size in
            var p = Path()
            stride(from: 0, through: size.width, by: 120).forEach { x in
                p.move(to: .init(x: x, y: 0)); p.addLine(to: .init(x: x, y: size.height))
            }
            stride(from: 0, through: size.height, by: 120).forEach { y in
                p.move(to: .init(x: 0, y: y)); p.addLine(to: .init(x: size.width, y: y))
            }
            ctx.stroke(p, with: .color(.white.opacity(a)), lineWidth: 1)
        }
    }

    @ViewBuilder @MainActor
    static func headline(_ t: Double) -> some View {
        let delay = Knob.double("title.delay", 0.3, in: 0...2)
        let scale = Knob.double("title.scale", 1.0, in: 0.5...2)
        let tracking = Knob.double("title.tracking", -2, in: -10...20)
        let color = Knob.color("title.color", "#FFFFFF")
        let copy = Knob.text("headline", "Tune it live.")
        let p = Ease.spring(max(0, t - delay), from: 0, to: 1, response: 0.55, dampingFraction: 0.8)
        let out = Ease.easeIn(Ease.clip(t, 2.7, 3.2))
        VStack(spacing: 18) {
            Text(copy)
                .font(.system(size: 150 * scale, weight: .bold))
                .tracking(tracking)
                .foregroundStyle(color)
            Text("no rebuild · no restart")
                .font(.system(size: 34, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
                .opacity(Ease.easeOut(Ease.clip(t, delay + 0.4, delay + 0.9)))
        }
        .opacity(p * (1 - out))
        .offset(y: CGFloat(1 - p) * 60)
        .blur(radius: CGFloat(out) * 12)
    }

    @ViewBuilder @MainActor
    static func stats(_ t: Double, props: KnobLabProps, accent: Color) -> some View {
        let rule = Ease.easeInOut(Ease.clip(t, 0.2, 0.9))
        VStack(alignment: .leading, spacing: 40) {
            VStack(alignment: .leading, spacing: 10) {
                Text(props.title).font(.system(size: 96, weight: .bold)).foregroundStyle(.white)
                Text(props.subtitle).font(.system(size: 36, weight: .medium)).foregroundStyle(.white.opacity(0.55))
            }
            Rectangle().fill(accent).frame(width: 1100 * rule, height: 4)
            HStack(alignment: .firstTextBaseline, spacing: 90) {
                ForEach(Array(props.stats.prefix(4).enumerated()), id: \.offset) { i, s in
                    let k = stagger(t, i, step: 0.15, ramp: 0.5, start: 0.6)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(number(s.value * k) + s.unit)
                            .font(.system(size: 88, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(accent)
                        Text(s.label.uppercased())
                            .font(.system(size: 24, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .opacity(k)
                    .offset(y: CGFloat(1 - k) * 30)
                }
            }
        }
        .frame(width: 1400, alignment: .leading)
    }

    static func number(_ v: Double) -> String {
        v.rounded() == v || abs(v) >= 10 ? String(format: "%.0f", v) : String(format: "%.1f", v)
    }
}
