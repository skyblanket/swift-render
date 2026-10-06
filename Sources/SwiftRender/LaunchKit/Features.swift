import SwiftRenderKit
import SwiftUI

// MARK: - FeatureCard

/// One feature on a glass card: accent SF Symbol, display title, two-line detail.
public struct FeatureCard: View {
    var feature: LaunchProps.Feature
    var compact: Bool
    @Environment(\.launchTheme) private var theme
    @Environment(\.renderContext) private var ctx

    /// `compact` lays the card out as a row (symbol left) — used on vertical canvases.
    public init(_ feature: LaunchProps.Feature, compact: Bool = false) {
        self.feature = feature; self.compact = compact
    }

    public var body: some View {
        let L = LaunchLayout(ctx)
        let u = L.type
        GlassPanel(cornerRadius: 34 * u) {
            if compact {
                HStack(alignment: .center, spacing: 34 * u) {
                    symbol(64 * u).frame(width: 96 * u)
                    VStack(alignment: .leading, spacing: 10 * u) { title(40 * u); detail(26 * u) }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 40 * u).padding(.vertical, 34 * u)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    symbol(60 * u).frame(height: 76 * u, alignment: .leading)
                    Spacer(minLength: 24 * u)
                    title(44 * u)
                    // Reserve two detail lines so titles align across the row.
                    detail(27 * u).padding(.top, 12 * u).frame(height: 27 * u * 2.7 + 12 * u, alignment: .top)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(46 * u)
            }
        }
    }

    private func symbol(_ size: CGFloat) -> some View {
        Image(systemName: LaunchAssets.symbol(feature.symbol))
            .font(.system(size: size, weight: .medium))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(theme.accent)
    }

    private func title(_ size: CGFloat) -> some View {
        Text(feature.title)
            .font(theme.display(size, .semibold)).tracking(LaunchTheme.tracking(size))
            .foregroundStyle(theme.primary)
            .lineLimit(1).minimumScaleFactor(0.6)
    }

    private func detail(_ size: CGFloat) -> some View {
        Text(feature.detail)
            .font(theme.text(size)).foregroundStyle(theme.secondary)
            .lineSpacing(4)
            .lineLimit(compact ? 3 : 2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - FeatureTriad

/// Three feature cards (four when there are exactly four) landing one per beat —
/// a row at 16:9, a column at 9:16.
public struct FeatureTriad: View {
    var features: [LaunchProps.Feature]
    var t: Double
    var start: Double
    var stagger: Double
    @Environment(\.renderContext) private var ctx

    public init(_ features: [LaunchProps.Feature], at t: Double, start: Double = 0.2, stagger: Double = 0.6) {
        self.features = Array(features.prefix(Self.shown(features.count))); self.t = t; self.start = start; self.stagger = stagger
    }

    /// How many of `count` features the triad shows (the rest go to `FeatureList`).
    public static func shown(_ count: Int) -> Int { count == 4 ? 4 : min(3, count) }

    /// When each card's spring peaks (the score puts a rim here).
    public static func landTimes(count: Int, start: Double, stagger: Double) -> [Double] {
        (0..<shown(count)).map { start + Double($0) * stagger }
    }

    public var body: some View {
        let L = LaunchLayout(ctx)
        let lands = Self.landTimes(count: features.count, start: start, stagger: stagger)
        let n = max(1, features.count)
        let layout = L.isVertical
            ? AnyLayout(VStackLayout(spacing: 36 * L.type))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 36 * L.type))
        layout {
            ForEach(Array(features.enumerated()), id: \.offset) { i, f in
                // Start 0.1 s early so the spring's first peak lands on the beat.
                let p = Motion.pop(t, lands[i] - 0.1, response: 0.5, damping: 0.76)
                FeatureCard(f, compact: L.isVertical)
                    .frame(width: L.isVertical ? L.width : min(540 * L.type, (L.width - 36 * L.type * CGFloat(n - 1)) / CGFloat(n)),
                           height: L.isVertical ? (n > 3 ? 270 : 320) * L.type : 430 * L.type)
                    .scaleEffect(0.94 + 0.06 * CGFloat(min(1.05, p)))
                    .reveal(p, rise: 70 * L.type)
            }
        }
    }
}

// MARK: - FeatureList

/// "And more." — remaining features as rows beside (or under) a headline.
public struct FeatureList: View {
    var features: [LaunchProps.Feature]
    var headline: [String]
    var t: Double
    var start: Double
    var stagger: Double
    @Environment(\.launchTheme) private var theme
    @Environment(\.renderContext) private var ctx

    public init(_ features: [LaunchProps.Feature], headline: [String] = ["And so", "much more."], at t: Double,
                start: Double = 0.1, stagger: Double = 0.3) {
        self.features = Array(features.prefix(4)); self.headline = headline
        self.t = t; self.start = start; self.stagger = stagger
    }

    /// When each row lands.
    public static func rowTimes(count: Int, start: Double, stagger: Double) -> [Double] {
        (0..<count).map { start + 0.5 + Double($0) * stagger }
    }

    public var body: some View {
        let L = LaunchLayout(ctx)
        let u = L.type
        let rows = Self.rowTimes(count: features.count, start: start, stagger: stagger)
        let layout = L.isVertical
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 80 * u))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 110 * u))
        layout {
            KeynoteTitle(headline, at: t, start: start, size: 104, alignment: .leading, accentLine: 1,
                         maxWidth: L.isVertical ? L.width : 640 * u)
                .frame(width: L.isVertical ? L.width : 640 * u, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(features.enumerated()), id: \.offset) { i, f in
                    let p = Motion.pop(t, rows[i] - 0.08, response: 0.42, damping: 0.8)
                    HStack(alignment: .firstTextBaseline, spacing: 30 * u) {
                        Image(systemName: LaunchAssets.symbol(f.symbol))
                            .font(.system(size: 40 * u, weight: .medium))
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(theme.accent)
                            .frame(width: 60 * u)
                        VStack(alignment: .leading, spacing: 8 * u) {
                            Text(f.title).font(theme.display(40 * u)).tracking(LaunchTheme.tracking(40 * u))
                                .foregroundStyle(theme.primary).lineLimit(1).minimumScaleFactor(0.6)
                            if !f.detail.isEmpty {
                                Text(f.detail).font(theme.text(25 * u)).foregroundStyle(theme.secondary)
                                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.vertical, 26 * u)
                    .frame(maxWidth: L.isVertical ? L.width : 860 * u, alignment: .leading)
                    .overlay(alignment: .top) {
                        if i > 0 { Rectangle().fill(theme.hairline).frame(height: 1) }
                    }
                    .opacity(min(1, max(0, p * 1.4)))
                    .offset(x: (1 - CGFloat(p)) * 70 * u)
                }
            }
        }
    }
}
