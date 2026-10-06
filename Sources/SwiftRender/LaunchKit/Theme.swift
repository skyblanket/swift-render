import AppKit
import SwiftRenderKit
import SwiftUI

// MARK: - LaunchKit
//
// Components for Apple-keynote-style product films. Every component is a View
// that is a pure function of a local time `t` (seconds since its clip started),
// reads its look from `\.launchTheme` and its canvas from `\.renderContext`, and
// is authored against 1920×1080 while restacking for 9:16.
//
// The grammar (enforced by defaults, not by choice): near-black stage, white type,
// exactly one accent; big tight-tracked display type; springs damped 0.6–0.85;
// slow camera pushes; hard cuts on downbeats. No shake, no flash frames, grain ≤ 0.04.

/// Colors and type for a launch film. Put one in the environment with `.launchTheme(_:)`.
public struct LaunchTheme: Sendable {
    public var background: Color
    public var surface: Color
    public var surfaceElevated: Color
    public var primary: Color
    public var secondary: Color
    public var tertiary: Color
    public var hairline: Color
    public var accent: Color
    /// Gradient partner for the accent (headline gradients, generated icons).
    public var accentSecondary: Color?
    public var typeface: LaunchProps.Typeface
    public var isDark: Bool

    public init(background: Color, surface: Color, surfaceElevated: Color, primary: Color, secondary: Color,
                tertiary: Color, hairline: Color, accent: Color, accentSecondary: Color? = nil,
                typeface: LaunchProps.Typeface = .sfPro, isDark: Bool = true) {
        self.background = background; self.surface = surface; self.surfaceElevated = surfaceElevated
        self.primary = primary; self.secondary = secondary; self.tertiary = tertiary; self.hairline = hairline
        self.accent = accent; self.accentSecondary = accentSecondary; self.typeface = typeface; self.isDark = isDark
    }

    public static let keynoteDark = LaunchTheme(
        background: Color(red: 0.012, green: 0.012, blue: 0.016),
        surface: Color(red: 0.078, green: 0.078, blue: 0.086),
        surfaceElevated: Color(red: 0.11, green: 0.11, blue: 0.118),
        primary: .white, secondary: .white.opacity(0.62), tertiary: .white.opacity(0.40),
        hairline: .white.opacity(0.10), accent: Color(red: 0.04, green: 0.52, blue: 1.0))

    public static let keynoteLight = LaunchTheme(
        background: Color(red: 0.961, green: 0.961, blue: 0.969),
        surface: .white,
        surfaceElevated: .white,
        primary: Color(red: 0.11, green: 0.11, blue: 0.118), secondary: .black.opacity(0.56),
        tertiary: .black.opacity(0.38), hairline: .black.opacity(0.08),
        accent: Color(red: 0.0, green: 0.44, blue: 0.89), isDark: false)

    /// Theme from props: appearance, accent (contrast-corrected), typeface.
    public init(props: LaunchProps) {
        self = props.appearance == .light ? .keynoteLight : .keynoteDark
        let accentHex = LaunchColor.readable(props.accent, onDark: isDark)
        accent = Color(rgbHex: accentHex) ?? accent
        accentSecondary = props.accentSecondary.flatMap { Color(rgbHex: $0) }
        typeface = props.typeface
    }

    /// Display face (headlines, numbers).
    public func display(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        switch typeface {
        case .sfPro: return .system(size: size, weight: weight)
        case .sfRounded: return .system(size: size, weight: weight, design: .rounded)
        case .newYork: return .system(size: size, weight: weight, design: .serif)
        case .inter: return .custom("InterDisplay-\(Self.interWeight(weight))", size: size)
        }
    }

    /// Body face.
    public func text(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        switch typeface {
        case .sfPro: return .system(size: size, weight: weight)
        case .sfRounded: return .system(size: size, weight: weight, design: .rounded)
        case .newYork: return .system(size: size, weight: weight, design: .serif)
        case .inter: return .custom("Inter-\(Self.interWeight(weight))", size: size)
        }
    }

