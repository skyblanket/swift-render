import SwiftUI
import SwiftRenderKit

// MARK: - Thread   // S6
//
// Header (number, timecode, frame, status menu), where the note points (region in
// scene points, clip source ↗, revision, canvas), BEFORE/AFTER thumbnails with
// Compare, the conversation (agent replies in violet bubbles, their frames inline),
// resolution and sign-off, then reply + actions. A resolved thread offers Accept /
// Reopen; Reopen sends the reply text as the reason. `@claude` queues the thread.

struct ThreadView: View {
    @Bindable var model: ProjectModel
    var comment: ReviewComment
    var number: Int?
    @State private var reply = ""

    var body: some View {
        let c = comment
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header(c)
                facts(c)
                attachments(c)
                Divider().opacity(0.5)
                message(c.author, c.body, c.createdAt, attachments: [])
                ForEach(c.replies) { r in message(r.author, r.body, r.createdAt, attachments: r.attachments) }
                outcome(c)
                composer(c)
                actions(c)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
        }
    }

    // MARK: Sections

    private func header(_ c: ReviewComment) -> some View {
        HStack(spacing: 7) {
            CommentBadge(number: number, status: c.status, agent: c.author.kind == .agent, selected: true, size: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(c.timecode).font(.system(size: 13, weight: .semibold, design: .monospaced))
                HStack(spacing: 5) {
                    Text(ReviewStyle.frame(c.t, fps: c.canvas?.fps ?? model.info?.fps))
                    Text("·")
                    Text(c.id).textSelection(.enabled)
                }
                .font(StudioStyle.monoSmall).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            StatusMenu(status: c.status) { s in act { try model.review.setStatus(c.id, s) } }
        }
    }

    @ViewBuilder
    private func facts(_ c: ReviewComment) -> some View {
        let size = CGSize(width: c.canvas?.width ?? model.info?.width ?? 1920,
                          height: c.canvas?.height ?? model.info?.height ?? 1080)
        VStack(alignment: .leading, spacing: 4) {
            if let r = c.region {
                fact(RegionMath.isPoint(r) ? "mappin" : "rectangle.dashed", RegionMath.describe(r, sceneSize: size))
            }
            HStack(spacing: 10) {
                if let src = c.source {
                    Button { SourceOpener.open(src) } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                            Text(ReviewStyle.short(src))
                            Image(systemName: "arrow.up.forward").font(.system(size: 8, weight: .bold))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(StudioStyle.accent)
                    .help("Open \(src.file):\(src.line)")
                }
                if let rev = c.revision { fact("arrow.triangle.branch", rev) }
                if let cv = c.canvas { fact("aspectratio", "\(cv.width)×\(cv.height)@\(cv.fps)") }
            }
        }
        .font(.system(size: 10.5, design: .monospaced))
    }

    private func fact(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9)).frame(width: 12)
            Text(text).lineLimit(1).truncationMode(.middle)
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func attachments(_ c: ReviewComment) -> some View {
        let before = c.beforeAttachment
        let after = c.latestAfter
        if before != nil || after != nil {
            HStack(alignment: .bottom, spacing: 8) {
                if let before { AttachmentThumb(model: model, attachment: before, commentID: c.id, width: 116) }
                if let after {
                    AttachmentThumb(model: model, attachment: after, commentID: c.id, width: 116)
                } else if before != nil {
                    placeholderAfter(c)
                }
            }
            if before != nil {
                Button {
                    model.review.compareID = c.id
                    model.ui.compare = model.ui.compare ?? .split
                } label: {
                    Label(after == nil ? "Compare with Live" : "Compare Before / After", systemImage: "rectangle.split.2x1")
                }
                .controlSize(.small)
                .help("A/B compare in the viewer (\\)")
            }
        }
    }

    private func placeholderAfter(_ c: ReviewComment) -> some View {
        VStack(spacing: 3) {
            Image(systemName: "bolt.fill").font(.system(size: 11))
            Text("AFTER = LIVE").font(.system(size: 8.5, weight: .bold, design: .rounded))
            Text("gen \(model.host.generation)").font(.system(size: 8.5, design: .monospaced))
        }
        .foregroundStyle(.tertiary)
        .frame(width: 116, height: 116 * 9 / 16)
        .background(RoundedRectangle(cornerRadius: 5).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .foregroundStyle(.white.opacity(0.15)))
    }

    private func message(_ a: ReviewAuthor, _ body: String, _ date: Date, attachments: [ReviewAttachment]) -> some View {
        let agent = a.kind == .agent
        return HStack(alignment: .top, spacing: 8) {
            AuthorAvatar(author: a, size: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(a.name).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(agent ? ReviewStyle.agent : .primary)
                    if agent { StudioBadge(text: "AGENT", color: ReviewStyle.agent) }
                    Text(ReviewStyle.age(date)).font(.system(size: 10)).foregroundStyle(.tertiary)
                        .help(date.formatted(date: .abbreviated, time: .standard))
                }
                Text(body).font(.system(size: 12)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(attachments, id: \.path) { att in
                    AttachmentThumb(model: model, attachment: att, commentID: comment.id, width: 150)
                        .padding(.top, 2)
                }
            }
            .padding(agent ? 8 : 0)
            .background(agent ? ReviewStyle.agentFill : .clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(agent ? RoundedRectangle(cornerRadius: 8).strokeBorder(ReviewStyle.agent.opacity(0.25)) : nil)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func outcome(_ c: ReviewComment) -> some View {
        if let res = c.resolution, !res.isEmpty {
            Label(res, systemImage: c.status == .wontFix ? "minus.circle" : "checkmark.seal")
                .font(.system(size: 11)).foregroundStyle(c.status == .wontFix ? .secondary : StudioStyle.ok)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let by = c.acceptedBy {
            Label("Accepted by \(by.name)", systemImage: "checkmark.seal.fill")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(StudioStyle.ok)
        } else if c.status == .inProgress, let who = c.assignee {
            Label("\(who.name) is working on this", systemImage: who.kind == .agent ? "sparkles" : "hammer")
                .font(.system(size: 11)).foregroundStyle(who.kind == .agent ? ReviewStyle.agent : .secondary)
        }
    }

    private func composer(_ c: ReviewComment) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            TextField(c.status == .resolved ? "Reply, or say why to reopen…" : "Reply…", text: $reply, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(7)
                .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.1)))
                .onSubmit(send)
            if ReviewController.mentionsAgent(reply) {
                Label("@claude queues this thread for the next run", systemImage: "sparkles")
                    .font(.system(size: 10)).foregroundStyle(ReviewStyle.agent)
            }
        }
    }

    @ViewBuilder
    private func actions(_ c: ReviewComment) -> some View {
        HStack(spacing: 6) {
            switch c.status {
            case .resolved:
                if c.acceptedBy == nil {
                    Button { act { try model.review.accept(c.id) } } label: { Label("Accept", systemImage: "checkmark") }
                        .buttonStyle(.borderedProminent).tint(StudioStyle.ok)
                }
                Button("Reopen") { reopen(c) }
            case .wontFix:
                Button("Reopen") { reopen(c) }
            case .open, .inProgress:
                Button("Resolve") { act { try model.review.setStatus(c.id, .resolved, resolution: trimmed.isEmpty ? nil : trimmed) }; reply = "" }
                Button("Won't Fix") { act { try model.review.setStatus(c.id, .wontFix, resolution: trimmed.isEmpty ? nil : trimmed) }; reply = "" }
            }
            Spacer(minLength: 4)
            if c.status.isActive {
                Button {
                    model.review.selection = c.id
                    model.perform(.askAgent)
                } label: { Label("Ask Claude", systemImage: "sparkles") }
                    .tint(ReviewStyle.agent)
                    .keyboardShortcut(model.review.draft == nil ? KeyboardShortcut(.return, modifiers: [.command, .shift]) : nil)
                    .help("Ask Claude about this thread (⌘⇧↩)")
            }
        }
        .controlSize(.small)
    }

    // MARK: Actions

    private var trimmed: String { reply.trimmingCharacters(in: .whitespacesAndNewlines) }

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
        do { try f() } catch { model.ui.toast = "\(error)" }
    }
}
