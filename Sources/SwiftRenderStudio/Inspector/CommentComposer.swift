import SwiftUI
import SwiftRenderKit

// MARK: - Comment composer
//
// One composer for every entry point (C, R/⌥-drag, timeline, toolbar). A region draft
// floats beside its spot in the viewer (never over it); a time-only draft, or a region
// with no room beside it, sits atop the Comments tab. Post ⌘↩ · Ask Claude ⌘⇧↩ · Esc
// cancels. The text lives in `review.draft`, so it survives switching tabs.

struct CommentComposer: View {
    @Bindable var model: ProjectModel
    /// Floating card (viewer) vs inline (inspector).
    var floating = false
    @FocusState private var focused: Bool
    @State private var posting = false

    var body: some View {
        if let draft = model.review.draft {
            VStack(alignment: .leading, spacing: StudioStyle.Space.s) {
                HStack(spacing: StudioStyle.Space.s) {
                    AuthorAvatar(author: ReviewAuthor(name: model.review.authorName), size: 22)
                    Text("New Comment · \(StudioTime.range(draft.t, draft.end))")
                        .font(StudioStyle.Fonts.calloutEmphasis)
                        .monospacedDigit()
                        .help(StudioTime.frameHelp(draft.t, fps: model.info?.fps ?? 60))
                    Spacer(minLength: StudioStyle.Space.xs)
                    Button { model.review.draft = nil } label: { Image(systemName: StudioStyle.Symbol.close) }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Cancel (Esc)")
                }
                TextField("What's off here?", text: Binding(
                    get: { model.review.draft?.body ?? "" },
                    set: { model.review.draft?.body = $0 }), axis: .vertical)
                    .lineLimit(2...6)
                    .font(StudioStyle.Fonts.body)
                    .focused($focused)
                    .studioField(focused: focused)
                    .onExitCommand { model.review.draft = nil }
                if ReviewController.mentionsAgent(draft.body) {
                    Text("Claude will pick this up next time you ask.")
                        .font(StudioStyle.Fonts.subheadline).foregroundStyle(.secondary)
                }
                HStack(spacing: StudioStyle.Space.s) {
                    if posting { ProgressView().controlSize(.small) }
                    Spacer(minLength: StudioStyle.Space.xs)
                    Button("Ask Claude") { post(ask: true) }
                        .keyboardShortcut(.return, modifiers: [.command, .shift])
                        .help("Post, then ask Claude about it (⌘⇧↩)")
                    Button("Post") { post(ask: false) }
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.borderedProminent)
                        .help("Saves this frame so you can compare before and after. (⌘↩)")
                }
                .disabled(posting || draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(floating ? StudioStyle.Space.m : StudioStyle.Space.gutter)
            .frame(width: floating ? RegionTool.composerSize.width : nil)
            .background {
                if floating {
                    StudioStyle.rounded(StudioStyle.Radius.large).fill(StudioStyle.raised)
                        .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
                }
            }
            .overlay {
                if floating { StudioStyle.rounded(StudioStyle.Radius.large).strokeBorder(StudioStyle.hairline) }
            }
            .onAppear { focused = true }
        }
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
                model.ui.toast = "Couldn't post that. \(error)"
            }
            posting = false
        }
    }
}