    /// SF Mono — eyebrows, code, URLs.
    public func mono(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Apple display tracking: −2.5% of the size at ≥ 96pt, −1.5% at ≥ 48, −0.6% at ≥ 28, else 0.
    public static func tracking(_ size: CGFloat) -> CGFloat {
        size >= 96 ? -size * 0.025 : size >= 48 ? -size * 0.015 : size >= 28 ? -size * 0.006 : 0
    }

    /// The display face as an NSFont, for measuring (`displayWidth`).
    public func displayNSFont(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> NSFont {
        let w: NSFont.Weight
        switch weight {
        case .ultraLight: w = .ultraLight
        case .thin: w = .thin
        case .light: w = .light
        case .regular: w = .regular
        case .medium: w = .medium
        case .bold: w = .bold
        case .heavy: w = .heavy
        case .black: w = .black
        default: w = .semibold
        }
        let system = NSFont.systemFont(ofSize: size, weight: w)
        switch typeface {
        case .sfPro: return system
        case .sfRounded: return system.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? system
        case .newYork: return system.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? system
        case .inter: return NSFont(name: "InterDisplay-\(Self.interWeight(weight))", size: size) ?? system
        }
    }

    /// Width of `text` set in the display face at `size` with display tracking (CoreText,
    /// deterministic — so a layout that depends on it stays a pure function of its inputs).
    public func displayWidth(_ text: String, size: CGFloat, weight: Font.Weight = .semibold) -> CGFloat {
        let attr = NSAttributedString(string: text, attributes: [.font: displayNSFont(size, weight),
                                                                  .kern: Self.tracking(size)])
        return CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attr), nil, nil, nil))
    }

    /// One size for a block of display lines: the largest ≤ `size` (and ≥ `size × minimumScale`)
    /// at which the widest line fits `width`. Every line of a headline is set at this size, so a
    /// long punchline never ends up smaller than its setup line.
    public func fittedDisplaySize(_ lines: [String], size: CGFloat, width: CGFloat, minimumScale: CGFloat = 0.45) -> CGFloat {
        guard width > 0, !lines.isEmpty else { return size }
        func widest(_ s: CGFloat) -> CGFloat { lines.map { displayWidth($0, size: s) }.max() ?? 0 }
        let target = width * 0.98   // SwiftUI sets a hair wider than CoreText measures
        var s = size
        // Tracking steps with the size, so refine once at the scaled size.
        for _ in 0..<3 {
            let w = widest(s)
            guard w > target else { break }
            s *= target / w
        }
        return max(size * minimumScale, min(size, s))
    }

    private static func interWeight(_ w: Font.Weight) -> String {
        switch w {
        case .bold, .heavy, .black: return "Bold"
        case .semibold: return "SemiBold"
        case .medium: return "Medium"
        default: return "Regular"
        }
    }
}

private struct LaunchThemeKey: EnvironmentKey {
    static let defaultValue = LaunchTheme.keynoteDark
}

public extension EnvironmentValues {
    var launchTheme: LaunchTheme {
        get { self[LaunchThemeKey.self] }
        set { self[LaunchThemeKey.self] = newValue }
    }
}

public extension View {
    /// Sets the LaunchKit theme (and the matching color scheme) for this subtree.
    func launchTheme(_ theme: LaunchTheme) -> some View {
        environment(\.launchTheme, theme).environment(\.colorScheme, theme.isDark ? .dark : .light)
    }
}

public extension View {
    /// The LaunchKit finish: grain 0.035 and a soft vignette (the house PostFX pass is
    /// heavier). Pair with `ownsPostFX = true` on the scene.
    func launchPostFX(at t: Double, dark: Bool = true) -> some View {
        modifier(PostFX(time: t, grainAmount: 0.035, vignetteAmount: dark ? 0.25 : 0.1))
    }
}

// MARK: - Layout

/// Canvas-aware sizes. Components are authored at 1920×1080; on a vertical
/// canvas `type` keeps headlines large relative to the narrow width. A square
/// (or near-square) canvas stacks like a vertical one, at a type scale between the two.
public struct LaunchLayout: Sendable {
    public let size: CGSize
    public let isVertical: Bool
    /// Square or near-square (landscape narrower than 1.3:1): not wide enough for side-by-side shots.
    public let isSquare: Bool
    /// Multiply authored point sizes by this.
    public let type: CGFloat
    /// Side margin.
    public let margin: CGFloat

    public init(_ ctx: RenderContext) {
        size = ctx.size
        isVertical = ctx.isVertical
        isSquare = !ctx.isVertical && ctx.width < ctx.height * 1.3
        type = ctx.isVertical ? ctx.width / 1920 * 1.75 : isSquare ? ctx.width / 1920 * 1.35 : ctx.referenceScale
        margin = ctx.isVertical ? ctx.width * 0.08 : ctx.width * 0.07
    }

    /// Lay shots out in a column (caption above the subject, cards stacked): 9:16 and 1:1.
    public var stacks: Bool { isVertical || isSquare }

    /// Usable content width.
    public var width: CGFloat { size.width - margin * 2 }
}

// MARK: - Motion

/// Closed-form motion primitives. All pure functions of time.
public enum Motion {
    /// Analytic spring from `from` to `to` starting at `start`. Damping is kept in
    /// the Apple range (0.6…0.85 unless you pass more).
    public static func pop(_ t: Double, _ start: Double, from: Double = 0, to: Double = 1,
                           response: Double = 0.42, damping: Double = 0.78) -> Double {
        t < start ? from : Ease.spring(t - start, from: from, to: to, response: response,
                                       dampingFraction: max(0.6, damping))
    }

