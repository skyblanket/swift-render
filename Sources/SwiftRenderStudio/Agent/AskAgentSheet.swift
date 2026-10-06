import SwiftUI
import SwiftRenderKit

// MARK: - Ask Claude sheet   // S8
//
// Pick comments (and/or "fix the build" when the last build failed), mode, scope,
// model, budget, continue-last-session and extra instructions → `AgentController.ask`.
// Pre-filled from the selected comment, else every open one; a failed build pre-checks
// "Fix the build" and nothing else. The footer shows the exact `claude` command.

struct AskAgentSheet: View {
    @Bindable var model: ProjectModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("agentModel") private var defaultModel = ""
    @AppStorage("agentBudgetUSD") private var defaultBudget = 2.0
    @State private var picked: Set<String> = []
    @State private var fixBuild = false
    @State private var mode: AgentRequest.Mode = .fix
    @State private var scope: AgentRequest.Scope = .sceneFile
    @State private var agentModel = ""
    @State private var budget = 2.0
    @State private var resume = false
    @State private var extra = ""
    @State private var showCommand = false
    @State private var claude: URL??

    private static let models: [(String, String)] = [("", "Default"), ("sonnet", "Sonnet"), ("opus", "Opus"), ("haiku", "Haiku")]

    private var candidates: [ReviewComment] { model.review.comments.filter { $0.status.isActive } }
    private var buildErrors: [CompilerDiagnostic] { model.build.errors }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                commentsBox
                options
                TextField("Extra instructions — e.g. keep the amber palette; no new fonts", text: $extra, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(18)
            Divider()
            footer
        }
        .frame(width: 600)
        .onAppear(perform: prefill)
        .task { claude = .some(await ToolPaths.resolve("claude")) }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.purple)
                .frame(width: 34, height: 34)
                .background(Color.purple.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                Text("Ask Claude").font(.system(size: 15, weight: .semibold))
                Text("swift-render-director · \(model.selectedScene ?? "no scene") · edits show up live as Studio rebuilds")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    private var commentsBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Address").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if candidates.count > 1 {
                    Button(picked.count == candidates.count ? "None" : "All") {
                        picked = picked.count == candidates.count ? [] : Set(candidates.map(\.id))
                    }
                    .buttonStyle(.link).font(.system(size: 11))
                }
            }
            VStack(spacing: 0) {
                if !buildErrors.isEmpty {
                    BuildRow(isOn: $fixBuild, errors: buildErrors, root: model.project.root)
                    if !candidates.isEmpty { Divider() }
                }
                if candidates.isEmpty && buildErrors.isEmpty {
                    Text("No open comments on this scene. Press C in the viewer to leave one.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(candidates) { c in
                            CommentPickRow(comment: c, isOn: Binding(
                                get: { picked.contains(c.id) },
                                set: { on in if on { picked.insert(c.id) } else { picked.remove(c.id) } }))
                            if c.id != candidates.last?.id { Divider().padding(.leading, 34) }
                        }
                    }
                }
                .frame(maxHeight: min(CGFloat(candidates.count) * 40, 200))
            }
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(StudioStyle.hairline))
        }
    }

    private var options: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                label("Mode")
                Picker("", selection: $mode) {
                    ForEach(AgentRequest.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 330)
                .help("Fix edits, rebuilds, verifies and resolves. Propose and Reply only write in the threads.")
            }
            GridRow {
                label("Scope")
                Picker("", selection: $scope) {
                    Text("This scene's file").tag(AgentRequest.Scope.sceneFile)
                    Text("Anything under Sources/").tag(AgentRequest.Scope.sources)
                }
                .pickerStyle(.radioGroup).horizontalRadioGroupLayout().labelsHidden()
                .disabled(mode != .fix)
            }
            GridRow {
                label("Model")
                HStack(spacing: 14) {
                    Picker("", selection: $agentModel) {
                        ForEach(modelChoices, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .labelsHidden().frame(width: 120)
                    Text("Budget").foregroundStyle(.secondary)
                    TextField("", value: $budget, format: .currency(code: "USD"))
                        .frame(width: 70).multilineTextAlignment(.trailing)
                    Toggle("Continue last session", isOn: $resume)
                        .disabled(model.agent.lastSessionID == nil)
                        .help(model.agent.lastSessionID.map { "Resume \($0.prefix(8)) with --resume" } ?? "No earlier run in this window")
                }
            }
        }
        .font(.system(size: 12))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showCommand {
                ScrollView(.horizontal) {
                    Text(ClaudeCodeBackend.commandLine(for: previewRequest))
                        .font(StudioStyle.monoSmall).foregroundStyle(.secondary)
                        .textSelection(.enabled).fixedSize().padding(8)
                }
                .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
            }
            HStack(spacing: 10) {
                Button { withAnimation(.snappy(duration: 0.2)) { showCommand.toggle() } } label: {
                    Label("Command", systemImage: showCommand ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.borderless).font(.system(size: 11))
                claudeStatus
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button { ask() } label: { Text("Ask Claude").frame(minWidth: 90) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAsk)
                    .help(blocker ?? "⌘↩")
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    @ViewBuilder private var claudeStatus: some View {
        switch claude {
        case .none:
            ProgressView().controlSize(.mini)
        case .some(.none):
            Label("claude not found — set its path in Settings", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11)).foregroundStyle(StudioStyle.warn)
        case .some(.some(let url)):
            Text(abbreviate(url.path)).font(StudioStyle.monoSmall).foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.middle)
        }
    }

    // MARK: Logic

    private var modelChoices: [(String, String)] {
        var list = Self.models
        if !defaultModel.isEmpty, !list.contains(where: { $0.0 == defaultModel }) { list.append((defaultModel, defaultModel)) }
        return list
    }

    private var blocker: String? {
        if model.agent.isRunning { return "An agent run is already in progress" }
        if picked.isEmpty && !(fixBuild && !buildErrors.isEmpty) { return "Pick at least one comment" }
        if fixBuild && mode != .fix && picked.isEmpty { return "Fixing the build needs Fix mode" }
        if !(budget > 0) { return "Set a budget above $0" }
        if case .some(.none) = claude { return "claude not found" }
        return nil
    }

    private var canAsk: Bool { blocker == nil }

    private var previewRequest: AgentRequest {
        var r = AgentRequest(project: model.project, scene: model.selectedScene ?? "",
                             commentIDs: candidates.map(\.id).filter(picked.contains), mode: mode, scope: scope,
                             instructions: extra, budgetUSD: budget, model: agentModel.isEmpty ? nil : agentModel,
                             resumeSessionID: resume ? model.agent.lastSessionID : nil,
                             buildDiagnostics: fixBuild && mode == .fix ? model.build.diagnostics : [])
        r.prompt = "<prompt>"
        r.systemPrompt = "<house rules>"
        return r
    }

    private func prefill() {
        agentModel = defaultModel
        budget = defaultBudget > 0 ? defaultBudget : 2
        let open = candidates.filter { $0.status == .open }
        if !buildErrors.isEmpty {
            fixBuild = true
            picked = model.review.selection.map { [$0] } ?? []
        } else if let sel = model.review.selection, candidates.contains(where: { $0.id == sel }) {
            picked = [sel]
        } else {
            picked = Set(open.map(\.id))
        }
    }

    private func ask() {
        var r = previewRequest
        r.prompt = ""
        r.systemPrompt = ""
        model.agent.ask(r, info: model.info)
        model.ui.showAgentPanel = true
        dismiss()
    }

    private func label(_ s: String) -> some View {
        Text(s).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }

    private func abbreviate(_ p: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }
}

