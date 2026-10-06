import AppKit
import SwiftUI
import SwiftRenderKit

// MARK: - Design system ("Friendly")
//
// The film is the loudest thing on screen; the chrome is quiet, native and friendly.
//
//   Color    One accent: the system accent (`Color.accentColor`). Red only for errors and
//            destructive actions, orange only for warnings inside diagnostics. Everything
//            else is a neutral token below, each a dynamic NSColor (light + dark).
//   Planes   canvas (behind the picture) · chrome (sidebar, inspector, transport, timeline,
//            Claude panel: one surface split by hairlines) · raised (fields, cards, popovers).
//   Type     SF Pro text styles: body 13, callout 12, subheadline 11, footnote 10. Nothing
//            smaller. Monospace only for code, file:line, commands and JSON; numbers use
//            monospaced digits. Section labels are Title Case, semibold, secondary.
//            Avatars and comment discs use SF Rounded.
//   Grid     4 pt spacing (4/8/12/16/24). Radii 4 (chips, clips, thumbnails), 8 (fields,
//            buttons, rows), 12 (sheets, popovers, composer), all continuous.
//   Symbols  Regular-weight monochrome SF Symbols (`Symbol`); no glitter, no magic wands.
//
// Every color, font size, radius and spacing value used by Studio views lives here.

enum StudioStyle {
    // MARK: Color tokens

    /// The one accent: whatever the person picked in System Settings.
    static let accent = Color.accentColor

    /// Darkest plane, behind the picture only.
    static let canvas = dynamic("canvas", light: gray(0xE3E3E6), dark: gray(0x0B0B0C))
    /// Sidebar, inspector, transport, timeline and the Claude panel.
    static let chrome = Color(nsColor: .windowBackgroundColor)
    /// A half-step off chrome: lane header column, alternating lanes, the ruler.
    static let chromeAlt = dynamic("chromeAlt", light: gray(0xF0F0F2), dark: gray(0x232325))
    /// Fields, cards, popovers, message bubbles.
    static let raised = dynamic("raised", light: gray(0xFFFFFF), dark: gray(0x2C2C2F))
    /// Text fields: a quiet inset with a hairline edge.
    static let field = dynamic("field", light: gray(0xFFFFFF), dark: gray(0x1C1C1E))
    /// Quiet fill for wells and thumbnails placeholders.
    static let well = dynamic("well", light: gray(0x000000, 0.05), dark: gray(0xFFFFFF, 0.06))
    static let hairline = Color(nsColor: .separatorColor)
    /// 1 px edge around the picture, so a black frame still reads as a frame.
    static let keyline = dynamic("keyline", light: gray(0x000000, 0.14), dark: gray(0xFFFFFF, 0.10))

    static let error = Color(nsColor: .systemRed)
    static let warning = Color(nsColor: .systemOrange)
    /// Frames already rendered for this build (the NLE render bar).
    static let cached = dynamic("cached", light: NSColor.systemGreen.withAlphaComponent(0.7),
                                dark: NSColor.systemGreen.withAlphaComponent(0.6))

    /// Comment discs and avatars: a neutral disc and the ink on it.
    static let discFill = dynamic("discFill", light: gray(0x3A3A3C), dark: gray(0xE5E5EA))
    static let discInk = dynamic("discInk", light: gray(0xFFFFFF), dark: gray(0x1C1C1E))
    static let avatarFill = dynamic("avatarFill", light: gray(0xDCDCE1), dark: gray(0x48484C))
    static let avatarInk = dynamic("avatarInk", light: gray(0x3A3A3C), dark: gray(0xF2F2F7))

    /// The box burned into review stills (`ReviewImage.boxColor`), drawn the same in Compare.
    static let regionBox = Color(.sRGB, red: ReviewImage.boxColor.r, green: ReviewImage.boxColor.g, blue: ReviewImage.boxColor.b)

    /// Playhead and its cap (never red).
    static let playhead = dynamic("playhead", light: gray(0x1D1D1F), dark: gray(0xFFFFFF))
    /// Ink and scrim for labels drawn over the picture, which is dark or light on its own terms.
    static let onPicture = Color.white
    static let pictureScrim = Color.black.opacity(0.55)

    /// One muted tone per timeline lane (content, not chrome), drawn at ~35%.
    enum Lane {
        static let clips = Color(nsColor: .systemGray)
        static let voice = Color(nsColor: .systemTeal)
        static let music = Color(nsColor: .systemIndigo)
        static let drums = Color(nsColor: .systemTeal)
        static let samples = Color(nsColor: .systemPink)
        static let fx = Color(nsColor: .systemBrown)
        static let audio = Color(nsColor: .systemGray)
        static let captions = Color(nsColor: .systemGray)
        static let fill = 0.35

