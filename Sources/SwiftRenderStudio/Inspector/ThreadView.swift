import AppKit
import SwiftUI
import SwiftRenderKit

// MARK: - Thread
//
// Pushed full height over the list. "‹ Comments" goes back; the arrows step through
// comments. Header (disc, who, when, status menu), the conversation (Claude's replies
// look like anyone's, with its frames inline), Before/After and one Compare button,
// then Details (collapsed). The reply field and its actions stay pinned at the bottom.

struct ThreadView: View {
    @Bindable var model: ProjectModel
    var comment: ReviewComment
    var number: Int?
    @State private var reply = ""
    @State private var showDetails = false
    @FocusState private var replyFocused: Bool

    var body: some View {
        let c = comment
        let state = CommentState(c)
        VStack(spacing: 0) {
            navigationBar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: StudioStyle.Space.l) {
                    header(c, state)
                    if state == .claudeOnIt, isLive(c) { working(c) }
                    VStack(alignment: .leading, spacing: StudioStyle.Space.m) {
                        message(c.author, c.body, c.createdAt, attachments: [])
                        ForEach(c.replies) { r in
                            if ReviewStyle.isStudioNote(r.author) { note(r.body) }
                            else { message(r.author, r.body, r.createdAt, attachments: r.attachments) }
                        }
                    }
                    outcome(c, state)
                    if model.ui.compare == nil { frames(c) }
                    details(c)
                }
                .padding(StudioStyle.Space.gutter)
            }
            Divider()
            composer(c, state)
        }
    }

    // MARK: Sections

    private var navigationBar: some View {
        HStack(spacing: StudioStyle.Space.xs) {
            Button {
                withAnimation(.smooth(duration: 0.2)) { model.review.threadOpen = false }
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: StudioStyle.Symbol.back)
                    Text("Comments")
                }
                .font(StudioStyle.Fonts.body)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.leftArrow, modifiers: [.command])
            .help("Back to all comments (⌘←)")
            Spacer()
            Button { model.perform(.selectComment(next: false)) } label: { Image(systemName: StudioStyle.Symbol.previous) }
                .help("Previous comment ([)")
            Button { model.perform(.selectComment(next: true)) } label: { Image(systemName: StudioStyle.Symbol.next) }
                .help("Next comment (])")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, StudioStyle.Space.m)
        .frame(height: 36)
    }

    /// Disc and time, the status menu, and the source file under them.
    private func header(_ c: ReviewComment, _ state: CommentState) -> some View {
        VStack(alignment: .leading, spacing: StudioStyle.Space.xs) {
            HStack(alignment: .center, spacing: 10) {
                CommentDisc(number: number, state: state, size: 28)
                Text(StudioTime.range(c.t, c.end))
                    .font(StudioStyle.Fonts.title)
                    .monospacedDigit()
                    .fixedSize()
                    .help(StudioTime.frameHelp(c.t, fps: c.canvas?.fps ?? model.info?.fps ?? 60))
                Spacer(minLength: StudioStyle.Space.s)
                StatusMenu(state: state) { choice in setStatus(c, choice) }
            }
            if let src = c.source {
                Button { SourceOpener.open(src) } label: {
                    HStack(spacing: StudioStyle.Space.xs) {
                        Text(ReviewStyle.file(src)).lineLimit(1).truncationMode(.middle)
                        Image(systemName: StudioStyle.Symbol.reveal).imageScale(.small)
                    }
                    .font(StudioStyle.Fonts.subheadline)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.leading, 38)
                .help("Open \(ReviewStyle.short(src))")
            }
        }
    }

    private func isLive(_ c: ReviewComment) -> Bool {
        model.agent.isRunning && (model.agent.currentRun?.commentIDs.contains(c.id) ?? false)
    }

    /// "Claude's on it · 0:42" with Stop and Show Steps, while a live run holds this comment.
    @ViewBuilder
    private func working(_ c: ReviewComment) -> some View {
        let agent = model.agent
        let live = agent.isRunning && (agent.currentRun?.commentIDs.contains(c.id) ?? false)
        HStack(spacing: StudioStyle.Space.s) {
            AuthorAvatar(author: AgentController.agentAuthor, size: 22)
            ProgressView().controlSize(.small)
            if live, let run = agent.currentRun {
                SwiftUI.TimelineView(.periodic(from: run.startedAt, by: 1)) { ctx in
                    Text("Claude's on it · \(AgentController.duration(ctx.date.timeIntervalSince(run.startedAt)))")
                        .monospacedDigit()
                }
            } else {
                Text("Claude's on it")
            }
            Spacer(minLength: StudioStyle.Space.xs)
            if live {
                Button("Stop") { model.perform(.stop) }
                Button("Show Steps") { model.ui.showAgentPanel = true; model.ui.agentPanelClosed = false }
            }
        }
        .font(StudioStyle.Fonts.callout)
        .foregroundStyle(.secondary)
        .controlSize(.small)
        .padding(StudioStyle.Space.s)
        .background(StudioStyle.well, in: StudioStyle.rounded(StudioStyle.Radius.medium))
    }

    private func message(_ a: ReviewAuthor, _ body: String, _ date: Date, attachments: [ReviewAttachment]) -> some View {
        HStack(alignment: .top, spacing: StudioStyle.Space.s) {
            AuthorAvatar(author: a, size: 24)
            VStack(alignment: .leading, spacing: StudioStyle.Space.xs) {
                HStack(spacing: 6) {
                    Text(ReviewStyle.displayName(a)).font(StudioStyle.Fonts.subheadline.weight(.semibold))
                    Text(ReviewStyle.age(date)).font(StudioStyle.Fonts.footnote).foregroundStyle(.tertiary)
                        .help(date.formatted(date: .abbreviated, time: .shortened))
                }
                Text(body)
                    .font(StudioStyle.Fonts.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(StudioStyle.bubble, in: StudioStyle.rounded(StudioStyle.Radius.large))
                ForEach(attachments, id: \.path) { att in
                    AttachmentThumb(model: model, attachment: att, commentID: comment.id, width: 168)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// Studio's own notes ("back on your list"): a quiet line, not a message.
    private func note(_ body: String) -> some View {
        Text(body)
            .font(StudioStyle.Fonts.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
            .padding(.horizontal, StudioStyle.Space.s)
    }

    @ViewBuilder
    private func outcome(_ c: ReviewComment, _ state: CommentState) -> some View {
        switch state {
        case .readyForReview:
            VStack(alignment: .leading, spacing: StudioStyle.Space.xs) {
                Label("Ready for review", systemImage: "checkmark.circle")
                    .font(StudioStyle.Fonts.calloutEmphasis).foregroundStyle(StudioStyle.accent)
                Text(c.resolution.map { "Claude says: \($0). Have a look, then tell Claude if it's right." }
                     ?? "Have a look, then tell Claude if it's right.")
                    .font(StudioStyle.Fonts.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .done:
            if let by = c.acceptedBy {
                Label("\(by.name) signed off", systemImage: "checkmark.circle.fill")
                    .font(StudioStyle.Fonts.subheadline).foregroundStyle(.secondary)
            }
            if let res = c.resolution, !res.isEmpty {
                Text(res).font(StudioStyle.Fonts.subheadline).foregroundStyle(.secondary)
            }
        case .wontFix:
            if let res = c.resolution, !res.isEmpty {
                Label(res, systemImage: "minus.circle").font(StudioStyle.Fonts.subheadline).foregroundStyle(.secondary)
            }
        case .inProgress:
            if let who = c.assignee {
                Label("\(who.name) is working on this", systemImage: "circle.lefthalf.filled")
                    .font(StudioStyle.Fonts.subheadline).foregroundStyle(.secondary)
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func frames(_ c: ReviewComment) -> some View {
        let before = c.beforeAttachment
        let after = c.latestAfter
        if let before {
            VStack(alignment: .leading, spacing: StudioStyle.Space.s) {
                HStack(alignment: .top, spacing: StudioStyle.Space.s) {
                    AttachmentThumb(model: model, attachment: before, commentID: c.id, width: 112)
                    if let after {
                        AttachmentThumb(model: model, attachment: after, commentID: c.id, width: 112)
                    } else {
                        VStack(spacing: 2) {
                            Text("After").font(StudioStyle.Fonts.footnoteEmphasis)
                            Text("Current build").font(StudioStyle.Fonts.footnote)
                        }
                        .foregroundStyle(.secondary)
                        .frame(width: 112, height: 63)
                        .background(StudioStyle.well, in: StudioStyle.rounded(StudioStyle.Radius.small))
                    }
                }
                Button("Compare") {
                    model.review.compareID = c.id
                    model.ui.compare = model.ui.compare ?? .split
                }
                .help("Compare before and after in the viewer (\\)")
            }
        }
    }

    private func details(_ c: ReviewComment) -> some View {
        DisclosureGroup("Details", isExpanded: $showDetails) {
            let size = CGSize(width: c.canvas?.width ?? model.info?.width ?? 1920, height: c.canvas?.height ?? model.info?.height ?? 1080)
            VStack(alignment: .leading, spacing: StudioStyle.Space.xs) {
                if let r = c.region {
                    let p = RegionMath.scenePoints(r, sceneSize: size)
                    fact("Spot", RegionMath.isPoint(r) ? "Point at \(Int(p.minX)), \(Int(p.minY))"
                                                       : "\(Int(p.width)) × \(Int(p.height)) at \(Int(p.minX)), \(Int(p.minY))")
                }
                fact("Time", StudioTime.frameHelp(c.t, fps: c.canvas?.fps ?? model.info?.fps ?? 60))
                if let src = c.source { fact("Source", ReviewStyle.short(src)) }
                if let rev = c.revision { fact("Revision", rev) }
                if let cv = c.canvas { fact("Canvas", "\(cv.width) × \(cv.height), \(cv.fps) fps") }
                fact("ID", c.id)
            }
            .padding(.top, StudioStyle.Space.xs)
        }
        .font(StudioStyle.Fonts.subheadline)
        .foregroundStyle(.secondary)
    }

    private func fact(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            Text(v).foregroundStyle(.primary).textSelection(.enabled).monospacedDigit()
        }
        .font(StudioStyle.Fonts.subheadline)
    }

    private func composer(_ c: ReviewComment, _ state: CommentState) -> some View {
        VStack(alignment: .leading, spacing: StudioStyle.Space.s) {
            TextField(state == .readyForReview || state.isSettled ? "Reply, or say what's still off…" : "Reply…",
                      text: $reply, axis: .vertical)
                .lineLimit(1...5)
                .font(StudioStyle.Fonts.callout)
                .focused($replyFocused)
                .studioField(focused: replyFocused)
                .onSubmit(send)
            if ReviewController.mentionsAgent(reply) {
                Text("Claude will pick this up next time you ask.")
                    .font(StudioStyle.Fonts.footnote).foregroundStyle(.secondary)
            }
            HStack(spacing: StudioStyle.Space.s) {
                switch state {
                case .readyForReview:
                    Button("Not Quite") { reopen(c) }
                    Spacer(minLength: 0)
                    Button("Looks Good") { act { try model.review.accept(c.id) } }
                        .buttonStyle(.borderedProminent)
                case .done, .wontFix:
                    Button("Reopen") { reopen(c) }
                    Spacer(minLength: 0)
                case .open, .inProgress, .claudeOnIt:
                    Button("Mark Done") { act { try model.review.markDone(c.id, resolution: trimmed.isEmpty ? nil : trimmed) }; reply = "" }
                    Button("Won't Fix") { act { try model.review.setStatus(c.id, .wontFix, resolution: trimmed.isEmpty ? nil : trimmed) }; reply = "" }
                    Spacer(minLength: 0)
                    Button("Ask Claude") {
                        if !trimmed.isEmpty { send() }
                        model.review.selection = c.id
                        model.perform(.askAgent)
                    }
                    .keyboardShortcut(model.review.draft == nil ? KeyboardShortcut(.return, modifiers: [.command, .shift]) : nil)
                    .help("Ask Claude about this comment (⌘⇧↩)")
                }
            }
            .controlSize(.regular)
        }
        .padding(StudioStyle.Space.gutter)
    }

    // MARK: Actions

    private var trimmed: String { reply.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func setStatus(_ c: ReviewComment, _ choice: StatusChoice) {
        act {
            switch choice {
            case .open: try model.review.reopen(c.id, note: nil)
            case .inProgress: try model.review.setStatus(c.id, .inProgress)
            case .done: try model.review.markDone(c.id, resolution: nil)
            case .wontFix: try model.review.setStatus(c.id, .wontFix)
            }
        }
    }

    private func send() {
        guard !trimmed.isEmpty else { return }
        act { try model.review.reply(comment.id, trimmed) }
        reply = ""
    }

    private func reopen(_ c: ReviewComment) {
        act { try model.review.reopen(c.id, note: trimmed) }
        reply = ""
    }

    private func act(_ f: () throws -> Void) {
        do { try f() } catch { model.ui.toast = "That didn't work. \(error)" }
    }
}
