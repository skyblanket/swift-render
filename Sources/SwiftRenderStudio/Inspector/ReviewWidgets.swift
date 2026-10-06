import AppKit
import SwiftUI
import SwiftRenderKit

// MARK: - Review widgets
//
// The pieces the comments list, thread, pins, lane and compare share: the display
// state of a comment (a mapping over `ReviewStatus`, which is unchanged on disk), the
// numbered disc, avatars (Claude is a participant with a "C" monogram, shaped like
// everyone else's), the status label and menu, and attachment thumbnails.

/// What a comment's status means to the person reading the list.
enum CommentState: Equatable, Sendable {
    case open, inProgress, claudeOnIt, readyForReview, done, wontFix

    init(_ c: ReviewComment) {
        switch c.status {
        case .open: self = .open
        case .inProgress: self = c.assignee?.kind == .agent ? .claudeOnIt : .inProgress
        case .resolved: self = c.acceptedBy == nil && Self.resolvedByClaude(c) ? .readyForReview : .done
        case .wontFix: self = .wontFix
        }
    }

    /// The last word in the thread is Claude's (Studio's own notes don't count), or Claude
    /// wrote a comment nobody answered. A person who resolves goes straight to Done.
    static func resolvedByClaude(_ c: ReviewComment) -> Bool {
        let voices = c.replies.filter { !ReviewStyle.isStudioNote($0.author) }
        guard let last = voices.last else { return c.author.kind == .agent }
        return last.author.kind == .agent
    }

    var title: String {
        switch self {
        case .open: return "Open"
        case .inProgress: return "In Progress"
        case .claudeOnIt: return "Claude's on it"
        case .readyForReview: return "Ready for Review"
        case .done: return "Done"
        case .wontFix: return "Won't Fix"
        }
    }

    /// nil = a small spinner (Claude's on it).
    var symbol: String? {
        switch self {
        case .open: return "circle"
        case .inProgress: return "circle.lefthalf.filled"
        case .claudeOnIt: return nil
        case .readyForReview: return "checkmark.circle"
        case .done: return "checkmark.circle.fill"
        case .wontFix: return "minus.circle"
        }
    }

    var segment: ReviewSegment {
        switch self {
        case .open, .inProgress, .claudeOnIt: return .open
        case .readyForReview: return .review
        case .done, .wontFix: return .done
        }
    }

    var isActive: Bool { segment == .open }
    /// Done and Won't Fix sit back.
    var isSettled: Bool { segment == .done }
}

enum ReviewStyle {
    /// "Sky Blanket" → "SB"; Claude → "C".
    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let letters = words.prefix(2).compactMap(\.first).map { String($0).uppercased() }
        return letters.isEmpty ? "?" : letters.joined()
    }

    /// Notes Studio itself leaves in a thread ("back on your list").
    static func isStudioNote(_ a: ReviewAuthor) -> Bool {
        a.kind == .agent && a.name == "Studio"
    }

    /// Every agent is shown as Claude, whatever its config calls it.
    static func displayName(_ a: ReviewAuthor) -> String {
        if isStudioNote(a) { return "Studio" }
        return a.kind == .agent ? "Claude" : a.name
    }

    /// Short relative time without a live timer ("Just now", "4 min", "2 hr", "3 days").
    static func age(_ d: Date, now: Date = Date()) -> String {
        let s = max(0, now.timeIntervalSince(d))
        if s < 45 { return "Just now" }
        if s < 3600 { return "\(Int((s / 60).rounded())) min" }
        if s < 86_400 { return "\(Int(s / 3600)) hr" }
        let days = Int(s / 86_400)
        return "\(days) day\(days == 1 ? "" : "s")"
    }

    /// Source file name ("RepoPromo.swift"); the line goes in a tooltip.
    static func file(_ s: SourceLocation) -> String { (s.file as NSString).lastPathComponent }

    /// "RepoPromo.swift:284" for tooltips and menus.
    static func short(_ s: SourceLocation) -> String { "\(file(s)):\(s.line)" }

    /// "2 replies".
    static func replies(_ n: Int) -> String { "\(n) repl\(n == 1 ? "y" : "ies")" }
}

/// The numbered disc on pins, the Comments lane and list rows. One grammar everywhere:
/// open = solid neutral disc, in progress = ring, ready for review = accent disc,
/// done = faded disc with a tiny check, won't fix = dashed faded ring. The numeral shows
/// in every state; selection adds a 2 pt accent ring.
struct CommentDisc: View {
    var number: Int?
    var state: CommentState
    var selected = false
    var size: CGFloat = 20

