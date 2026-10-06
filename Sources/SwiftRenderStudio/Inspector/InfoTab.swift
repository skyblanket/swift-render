import SwiftUI
import SwiftRenderKit

// MARK: - Info tab   // S7
//
// Shell: scene metadata, source link, clip/caption/score counts, host pid/gen/ms.
// S7 adds Run check (host `check`), the clickable contact sheet (cell → seek
// (i+0.5)·step), audio peak/RMS and the loudness sparkline.

struct InfoTab: View {
    @Bindable var model: ProjectModel

    var body: some View {
        if let info = model.info {
            Form {
                Section("Scene") {
                    row("Name", info.name)
                    row("Kind", info.kind.rawValue)
                    row("Duration", String(format: "%.2f s", info.duration))
                    row("Canvas", "\(info.width)×\(info.height) @ \(info.fps)")
                    if let src = info.sourcePath {
                        LabeledContent("Source") {
                            Button(URL(fileURLWithPath: src).lastPathComponent) { SourceOpener.open(file: src, line: 1) }
                                .buttonStyle(.link)
                        }
                    }
                }
                Section("Structure") {
                    row("Clips", info.clips.isEmpty ? "0 (no Timeline)" : "\(info.clips.count)")
                    row("Captions", "\(info.captions.count)")
                    row("Score", scoreSummary(info.events))
                    row("Knobs", "\(info.knobs.count)")
                }
                Section("Host") {
                    row("Process", model.host.pid.map { "pid \($0)" } ?? "—")
                    row("Generation", "\(model.host.generation)")
                    row("Render", String(format: "%.1f ms/frame (EWMA)", model.playback.stats.msPerFrame))
                    if let v = model.host.hostVersion { row("Version", v) }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        } else {
            ContentUnavailableView("No scene", systemImage: "film")
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        LabeledContent(k) { Text(v).font(StudioStyle.mono).textSelection(.enabled) }
    }

    private func scoreSummary(_ e: [ScoreEventInfo]) -> String {
        guard !e.isEmpty else { return "none" }
        let counts = Dictionary(grouping: e, by: \.kind).mapValues(\.count).sorted { $0.value > $1.value }
        return "\(e.count): " + counts.prefix(3).map { "\($0.key)×\($0.value)" }.joined(separator: " ")
    }
}
