import SwiftUI
import SwiftRenderKit

// MARK: - Comment composer   // S6
//
// One composer for every entry point (C, R/⌥-drag, timeline, toolbar). Region drafts
// float next to their rect in the viewer; time-only drafts sit atop the Comments tab.
// Post ⌘↩ · Post & Ask Claude ⌘⇧↩ · Esc cancels. The text lives in `review.draft`
// so the draft survives switching tabs.

struct CommentComposer: View {
    @Bindable var model: ProjectModel
    /// Floating card (viewer) vs inline banner (inspector).
    var floating = false
    @FocusState private var focused: Bool
    @State private var posting = false

    var body: some View {
        if let draft = model.review.draft {
            VStack(alignment: .leading, spacing: 8) {
                header(draft)
                TextField("What should change?", text: Binding(
                    get: { model.review.draft?.body ?? "" },
                    set: { model.review.draft?.body = $0 }), axis: .vertical)
                    .lineLimit(2...6)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .padding(7)
                    .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(focused ? 0.25 : 0.1)))
                    .focused($focused)
                    .onExitCommand { model.review.draft = nil }
                if ReviewController.mentionsAgent(draft.body) {
                    Label("@claude queues this thread for the next run", systemImage: "sparkles")
                        .font(.system(size: 10)).foregroundStyle(ReviewStyle.agent)
                }
                HStack(spacing: 8) {
                    Image(systemName: "camera.viewfinder").font(.system(size: 10)).foregroundStyle(.tertiary)
                        .help("Posting saves this frame as the comment's BEFORE still")
                    Spacer(minLength: 4)
                    if posting { ProgressView().controlSize(.mini) }
                    Button("Post & Ask Claude") { post(ask: true) }
                        .keyboardShortcut(.return, modifiers: [.command, .shift])
                        .help("Post, then ask Claude about this thread (⌘⇧↩)")
                    Button("Post") { post(ask: false) }
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.borderedProminent)
                        .help("Post (⌘↩)")
                }
                .controlSize(.small)
                .disabled(posting || draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(10)
            .frame(width: floating ? 330 : nil)
            .background {
                if floating {
                    RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.13).opacity(0.97))
                        .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
                } else {
                    StudioStyle.accent.opacity(0.06)
                }
            }
            .overlay {
                if floating { RoundedRectangle(cornerRadius: 10).strokeBorder(StudioStyle.accent.opacity(0.35)) }
            }
            .onAppear { focused = true }
        }
    }

    private func header(_ d: CommentDraft) -> some View {
        HStack(spacing: 6) {
            Image(systemName: d.region == nil ? "text.bubble" : RegionMath.isPoint(d.region!) ? "mappin" : "rectangle.dashed")
                .foregroundStyle(StudioStyle.accent)
            Text("New comment").font(.system(size: 11.5, weight: .semibold))
            Text(timecode(d)).font(StudioStyle.monoSmall).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Button { model.review.draft = nil } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Cancel (Esc)")
        }
    }

    private func timecode(_ d: CommentDraft) -> String {
        let fps = model.info?.fps
        let a = "\(StudioStyle.timecode(d.t)) \(ReviewStyle.frame(d.t, fps: fps))"
        guard let e = d.end else { return a }
        return "\(StudioStyle.timecode(d.t))–\(StudioStyle.timecode(e))"
    }

    private func post(ask: Bool) {
        let text = model.review.draft?.body ?? ""
        posting = true
        Task {
            do {
                if try await model.review.postDraft(body: text, askAgent: ask) != nil {
                    model.ui.inspectorTab = .comments
                    model.ui.showInspector = true
                    if ask { model.perform(.askAgent) }
                }
            } catch {
                model.ui.toast = "Couldn't post: \(error)"
            }
            posting = false
        }
    }
}
