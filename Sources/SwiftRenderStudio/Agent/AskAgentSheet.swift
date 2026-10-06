import SwiftUI
import SwiftRenderKit

// MARK: - Ask Claude sheet   // S8
//
// Shell: pick comments, mode, scope, budget, extra instructions → `AgentController.ask`.
// S8 adds model picker, "continue last session", fix-the-build prefill from
// diagnostics, and validation.

struct AskAgentSheet: View {
    @Bindable var model: ProjectModel
    @Environment(\.dismiss) private var dismiss
    @State private var picked: Set<String> = []
    @State private var mode: AgentRequest.Mode = .fix
    @State private var scope: AgentRequest.Scope = .sceneFile
    @State private var budget = 2.0
    @State private var extra = ""

    var body: some View {
        let open = model.review.comments.filter { $0.status.isActive }
        VStack(alignment: .leading, spacing: 14) {
            Label("Ask Claude", systemImage: "sparkles").font(.title3.weight(.semibold))
            GroupBox("Comments to address") {
                if open.isEmpty && model.build.errors.isEmpty {
                    Text("No open comments on this scene.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        if !model.build.errors.isEmpty {
                            Label("Fix the build (\(model.build.errors.count) errors)", systemImage: "hammer")
                        }
                        ForEach(open) { c in
                            Toggle(isOn: Binding(get: { picked.contains(c.id) },
                                                 set: { on in if on { picked.insert(c.id) } else { picked.remove(c.id) } })) {
                                HStack {
                                    Text(c.id).font(StudioStyle.monoSmall)
                                    Text(c.timecode).font(StudioStyle.monoSmall).foregroundStyle(.secondary)
                                    Text(c.body).lineLimit(1)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Picker("Mode", selection: $mode) {
                Text("Fix & resolve").tag(AgentRequest.Mode.fix)
                Text("Propose only (plan mode)").tag(AgentRequest.Mode.plan)
            }
            .pickerStyle(.radioGroup)
            Picker("Scope", selection: $scope) {
                Text("This scene's file").tag(AgentRequest.Scope.sceneFile)
                Text("Anything under Sources/").tag(AgentRequest.Scope.sources)
            }
            .pickerStyle(.radioGroup)
            HStack {
                Text("Budget")
                TextField("", value: $budget, format: .currency(code: "USD")).frame(width: 80)
            }
            TextField("Extra instructions (e.g. keep the amber palette; no new fonts)", text: $extra, axis: .vertical)
                .lineLimit(1...3)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Ask Claude") {
                    model.agent.ask(AgentRequest(project: model.project, scene: model.selectedScene ?? "",
                                                 commentIDs: Array(picked), mode: mode, scope: scope,
                                                 instructions: extra, budgetUSD: budget,
                                                 buildDiagnostics: model.build.errors))
                    model.ui.showAgentPanel = true
                    dismiss()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(picked.isEmpty && model.build.errors.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            picked = model.review.selection.map { [$0] } ?? Set(open.filter { $0.status == .open }.map(\.id))
        }
    }
}
