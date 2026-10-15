import SwiftRenderKit
import SwiftUI

// MARK: - StatCounter

/// One big number counting up (exponential ease, so it settles rather than stops),
/// with a label underneath.
public struct StatCounter: View {
    var stat: LaunchProps.Stat
    var t: Double
    var start: Double
    var duration: Double
    var size: CGFloat
    var accent: Bool
    @Environment(\.launchTheme) private var theme
    @Environment(\.renderContext) private var ctx

    /// Counts from `start` for `duration` seconds; `accent` colors the number with the theme accent.
    public init(_ stat: LaunchProps.Stat, at t: Double, start: Double = 0.1, duration: Double = 1.1,
                size: CGFloat = 190, accent: Bool = false) {
        self.stat = stat; self.t = t; self.start = start; self.duration = duration; self.size = size; self.accent = accent
    }

    /// When the count settles on its value (the score blips here).
    public static func landTime(start: Double, duration: Double) -> Double { start + duration }

    /// `value` printed in `format` (with the stat's prefix/suffix).
    public static func format(_ value: Double, _ stat: LaunchProps.Stat) -> String {
        let body: String
        switch stat.format {
        case .integer:
            let f = NumberFormatter(); f.numberStyle = .decimal; f.maximumFractionDigits = 0
            f.locale = Locale(identifier: "en_US")
            body = f.string(from: NSNumber(value: value.rounded())) ?? "\(Int(value))"
        case .compact:
            let a = abs(value)
            if a >= 1_000_000 { body = String(format: a >= 10_000_000 ? "%.0fM" : "%.1fM", value / 1_000_000) }
            else if a >= 1_000 { body = String(format: a >= 10_000 ? "%.0fk" : "%.1fk", value / 1_000) }
            else { body = "\(Int(value.rounded()))" }
        case .percent: body = "\(Int(value.rounded()))%"
        case .multiplier: body = value < 10 && value != value.rounded() ? String(format: "%.1f×", value) : "\(Int(value.rounded()))×"
        }
        return (stat.prefix ?? "") + body.replacingOccurrences(of: ".0k", with: "k").replacingOccurrences(of: ".0M", with: "M") + (stat.suffix ?? "")
    }

    /// The number (scaled to fit) over its label, rising in just before the count starts.
    public var body: some View {
        let L = LaunchLayout(ctx)
        let s = size * L.type
        let p = Ease.expo(Ease.clip(t, start, start + duration))
        let appear = Motion.rise(t, start - 0.1, 0.45)
        // Count in whole steps so integers never show fractions mid-count.
        let v = stat.format == .multiplier ? stat.value * p : (stat.value * p).rounded(.down)
        VStack(spacing: 6 * L.type) {
            Text(Self.format(p >= 1 ? stat.value : v, stat))
                .font(theme.display(s, .semibold)).monospacedDigit()
                .tracking(LaunchTheme.tracking(s))
                .foregroundStyle(accent ? theme.accent : theme.primary)
                .lineLimit(1).minimumScaleFactor(0.5)
            Text(stat.label)
                .font(theme.text(30 * L.type, .medium))
                .foregroundStyle(theme.secondary)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .reveal(appear, rise: 20)
    }
}

/// Up to three stats side by side (stacked at 9:16), landing one per beat.
public struct StatRow: View {
    var stats: [LaunchProps.Stat]
    var t: Double
    var start: Double
    var stagger: Double
    @Environment(\.renderContext) private var ctx

    /// Shows the first three stats; each starts counting `stagger` seconds after the previous.
    public init(_ stats: [LaunchProps.Stat], at t: Double, start: Double = 0.1, stagger: Double = 0.6) {
        self.stats = Array(stats.prefix(3)); self.t = t; self.start = start; self.stagger = stagger
    }

    /// When each of the (at most three) counts settles.
    public static func landTimes(count: Int, start: Double, stagger: Double, duration: Double = 1.1) -> [Double] {
        (0..<min(3, count)).map { StatCounter.landTime(start: start + Double($0) * stagger, duration: duration) }
    }

