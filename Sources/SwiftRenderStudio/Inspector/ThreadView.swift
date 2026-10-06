import SwiftUI
import SwiftRenderKit

// MARK: - Thread   // S6
//
// Shell: header, body, replies, reply field, status buttons. S6 adds before/after
// thumbnails + Compare, clip source link, Accept/Reopen, Ask Claude (⌘⇧↩).

struct ThreadView: View {
    @Bindable var model: ProjectModel
    var comment: ReviewComment
    @State private var reply = ""

    var body: some View {
        let c = comment
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("\(c.id) · \(c.timecode)").font(StudioStyle.mono)
                    Spacer()
                    StudioBadge(text: c.status.rawValue, color: StudioStyle.color(c.status))
                }
                message(c.author, c.body, c.createdAt)
                ForEach(c.replies) { r in message(r.author, r.body, r.createdAt) }
                if let res = c.resolution {
                    Label(res, systemImage: "checkmark.seal").font(.caption).foregroundStyle(StudioStyle.ok)
                }
                TextField("Reply…", text: $reply, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                HStack {
                    Button("Resolve") { try? model.review.setStatus(c.id, .resolved) }
                    Button("Won't fix") { try? model.review.setStatus(c.id, .wontFix) }
                    Spacer()
                    Button { model.perform(.askAgent) } label: { Label("Ask Claude", systemImage: "sparkles") }
                }
                .controlSize(.small)
            }
            .padding(10)
        }
    }

    private func send() {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        try? model.review.reply(comment.id, text)
        reply = ""
    }

    private func message(_ a: ReviewAuthor, _ body: String, _ date: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if a.kind == .agent { Image(systemName: "sparkles").foregroundStyle(.purple) }
                Text(a.name).font(.caption.weight(.semibold))
                Text(date, style: .relative).font(.caption2).foregroundStyle(.tertiary)
            }
            Text(body).font(.callout).textSelection(.enabled)
        }
    }
}