    /// Eased-out 0→1 over `duration` from `start`.
    public static func rise(_ t: Double, _ start: Double, _ duration: Double = 0.5) -> Double {
        Ease.easeOut(Ease.clip(t, start, start + duration))
    }

    /// Prefix of `s` typed at `cps` characters per second from `start`.
    public static func typed(_ s: String, _ t: Double, start: Double, cps: Double = 40) -> String {
        String(s.prefix(max(0, Int((t - start) * cps))))
    }

    /// 1 on every beat, decaying exponentially until the next.
    public static func beatPulse(_ t: Double, beat: Double, decay: Double = 5) -> Double {
        guard beat > 0, t >= 0 else { return 0 }
        return exp(-t.truncatingRemainder(dividingBy: beat) * decay)
    }

    /// Slow camera push: scale (1 − amount) → 1 across the shot, decelerating.
    public static func push(_ t: Double, over duration: Double, amount: Double = 0.05) -> CGFloat {
        let p = Ease.clip(t, 0, max(0.01, duration))
        return CGFloat(1 - amount + amount * (1 - pow(1 - p, 1.6)))
    }

    /// Deterministic 0…1 hash of an integer.
    public static func hash(_ n: Int) -> Double {
        let x = sin(Double(n) * 12.9898 + 78.233) * 43758.5453
        return x - floor(x)
    }
}

public extension View {
    /// Opacity, upward rise and focus-in from one progress value (0 hidden → 1 settled).
    /// Values past 1 from a spring overshoot keep moving but never over-brighten.
    func reveal(_ p: Double, rise: CGFloat = 26, blur: CGFloat = 0) -> some View {
        let q = max(0, p)
        return self
            .opacity(min(1, q))
            .offset(y: (1 - CGFloat(q)) * rise)
            .blur(radius: blur * CGFloat(max(0, 1 - q)))
    }

    /// One diagonal highlight pass across the view's opaque pixels — the "light
    /// catches the glass" moment. Pure SwiftUI (no shader).
    func specularSweep(at t: Double, start: Double, duration: Double = 0.75,
                       angle: Angle = .degrees(22), width: CGFloat = 0.28, intensity: Double = 0.6) -> some View {
        let p = Ease.easeInOut(Ease.clip(t, start, start + duration))
        let live = t > start && t < start + duration
        return overlay(
            GeometryReader { g in
                let w = g.size.width, h = g.size.height
                LinearGradient(stops: [.init(color: .white.opacity(0), location: 0),
                                       .init(color: .white.opacity(intensity), location: 0.5),
                                       .init(color: .white.opacity(0), location: 1)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: w * width, height: h * 2.2)
                    .rotationEffect(angle)
                    .position(x: -w * width + (w * (1 + 2 * width)) * p, y: h / 2)
            }
            .mask(self)
            .blendMode(.plusLighter)
            .opacity(live ? 1 : 0)
            .allowsHitTesting(false)
        )
    }
}

// MARK: - Transitions

extension Transition {
    /// Blur-dissolve: the outgoing shot defocuses as the incoming one comes into focus.
    /// The one dissolve a launch film gets (into the end card).
    public static func focusPull(_ d: Double = 0.4, blur: CGFloat = 12) -> Transition {
        Transition("focusPull", duration: d) { v, p, phase in
            let e = Ease.easeInOut(p)
            let k = phase == .in ? 1 - e : e
            return AnyView(v.blur(radius: blur * CGFloat(k)).opacity(phase == .in ? e : 1 - e))
        }
    }

    /// The outgoing shot pushes past camera (scale up + fade) while the next settles in.
    public static func zoomThrough(_ d: Double = 0.5, scale: CGFloat = 1.3, anchor: UnitPoint = .center) -> Transition {
        Transition("zoomThrough", duration: d) { v, p, phase in
            let e = Ease.easeIn(p)
            if phase == .out {
                return AnyView(v.scaleEffect(1 + (scale - 1) * CGFloat(e), anchor: anchor).opacity(1 - e))
            }
            let i = Ease.easeOut(p)
            return AnyView(v.scaleEffect(0.96 + 0.04 * CGFloat(i)).opacity(i))
        }
    }
}

// MARK: - Assets

/// Image and symbol helpers for props-driven films.
public enum LaunchAssets {
    /// An image file (absolute, or relative to cwd / assets / `AssetPaths.extraSearchPaths`), nil if missing.
    public static func image(_ path: String?) -> Image? {
        guard let path, !path.isEmpty, let cg = MediaLibrary.image(path) else { return nil }
        return Image(decorative: cg, scale: 1)
    }

    /// `name` if it is a real SF Symbol on this system, else `fallback`.
    public static func symbol(_ name: String, fallback: String = "sparkle") -> String {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil ? name : fallback
    }

    /// Black or white, whichever reads better on `color`.
    public static func onColor(_ hex: String) -> Color {
        LaunchColor.luminance(hex) > 0.4 ? Color.black.opacity(0.88) : .white
    }
}