    /// The counters in a row, or a column on stacked canvases; the first is in the accent.
    public var body: some View {
        let L = LaunchLayout(ctx)
        let size: CGFloat = stats.count == 1 ? 260 : stats.count == 2 ? 210 : 180
        // Side by side, the labels share a baseline even when one number scales down to fit its column.
        let layout = L.stacks
            ? AnyLayout(VStackLayout(spacing: 90 * L.type))
            : AnyLayout(HStackLayout(alignment: .lastTextBaseline, spacing: 0))
        layout {
            ForEach(Array(stats.enumerated()), id: \.offset) { i, s in
                StatCounter(s, at: t, start: start + Double(i) * stagger, size: size, accent: i == 0)
                    .frame(width: L.stacks ? L.width : L.width / CGFloat(max(1, stats.count)))
            }
        }
    }
}

// MARK: - ChangelogList

/// "What's new in 1.2" with up to five rows sliding in on the beat.
public struct ChangelogList: View {
    var version: String
    var items: [LaunchProps.ChangelogItem]
    var t: Double
    var start: Double
    var stagger: Double
    var headline: String?
    @Environment(\.launchTheme) private var theme
    @Environment(\.renderContext) private var ctx

    /// Shows up to `maxItems` rows; `headline` replaces "What's new in <version>.".
    public init(version: String, items: [LaunchProps.ChangelogItem], at t: Double, start: Double = 0.25,
                stagger: Double = 0.3, maxItems: Int = 5, headline: String? = nil) {
        self.version = version; self.items = Array(items.prefix(maxItems)); self.t = t
        self.start = start; self.stagger = stagger; self.headline = headline
    }

    /// When each row lands (0.55 s after `start`, then every `stagger`).
    public static func rowTimes(count: Int, start: Double, stagger: Double) -> [Double] {
        (0..<count).map { start + 0.55 + Double($0) * stagger }
    }

    static func symbol(_ k: LaunchProps.ChangelogItem.Kind) -> String {
        switch k {
        case .added: return "plus.circle.fill"
        case .performance: return "bolt.circle.fill"
        case .fixed: return "hammer.circle.fill"
        case .changed: return "arrow.triangle.2.circlepath.circle.fill"
        case .removed: return "minus.circle.fill"
        case .security: return "lock.circle.fill"
        case .deprecated: return "exclamationmark.circle.fill"
        }
    }

    /// The headline, then one row per item: kind symbol, title and kind label.
    public var body: some View {
        let L = LaunchLayout(ctx)
        let u = L.type
        let rows = Self.rowTimes(count: items.count, start: start, stagger: stagger)
        let w = min(L.width, 1300 * u)
        VStack(alignment: .leading, spacing: 0) {
            KeynoteTitle(headline.map { [$0] } ?? ["What's new", "in \(version)."], eyebrow: "Release notes",
                         at: t, start: max(0, start - 0.25), size: 92, alignment: .leading, accentLine: 1, maxWidth: w)
                .padding(.bottom, 44 * u)
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                let p = Motion.pop(t, rows[i] - 0.08, response: 0.42, damping: 0.8)
                HStack(spacing: 26 * u) {
                    Image(systemName: Self.symbol(item.kind))
                        .font(.system(size: 34 * u, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(theme.accent)
                        .frame(width: 44 * u)
                    Text(item.title)
                        .font(theme.text(34 * u, .medium)).foregroundStyle(theme.primary)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Spacer(minLength: 0)
                    Text(item.kind.rawValue.uppercased())
                        .font(theme.mono(15 * u, .semibold)).tracking(2.5 * u)
                        .foregroundStyle(theme.tertiary)
                }
                .padding(.vertical, 20 * u)
                .overlay(alignment: .top) { Rectangle().fill(theme.hairline).frame(height: 1) }
                .opacity(min(1, max(0, p * 1.4)))
                .offset(x: (1 - CGFloat(p)) * 70 * u)
            }
        }
        .frame(width: w, alignment: .leading)
    }
}

// MARK: - PlatformBadges

/// One claim as a headline ("Zero dependencies."), platform symbols with minimum
/// versions, and a line of smaller facts underneath.
public struct PlatformBadges: View {
    var platforms: [LaunchProps.Platform]
    var facts: [String]
    var headline: String?
    var t: Double
    var start: Double
    @Environment(\.launchTheme) private var theme
    @Environment(\.renderContext) private var ctx

