import SwiftUI

// MARK: - Render sheet   // S9
//
// Shell: preset, range, build, knobs, output → `RenderQueue.enqueue`. S9 adds frame
// counts, 9:16 gating on scene formats, output chooser, and validation.

struct RenderSheet: View {
    @Bindable var model: ProjectModel
    @Environment(\.dismiss) private var dismiss
    @State private var preset: RenderPreset = .master1080p60
    @State private var useRange = false
    @State private var build: BuildChoice = .optimized
    @State private var knobs: KnobChoice = .useLive

    var body: some View {
        let scene = model.selectedScene ?? "—"
        VStack(alignment: .leading, spacing: 14) {
            Text("Render \(scene)").font(.title3.weight(.semibold))
            Picker("Preset", selection: $preset) {
                ForEach(RenderPreset.allCases) { p in
                    Text(p.title).tag(p)
                }
            }
            .pickerStyle(.radioGroup)
            Text(preset.summary).font(.caption).foregroundStyle(.secondary)
            if let io = model.playback.inOut {
                Toggle("In→Out only \(StudioStyle.timecode(io.lowerBound))–\(StudioStyle.timecode(io.upperBound)) (audio mux skipped)",
                       isOn: $useRange)
            }
            Picker("Build", selection: $build) {
                Text("Optimized (release)").tag(BuildChoice.optimized)
                Text("Current debug build").tag(BuildChoice.currentDebug)
            }
            .pickerStyle(.segmented)
            Picker("Knobs", selection: $knobs) {
                Text("Use live values").tag(KnobChoice.useLive)
                Text("Save to file").tag(KnobChoice.saveToFile)
            }
            .pickerStyle(.segmented)
            LabeledContent("Output") {
                Text(RenderQueue.defaultOutput(project: model.project, scene: scene, preset: preset).path(percentEncoded: false))
                    .font(StudioStyle.monoSmall).lineLimit(1).truncationMode(.head)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Render") {
                    model.renders.enqueue(scene: scene, preset: preset, range: useRange ? model.playback.inOut : nil,
                                          build: build, knobs: knobs)
                    model.ui.showRenderActivity = true
                    dismiss()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(model.selectedScene == nil)
            }
        }
        .padding(20)
        .frame(width: 500)
        .onChange(of: preset) { _, p in build = p.prefersRelease ? .optimized : .currentDebug }
    }
}
