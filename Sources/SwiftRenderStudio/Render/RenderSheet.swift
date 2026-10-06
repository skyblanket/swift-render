import AppKit
import UniformTypeIdentifiers
import SwiftUI
import SwiftRenderKit

// MARK: - Export sheet
//
//   Export RepoPromo
//   25 seconds · 1920×1080 · with music
//   Best Quality   Social      App Store    Draft
//   [1080p60]      [9:16]      [Portrait]   [Preview]
//   [4K UHD]       [1:1]       [Landscape]  [GIF]
//   960×540 · 30 fps · H.264 · 25 s · with music
//   Length / Quality / Knobs / Save To
//                                             [Cancel] [Export]
//
// App Store previews are only enabled for a 15–30 s film or In→Out range; GIFs need
// ffmpeg. Presets that change the aspect say so and offer to preview that shape first.

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
        if model.selectedScene == nil { return "Pick a scene first." }
        return RenderQueue.problem(preset: preset, duration: sceneDuration, range: range,
                                   ffmpegAvailable: !model.renders.ffmpegResolved || model.renders.ffmpeg != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: StudioStyle.Space.xs) {
                Text("Export \(scene)").font(StudioStyle.Fonts.title)
                Text(sceneLine).font(StudioStyle.Fonts.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, StudioStyle.Space.xl).padding(.top, StudioStyle.Space.xl).padding(.bottom, StudioStyle.Space.l)
            VStack(alignment: .leading, spacing: StudioStyle.Space.m) {
                presetGrid
                presetDetail
            }
            .padding(.horizontal, StudioStyle.Space.xl)
            Form {
                options
                notes
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            footer
                .padding(.horizontal, StudioStyle.Space.xl).padding(.vertical, StudioStyle.Space.l)
        }
        .frame(width: 680, height: 486)
        .onAppear {
            guard !appeared else { return }
            appeared = true
            preset = model.renders.lastPreset
            build = preset.prefersRelease ? .optimized : .currentDebug
            useRange = false
        }
        .onChange(of: preset) { _, p in
            build = p.prefersRelease ? .optimized : .currentDebug
            if let old = customOutput, old.pathExtension != p.fileExtension {
                // The person agreed to replace `old`, not whatever already has the new extension.
                customOutput = RenderQueue.unused(old.deletingPathExtension().appendingPathExtension(p.fileExtension),
                                                  taken: model.renders.pendingOutputs)
            }
            // A too-long film with In/Out set: App Store presets need the range.
            if p.durationLimit != nil, model.playback.inOut != nil,
               p.durationProblem(sceneDuration ?? 0) != nil { useRange = true }
        }
        .onChange(of: useRange) { _, on in
            build = preset.prefersRelease ? .optimized : .currentDebug
        }
    }

    private var sceneLine: String {
        guard let info = model.info else { return "Nothing loaded yet" }
        return [StudioTime.spoken(info.duration), "\(info.width)×\(info.height)", hasSoundtrack ? "with music" : "no sound"]
            .joined(separator: " · ")
    }

    // MARK: Presets

    private var presetGrid: some View {
        HStack(alignment: .top, spacing: StudioStyle.Space.s) {
            ForEach(RenderPreset.Group.allCases, id: \.self) { g in
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(text: g.title).padding(.leading, 2)
                    ForEach(RenderPreset.allCases.filter { $0.group == g }) { p in
                        PresetTile(preset: p, selected: p == preset, disabled: !usable(p))
                            .onTapGesture { preset = p }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// Exportable for the whole film or for the In→Out range.
    private func usable(_ p: RenderPreset) -> Bool {
        let ffmpeg = !model.renders.ffmpegResolved || model.renders.ffmpeg != nil
        if RenderQueue.problem(preset: p, duration: sceneDuration, range: nil, ffmpegAvailable: ffmpeg) == nil { return true }
        guard let io = model.playback.inOut else { return false }
        return RenderQueue.problem(preset: p, duration: sceneDuration, range: io, ffmpegAvailable: ffmpeg) == nil
    }

    private var presetDetail: some View {
        var parts = ["\(preset.sizeLabel)", "\(preset.fps) fps", preset.isGIF ? "GIF" : "H.264"]
        if let d = effectiveDuration { parts.append(StudioTime.compact(d)) }
        parts.append(audioLabel)
        let frames = effectiveDuration.map { "\(Int(($0 * Double(preset.fps)).rounded()).formatted()) frames" }
        return Text(parts.joined(separator: " · "))
            .font(StudioStyle.Fonts.callout)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .help([frames, preset.megabitsPerSecond.map { "\($0) Mb/s" }].compactMap { $0 }.joined(separator: " · "))
    }

    private var audioLabel: String {
        if preset.isGIF || !hasSoundtrack { return "no sound" }
        if range != nil, model.renders.ffmpeg == nil { return "no sound (section)" }
        return "with music"
    }

    // MARK: Options

    @ViewBuilder private var options: some View {
        Section {
            Picker("Length", selection: $useRange) {
                Text("Whole Film").tag(false)
                if let io = model.playback.inOut {
                    Text("In to Out (\(StudioTime.range(io.lowerBound, io.upperBound)))").tag(true)
                } else {
                    Text("In to Out (press I and O to set)").tag(true)
                }
            }
            .disabled(model.playback.inOut == nil)
            VStack(alignment: .leading, spacing: StudioStyle.Space.xs) {
                Picker("Quality", selection: $build) {
                    Text("Final (slower the first time)").tag(BuildChoice.optimized)
                    Text("Quick (what's playing now)").tag(BuildChoice.currentDebug)
                }
                Text(buildHint).font(StudioStyle.Fonts.subheadline).foregroundStyle(.secondary)
            }
            if knobsDiffer {
                Picker("Knobs", selection: $knobs) {
                    Text("Use What's on Screen").tag(KnobChoice.useLive)
                    Text("Save Knobs, Then Export").tag(KnobChoice.saveToFile)
                }
            } else {
                LabeledContent("Knobs") {
                    Text(savedKnobs.isEmpty ? "Defaults" : "\(savedKnobs.count) saved change\(savedKnobs.count == 1 ? "" : "s")")
                }
            }
            LabeledContent("Save To") {
                HStack(spacing: StudioStyle.Space.s) {
                    Text(model.renders.relativePath(output))
                        .lineLimit(1).truncationMode(.head)
                        .textSelection(.enabled)
                    Button("Change…", action: chooseOutput).controlSize(.small)
                }
            }
        }
    }

    private var buildHint: String {
        switch build {
        case .optimized:
            let exe = BuildController.canonical(model.project.root)
                .appendingPathComponent(".build/studio-release/release/\(model.project.config.product)")
            return FileManager.default.fileExists(atPath: exe.path)
                ? "Renders several times faster than Quick, using every core."
                : "The first Final export builds for a few minutes first. After that it starts right away."
        case .currentDebug:
            return model.build.lastGoodExecutable == nil
                ? "Builds first, since nothing is playing yet."
                : "Starts now, using what's playing in Studio."
        }
    }

    // MARK: Notes

    @ViewBuilder private var notes: some View {
        let items = noteItems
        if !items.isEmpty {
            Section {
                ForEach(items, id: \.text) { n in
                    HStack(alignment: .firstTextBaseline, spacing: StudioStyle.Space.s) {
                        Image(systemName: n.symbol).foregroundStyle(n.color)
                        Text(n.text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if n.preview, let a = viewerAspect, model.aspect != a {
                            Spacer(minLength: StudioStyle.Space.s)
                            Button("Preview \(a.rawValue)") { Task { await model.setAspect(a) } }
                                .controlSize(.small)
                        }
                    }
                    .font(StudioStyle.Fonts.callout)
                }
            }
        }
    }

    private struct Note { var text: String; var symbol: String; var color: AnyShapeStyle; var preview = false }

    private var noteItems: [Note] {
        var out: [Note] = []
        if let problem { out.append(Note(text: problem, symbol: StudioStyle.Symbol.error, color: AnyShapeStyle(StudioStyle.error))) }
        if preset.changesAspect {
            out.append(Note(text: "Made for widescreen, so it'll be re-laid out for \(preset.pixelSize.height > preset.pixelSize.width ? "portrait" : "this shape").",
                            symbol: "aspectratio", color: AnyShapeStyle(.secondary), preview: true))
        }
        if range != nil, hasSoundtrack, !preset.isGIF, model.renders.ffmpeg == nil {
            out.append(Note(text: "Exporting a section leaves out the music unless ffmpeg is installed (brew install ffmpeg).",
                            symbol: "speaker.slash", color: AnyShapeStyle(.secondary)))
        }
        if preset.group == .appStore, problem == nil {
            if hasSoundtrack && (range == nil || model.renders.ffmpeg != nil) {
                out.append(Note(text: "Ready for App Store Connect: 15 to 30 seconds, 30 fps, with sound.",
                                symbol: StudioStyle.Symbol.ok, color: AnyShapeStyle(.secondary)))
            } else {
                out.append(Note(text: "Heads up: this film has no sound. App Store previews usually do.",
                                symbol: "speaker.slash", color: AnyShapeStyle(.secondary)))
            }
        }
        return out
    }

    private var viewerAspect: AspectChoice? {
        switch preset {
        case .vertical9x16, .appStorePortrait: return .vertical
        case .square: return .square
        default: return nil
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Text("⌘R exports another \(model.renders.lastPreset.tileTitle).")
                .font(StudioStyle.Fonts.subheadline).foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Export") { render() }
                .keyboardShortcut(.defaultAction)
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
        HStack(spacing: StudioStyle.Space.s) {
            AspectGlyph(width: preset.pixelSize.width, height: preset.pixelSize.height, highlighted: selected)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(preset.tileTitle)
                    .font(StudioStyle.Fonts.calloutEmphasis)
                    .lineLimit(1)
                // Every tile shows its fps (shrinks a touch rather than dropping it).
                Text(verbatim: "\(preset.sizeLabel) · \(preset.fps) fps")
                    .font(StudioStyle.Fonts.footnote).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, StudioStyle.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StudioStyle.rounded(StudioStyle.Radius.medium)
            .fill(selected ? StudioStyle.accent.opacity(0.10) : StudioStyle.well))
        .overlay(StudioStyle.rounded(StudioStyle.Radius.medium)
            .strokeBorder(selected ? StudioStyle.accent : .clear, lineWidth: 2))
        .opacity(disabled && !selected ? 0.45 : 1)
        .contentShape(Rectangle())
        .help("\(preset.sizeLabel) · \(preset.fps) fps")
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
                    .fill((highlighted ? StudioStyle.accent : Color.secondary).opacity(0.12)))
                .frame(width: w, height: h)
                .frame(width: g.size.width, height: g.size.height)
        }
    }
}
