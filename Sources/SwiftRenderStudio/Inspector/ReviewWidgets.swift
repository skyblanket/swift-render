import AppKit
import SwiftUI
import SwiftRenderKit

// MARK: - Review widgets
//
// Pieces the comments list, thread, pins, lane and compare share: the numbered
// status badge, author avatars (initials for people, a sparkle for agents), the
// status menu and attachment thumbnails. Agent work is violet everywhere so a
// thread Claude touched reads at a glance.

enum ReviewStyle {
    /// Agent violet (pins, avatars, reply bubbles, list stripe).
    static let agent = Color(red: 0.72, green: 0.56, blue: 1.0)
    static let agentFill = Color(red: 0.72, green: 0.56, blue: 1.0).opacity(0.10)
    static let human = Color(white: 0.62)

    static func title(_ s: ReviewStatus) -> String {
        switch s {
        case .open: return "Open"
        case .inProgress: return "In Progress"
        case .resolved: return "Resolved"
        case .wontFix: return "Won't Fix"
        }
    }

    static func shortTitle(_ s: ReviewStatus) -> String {
        switch s {
        case .open: return "Open"
        case .inProgress: return "Working"
        case .resolved: return "Resolved"
        case .wontFix: return "Won't fix"
        }
    }

    /// "Sky Blanket" → "SB".
    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let letters = words.prefix(2).compactMap(\.first).map { String($0).uppercased() }
        return letters.isEmpty ? "?" : letters.joined()
    }

    /// Short relative time without a live timer ("now", "4m", "2h", "3d").
    static func age(_ d: Date, now: Date = Date()) -> String {
        let s = max(0, now.timeIntervalSince(d))
        if s < 45 { return "now" }
        if s < 3600 { return "\(Int((s / 60).rounded()))m" }
        if s < 86_400 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86_400))d"
    }

    /// "f744" at the scene's fps.
    static func frame(_ t: Double, fps: Int?) -> String { "f\(frameIndex(t, fps: fps ?? 60))" }

    /// Source location as "RepoPromo.swift:284".
    static func short(_ s: SourceLocation) -> String { "\((s.file as NSString).lastPathComponent):\(s.line)" }
}

/// The numbered disc used on pins, the NOTES lane and list rows.
struct CommentBadge: View {
    var number: Int?
    var status: ReviewStatus
    var agent = false
    var selected = false
    var size: CGFloat = 18

    var body: some View {
        let color = StudioStyle.color(status)
        ZStack {
            Circle().fill(color)
            if status == .resolved {
                Image(systemName: "checkmark").font(.system(size: size * 0.5, weight: .heavy))
            } else {
                Text(number.map(String.init) ?? "•").font(.system(size: size * 0.55, weight: .bold, design: .rounded))
            }
        }
        .foregroundStyle(.black.opacity(0.85))
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(.white.opacity(selected ? 0.95 : 0.35), lineWidth: selected ? 1.5 : 1))
        .overlay(alignment: .topTrailing) {
            if agent {
                Image(systemName: "sparkle")
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(1.5)
                    .background(ReviewStyle.agent, in: Circle())
                    .offset(x: size * 0.28, y: -size * 0.28)
            }
        }
    }
}

/// Initials for people, a violet sparkle for agents.
struct AuthorAvatar: View {
    var author: ReviewAuthor
    var size: CGFloat = 20

    var body: some View {
        Group {
            if author.kind == .agent {
                Image(systemName: "sparkles")
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(LinearGradient(colors: [ReviewStyle.agent, Color(red: 0.48, green: 0.36, blue: 0.95)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
            } else {
                Text(ReviewStyle.initials(author.name))
                    .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: size, height: size)
                    .background(Color(white: 0.30), in: Circle())
            }
        }
        .help(author.kind == .agent ? "\(author.name) (agent)" : author.name)
    }
}

/// Status pill that is also the status menu.
struct StatusMenu: View {
    var status: ReviewStatus
    var onPick: (ReviewStatus) -> Void

    var body: some View {
        Menu {
            ForEach(ReviewStatus.allCases, id: \.self) { s in
                Button { onPick(s) } label: {
                    Label(ReviewStyle.title(s), systemImage: StudioStyle.symbol(s))
                }
                .disabled(s == status)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: StudioStyle.symbol(status))
                Text(ReviewStyle.title(status))
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).opacity(0.7)
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(StudioStyle.color(status))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(StudioStyle.color(status).opacity(0.15), in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Change status")
    }
}

/// A 16:9 attachment thumbnail. Click → A/B compare; double-click → open the PNG.
struct AttachmentThumb: View {
    @Bindable var model: ProjectModel
    var attachment: ReviewAttachment
    var commentID: String
    var width: CGFloat = 120

    var body: some View {
        let img = model.review.image(attachment)
        let label = attachment.kind == .before ? "BEFORE" : attachment.kind == .after ? "AFTER" : attachment.kind.rawValue.uppercased()
        ZStack(alignment: .bottomLeading) {
            if let img {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
            } else {
                Rectangle().fill(Color.black.opacity(0.4))
                    .overlay(Label("Missing", systemImage: "photo").font(.caption2).foregroundStyle(.tertiary))
            }
            Text(label)
                .font(.system(size: 8.5, weight: .bold, design: .rounded))
                .padding(.horizontal, 4).padding(.vertical, 1.5)
                .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 3))
                .foregroundStyle(attachment.kind == .after ? StudioStyle.ok : .white)
                .padding(4)
        }
        .frame(width: width, height: width * 9 / 16)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.12)))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { NSWorkspace.shared.open(model.review.url(attachment)) }
        .onTapGesture {
            model.review.selection = commentID
            model.review.compareID = commentID
            if model.ui.compare == nil { model.ui.compare = .split }
        }
        .help(img == nil ? "\(attachment.path) is missing" : "Click to compare · double-click to open \(attachment.path)")
    }
}

/// Status filter chip with a count.
struct StatusChip: View {
    var status: ReviewStatus
    var count: Int
    var on: Bool
    var action: () -> Void

    var body: some View {
        let color = StudioStyle.color(status)
        Button(action: action) {
            HStack(spacing: 4) {
                Circle().fill(color.opacity(on ? 1 : 0.45)).frame(width: 6, height: 6)
                Text(ReviewStyle.shortTitle(status))
                Text("\(count)").foregroundStyle(on ? .primary : .tertiary).monospacedDigit()
            }
            .font(.system(size: 10.5, weight: on ? .semibold : .regular))
            .foregroundStyle(on ? .primary : .secondary)
            .padding(.horizontal, 7).padding(.vertical, 3.5)
            .background(on ? color.opacity(0.18) : Color.white.opacity(0.04), in: Capsule())
            .overlay(Capsule().strokeBorder(on ? color.opacity(0.45) : .white.opacity(0.08)))
            .fixedSize()
        }
        .buttonStyle(.plain)
        .help("\(on ? "Hide" : "Show") \(ReviewStyle.title(status).lowercased()) comments")
    }
}