    /// `swift`, when given, is listed first among the facts as "Swift <version>".
    public init(_ platforms: [LaunchProps.Platform], swift: String? = nil, facts: [String] = [],
                headline: String? = nil, at t: Double, start: Double = 0.1) {
        self.platforms = platforms
        self.facts = (swift.map { ["Swift \($0)"] } ?? []) + facts
        self.headline = headline
        self.t = t; self.start = start
    }

    static func symbol(_ p: LaunchProps.Platform.Name) -> String {
        switch p {
        case .iOS: return "iphone"
        case .macOS: return "laptopcomputer"
        case .watchOS: return "applewatch"
        case .tvOS: return "appletv"
        case .visionOS: return LaunchAssets.symbol("visionpro", fallback: "eyeglasses")
        case .macCatalyst: return "ipad.and.iphone"
        case .linux: return "server.rack"
        }
    }

    /// "iOS 17+", "macOS 14+".
    public static func label(_ p: LaunchProps.Platform) -> String {
        let name = p.name == .macCatalyst ? "Mac Catalyst" : p.name == .linux ? "Linux" : p.name.rawValue
        return p.minimum.map { "\(name) \($0)+" } ?? name
    }

    /// Headline, up to five platform badges (three when vertical) and the facts line.
    public var body: some View {
        let L = LaunchLayout(ctx)
        let u = L.type
        let shown = Array(platforms.prefix(L.isVertical ? 3 : 5))
        let badgesAt = start + (headline == nil ? 0 : 0.45)
        VStack(spacing: 64 * u) {
            if let headline {
                KeynoteTitle([headline], at: t, start: max(0, start - 0.1), size: 112, accentLine: nil)
            }
            if !shown.isEmpty {
                HStack(alignment: .bottom, spacing: (L.isVertical ? 70 : 100) * u) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { i, p in
                        let a = Motion.pop(t, badgesAt + 0.15 * Double(i), response: 0.45, damping: 0.8)
                        VStack(spacing: 20 * u) {
                            Image(systemName: Self.symbol(p.name))
                                .font(.system(size: 64 * u, weight: .regular))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(theme.accent)
                                .frame(height: 80 * u)
                            Text(Self.label(p)).font(theme.text(28 * u, .medium)).foregroundStyle(theme.primary)
                        }
                        .reveal(a, rise: 30)
                    }
                }
            }
            if !facts.isEmpty {
                Text(facts.joined(separator: "  ·  "))
                    .font(theme.text(28 * u, .regular))
                    .foregroundStyle(theme.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2).minimumScaleFactor(0.6)
                    .frame(maxWidth: L.width)
                    .reveal(Motion.rise(t, badgesAt + 0.15 * Double(shown.count) + 0.2, 0.5), rise: 16)
            }
        }
    }
}

// MARK: - EndCard

/// The closing lockup: icon, name, "Available now.", a call to action, the URL and a footnote.
public struct EndCard: View {
    var name: String
    var icon: Image?
    var iconShape: LaunchProps.IconShape
    var headline: String
    var cta: LaunchProps.CTA
    var url: String?
    var footnote: String?
    var t: Double
    @Environment(\.launchTheme) private var theme
    @Environment(\.renderContext) private var ctx

    /// `headline` sits under the name; `cta` picks the chip or button shown below it.
    public init(name: String, icon: Image?, iconShape: LaunchProps.IconShape = .iOS, headline: String = "Available now.",
                cta: LaunchProps.CTA, url: String? = nil, footnote: String? = nil, at t: Double) {
        self.name = name; self.icon = icon; self.iconShape = iconShape; self.headline = headline
        self.cta = cta; self.url = url; self.footnote = footnote; self.t = t
    }