private struct CommentPickRow: View {
    var comment: ReviewComment
    @Binding var isOn: Bool

    var body: some View {
        let c = comment
        Toggle(isOn: $isOn) {
            HStack(spacing: 8) {
                Image(systemName: StudioStyle.symbol(c.status)).foregroundStyle(StudioStyle.color(c.status))
                    .imageScale(.small)
                Text(c.id).font(StudioStyle.monoSmall).foregroundStyle(.secondary)
                Text(c.timecode).font(StudioStyle.monoSmall)
                    .frame(minWidth: 62, alignment: .leading)
                Image(systemName: c.region == nil ? "rectangle" : "rectangle.dashed")
                    .imageScale(.small).foregroundStyle(c.region == nil ? .quaternary : .secondary)
                Text(c.body).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 6)
                if !c.replies.isEmpty {
                    Label("\(c.replies.count)", systemImage: "bubble.left").labelStyle(.titleAndIcon)
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, 10).frame(height: 32)
    }
}

private struct BuildRow: View {
    @Binding var isOn: Bool
    var errors: [CompilerDiagnostic]
    var root: URL

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 8) {
                Image(systemName: "hammer.fill").foregroundStyle(StudioStyle.bad).imageScale(.small)
                Text("Fix the build").font(.system(size: 12, weight: .semibold))
                Text("\(errors.count) error\(errors.count == 1 ? "" : "s")").font(StudioStyle.monoSmall).foregroundStyle(StudioStyle.bad)
                if let first = errors.first {
                    Text(first.file.isEmpty ? first.message
                         : "\(URL(fileURLWithPath: first.file).lastPathComponent):\(first.line) \(first.message)")
                        .font(StudioStyle.monoSmall).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, 10).frame(height: 34)
        .background(StudioStyle.bad.opacity(0.07))
    }
}
