import SwiftUI
import SwiftRenderKit

// MARK: - Ask Claude sheet
//
// Which comments (and/or the build errors), what Claude should do, anything else it
// should know, and Options (what it can edit, model, spend limit, continuing the last
// session, the exact command), which remember the last choices. Pre-filled from the
// selected comment, then the queued ones, then every open one; a failed build pre-checks
// "Fix the build errors".

struct AskAgentSheet: View {
    @Bindable var model: ProjectModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("agentModel") private var agentModel = ""
    @AppStorage("agentBudgetUSD") private var budget = 2.0
    @AppStorage("agentScope") private var scopeRaw = AgentRequest.Scope.sceneFile.rawValue
    @AppStorage("ask.optionsExpanded") private var optionsExpanded = false
    @State private var picked: Set<String> = []
    @State private var fixBuild = false
    @State private var mode: AgentRequest.Mode = .fix
    @State private var resume = false
    @State private var extra = ""
    @State private var claude: URL??

    private static let models: [(String, String)] = [("", "Default"), ("sonnet", "Sonnet"), ("opus", "Opus"), ("haiku", "Haiku")]

    private var candidates: [ReviewComment] { model.review.comments.filter { $0.status.isActive } }
    private var buildErrors: [CompilerDiagnostic] { model.build.errors }
    private var scope: AgentRequest.Scope { AgentRequest.Scope(rawValue: scopeRaw) ?? .sceneFile }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: StudioStyle.Space.xs) {
                Text("Ask Claude").font(StudioStyle.Fonts.title)
                Text("Claude edits \(model.selectedScene ?? "this scene"). You'll see changes live as Studio rebuilds.")
                    .font(StudioStyle.Fonts.callout).foregroundStyle(.secondary)
            }
            .padding(.horizontal, StudioStyle.Space.xl).padding(.top, StudioStyle.Space.xl)

            Form {
                commentsSection
                Section("Claude Should") {
                    Picker("Claude Should", selection: $mode) {
                        ForEach(AgentRequest.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(modeHelp).font(StudioStyle.Fonts.subheadline).foregroundStyle(.secondary)
                }
                Section {
                    TextField("Anything else Claude should know? (optional)", text: $extra, axis: .vertical)
                        .lineLimit(2...4)
                        .labelsHidden()
                        .textFieldStyle(.plain)
                } header: {
                    Text("Anything Else")
                } footer: {
                    Text("Optional. For example: keep the colors, no new fonts.")
                        .font(StudioStyle.Fonts.subheadline).foregroundStyle(.secondary)
                }
                Section {
                    DisclosureGroup("Options", isExpanded: $optionsExpanded) { options }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            footer
        }
        .frame(width: 560, height: optionsExpanded ? 680 : 540)
        .onAppear(perform: prefill)
        // A build that fails (or recovers) while the sheet is open.
        .onChange(of: buildErrors.isEmpty) { _, clean in fixBuild = !clean }
        .task { claude = .some(await ToolPaths.resolve("claude")) }
    }

    // MARK: Sections

    private var commentsSection: some View {
        Section {
            if !buildErrors.isEmpty {
                Toggle(isOn: $fixBuild) {
                    HStack(spacing: StudioStyle.Space.s) {
                        Image(systemName: StudioStyle.Symbol.build).foregroundStyle(.secondary)
                        Text("Fix the build errors")
                        Spacer(minLength: StudioStyle.Space.s)
                        Text("\(buildErrors.count) error\(buildErrors.count == 1 ? "" : "s")").foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
                .help(buildErrors.first.map { "\(URL(fileURLWithPath: $0.file).lastPathComponent):\($0.line) \($0.message)" } ?? "")
            }
            if candidates.isEmpty && buildErrors.isEmpty {
                Text("No comments to fix yet. Press C on the video to leave one.")
                    .foregroundStyle(.secondary)
            }
            let numbers = ReviewController.numbering(model.review.comments)
            ForEach(candidates) { c in
                Toggle(isOn: Binding(get: { picked.contains(c.id) },
                                     set: { on in if on { picked.insert(c.id) } else { picked.remove(c.id) } })) {
                    HStack(spacing: StudioStyle.Space.s) {
                        CommentDisc(number: numbers[c.id], state: CommentState(c), size: 18)
                        Text(c.body).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: StudioStyle.Space.s)
                        Text(StudioTime.short(c.t)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .toggleStyle(.checkbox)
            }
        } header: {
            HStack {
                Text("Comments")
                Spacer()
                if candidates.count > 1 {
                    Button(picked.count == candidates.count ? "Select None" : "Select All") {
                        picked = picked.count == candidates.count ? [] : Set(candidates.map(\.id))
                    }
                    .buttonStyle(.link)
                    .font(StudioStyle.Fonts.subheadline)
                }
            }
        }
    }

    @ViewBuilder private var options: some View {
        Picker("Can Edit", selection: $scopeRaw) {
            Text("Just This Scene").tag(AgentRequest.Scope.sceneFile.rawValue)
            Text("Any File in Sources").tag(AgentRequest.Scope.sources.rawValue)
        }
        .disabled(mode != .fix)
        Picker("Model", selection: $agentModel) {
            ForEach(modelChoices, id: \.0) { Text($0.1).tag($0.0) }
        }
        TextField("Spend Up To", value: $budget, format: .currency(code: "USD"))
            .multilineTextAlignment(.trailing)
        Toggle("Pick up where Claude left off", isOn: $resume)
            .disabled(model.agent.lastSessionID == nil)
            .help(model.agent.lastSessionID == nil ? "Nothing to pick up yet in this window" : "Continues Claude's last conversation")
        LabeledContent("Command") {
            Text(ClaudeCodeBackend.commandLine(for: previewRequest))
                .font(StudioStyle.Fonts.codeSmall).foregroundStyle(.secondary)
                .lineLimit(3).truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private var modeHelp: String {
        switch mode {
        case .fix: return "Claude edits the scene, rebuilds, checks the frames, and leaves each comment ready for your review."
        case .plan: return "Claude explains a fix in the thread without changing any files."
        case .reply: return "Claude answers in the thread. Nothing else changes."
        }
    }

    private var footer: some View {
        HStack(spacing: StudioStyle.Space.s) {
            if case .some(.none) = claude {
                Label("Claude Code isn't installed yet. Install it, or set its location in Settings.", systemImage: StudioStyle.Symbol.warning)
                    .font(StudioStyle.Fonts.subheadline).foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if let blocker, model.agent.isRunning || !picked.isEmpty || fixBuild {
                Text(blocker).font(StudioStyle.Fonts.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Ask Claude") { ask() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canAsk)
                .help(blocker ?? "⌘↩")
        }
        .padding(.horizontal, StudioStyle.Space.xl).padding(.vertical, StudioStyle.Space.l)
    }

    // MARK: Logic

    private var modelChoices: [(String, String)] {
        var list = Self.models
        if !agentModel.isEmpty, !list.contains(where: { $0.0 == agentModel }) { list.append((agentModel, agentModel)) }
        return list
    }

    private var blocker: String? {
        if model.agent.isRunning { return "Claude's still working on the last one." }
        if picked.isEmpty && !(fixBuild && !buildErrors.isEmpty) { return "Pick a comment for Claude." }
        if fixBuild && mode != .fix && picked.isEmpty { return "To fix build errors, choose Fix It." }
        if !(budget > 0) { return "Set a spend limit above $0." }
        if case .some(.none) = claude { return "Claude Code isn't installed yet." }
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
        if !(budget > 0) { budget = 2 }
        let open = candidates.filter { $0.status == .open }
        // Threads posted with "Ask Claude" or that mention @claude ride along with the selection.
        let queued = model.review.agentQueue.filter { id in candidates.contains { $0.id == id } }
        if !buildErrors.isEmpty {
            fixBuild = true
            picked = Set(model.review.selection.map { [$0] } ?? []).union(queued)
        } else if let sel = model.review.selection, candidates.contains(where: { $0.id == sel }) {
            picked = Set([sel]).union(queued)
        } else if !queued.isEmpty {
            picked = queued
        } else {
            picked = Set(open.map(\.id))
        }
    }

    private func ask() {
        var r = previewRequest
        r.prompt = ""
        r.systemPrompt = ""
        model.agent.ask(r, info: model.info)
        model.review.clearAgentQueue()
        model.ui.showAgentPanel = true
        dismiss()
    }
}