        static func tone(_ lane: String) -> Color {
            switch lane {
            case "speech": return voice
            case "melodic": return music
            case "drums", "mark": return drums
            case "sample": return samples
            case "fx": return fx
            default: return clips
            }
        }
    }

    // MARK: Type

    enum Fonts {
        static let body = Font.body                               // 13
        static let bodyEmphasis = Font.body.weight(.semibold)
        static let callout = Font.callout                         // 12
        static let calloutEmphasis = Font.callout.weight(.semibold)
        static let subheadline = Font.subheadline                 // 11
        static let footnote = Font.footnote                       // 10
        static let footnoteEmphasis = Font.footnote.weight(.semibold)
        static let sectionLabel = Font.subheadline.weight(.semibold)
        static let headline = Font.headline
        static let title = Font.title3.weight(.semibold)          // sheet titles, 15
        /// The transport's typographic anchor.
        static let timecodeLarge = Font.system(size: 20, weight: .medium).monospacedDigit()
        static let code = Font.system(.callout, design: .monospaced)
        static let codeSmall = Font.system(.footnote, design: .monospaced)
        /// Picture-overlay labels (guides) drawn in a Canvas.
        static let overlay = Font.footnote.weight(.semibold)
        static let emptyGlyph = Font.system(size: 28, weight: .light)

        /// SF Rounded for numerals on discs and avatar monograms.
        static func rounded(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
            .system(size: max(10, size), weight: weight, design: .rounded)
        }
    }

    // MARK: Grid

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        /// Inspector content inset, everywhere.
        static let gutter: CGFloat = 16
    }

    enum Radius {
        static let small: CGFloat = 4
        static let medium: CGFloat = 8
        static let large: CGFloat = 12
    }

    /// `--snapshot`: render without effects a layer snapshot can't see.
    nonisolated(unsafe) static var isSnapshot = false

    static func rounded(_ r: CGFloat) -> RoundedRectangle { RoundedRectangle(cornerRadius: r, style: .continuous) }

    // MARK: Symbols

    enum Symbol {
        static let comment = "plus.bubble"
        static let compare = "rectangle.split.2x1"
        static let export = "square.and.arrow.up"
        static let filter = "line.3.horizontal.decrease.circle"
        static let filterOn = "line.3.horizontal.decrease.circle.fill"
        static let build = "hammer"
        static let sidebar = "sidebar.leading"
        static let inspector = "sidebar.trailing"
        static let add = "plus"
        static let more = "ellipsis.circle"
        static let reveal = "arrow.up.forward"
        static let close = "xmark"
        static let error = "xmark.octagon.fill"
        static let warning = "exclamationmark.triangle.fill"
        static let ok = "checkmark.circle"
        static let reset = "arrow.counterclockwise"
        static let back = "chevron.left"
        static let previous = "chevron.up"
        static let next = "chevron.down"
        static let comments = "text.bubble"
        static let knobs = "slider.horizontal.3"
        static let content = "doc.richtext"
        static let film = "film"
    }

    static func symbol(_ k: SceneKind) -> String {
        switch k {
        case .render: return "film"
        case .audio: return "waveform"
        case .props: return "doc.richtext"
        case .propsAudio: return "music.note"
        }
    }

    // MARK: Helpers

    private static func dynamic(_ name: String, light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name("studio." + name)) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua, .vibrantDark, .vibrantLight]).map {
                $0 == .darkAqua || $0 == .vibrantDark ? dark : light
            } ?? dark
        })
    }

    private static func gray(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

// MARK: - Appearance

/// View › Appearance and Settings: dark by default, or light, or whatever the system uses.
enum StudioAppearance: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark
    static let key = "appearance"
    static let fallback = StudioAppearance.dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "Match System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
    /// The launch flag (`--appearance light|dark|system`) wins over the saved choice.
    @MainActor static var current: StudioAppearance {
        if let a = StudioLaunch.options.appearance { return a }
        return UserDefaults.standard.string(forKey: key).flatMap(StudioAppearance.init(rawValue:)) ?? fallback
    }
}

// MARK: - Time

