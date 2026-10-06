import AppKit
import UniformTypeIdentifiers
import SwiftUI
import SwiftRenderKit

// MARK: - Render sheet
//
// ┌ Render NeverHeard ─────────────────── 93.00 s · 60 fps · score ┐
// │ MASTER        SOCIAL        APP STORE        DRAFT              │
// │ [1080p60]     [9:16]        [886×1920]       [Preview]          │
// │ [4K UHD]      [1:1]         [1920×886]       [GIF]              │
// │ 1920×1080 · 60 fps · H.264 12 Mb/s · 5,580 frames · audio       │
// │ Range / Build / Knobs / Output [Change…]                        │
// │                                        [Cancel] [Render ⌘↩]    │
// └─────────────────────────────────────────────────────────────────┘
//
// App Store previews are only enabled for a 15–30 s scene or In→Out range; GIFs need
// ffmpeg. Presets that change the aspect warn (scenes are authored at 16:9) and offer
// to preview that canvas in the viewer first.

struct RenderSheet: View {
    @Bindable var model: ProjectModel
    @Environment(\.dismiss) private var dismiss
    @State private var preset: RenderPreset = .master1080p60
    @State private var useRange = false
    @State private var build: BuildChoice = .optimized
    @State private var knobs: KnobChoice = .useLive
    /// nil = the default name in `out/`.
    @State private var customOutput: URL?
    @State private var appeared = false

    private var scene: String { model.selectedScene ?? "—" }
    private var range: ClosedRange<Double>? { useRange ? model.playback.inOut : nil }

    private var sceneDuration: Double? { model.info?.duration }
    private var effectiveDuration: Double? {
        if let r = range { return r.upperBound - r.lowerBound }
        return sceneDuration
    }

    private var hasSoundtrack: Bool {
        model.scenes.first { $0.name == model.selectedScene }?.hasSoundtrack ?? false
    }

    private var savedKnobs: [String: KnobValue] {
        guard let s = model.selectedScene else { return [:] }
        return KnobFile.load(model.project.knobsURL(scene: s))
    }

    private var knobsDiffer: Bool { !model.knobValues.isEmpty && model.knobValues != savedKnobs }

    private var output: URL { customOutput ?? model.renders.defaultOutput(scene: scene, preset: preset) }

