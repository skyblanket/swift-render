import SwiftRenderKit
import SwiftUI

// MARK: - LaunchIcon

/// An app icon at `size`: the image clipped to the iOS squircle (or left as-is for
/// macOS art), or — when there is no image — a generated mark: a dark glass tile
/// with the name's initial in the accent.
public struct LaunchIcon: View {
    var image: Image?
    var size: CGFloat
    var shape: LaunchProps.IconShape
    var monogram: String
    @Environment(\.launchTheme) private var theme

    public init(_ image: Image?, size: CGFloat, shape: LaunchProps.IconShape = .iOS, monogram: String = "") {
        self.image = image; self.size = size; self.shape = shape; self.monogram = monogram
    }

    /// The iOS icon mask: a continuous rounded rect at 22.37% of the side.
    public static func squircle(_ size: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
    }

    public var body: some View {
        if let image {
            switch shape {
            case .iOS:
                image.resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(Self.squircle(size))
                    .overlay(Self.squircle(size).strokeBorder(Color.white.opacity(0.10), lineWidth: max(1, size / 360)))
            case .macOS, .none:
                image.resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
            }
        } else {
            generated
        }
    }

    private var generated: some View {
        let tile = Self.squircle(size)
        let glyph = String(monogram.first(where: { $0.isLetter || $0.isNumber }) ?? "✦").uppercased()
        return ZStack {
            tile.fill(LinearGradient(colors: [Color(white: 0.17), Color(white: 0.06)], startPoint: .top, endPoint: .bottom))
            RadialGradient(colors: [theme.accent.opacity(0.35), .clear], center: UnitPoint(x: 0.5, y: 0.62),
                           startRadius: 0, endRadius: size * 0.55)
                .clipShape(tile)
            Text(glyph)
                .font(theme.display(size * 0.56, .semibold))
                .foregroundStyle(LinearGradient(colors: [theme.accent, theme.accentSecondary ?? theme.accent.opacity(0.75)],
                                                startPoint: .top, endPoint: .bottom))
                .offset(y: -size * 0.01)
            tile.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.28), Color.white.opacity(0.04)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: max(1, size / 180))
        }
        .frame(width: size, height: size)
    }
}

// MARK: - AppIconHero

/// The hero moment: the icon springs up out of a slight tilt with an accent glow
/// pulsing on the beat, a specular sweep crosses it, then the name focuses in
/// letter by letter and the tagline rises underneath.
public struct AppIconHero: View {
    var icon: Image?
    var t: Double
    var size: CGFloat
    var shape: LaunchProps.IconShape
    var beat: Double?
    var sweepAt: Double
    var name: String?
    var tagline: String?
    var nameAt: Double
    var taglineAt: Double
    @Environment(\.launchTheme) private var theme
    @Environment(\.renderContext) private var ctx

    public init(icon: Image?, at t: Double, size: CGFloat = 300, shape: LaunchProps.IconShape = .iOS,
                beat: Double? = 0.6, sweepAt: Double = 1.0, name: String? = nil, tagline: String? = nil,
                nameAt: Double = 1.1, taglineAt: Double = 1.9) {
        self.icon = icon; self.t = t; self.size = size; self.shape = shape; self.beat = beat
        self.sweepAt = sweepAt; self.name = name; self.tagline = tagline
        self.nameAt = nameAt; self.taglineAt = taglineAt
    }

    /// Loads the icon from a file path (nil or missing → generated mark).
    public init(iconPath: String?, at t: Double, size: CGFloat = 300, shape: LaunchProps.IconShape = .iOS,
                beat: Double? = 0.6, sweepAt: Double = 1.0, name: String? = nil, tagline: String? = nil,
                nameAt: Double = 1.1, taglineAt: Double = 1.9) {
        self.init(icon: LaunchAssets.image(iconPath), at: t, size: size, shape: shape, beat: beat, sweepAt: sweepAt,
                  name: name, tagline: tagline, nameAt: nameAt, taglineAt: taglineAt)
    }

