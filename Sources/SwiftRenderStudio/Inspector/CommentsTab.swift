import AppKit
import SwiftUI
import SwiftRenderKit

// MARK: - Comments tab   // S6
//
// Search + author menu, status chips (open / working / resolved / won't fix, with
// counts), the time-only composer, the list (numbered like the pins, agent threads
// striped violet), then the selected thread. Selecting a row seeks to it.

struct CommentsTab: View {
    @Bindable var model: ProjectModel

    var body: some View {
        let review = model.review
        let rows = review.filtered
        let numbers = ReviewController.numbering(review.comments)
        VStack(spacing: 0) {
            filterBar
            Divider()
            if let d = review.draft, !d.anchoredInViewer {
                CommentComposer(model: model)
                Divider()
            }
            if rows.isEmpty {
                StudioEmptyState(title: review.comments.isEmpty ? "No Comments Yet" : "No Matching Comments",
                                 symbol: "text.bubble",
                                 message: review.comments.isEmpty
                                    ? "Press C to comment at the playhead, or R to mark a region on the frame."
                                    : "\(review.comments.count) comment\(review.comments.count == 1 ? "" : "s") hidden by the filters.")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(rows) { c in
                                let selected = review.selection == c.id
                                CommentRow(comment: c, number: numbers[c.id], fps: model.info?.fps,
                                           queued: review.agentQueue.contains(c.id))
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(rowBackground(c, selected: selected))
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        review.selection = c.id
                                        model.playback.seek(c.t, precise: true)
                                    }
                                    .contextMenu { menu(c) }
                                    .id(c.id)
                            }
                        }
                        .padding(.horizontal, 6).padding(.vertical, 6)
                    }
                    .onChange(of: review.selection) { _, id in
                        if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
                    }
                }
                // Capped while a thread is open so the thread gets the rest of the column.
                .frame(height: review.selected == nil ? nil : min(214, CGFloat(rows.count) * 80 + 12))
                .frame(maxHeight: review.selected == nil ? .infinity : nil)
                .onDeleteCommand { if let id = review.selection { try? review.delete(id) } }
            }
            if let c = review.selected {
                Divider()
                ThreadView(model: model, comment: c, number: numbers[c.id])
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            if let err = review.lastError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(StudioStyle.warn).lineLimit(2)
                    .padding(.horizontal, 10).padding(.vertical, 4)
            }
        }
    }

    private var filterBar: some View {
        let review = model.review
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(.tertiary)
                    TextField("Search comments", text: Binding(get: { review.query.text }, set: { review.query.text = $0 }))
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5))
                    if !review.query.text.isEmpty {
                        Button { review.query.text = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
                Menu {
                    Picker("Author", selection: Binding(get: { review.query.author }, set: { review.query.author = $0 })) {
                        ForEach(AuthorFilter.allCases) { a in
                            Label(a.title, systemImage: symbol(a)).tag(a)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(review.query.author.title, systemImage: symbol(review.query.author))
                        .font(.system(size: 10.5))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .foregroundStyle(review.query.author == .agent ? ReviewStyle.agent : .secondary)
                .help("Filter by author")
                Button { model.perform(.newComment) } label: { Image(systemName: "plus.bubble") }
                    .buttonStyle(.borderless)
                    .help("New comment at the playhead (C)")
            }
            HStack(spacing: 4) {
                ForEach(ReviewStatus.allCases, id: \.self) { s in
                    StatusChip(status: s, count: review.count(s), on: review.query.statuses.contains(s)) {
                        review.toggleStatus(s)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    private func symbol(_ a: AuthorFilter) -> String {
        switch a {
        case .anyone: return "person.2"
        case .people: return "person"
        case .agent: return "sparkles"
        case .mine: return "person.crop.circle"
        }
    }

    @ViewBuilder
    private func menu(_ c: ReviewComment) -> some View {
        let r = model.review
        Button("Go to \(StudioStyle.timecode(c.t))") { r.selection = c.id; model.playback.seek(c.t, precise: true) }
        if c.beforeAttachment != nil {
            Button("Compare Before / After") { r.selection = c.id; r.compareID = c.id; model.ui.compare = .split }
        }
        Divider()
        ForEach(ReviewStatus.allCases.filter { $0 != c.status }, id: \.self) { s in
            Button("Mark \(ReviewStyle.title(s))") { try? r.setStatus(c.id, s) }
        }
        if c.status == .resolved, c.acceptedBy == nil { Button("Accept Resolution") { try? r.accept(c.id) } }
        Divider()
        if let src = c.source { Button("Open \(ReviewStyle.short(src))") { SourceOpener.open(src) } }
        Button("Copy ID") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(c.id, forType: .string)
        }
        Divider()
        Button("Delete Comment", role: .destructive) { try? r.delete(c.id) }
    }
}

/// Violet edge + wash behind rows an agent wrote, claimed or answered.
private struct AgentStripe: View {
    var body: some View {
        HStack(spacing: 0) {
            ReviewStyle.agent.frame(width: 2.5)
            ReviewStyle.agentFill
        }
    }
}

extension CommentsTab {
    @ViewBuilder
    fileprivate func rowBackground(_ c: ReviewComment, selected: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7)
        ZStack {
            if ReviewQuery.involvesAgent(c) { AgentStripe().clipShape(shape) }
            if selected {
                shape.fill(Color.white.opacity(0.10))
                shape.strokeBorder(Color.white.opacity(0.14))
            }
        }
    }
}

struct CommentRow: View {
    var comment: ReviewComment
    var number: Int?
    var fps: Int?
    var queued = false

    var body: some View {
        let c = comment
        let agent = ReviewQuery.involvesAgent(c)
        HStack(alignment: .top, spacing: 8) {
            CommentBadge(number: number, status: c.status, agent: c.author.kind == .agent, size: 18)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(c.timecode).font(StudioStyle.mono)
                    if let r = c.region {
                        Image(systemName: RegionMath.isPoint(r) ? "mappin" : "rectangle.dashed")
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if c.assignee?.kind == .agent, c.status == .inProgress {
                        Label("Claude working", systemImage: "sparkles")
                            .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(ReviewStyle.agent)
                    } else if c.author.kind == .agent {
                        Label(c.author.name, systemImage: "sparkles")
                            .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(ReviewStyle.agent)
                    } else {
                        Text(c.author.name).font(.system(size: 9.5)).foregroundStyle(.secondary)
                    }
                }
                Text(c.body).font(.system(size: 12)).lineLimit(2).foregroundStyle(c.status.isActive ? .primary : .secondary)
                HStack(spacing: 8) {
                    Text(c.id).font(StudioStyle.monoSmall).foregroundStyle(.tertiary)
                    if !c.replies.isEmpty {
                        Label("\(c.replies.count)", systemImage: "arrowshape.turn.up.left")
                            .foregroundStyle(agent ? ReviewStyle.agent.opacity(0.85) : .secondary)
                    }
                    if !ReviewController.attachments(of: c).isEmpty {
                        Label("\(ReviewController.attachments(of: c).count)", systemImage: "photo")
                    }
                    if c.acceptedBy != nil { Label("Accepted", systemImage: "checkmark.seal.fill").foregroundStyle(StudioStyle.ok) }
                    if queued { Label("@claude", systemImage: "sparkles").foregroundStyle(ReviewStyle.agent) }
                }
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .labelStyle(CompactLabel())
            }
        }
        .padding(.vertical, 3)
        .opacity(c.status == .wontFix ? 0.7 : 1)
    }
}

/// Icon and text with a tight gap.
struct CompactLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) { configuration.icon; configuration.title }
    }
}