    /// Icon, name, headline, call to action, URL and footnote, each rising in turn.
    public var body: some View {
        let L = LaunchLayout(ctx)
        let u = L.type
        let iconP = Motion.pop(t, 0.05, from: 0.7, to: 1, response: 0.55, damping: 0.8)
        VStack(spacing: 0) {
            LaunchIcon(icon, size: 168 * u, shape: iconShape, monogram: name)
                .shadow(color: .black.opacity(theme.isDark ? 0.7 : 0.2), radius: 30 * u, y: 16 * u)
                .scaleEffect(CGFloat(iconP))
                .opacity(Motion.rise(t, 0, 0.35))
            Text(name)
                .font(theme.display(124 * u)).tracking(LaunchTheme.tracking(124 * u))
                .foregroundStyle(theme.primary)
                .lineLimit(1).minimumScaleFactor(0.5)
                .frame(maxWidth: L.width)
                .padding(.top, 34 * u)
                .reveal(Motion.rise(t, 0.2, 0.55), rise: 24, blur: 6)
            Text(headline)
                .font(theme.display(48 * u, .medium)).tracking(LaunchTheme.tracking(48 * u))
                .foregroundStyle(theme.secondary)
                .padding(.top, 6 * u)
                .reveal(Motion.rise(t, 0.6, 0.5), rise: 16)
            ctaView(u)
                .padding(.top, 52 * u)
                .reveal(Motion.rise(t, 1.2, 0.5), rise: 16)
            if let url {
                Text(Self.displayURL(url))
                    .font(theme.mono(30 * u, .semibold)).foregroundStyle(theme.accent)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .padding(.top, 40 * u)
                    .reveal(Motion.rise(t, 1.8, 0.5), rise: 12)
            }
            if let footnote {
                Text(footnote)
                    .font(theme.mono(18 * u, .medium)).tracking(1.5 * u)
                    .foregroundStyle(theme.tertiary)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .frame(maxWidth: L.width)
                    .padding(.top, 20 * u)
                    .reveal(Motion.rise(t, 2.3, 0.5), rise: 10)
            }
        }
    }

    /// "https://github.com/a/b" → "github.com/a/b"
    public static func displayURL(_ url: String) -> String {
        var s = url
        for p in ["https://", "http://", "www."] where s.hasPrefix(p) { s.removeFirst(p.count) }
        return s.hasSuffix("/") ? String(s.dropLast()) : s
    }

    @ViewBuilder private func ctaView(_ u: CGFloat) -> some View {
        switch cta.kind {
        case .swiftPackage:
            let line = ".package(url: \"\(cta.value ?? url ?? "")\", from: \"\(cta.from ?? "1.0.0")\")"
            chip(code: line, u)
        case .brew:
            chip(code: "brew install \(cta.value ?? name.lowercased())", u, shell: true)
        case .availableNow:
            EmptyView()
        default:
            capsule(title: cta.title ?? defaultTitle, symbol: cta.symbol ?? defaultSymbol, u)
        }
    }

    private var defaultTitle: String {
        switch cta.kind {
        case .downloadForMac: return "Download for Mac"
        case .appStore: return "Available on the App Store"
        case .github: return "Star on GitHub"
        default: return "Learn more"
        }
    }

    private var defaultSymbol: String {
        switch cta.kind {
        case .downloadForMac: return "arrow.down.circle.fill"
        case .appStore: return "arrow.down.app.fill"
        case .github: return "star.fill"
        default: return "arrow.right.circle.fill"
        }
    }

    private func capsule(title: String, symbol: String, _ u: CGFloat) -> some View {
        HStack(spacing: 14 * u) {
            Image(systemName: LaunchAssets.symbol(symbol, fallback: "arrow.right.circle.fill"))
                .font(.system(size: 28 * u, weight: .semibold))
            Text(title).font(theme.text(30 * u, .semibold))
        }
        .foregroundStyle(theme.isDark ? Color.black.opacity(0.88) : .white)
        .padding(.horizontal, 40 * u).frame(height: 80 * u)
        .background(Capsule().fill(theme.isDark ? Color.white : Color.black.opacity(0.88)))
    }

    private func chip(code: String, _ u: CGFloat, shell: Bool = false) -> some View {
        let toks = shell ? [[SwiftHighlighter.Token(code, .plain)]] : SwiftHighlighter.tokenize(code)
        let pal = CodePalette.xcodeDark
        var text = shell ? Text("$ ").foregroundColor(theme.accent) : Text("")
        for tok in toks.first ?? [] { text = text + Text(tok.text).foregroundColor(pal.color(tok.kind)) }
        return text
            .font(.system(size: 27 * u, weight: .regular, design: .monospaced))
            .lineLimit(1).minimumScaleFactor(0.5)
            .padding(.horizontal, 34 * u).frame(height: 80 * u)
            .background(Capsule().fill(pal.background))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            .frame(maxWidth: LaunchLayout(ctx).width)
    }
}