    private var problem: String? {
        if model.selectedScene == nil { return "Select a scene first." }
        return RenderQueue.problem(preset: preset, duration: sceneDuration, range: range,
                                   ffmpegAvailable: !model.renders.ffmpegResolved || model.renders.ffmpeg != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 14)
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                presetGrid
                presetDetail
                Divider()
                options
                notes
            }
            .padding(.horizontal, 22).padding(.vertical, 16)
            Divider()
            footer
                .padding(.horizontal, 22).padding(.vertical, 14)
        }
        .frame(width: 700)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            guard !appeared else { return }
            appeared = true
            preset = model.renders.lastPreset
            build = preset.prefersRelease ? .optimized : .currentDebug
            useRange = false
        }
        .onChange(of: preset) { _, p in
            build = p.prefersRelease && !useRange ? .optimized : .currentDebug
            if let old = customOutput, old.pathExtension != p.fileExtension {
                customOutput = old.deletingPathExtension().appendingPathExtension(p.fileExtension)
            }
            // A too-long scene with In/Out set: App Store presets need the range.
            if p.durationLimit != nil, model.playback.inOut != nil,
               p.durationProblem(sceneDuration ?? 0) != nil { useRange = true }
        }
        .onChange(of: useRange) { _, on in
            build = preset.prefersRelease && !on ? .optimized : .currentDebug
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "film.stack")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(StudioStyle.accent)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 4 }
            VStack(alignment: .leading, spacing: 3) {
                Text("Render \(scene)").font(.system(size: 17, weight: .semibold))
                Text(sceneLine).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var sceneLine: String {
        guard let info = model.info else { return "No scene loaded" }
        var parts = [String(format: "%.2f s", info.duration), "authored \(info.width)×\(info.height)"]
        parts.append(hasSoundtrack ? "scored" : "silent")
        if !info.knobs.isEmpty { parts.append("\(info.knobs.count) knob\(info.knobs.count == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    // MARK: Presets

    private var presetGrid: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(RenderPreset.Group.allCases, id: \.self) { g in
                VStack(alignment: .leading, spacing: 6) {
                    Text(g.rawValue.uppercased())
                        .font(.system(size: 9.5, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 2)
                    ForEach(RenderPreset.allCases.filter { $0.group == g }) { p in
                        PresetTile(preset: p, selected: p == preset,
                                   disabled: RenderQueue.problem(preset: p, duration: sceneDuration,
                                                                 range: p.durationLimit != nil ? model.playback.inOut : nil,
                                                                 ffmpegAvailable: !model.renders.ffmpegResolved || model.renders.ffmpeg != nil) != nil)
                            .onTapGesture { preset = p }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var presetDetail: some View {
        HStack(spacing: 6) {
            Text(preset.summary)
            if let d = effectiveDuration {
                Text("·")
                Text("\(Int((d * Double(preset.fps)).rounded()).formatted()) frames")
                Text("·")
                Text(String(format: "%.2f s", d))
            }
            Text("·")
            Text(audioLabel)
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var audioLabel: String {
        if preset.isGIF { return "no audio" }
        guard hasSoundtrack else { return "silent" }
        if range != nil { return model.renders.ffmpeg != nil ? "audio: score (muxed)" : "audio skipped" }
        return "audio: score"
    }

    // MARK: Options

    private var options: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 12) {
            GridRow {
                label("Range")
                Picker("", selection: $useRange) {
                    Text("Whole scene").tag(false)
                    if let io = model.playback.inOut {
                        Text("In→Out \(StudioStyle.timecode(io.lowerBound))–\(StudioStyle.timecode(io.upperBound))").tag(true)
                    } else {
                        Text("In→Out (set with I / O)").tag(true)
                    }
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                .labelsHidden()
                .disabled(model.playback.inOut == nil)
            }
            GridRow {
                label("Build")
                VStack(alignment: .leading, spacing: 4) {
                    Picker("", selection: $build) {
                        Text("Optimized (release)").tag(BuildChoice.optimized)
                        Text("Current debug build").tag(BuildChoice.currentDebug)
                    }
                    .pickerStyle(.radioGroup)
                    .horizontalRadioGroupLayout()
                    .labelsHidden()
                    Text(buildHint).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
            }
            GridRow {
                label("Knobs")
                if knobsDiffer {
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("", selection: $knobs) {
                            Text("Use live values").tag(KnobChoice.useLive)
                            Text("Save to file, then render").tag(KnobChoice.saveToFile)
                        }
                        .pickerStyle(.radioGroup)
                        .horizontalRadioGroupLayout()
                        .labelsHidden()
                        Text("Live values differ from .swift-render/knobs/\(scene).json.")
                            .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    }
                } else {
                    Text(savedKnobs.isEmpty ? "Scene defaults" : "\(savedKnobs.count) saved override\(savedKnobs.count == 1 ? "" : "s")")
                        .foregroundStyle(.secondary)
                }
            }
            GridRow {
                label("Output")
                HStack(spacing: 8) {
                    Text(model.renders.relativePath(output))
                        .font(StudioStyle.mono)
                        .lineLimit(1).truncationMode(.head)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Change…", action: chooseOutput).controlSize(.small)
                }
            }
        }
        .font(.system(size: 12))
    }

    private func label(_ s: String) -> some View {
        Text(s).foregroundStyle(.secondary).gridColumnAlignment(.trailing).frame(width: 52, alignment: .trailing)
    }

    private var buildHint: String {
        switch build {
        case .optimized:
            let exe = BuildController.canonical(model.project.root)
                .appendingPathComponent(".build/studio/release/\(model.project.config.product)")
            return FileManager.default.fileExists(atPath: exe.path)
                ? "Incremental release build first; renders 1.2–5× faster than debug."
                : "First release build compiles the whole package (a few minutes); later ones are incremental."
        case .currentDebug:
            return model.build.lastGoodExecutable == nil
                ? "Builds debug first (no live build yet)."
                : "Starts right away with the build the viewer is running."
        }
    }

    // MARK: Notes

    @ViewBuilder private var notes: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let problem {
                note(problem, symbol: "exclamationmark.octagon.fill", color: StudioStyle.bad)
            }
            if preset.changesAspect {
                HStack(spacing: 8) {
                    note("Lays the scene out at \(preset.sizeLabel); it was authored at 16:9.",
                         symbol: "aspectratio", color: StudioStyle.warn)
                    if let a = viewerAspect, model.aspect != a {
                        Button("Preview \(a.rawValue)") { Task { await model.setAspect(a) } }
                            .controlSize(.small)
                    }
                }
            }
            if range != nil, hasSoundtrack, !preset.isGIF, model.renders.ffmpeg == nil {
                note("In→Out renders skip the audio mux; install ffmpeg to keep the score.",
                     symbol: "speaker.slash", color: StudioStyle.warn)
            }
            if preset.group == .appStore, problem == nil {
                note("App Store Connect: 15–30 s, 30 fps, H.264 with an AAC score track.",
                     symbol: "checkmark.seal", color: StudioStyle.ok)
            }
        }
    }

    private var viewerAspect: AspectChoice? {
        switch preset {
        case .vertical9x16, .appStorePortrait: return .vertical
        case .square: return .square
        default: return nil
        }
    }

    private func note(_ text: String, symbol: String, color: Color) -> some View {
        Label {
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
        .font(.system(size: 11))
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Text("⌘R renders \(model.renders.lastPreset.title) again")
                .font(.system(size: 10.5)).foregroundStyle(.tertiary)
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Render") { render() }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(problem != nil)
        }
    }

    private func render() {
        guard let scene = model.selectedScene else { return }
        if knobsDiffer && knobs == .saveToFile { model.saveKnobs() }
        model.renders.enqueue(scene: scene, preset: preset, range: range, build: build,
                              knobs: knobsDiffer ? knobs : .saveToFile, output: customOutput)
        model.ui.showRenderActivity = true
        dismiss()
    }

    private func chooseOutput() {
        let panel = NSSavePanel()
        panel.directoryURL = output.deletingLastPathComponent()
        panel.nameFieldStringValue = output.lastPathComponent
        panel.allowedContentTypes = [preset.isGIF ? .gif : .mpeg4Movie]
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { customOutput = url }
    }
}

/// One preset: an aspect glyph, the name and its pixel size.
struct PresetTile: View {
    var preset: RenderPreset
    var selected: Bool
    var disabled: Bool

    var body: some View {
        HStack(spacing: 9) {
            AspectGlyph(width: preset.pixelSize.width, height: preset.pixelSize.height, highlighted: selected)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(preset.tileTitle)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.85)
                Text("\(preset.sizeLabel) · \(preset.fps)")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(selected ? StudioStyle.accent.opacity(0.14) : Color.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(selected ? StudioStyle.accent.opacity(0.85) : Color.white.opacity(0.07), lineWidth: selected ? 1.5 : 1))
        .opacity(disabled && !selected ? 0.45 : 1)
        .contentShape(Rectangle())
        .help(preset.summary)
    }
}

/// A frame outline at the preset's aspect ratio.
struct AspectGlyph: View {
    var width: Int
    var height: Int
    var highlighted: Bool

    var body: some View {
        GeometryReader { g in
            let r = Double(width) / Double(height)
            let side = min(g.size.width, g.size.height)
            let w = r >= 1 ? side : side * r, h = r >= 1 ? side / r : side
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .strokeBorder(highlighted ? StudioStyle.accent : Color.secondary, lineWidth: 1.4)
                .background(RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill((highlighted ? StudioStyle.accent : Color.secondary).opacity(0.15)))
                .frame(width: w, height: h)
                .frame(width: g.size.width, height: g.size.height)
        }
    }
}