    var body: some View {
        let label = number.map(String.init) ?? "•"
        ZStack {
            switch state {
            case .open:
                Circle().fill(StudioStyle.discFill)
                numeral(label, StudioStyle.discInk)
            case .inProgress, .claudeOnIt:
                Circle().fill(StudioStyle.raised)
                Circle().strokeBorder(StudioStyle.discFill, lineWidth: 1.5)
                numeral(label, StudioStyle.discFill)
            case .readyForReview:
                Circle().fill(StudioStyle.accent)
                numeral(label, .white)
            case .done:
                Circle().fill(StudioStyle.discFill.opacity(0.35))
                numeral(label, StudioStyle.discInk.opacity(0.9))
            case .wontFix:
                Circle().fill(StudioStyle.raised.opacity(0.6))
                Circle().strokeBorder(StudioStyle.discFill.opacity(0.45), style: StrokeStyle(lineWidth: 1.25, dash: [2.5, 2]))
                numeral(label, StudioStyle.discFill.opacity(0.6))
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if state == .done {
                Image(systemName: "checkmark.circle.fill")
                    .font(StudioStyle.Fonts.rounded(size * 0.5, weight: .bold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(StudioStyle.discInk, StudioStyle.discFill)
                    .offset(x: size * 0.18, y: size * 0.12)
            }
        }
        .padding(selected ? 3 : 0)
        .overlay { if selected { Circle().strokeBorder(StudioStyle.accent, lineWidth: 2) } }
        .accessibilityLabel("Comment \(label), \(state.title)")
    }

    private func numeral(_ s: String, _ color: Color) -> some View {
        Text(s)
            .font(StudioStyle.Fonts.rounded(size * (s.count > 1 ? 0.48 : 0.56), weight: .bold))
            .monospacedDigit()
            .foregroundStyle(color)
            .minimumScaleFactor(0.6)
    }
}

/// A round monogram, the same shape for people and Claude: initials for people, "C" for Claude.
struct AuthorAvatar: View {
    var author: ReviewAuthor
    var size: CGFloat = 24

    var body: some View {
        Text(author.kind == .agent ? (ReviewStyle.isStudioNote(author) ? "S" : "C") : ReviewStyle.initials(author.name))
            .font(StudioStyle.Fonts.rounded(size * 0.44, weight: .semibold))
            .foregroundStyle(StudioStyle.avatarInk)
            .frame(width: size, height: size)
            .background(StudioStyle.avatarFill, in: Circle())
            .help(ReviewStyle.displayName(author))
            .accessibilityLabel(ReviewStyle.displayName(author))
    }
}

/// Status as a monochrome symbol plus a word. Only Ready for Review takes the accent.
struct StatusLabel: View {
    var state: CommentState
    var font: Font = StudioStyle.Fonts.subheadline

    var body: some View {
        HStack(spacing: StudioStyle.Space.xs) {
            if let symbol = state.symbol {
                Image(systemName: symbol)
            } else {
                ProgressView().controlSize(.mini)
            }
            Text(state.title).lineLimit(1)
        }
        .font(font)
        .foregroundStyle(color)
        .fixedSize()
    }

    private var color: AnyShapeStyle {
        switch state {
        case .readyForReview: return AnyShapeStyle(StudioStyle.accent)
        case .done, .wontFix: return AnyShapeStyle(.tertiary)
        default: return AnyShapeStyle(.secondary)
        }
    }
}

/// What a person can set a comment to from the status menu.
enum StatusChoice: CaseIterable {
    case open, inProgress, done, wontFix
    var title: String {
        switch self {
        case .open: return "Open"
        case .inProgress: return "In Progress"
        case .done: return "Done"
        case .wontFix: return "Won't Fix"
        }
    }
    var symbol: String {
        switch self {
        case .open: return "circle"
        case .inProgress: return "circle.lefthalf.filled"
        case .done: return "checkmark.circle.fill"
        case .wontFix: return "minus.circle"
        }
    }
}

/// The status label that is also the status menu.
struct StatusMenu: View {
    var state: CommentState
    var onPick: (StatusChoice) -> Void

    var body: some View {
        Menu {
            ForEach(StatusChoice.allCases, id: \.self) { s in
                Button { onPick(s) } label: { Label(s.title, systemImage: s.symbol) }
            }
        } label: {
            StatusLabel(state: state)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Change status")
    }
}

/// A 16:9 attachment thumbnail. Click → compare; double-click → open the PNG.
struct AttachmentThumb: View {
    @Bindable var model: ProjectModel
    var attachment: ReviewAttachment
    var commentID: String
    var width: CGFloat = 120
    var title: String? = nil

    var body: some View {
        let img = model.review.image(attachment)
        let label = title ?? (attachment.kind == .before ? "Before" : attachment.kind == .after ? "After" : attachment.kind.rawValue.capitalized)
        ZStack(alignment: .bottomLeading) {
            if let img {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
            } else {
                StudioStyle.well
                    .overlay(Image(systemName: "photo").foregroundStyle(.tertiary))
            }
            Text(label)
                .font(StudioStyle.Fonts.footnoteEmphasis)
                .foregroundStyle(StudioStyle.onPicture)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(StudioStyle.pictureScrim, in: Capsule())
                .padding(StudioStyle.Space.xs)
        }
        .frame(width: width, height: width * 9 / 16)
        .background(StudioStyle.canvas)
        .clipShape(StudioStyle.rounded(StudioStyle.Radius.small))
        .overlay(StudioStyle.rounded(StudioStyle.Radius.small).strokeBorder(StudioStyle.keyline))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { NSWorkspace.shared.open(model.review.url(attachment)) }
        .onTapGesture {
            model.review.selection = commentID
            model.review.compareID = commentID
            if model.ui.compare == nil { model.ui.compare = .split }
        }
        .help(img == nil ? "This frame is missing" : "Click to compare. Double-click to open the image.")
    }
}
