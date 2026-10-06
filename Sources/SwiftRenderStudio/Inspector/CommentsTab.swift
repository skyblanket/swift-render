import SwiftUI
import SwiftRenderKit

// MARK: - Comments tab   // S6
//
// Shell: filter chips, list (status, id, timecode, region/range glyph, author,
// body), selection → seek, thread below. S6 adds search, the composer for
// `review.draft`, keyboard navigation, `@claude`, and context menus.

struct CommentsTab: View {
    @Bindable var model: ProjectModel

    var body: some View {
        let review = model.review
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(ReviewFilter.allCases) { f in
                    Button { review.filter = f } label: {
                        Text(chip(f))
                            .font(.system(size: 11, weight: review.filter == f ? .semibold : .regular))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(review.filter == f ? Color.accentColor.opacity(0.25) : .clear, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)

            if let draft = review.draft { DraftBanner(model: model, draft: draft) }

            if review.filtered.isEmpty {
                ContentUnavailableView {
                    Label(review.comments.isEmpty ? "No comments yet" : "Nothing here", systemImage: "text.bubble")
                } description: {
                    Text("Press C to comment at the playhead, or R to mark a region on the frame.")
                }
                .frame(maxHeight: .infinity)
            } else {
                List(selection: Binding(get: { review.selection }, set: { id in
                    review.selection = id
                    if let c = review.comments.first(where: { $0.id == id }) { model.playback.seek(c.t, precise: true) }
                })) {
                    ForEach(review.filtered) { c in
                        CommentRow(comment: c).tag(c.id)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 120, maxHeight: review.selected == nil ? .infinity : 220)
                if let c = review.selected {
                    Divider()
                    ThreadView(model: model, comment: c)
                }
            }
        }
    }

    private func chip(_ f: ReviewFilter) -> String {
        let r = model.review
        switch f {
        case .open: return "Open \(r.comments.filter { $0.status.isActive }.count)"
        case .all: return "All \(r.comments.count)"
        default: return f.title
        }
    }
}

struct CommentRow: View {
    var comment: ReviewComment

    var body: some View {
        let c = comment
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: StudioStyle.symbol(c.status)).foregroundStyle(StudioStyle.color(c.status))
                Text(c.id).font(StudioStyle.monoSmall).foregroundStyle(.secondary)
                Text(c.timecode).font(StudioStyle.monoSmall)
                if let r = c.region { Image(systemName: RegionMath.isPoint(r) ? "mappin" : "rectangle.dashed").imageScale(.small) }
                Spacer(minLength: 4)
                if c.author.kind == .agent || c.assignee?.kind == .agent {
                    Label("Claude", systemImage: "sparkles").font(.caption2).foregroundStyle(.purple)
                } else {
                    Text(c.author.name).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text(c.body).font(.callout).lineLimit(2)
        }
        .padding(.vertical, 2)
    }
}

/// The open composer (S6 replaces with the real composer).
struct DraftBanner: View {
    @Bindable var model: ProjectModel
    var draft: CommentDraft
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("New comment at \(draft.end.map { "\(StudioStyle.timecode(draft.t))–\(StudioStyle.timecode($0))" } ?? StudioStyle.timecode(draft.t))")
                    .font(.caption.weight(.semibold))
                if let r = draft.region { Text(RegionMath.isPoint(r) ? "· point" : "· region").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button { model.review.draft = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
            TextField("What should change?", text: $text, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Post") {
                    let d = draft, body = text
                    Task {
                        _ = try? await model.review.add(t: d.t, end: d.end, region: d.region, body: body)
                        model.review.draft = nil
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.08))
    }
}