    public var body: some View {
        let L = LaunchLayout(ctx)
        let s = size * L.type
        let p = Motion.pop(t, 0, from: 0.55, to: 1, response: 0.55, damping: 0.72)
        let tilt = Motion.pop(t, 0, from: 1, to: 0, response: 0.7, damping: 0.8)
        let pulse = beat.map { Motion.beatPulse(t, beat: $0) } ?? 0
        let nameSize = (name?.count ?? 0) > 14 ? 120.0 : 150.0
        VStack(spacing: 0) {
            ZStack {
                Circle().fill(theme.accent)
                    .frame(width: s * 0.9, height: s * 0.9)
                    .blur(radius: s * 0.32)
                    .opacity((0.28 + 0.22 * pulse) * min(1, max(0, p)))
                LaunchIcon(icon, size: s, shape: shape, monogram: name ?? "")
                    .specularSweep(at: t, start: sweepAt, duration: 0.8, intensity: 0.55)
                    .shadow(color: .black.opacity(theme.isDark ? 0.75 : 0.25), radius: s * 0.13, y: s * 0.07)
                    .rotation3DEffect(.degrees(18 * tilt), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
                    .scaleEffect(CGFloat(p))
                    .opacity(min(1, max(0, (p - 0.55) / 0.3)))
            }
            .frame(width: s * 1.3, height: s * 1.15)
            if let name {
                KeynoteTitle([name], at: t, start: nameAt - 0.12, size: nameSize, reveal: .letters(stagger: 0.035),
                             accentLine: nil)
                    .padding(.top, 30 * L.type)
            }
            if let tagline {
                Text(tagline)
                    .font(theme.text(34 * L.type, .regular))
                    .foregroundStyle(theme.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: L.width)
                    .padding(.top, 18 * L.type)
                    .reveal(Motion.rise(t, taglineAt, 0.6), rise: 16)
            }
        }
    }
}

// MARK: - GlassPanel

/// A frosted surface. By default a tinted translucent fill with a lit hairline
/// (identical on every machine). Pass `backdrop` to blur an explicit view behind
/// the panel, or `material: true` for the system material (renders under
/// ImageRenderer, but follows the host's transparency settings).
public struct GlassPanel<Content: View>: View {
    var cornerRadius: CGFloat
    var tint: Color?
    var backdrop: AnyView?
    var blur: CGFloat
    var material: Bool
    var t: Double
    var sheenAt: Double?
    var content: Content
    @Environment(\.launchTheme) private var theme

    public init(cornerRadius: CGFloat = 28, tint: Color? = nil, backdrop: AnyView? = nil, blur: CGFloat = 40,
                material: Bool = false, at t: Double = 0, sheenAt: Double? = nil,
                @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius; self.tint = tint; self.backdrop = backdrop; self.blur = blur
        self.material = material; self.t = t; self.sheenAt = sheenAt; self.content = content()
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let fill = tint ?? (theme.isDark ? Color.white.opacity(0.055) : Color.white.opacity(0.75))
        let panel = content
            .background {
                ZStack {
                    if let backdrop {
                        backdrop.blur(radius: blur, opaque: true).clipShape(shape)
                    } else if material {
                        shape.fill(.ultraThinMaterial)
                    }
                    shape.fill(fill)
                    shape.fill(LinearGradient(colors: [Color.white.opacity(theme.isDark ? 0.07 : 0.4), .clear],
                                              startPoint: .top, endPoint: .center))
                }
            }
            .overlay(shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(theme.isDark ? 0.22 : 0.9),
                                                                Color.white.opacity(theme.isDark ? 0.05 : 0.3)],
                                                       startPoint: .top, endPoint: .bottom), lineWidth: 1))
        if let sheenAt {
            panel.specularSweep(at: t, start: sheenAt, duration: 0.9, intensity: 0.18)
        } else {
            panel
        }
    }
}

// MARK: - DeviceFrame

/// A generic device (no Apple product imagery) around `screen`. Screen content is
/// laid out at the device's point size, then the whole device is scaled to
/// `width`, so screenshots and text stay sharp.
public struct DeviceFrame<Screen: View>: View {
    public enum Enter: Sendable { case none, settle, rise }

    var kind: LaunchProps.Device
    var t: Double
    var enter: Enter
    var width: CGFloat?
    var title: String?
    var screen: Screen
    @Environment(\.launchTheme) private var theme
    @Environment(\.renderContext) private var ctx

    public init(_ kind: LaunchProps.Device, at t: Double = 10, enter: Enter = .settle, width: CGFloat? = nil,
                title: String? = nil, @ViewBuilder screen: () -> Screen) {
        self.kind = kind; self.t = t; self.enter = enter; self.width = width; self.title = title; self.screen = screen()
    }

    /// Screen size in points.
    public static func screenSize(_ kind: LaunchProps.Device) -> CGSize {
        switch kind {
        case .iPhone: return CGSize(width: 393, height: 852)
        case .iPad: return CGSize(width: 1180, height: 820)
        case .mac: return CGSize(width: 1512, height: 982)
        case .macWindow: return CGSize(width: 1280, height: 800)
        }
    }

