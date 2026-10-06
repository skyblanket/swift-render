import SwiftUI
import SwiftRenderKit

// MARK: - Look and feel
//
// Dark, dense, pro-app chrome: system materials for panels, near-black viewer,
// monospaced digits for anything that ticks, status colors shared by pins, lanes
// and the comments list.

enum StudioStyle {
    static let viewerBackground = Color(red: 0.035, green: 0.035, blue: 0.04)
    static let panelBackground = Color(nsColor: .underPageBackgroundColor)
    static let laneBackground = Color(white: 0.105)
    static let laneAltBackground = Color(white: 0.12)
    static let hairline = Color.white.opacity(0.08)
    static let accent = Color(red: 1.0, green: 0.78, blue: 0.36)      // #FFC75C, the house amber
    static let playhead = Color(red: 1.0, green: 0.27, blue: 0.23)
    static let ok = Color(red: 0.30, green: 0.82, blue: 0.47)
    static let warn = Color(red: 1.0, green: 0.72, blue: 0.20)
    static let bad = Color(red: 1.0, green: 0.36, blue: 0.33)

    static let mono = Font.system(size: 11, weight: .medium, design: .monospaced)
    static let monoSmall = Font.system(size: 10, weight: .regular, design: .monospaced)
    static let laneLabel = Font.system(size: 9.5, weight: .semibold)
    static let timecodeLarge = Font.system(size: 15, weight: .semibold, design: .monospaced)

    static func color(_ s: ReviewStatus) -> Color {
        switch s {
        case .open: return Color(red: 1.0, green: 0.62, blue: 0.24)
        case .inProgress: return Color(red: 0.35, green: 0.62, blue: 1.0)
        case .resolved: return ok
        case .wontFix: return Color(white: 0.5)
        }
    }

    static func symbol(_ s: ReviewStatus) -> String {
        switch s {
        case .open: return "circle"
        case .inProgress: return "circle.lefthalf.filled"
        case .resolved: return "checkmark.circle.fill"
        case .wontFix: return "minus.circle"
        }
    }

    static func symbol(_ k: SceneKind) -> String {
        switch k {
        case .render: return "film"
        case .audio: return "waveform"
        case .props: return "curlybraces.square"
        case .propsAudio: return "music.note.list"
        }
    }

    /// Score lane colors.
    static func lane(_ name: String) -> Color {
        switch name {
        case "speech": return Color(red: 0.55, green: 0.75, blue: 1.0)
        case "melodic": return Color(red: 0.70, green: 0.55, blue: 1.0)
        case "drums": return Color(red: 0.45, green: 0.85, blue: 0.80)
        case "mark": return Color(red: 0.95, green: 0.90, blue: 0.55)
        case "sample": return Color(red: 0.95, green: 0.60, blue: 0.80)
        case "fx": return warn
        default: return .gray
        }
    }

    static func timecode(_ t: Double) -> String { ReviewComment.format(max(0, t)) }
}

/// Inspector-sized empty state: `ContentUnavailableView` is sized for a whole window
/// and dwarfs a 300-pt panel.
struct StudioEmptyState: View {
    var title: String
    var symbol: String
    var message: String? = nil

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 2)
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            if let message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    // Not fixedSize(vertical:): measured at a column's minimum width the message
                    // wraps a character per line, and that ~970 pt "minimum" made the whole window
                    // content taller than the window (sidebar footer and agent panel cut off).
                    .lineLimit(6)
            }
        }
        .frame(maxWidth: 260)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Small capsule label used in HUD rows and badges.
struct StudioBadge: View {
    var text: String
    var color: Color = .secondary
    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .foregroundStyle(color)
            .background(color.opacity(0.16), in: Capsule())
    }
}
