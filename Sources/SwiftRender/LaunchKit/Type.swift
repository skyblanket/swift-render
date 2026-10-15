import SwiftRenderKit
import SwiftUI

// MARK: - Stage

/// The background: near-black (or light) ground with one soft accent glow.
/// Place it outside the Timeline so the light carries across hard cuts.
public struct Stage: View {
    var glow: Double
    var center: UnitPoint
    var t: Double
    var breathe: Bool
    @Environment(\.launchTheme) private var theme
    @Environment(\.renderContext) private var ctx

    /// `glow` is the accent glow's opacity; `breathe` makes it pulse slowly with `t`.
    public init(glow: Double = 0.12, center: UnitPoint = .top, at t: Double = 0, breathe: Bool = true) {
        self.glow = glow; self.center = center; self.t = t; self.breathe = breathe
    }

    /// The ground color with the accent glow and a faint center lift.
    public var body: some View {
        let b = breathe ? 0.88 + 0.12 * sin(t * 0.9) : 1
        let r = max(ctx.width, ctx.height) * 0.75
        ZStack {
            theme.background
            RadialGradient(colors: [theme.accent.opacity(glow * b), theme.accent.opacity(0)],
                           center: center, startRadius: 0, endRadius: r)
            RadialGradient(colors: [theme.primary.opacity(theme.isDark ? 0.035 : 0), .clear],
                           center: .center, startRadius: 0, endRadius: r * 0.9)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Eyebrow

/// Small mono caps label above a headline ("INTRODUCING", "WHAT'S NEW").
public struct Eyebrow: View {
    var text: String
    var t: Double
    var start: Double
    var accent: Bool
    @Environment(\.launchTheme) private var theme
    @Environment(\.renderContext) private var ctx

    /// `accent` colors the label with the theme accent instead of tertiary.
    public init(_ text: String, at t: Double, start: Double = 0, accent: Bool = false) {
        self.text = text; self.t = t; self.start = start; self.accent = accent
    }

    /// The uppercased label, rising in at `start`.
    public var body: some View {
        let L = LaunchLayout(ctx)
        Text(text.uppercased())
            .font(theme.mono(20 * L.type, .semibold))
            .tracking(5 * L.type)
            .foregroundStyle(accent ? theme.accent : theme.tertiary)
            .lineLimit(1)
            .reveal(Motion.rise(t, start, 0.45), rise: 10)
    }
}

// MARK: - KeynoteTitle

/// The keynote caption block: optional eyebrow, one to three display lines (one of
/// them in the accent), and a secondary sub line. Lines rise in 0.14 s apart, the first
/// one from `start` itself — pass `start: 0` and the headline is moving on the cut frame.
/// All lines share one size: when the widest is too wide for `maxWidth`, the whole block
/// scales down together.
public struct KeynoteTitle: View {
    /// How the lines come in.
    public enum Reveal: Sendable {
        /// Each line rises 28pt and fades in over 0.5 s.
        case rise
        /// Letters focus in one after another.
        case letters(stagger: Double = 0.04)
        /// Words rise one after another.
        case words(stagger: Double = 0.12)
    }

    var lines: [String]
    var eyebrow: String?
    var sub: String?
    var t: Double
    var start: Double
    var size: CGFloat
    var alignment: HorizontalAlignment
    var reveal: Reveal
    var accentLine: Int?
    var gradient: Bool
    var maxWidth: CGFloat?
    @Environment(\.launchTheme) private var theme
    @Environment(\.renderContext) private var ctx

    /// `accentLine` is the index of the line drawn in the accent (nil for none); `gradient` uses the accent gradient for it when the theme has `accentSecondary`.
    public init(_ lines: [String], eyebrow: String? = nil, sub: String? = nil, at t: Double,
                start: Double = 0.1, size: CGFloat = 120, alignment: HorizontalAlignment = .center,
                reveal: Reveal = .rise, accentLine: Int? = 1, gradient: Bool = false, maxWidth: CGFloat? = nil) {
        self.lines = lines; self.eyebrow = eyebrow; self.sub = sub; self.t = t; self.start = start
        self.size = size; self.alignment = alignment; self.reveal = reveal; self.accentLine = accentLine
        self.gradient = gradient; self.maxWidth = maxWidth
    }

    /// When line `i` starts revealing.
    public static func lineStart(_ i: Int, start: Double) -> Double { start + 0.14 * Double(i) }

    /// Eyebrow, display lines and sub line, revealed from `start`.
    public var body: some View {
        let L = LaunchLayout(ctx)
        let width = maxWidth ?? L.width
        // One size for every line (a per-line fit would shrink a long accent line below its setup line).
        let s = theme.fittedDisplaySize(measured, size: size * L.type, width: width)
        let textAlign: TextAlignment = alignment == .leading ? .leading : alignment == .trailing ? .trailing : .center
        let frameAlign: Alignment = alignment == .leading ? .leading : alignment == .trailing ? .trailing : .center
        VStack(alignment: alignment, spacing: 0) {
            if let eyebrow {
                Eyebrow(eyebrow, at: t, start: start).padding(.bottom, 26 * L.type)
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                lineView(line, i, s)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)   // safety net only; `s` already fits
                    .frame(maxWidth: width, alignment: frameAlign)
            }
            if let sub {
                let subStart = Self.lineStart(lines.count, start: start) + 0.25
                let fullSize = size * L.type
                Text(sub)
                    .font(theme.text(max(26, fullSize * 0.27)))
                    .foregroundStyle(theme.secondary)
                    .multilineTextAlignment(textAlign)
                    .lineSpacing(6 * L.type)
                    .lineLimit(3)
                    .frame(maxWidth: min(width, 1100 * L.type), alignment: frameAlign)
                    .padding(.top, max(20, fullSize * 0.26))
                    .reveal(Motion.rise(t, subStart, 0.6), rise: 14)
            }
        }
    }

    /// The strings as they are set (the word reveal adds a trailing space per word).
    private var measured: [String] {
        if case .words = reveal { return lines.map { $0.split(separator: " ").map { $0 + " " }.joined() } }
        return lines
    }

    @ViewBuilder
    private func lineView(_ line: String, _ i: Int, _ s: CGFloat) -> some View {
        let isAccent = i == accentLine
        let lineStart = Self.lineStart(i, start: start)
        let base = Text(line).font(theme.display(s)).tracking(LaunchTheme.tracking(s))
        switch reveal {
        case .rise:
            styled(base, isAccent)
                .reveal(Motion.rise(t, lineStart, 0.5), rise: 28 * s / 120)
        case .letters(let stagger):
            let chars = Array(line)
            let lastIn = lineStart + Double(max(0, chars.count - 1)) * stagger + 0.35
            let focus = 1 - Ease.easeOut(Ease.clip(t, lineStart, lastIn))
            staggered(chars.map(String.init), lineStart, stagger, s, isAccent ? theme.accent : theme.primary)
                .blur(radius: 6 * focus * s / 120)
        case .words(let stagger):
            let words = line.split(separator: " ").map { String($0) + " " }
            staggered(words, lineStart, stagger, s, isAccent ? theme.accent : theme.primary)
        }
    }

    /// One Text whose pieces fade in in sequence (keeps kerning and scale-to-fit).
    private func staggered(_ pieces: [String], _ start: Double, _ stagger: Double, _ s: CGFloat, _ color: Color) -> Text {
        var out = Text("")
        for (k, piece) in pieces.enumerated() {
            let p = Ease.easeOut(Ease.clip(t, start + Double(k) * stagger, start + Double(k) * stagger + 0.35))
            out = out + Text(piece).foregroundColor(color.opacity(p)).baselineOffset(-(1 - p) * 0.18 * s)
        }
        return out.font(theme.display(s)).tracking(LaunchTheme.tracking(s))
    }

    @ViewBuilder
    private func styled<V: View>(_ v: V, _ isAccent: Bool) -> some View {
        if isAccent && gradient, let second = theme.accentSecondary {
            v.foregroundStyle(LinearGradient(colors: [theme.accent, second], startPoint: .leading, endPoint: .trailing))
        } else {
            v.foregroundStyle(isAccent ? theme.accent : theme.primary)
        }
    }
}