/// One formatter for every time Studio shows. Rows and headers read "0:11"; the
/// transport reads "00:11:10" (minutes, seconds, frames); frame numbers and the fps
/// live in tooltips. (`ReviewComment.format` stays as is: the CLI and agents read it.)
enum StudioTime {
    /// "0:11", "1:05:02" past an hour.
    static func short(_ t: Double) -> String {
        let s = Int(max(0, t).rounded(.down))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// "0:06–0:07", or one time when the range is under a second wide in the same second.
    static func range(_ a: Double, _ b: Double?) -> String {
        guard let b, short(b) != short(a) else { return short(a) }
        return "\(short(a))–\(short(b))"
    }

    /// "00:11:10" (MM:SS:FF).
    static func transport(_ t: Double, fps: Int) -> String {
        let f = max(1, fps)
        let frames = Int((max(0, t) * Double(f)).rounded(.down))
        return String(format: "%02d:%02d:%02d", frames / f / 60, (frames / f) % 60, frames % f)
    }

    /// Tooltip for any timecode: "Frame 671 at 60 fps".
    static func frameHelp(_ t: Double, fps: Int) -> String {
        "Frame \(frameIndex(t, fps: fps)) at \(fps) fps"
    }

    /// "0:02.40" for hover cards and the skimmer chip.
    static func precise(_ t: Double) -> String {
        let v = max(0, t)
        let m = Int(v) / 60
        return String(format: "%d:%05.2f", m, v - Double(m * 60))
    }

    /// "25 seconds", "1 minute 33 seconds".
    static func spoken(_ s: Double) -> String {
        let n = Int(s.rounded())
        if n < 60 { return "\(n) second\(n == 1 ? "" : "s")" }
        let m = n / 60, r = n % 60
        return "\(m) minute\(m == 1 ? "" : "s")" + (r > 0 ? " \(r) second\(r == 1 ? "" : "s")" : "")
    }

    /// "25 s", "1.3 s", "1:04".
    static func compact(_ s: Double) -> String {
        if s >= 60 { return String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }
        return s < 10 ? String(format: "%.1f s", s) : String(format: "%.0f s", s)
    }
}

// MARK: - Shared pieces

/// Inspector-sized empty state that teaches the next step: `ContentUnavailableView` is
/// sized for a whole window and dwarfs a 300-pt panel.
struct StudioEmptyState: View {
    var title: String
    var symbol: String
    var message: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: StudioStyle.Space.s) {
            Image(systemName: symbol)
                .font(StudioStyle.Fonts.emptyGlyph)
                .foregroundStyle(.tertiary)
                .padding(.bottom, StudioStyle.Space.xs)
            Text(title).font(StudioStyle.Fonts.bodyEmphasis).foregroundStyle(.secondary)
            if let message {
                Text(.init(message))
                    .font(StudioStyle.Fonts.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    // Not fixedSize(vertical:): measured at a column's minimum width the message
                    // wraps a character per line, and that ~970 pt "minimum" made the whole window
                    // content taller than the window (sidebar footer and agent panel cut off).
                    .lineLimit(6)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.regular)
                    .padding(.top, StudioStyle.Space.xs)
            }
        }
        .frame(maxWidth: 280)
        .padding(StudioStyle.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// "Title Case" section label in secondary.
struct SectionLabel: View {
    var text: String
    var body: some View {
        Text(text).font(StudioStyle.Fonts.sectionLabel).foregroundStyle(.secondary)
    }
}

extension View {
    /// Floating controls over the picture: Liquid Glass on macOS 26, regular material before.
    @ViewBuilder
    func studioGlass(cornerRadius: CGFloat = StudioStyle.Radius.large) -> some View {
        // Snapshots can't capture glass (its content lives in a portal layer): use material there.
        if #available(macOS 26, *), !StudioStyle.isSnapshot {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.regularMaterial, in: StudioStyle.rounded(cornerRadius))
        }
    }

    /// Studio's text field look: plain field, soft 8 pt corners, a hairline that turns
    /// accent while editing (and red when the value is rejected).
    func studioField(focused: Bool = false, invalid: Bool = false) -> some View {
        textFieldStyle(.plain)
            .padding(.horizontal, StudioStyle.Space.s).padding(.vertical, 5)
            .background(StudioStyle.field, in: StudioStyle.rounded(StudioStyle.Radius.medium))
            .overlay(StudioStyle.rounded(StudioStyle.Radius.medium)
                .strokeBorder(invalid ? StudioStyle.error : focused ? StudioStyle.accent.opacity(0.8) : StudioStyle.hairline,
                              lineWidth: invalid || focused ? 1.5 : 1))
    }

    /// A raised card: fields, composer, hover cards.
    func studioCard(cornerRadius: CGFloat = StudioStyle.Radius.large, shadow: Bool = true) -> some View {
        background(StudioStyle.rounded(cornerRadius).fill(StudioStyle.raised)
            .shadow(color: .black.opacity(shadow ? 0.25 : 0), radius: 12, y: 4))
            .overlay(StudioStyle.rounded(cornerRadius).strokeBorder(StudioStyle.hairline))
    }
}