    /// Outer size of the whole device in points (before scaling).
    public static func bodySize(_ kind: LaunchProps.Device) -> CGSize {
        let s = screenSize(kind)
        switch kind {
        case .iPhone: return CGSize(width: s.width + 26, height: s.height + 26)
        case .iPad: return CGSize(width: s.width + 48, height: s.height + 48)
        case .mac: return CGSize(width: s.width * 1.14, height: s.height + 32 + 26)
        case .macWindow: return CGSize(width: s.width, height: s.height + 52)
        }
    }

    public var body: some View {
        let L = LaunchLayout(ctx)
        let size = Self.bodySize(kind)
        let target = (width ?? defaultWidth(L))
        let k = target / size.width
        let p = enter == .none ? 1 : Motion.pop(t, 0, response: 0.62, damping: 0.82)
        let fade = enter == .none ? 1 : Motion.rise(t, 0, 0.35)
        device
            .frame(width: size.width, height: size.height)
            .scaleEffect(k)
            .frame(width: size.width * k, height: size.height * k)
            .shadow(color: .black.opacity(theme.isDark ? 0.6 : 0.18), radius: 50 * k, y: 30 * k)
            .rotation3DEffect(.degrees(enter == .settle ? -14 * (1 - p) : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
            .scaleEffect(enter == .settle ? 0.92 + 0.08 * CGFloat(p) : 1)
            .offset(y: enter == .rise ? (1 - CGFloat(p)) * 140 * L.type : 0)
            .opacity(fade)
    }

    private func defaultWidth(_ L: LaunchLayout) -> CGFloat {
        switch kind {
        case .iPhone: return (L.isVertical ? 560 : 400) * L.type
        case .iPad: return (L.isVertical ? 1150 : 1100) * L.type
        case .mac, .macWindow: return (L.isVertical ? 1250 : 1200) * L.type
        }
    }

    private var rim: LinearGradient {
        LinearGradient(colors: [Color.white.opacity(0.42), Color.white.opacity(0.10), Color.white.opacity(0.28)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    @ViewBuilder private var device: some View {
        let ss = Self.screenSize(kind)
        switch kind {
        case .iPhone:
            ZStack {
                RoundedRectangle(cornerRadius: 68, style: .continuous).fill(Color(white: 0.07))
                RoundedRectangle(cornerRadius: 68, style: .continuous).strokeBorder(rim, lineWidth: 3)
                screen.frame(width: ss.width, height: ss.height)
                    .clipShape(RoundedRectangle(cornerRadius: 55, style: .continuous))
                Capsule().fill(Color.black).frame(width: 124, height: 36)
                    .frame(maxHeight: .infinity, alignment: .top).padding(.top, 24)
            }
        case .iPad:
            ZStack {
                RoundedRectangle(cornerRadius: 40, style: .continuous).fill(Color(white: 0.07))
                RoundedRectangle(cornerRadius: 40, style: .continuous).strokeBorder(rim, lineWidth: 3)
                screen.frame(width: ss.width, height: ss.height)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        case .mac:
            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color(white: 0.05))
                    RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(rim, lineWidth: 2.5)
                    screen.frame(width: ss.width, height: ss.height)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding(.top, 16)
                    UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12, style: .continuous)
                        .fill(Color(white: 0.05)).frame(width: 190, height: 30).padding(.top, 16)
                }
                .frame(width: ss.width + 32, height: ss.height + 32)
                ZStack(alignment: .top) {
                    UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22, style: .continuous)
                        .fill(LinearGradient(colors: [Color(white: 0.36), Color(white: 0.16)], startPoint: .top, endPoint: .bottom))
                    UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10, style: .continuous)
                        .fill(Color(white: 0.12)).frame(width: 240, height: 9)
                }
                .frame(width: ss.width * 1.14, height: 26)
            }
        case .macWindow:
            VStack(spacing: 0) {
                ZStack {
                    HStack(spacing: 9) {
                        Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.34))
                        Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.18))
                        Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25))
                    }
                    .frame(width: 62, height: 13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 20)
                    if let title {
                        Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.secondary)
                    }
                }
                .frame(height: 52)
                screen.frame(width: ss.width, height: ss.height).clipped()
            }
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(colors: [theme.surfaceElevated, theme.surface], startPoint: .top, endPoint: .bottom)))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(theme.hairline, lineWidth: 1))
        }
    }
}

/// A screenshot from disk filling a device screen; a soft placeholder when missing.
public struct ScreenshotView: View {
    var path: String?
    @Environment(\.launchTheme) private var theme
    public init(_ path: String?) { self.path = path }
    public var body: some View {
        if let img = LaunchAssets.image(path) {
            img.resizable().interpolation(.high).aspectRatio(contentMode: .fill)
        } else {
            LinearGradient(colors: [theme.surfaceElevated, theme.background], startPoint: .top, endPoint: .bottom)
        }
    }
}
