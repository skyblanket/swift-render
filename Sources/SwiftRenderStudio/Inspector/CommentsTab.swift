import AppKit
import SwiftUI
import SwiftRenderKit

// MARK: - Comments tab
//
// Segments (Open · Review · Done) and a Filter menu, search once there are more than
// five, the inline composer, then a native list numbered like the pins. Clicking a row
// (or Return, or a pin, or a lane marker) pushes its thread over the list; "‹ Comments"
// comes back. Selecting a row seeks to it.

struct CommentsTab: View {
    @Bindable var model: ProjectModel

    var body: some View {
        let review = model.review
        if review.threadOpen, let c = review.selected {
            ThreadView(model: model, comment: c, number: review.number(of: c.id))
                .id(c.id)
                .transition(.move(edge: .trailing))
        } else {
            list
        }
    }

    private var list: some View {
        let review = model.review
        let rows = review.filtered
        let numbers = ReviewController.numbering(review.comments)
        return VStack(spacing: 0) {
            header
            if let d = review.draft, d.region == nil || review.draftDocked {
                Divider()
                CommentComposer(model: model)
            }
            Divider()
            if rows.isEmpty {
                emptyState
            } else {
                List(selection: Binding(get: { review.selection }, set: { pick($0) })) {
                    ForEach(rows) { c in
                        CommentRow(comment: c, number: numbers[c.id], queued: review.agentQueue.contains(c.id))
                            .tag(c.id)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .contextMenu(forSelectionType: String.self) { ids in
                    if let id = ids.first, let c = review.comments.first(where: { $0.id == id }) { menu(c) }
                } primaryAction: { ids in
                    if let id = ids.first { review.open(id) }
                }
                .onDeleteCommand { if let id = review.selection { try? review.delete(id) } }
            }
            if let err = review.lastError {
                Label(err, systemImage: StudioStyle.Symbol.warning)
                    .font(StudioStyle.Fonts.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    .padding(.horizontal, StudioStyle.Space.gutter).padding(.vertical, StudioStyle.Space.xs)
            }
        }
    }

    /// A click opens the thread; arrow keys only move the selection (and the playhead).
    private func pick(_ id: String?) {
        let review = model.review
        review.selection = id
        guard let id, let c = review.comments.first(where: { $0.id == id }) else { return }
        model.playback.seek(c.t, precise: true)
        if let type = NSApp.currentEvent?.type, type == .leftMouseDown || type == .leftMouseUp {
            withAnimation(.smooth(duration: 0.2)) { review.open(id) }
        }
    }

    private var header: some View {
        let review = model.review
        return VStack(spacing: StudioStyle.Space.s) {
            HStack(spacing: StudioStyle.Space.s) {
                Picker("Show", selection: Binding(get: { review.query.segment }, set: { review.query.segment = $0 })) {
                    ForEach(ReviewSegment.allCases) { s in
                        let n = review.count(segment: s)
                        Text(s != .done && n > 0 ? "\(s.title) \(n)" : s.title).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                Menu {
                    Picker("From", selection: Binding(get: { review.query.author }, set: { review.query.author = $0 })) {
                        ForEach(AuthorFilter.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: review.query.author == .anyone ? StudioStyle.Symbol.filter : StudioStyle.Symbol.filterOn)
                        .foregroundStyle(review.query.author == .anyone ? AnyShapeStyle(.secondary) : AnyShapeStyle(StudioStyle.accent))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(review.query.author == .anyone ? "Filter by who wrote it" : "Showing comments from \(review.query.author.title)")
            }
            if review.comments.count > 5 {
                SearchField(text: Binding(get: { review.query.text }, set: { review.query.text = $0 }), prompt: "Search comments")
            }
        }
        .padding(.horizontal, StudioStyle.Space.gutter)
        .padding(.vertical, StudioStyle.Space.m)
    }

    @ViewBuilder private var emptyState: some View {
        let review = model.review
        if review.comments.isEmpty {
            StudioEmptyState(title: "No comments yet", symbol: StudioStyle.Symbol.comments,
                             message: "Press C to comment at the playhead, or R to mark a spot on the frame.",
                             actionTitle: "Add a Comment") { model.perform(.newComment) }
                .inspectorFill()
        } else if review.query.author != .anyone || !review.query.text.isEmpty {
            let hidden = ReviewQuery(segment: review.query.segment).apply(review.comments, me: review.authorName).count
            StudioEmptyState(title: "Nothing matches", symbol: StudioStyle.Symbol.filter,
                             message: hidden > 0 ? "\(hidden) comment\(hidden == 1 ? " is" : "s are") hidden by filters." : nil,
                             actionTitle: "Show All") {
                review.query.author = .anyone
                review.query.text = ""
            }
            .inspectorFill()
        } else {
            switch review.query.segment {
            case .open:
                StudioEmptyState(title: "You're all caught up", symbol: "checkmark.circle",
                                 message: "Nothing open here. Press C to add a comment.").inspectorFill()
            case .review:
                StudioEmptyState(title: "Nothing to review", symbol: "checkmark.circle",
                                 message: "When Claude finishes a comment, it waits here for your OK.").inspectorFill()
            case .done:
                StudioEmptyState(title: "Nothing done yet", symbol: "checkmark.circle",
                                 message: "Comments you mark done, or sign off, land here.").inspectorFill()
            }
        }
    }

    @ViewBuilder
    private func menu(_ c: ReviewComment) -> some View {
        let r = model.review
        Button("Open Thread") { r.open(c.id) }
        Button("Go to \(StudioTime.short(c.t))") { r.selection = c.id; model.playback.seek(c.t, precise: true) }
        if c.beforeAttachment != nil {
            Button("Compare") { r.selection = c.id; r.compareID = c.id; model.ui.compare = .split }
        }
        Divider()
        let state = CommentState(c)
        if state == .readyForReview { Button("Looks Good") { try? r.accept(c.id) } }
        if state.isActive { Button("Mark Done") { try? r.markDone(c.id, resolution: nil) } }
        if state.isActive { Button("Won't Fix") { try? r.setStatus(c.id, .wontFix) } }
        if !state.isActive { Button("Reopen") { try? r.reopen(c.id, note: nil) } }
        Divider()
        if let src = c.source { Button("Open \(ReviewStyle.file(src))") { SourceOpener.open(src) } }
        Button("Copy ID") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(c.id, forType: .string)
        }
        Divider()
        Button("Delete Comment", role: .destructive) { try? r.delete(c.id) }
    }
}

/// One comment in the list: its disc, who and when, the note, and its state.
struct CommentRow: View {
    var comment: ReviewComment
    var number: Int?
    var queued = false

    var body: some View {
        let c = comment
        let state = CommentState(c)
        HStack(alignment: .top, spacing: 10) {
            CommentDisc(number: number, state: state, size: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(ReviewStyle.displayName(c.author)).font(StudioStyle.Fonts.subheadline.weight(.semibold))
                    Text(StudioTime.range(c.t, c.end))
                        .font(StudioStyle.Fonts.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    if let r = c.region {
                        Image(systemName: RegionMath.isPoint(r) ? "mappin" : "viewfinder")
                            .font(StudioStyle.Fonts.footnote).foregroundStyle(.tertiary)
                            .help("Marks a spot on the frame")
                    }
                    Spacer(minLength: StudioStyle.Space.xs)
                    if state == .claudeOnIt { AuthorAvatar(author: AgentController.agentAuthor, size: 16) }
                    StatusLabel(state: state, font: StudioStyle.Fonts.footnote)
                }
                Text(c.body)
                    .font(StudioStyle.Fonts.callout)
                    .lineLimit(2)
                    .foregroundStyle(state.isSettled ? .secondary : .primary)
                let replies = c.replies.filter { !ReviewStyle.isStudioNote($0.author) }.count
                if replies > 0 || queued {
                    HStack(spacing: StudioStyle.Space.s) {
                        if replies > 0 { Text(ReviewStyle.replies(replies)) }
                        if queued { Text("Claude's up next") }
                    }
                    .font(StudioStyle.Fonts.footnote)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

/// A native search field (`NSSearchField`) bound to a string.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var prompt: String

    func makeNSView(context: Context) -> NSSearchField {
        let f = NSSearchField()
        f.placeholderString = prompt
        f.controlSize = .regular
        f.sendsSearchStringImmediately = true
        f.delegate = context.coordinator
        return f
    }

    func updateNSView(_ f: NSSearchField, context: Context) {
        if f.stringValue != text { f.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ n: Notification) {
            if let f = n.object as? NSSearchField { text.wrappedValue = f.stringValue }
        }
    }
}
