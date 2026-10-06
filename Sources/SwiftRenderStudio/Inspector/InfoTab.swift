import AppKit
import SwiftUI
import SwiftRenderKit

// MARK: - Info tab
//
// Scene metadata, sources, structure counts, audio (loudness sparkline, peak/RMS
// from the last check) and host stats. Run Check asks the host for `check`: the
// 4×4 contact sheet comes back as a PNG whose cells seek on click ((i+0.5)·step),
// with the playhead's cell outlined, plus the report lines.

struct InfoTab: View {
    @Bindable var model: ProjectModel

    var body: some View {
        if let info = model.info {
            Form {
                sceneSection(info)
                checkSection(info)
                structureSection(info)
                audioSection(info)
                hostSection()
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        } else {
            StudioEmptyState(title: "No Scene", symbol: "film")
        }
    }

    // MARK: Sections

    private func sceneSection(_ info: SceneInfo) -> some View {
        Section {
            LabeledContent("Name") {
                HStack(spacing: 5) {
                    Text(info.name).font(StudioStyle.mono).textSelection(.enabled)
                    StudioBadge(text: info.kind.rawValue, color: StudioStyle.accent)
                }
            }
            row("Duration", String(format: "%.2f s · %d frames", info.duration, Int((info.duration * Double(info.fps)).rounded())))
            row("Canvas", "\(info.width)×\(info.height) @ \(info.fps) fps")
            if let src = info.sourcePath {
                LabeledContent("Source") {
                    Button { SourceOpener.open(file: src, line: 1) } label: {
                        HStack(spacing: 3) {
                            Text(relative(src)).lineLimit(1).truncationMode(.head)
                            Image(systemName: "arrow.up.forward").imageScale(.small)
                        }
                        .font(StudioStyle.mono)
                    }
                    .buttonStyle(.link)
                    .help(src)
                }
            }
            let files = clipSourceFiles(info)
            if files.count > 1 {
                LabeledContent("Also") {
                    VStack(alignment: .trailing, spacing: 2) {
                        ForEach(files.dropFirst(), id: \.self) { f in
                            Button(relative(f)) { SourceOpener.open(file: f, line: 1) }
                                .buttonStyle(.link)
                                .font(StudioStyle.monoSmall)
                                .lineLimit(1)
                                .truncationMode(.head)
                                .help(f)
                        }
                    }
                }
            }
        } header: {
            Text("Scene")
        }
    }

    private func checkSection(_ info: SceneInfo) -> some View {
        let insp = model.inspector
        let result = insp.currentCheck
        return Section {
            HStack(spacing: 8) {
                Button {
                    Task { await insp.runCheck() }
                } label: {
                    Label(insp.checkRunning ? "Checking…" : result == nil ? "Run Check" : "Run Again",
                          systemImage: "checkmark.seal")
                }
                .disabled(insp.checkRunning || model.host.active == nil)
                .controlSize(.small)
                if insp.checkRunning { ProgressView().controlSize(.mini) }
                Spacer()
                if let r = result {
                    let stale = r.generation != model.host.generation
                    Text(stale ? "gen \(r.generation) · stale" : r.at.formatted(date: .omitted, time: .shortened))
                        .font(StudioStyle.monoSmall)
                        .foregroundStyle(stale ? AnyShapeStyle(StudioStyle.warn) : AnyShapeStyle(.tertiary))
                        .help(stale ? "Rebuilt since this check — run it again" : "Checked at \(r.at.formatted())")
                    Button { SourceOpener.reveal(URL(fileURLWithPath: r.sheetPath)) } label: { Image(systemName: "folder") }
                        .buttonStyle(.borderless)
                        .help("Reveal the contact sheet in Finder")
                }
            }
            if let e = insp.checkError {
                Label(e, systemImage: "xmark.octagon").font(.system(size: 11)).foregroundStyle(StudioStyle.bad)
            }
            if let r = result {
                if let img = r.image {
                    ContactSheetView(image: img, duration: r.duration, playhead: model.playback.t) { i in
                        insp.seek(cell: i, of: r)
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6))
                }
                // The first line repeats the Scene section; the ASCII loudness lane is the sparkline below.
                let lines = r.report.dropFirst().filter { !(info.loudness.count > 1 && $0.hasPrefix("loudness")) }
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    ReportLine(text: line)
                }
            } else if !insp.checkRunning {
                Text("Renders 16 frames across the scene into a contact sheet, flags blank frames, and measures the mix. Click a frame to jump there.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Check")
        }
    }

    private func structureSection(_ info: SceneInfo) -> some View {
        Section("Structure") {
            row("Clips", info.clips.isEmpty ? "0 (no Timeline)" : clipSummary(info.clips))
            row("Captions", "\(info.captions.count)")
            row("Score", scoreSummary(info.events))
            row("Knobs", knobSummary(info))
            if let json = model.propsJSON ?? info.propsJSON {
                row("Props", (try? JSONValue.parse(json)).map { "\($0.children.count) top-level keys" } ?? "invalid JSON")
            }
        }
    }

    @ViewBuilder private func audioSection(_ info: SceneInfo) -> some View {
        let audioLine = model.inspector.currentCheck?.report.first { $0.hasPrefix("audio:") }
        if info.audioPath != nil || !info.loudness.isEmpty || audioLine != nil {
            Section("Audio") {
                if let p = info.audioPath {
                    LabeledContent("Track") {
                        Button(URL(fileURLWithPath: p).lastPathComponent) { SourceOpener.reveal(URL(fileURLWithPath: p)) }
                            .buttonStyle(.link)
                            .font(StudioStyle.monoSmall)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(p)
                    }
                }
                if let a = audioLine { row("Levels", Self.levels(a)) }
                if !info.loudness.isEmpty {
                    LoudnessSparkline(levels: info.loudness, rate: info.loudnessRate, duration: info.duration,
                                      playhead: model.playback.t)
                        .frame(height: 34)
                        .help("RMS loudness · \(Int(info.loudnessRate)) samples/s")
                }
            }
        }
    }

    private func hostSection() -> some View {
        Section("Host") {
            row("Process", model.host.pid.map { "pid \($0)" } ?? "—")
            row("Generation", "\(model.host.generation)")
            row("Render", String(format: "%.1f ms/frame (EWMA)", model.playback.stats.msPerFrame))
            if let v = model.host.hostVersion { row("Version", v) }
        }
    }

    // MARK: Helpers

    private func row(_ k: String, _ v: String) -> some View {
        LabeledContent(k) { Text(v).font(StudioStyle.mono).textSelection(.enabled) }
    }

    private func relative(_ path: String) -> String {
        let root = model.project.root.path + "/"
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
    }

    /// Distinct files clips were declared in, the scene file first.
    private func clipSourceFiles(_ info: SceneInfo) -> [String] {
        var out: [String] = info.sourcePath.map { [$0] } ?? []
        for f in info.clips.compactMap({ $0.source?.file }) where !out.contains(f) { out.append(f) }
        return out
    }

    private func clipSummary(_ clips: [ClipInfo]) -> String {
        let depth = (clips.map(\.depth).max() ?? 0) + 1
        return depth > 1 ? "\(clips.count) · \(depth) levels" : "\(clips.count)"
    }

    private func knobSummary(_ info: SceneInfo) -> String {
        let live = model.knobValues.count
        return live == 0 ? "\(info.knobs.count)" : "\(info.knobs.count) · \(live) overridden"
    }

    private func scoreSummary(_ e: [ScoreEventInfo]) -> String {
        guard !e.isEmpty else { return "none" }
        let counts = Dictionary(grouping: e, by: \.kind).mapValues(\.count).sorted { $0.value > $1.value }
        return "\(e.count): " + counts.prefix(3).map { "\($0.key)×\($0.value)" }.joined(separator: " ")
    }

    /// "audio: 93.00s · peak -0.3 dBFS · RMS -21.0 dBFS · clipped samples 0" → "peak -0.3 · RMS -21.0 dBFS".
    static func levels(_ line: String) -> String {
        let parts = line.dropFirst("audio:".count).split(separator: "·").map { $0.trimmingCharacters(in: .whitespaces) }
        let keep = parts.filter { $0.hasPrefix("peak") || $0.hasPrefix("RMS") || ($0.hasPrefix("clipped") && !$0.hasSuffix(" 0")) }
        return keep.isEmpty ? String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces) : keep.joined(separator: " · ")
    }
}

// MARK: - Contact sheet

/// The host's 4×4 sheet. Hover shows the cell's time, click seeks there, and the
/// cell holding the playhead is outlined.
struct ContactSheetView: View {
    let image: CGImage
    let duration: Double
    let playhead: Double
    let seek: (Int) -> Void
    @State private var hovered: Int?

    var body: some View {
        let sheet = CGSize(width: image.width, height: image.height)
        Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(.high)
            .aspectRatio(sheet, contentMode: .fit)
            .overlay {
                GeometryReader { geo in
                    let s = geo.size.width / sheet.width
                    ZStack(alignment: .topLeading) {
                        if let c = ContactSheetGeometry.cell(for: playhead, duration: duration) {
                            outline(c, scale: s, sheet: sheet, color: StudioStyle.playhead, width: 1.5)
                        }
                        if let h = hovered {
                            outline(h, scale: s, sheet: sheet, color: StudioStyle.accent, width: 2)
                            let r = ContactSheetGeometry.cellRect(h, sheet: sheet)
                            Text(StudioStyle.timecode(ContactSheetGeometry.time(cell: h, duration: duration)))
                                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 3))
                                .foregroundStyle(StudioStyle.accent)
                                .offset(x: r.minX * s + 3, y: r.minY * s + 3)
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p): hovered = ContactSheetGeometry.cell(at: CGPoint(x: p.x / s, y: p.y / s), sheet: sheet)
                        case .ended: hovered = nil
                        }
                    }
                    .onTapGesture { p in
                        if let i = ContactSheetGeometry.cell(at: CGPoint(x: p.x / s, y: p.y / s), sheet: sheet) { seek(i) }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .help("Click a frame to jump there")
    }

    private func outline(_ i: Int, scale s: CGFloat, sheet: CGSize, color: Color, width: CGFloat) -> some View {
        let r = ContactSheetGeometry.cellRect(i, sheet: sheet)
        return RoundedRectangle(cornerRadius: 2)
            .strokeBorder(color, lineWidth: width)
            .frame(width: r.width * s, height: r.height * s)
            .offset(x: r.minX * s, y: r.minY * s)
    }
}

/// One `check` report line; ⚠︎ lines are called out.
struct ReportLine: View {
    let text: String

    var body: some View {
        // "⚠︎" is U+26A0 + a variation selector: a different Character than "⚠", so match the scalar.
        let warn = text.unicodeScalars.contains("\u{26A0}")
        let (head, rest) = split(warn ? Self.stripWarning(text) : text)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: warn ? "exclamationmark.triangle.fill" : "checkmark.circle")
                .imageScale(.small)
                .foregroundStyle(warn ? StudioStyle.warn : StudioStyle.ok.opacity(0.8))
            VStack(alignment: .leading, spacing: 1) {
                if let head { Text(head).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary) }
                Text(rest)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(warn ? AnyShapeStyle(StudioStyle.warn) : AnyShapeStyle(.primary))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static func stripWarning(_ s: String) -> String {
        guard s.unicodeScalars.first == "\u{26A0}" else { return s }
        return String(String.UnicodeScalarView(s.unicodeScalars.drop { $0 == "\u{26A0}" || $0 == "\u{FE0E}" || $0 == " " }))
    }

    /// "frames: no blank samples" → ("frames", "no blank samples").
    private func split(_ s: String) -> (String?, String) {
        guard let c = s.firstIndex(of: ":"), s.distance(from: s.startIndex, to: c) < 18,
              !s[..<c].contains(" ") || s.hasPrefix("loudness") else { return (nil, s) }
        return (String(s[..<c]), s[s.index(after: c)...].trimmingCharacters(in: .whitespaces))
    }
}

/// RMS envelope as a filled area with the playhead.
struct LoudnessSparkline: View {
    let levels: [Float]
    let rate: Double
    let duration: Double
    let playhead: Double

    var body: some View {
        Canvas { ctx, size in
            guard levels.count > 1 else { return }
            let peak = CGFloat(max(levels.max() ?? 1, 1e-4))
            let n = Int(size.width.rounded())
            var area = Path()
            area.move(to: CGPoint(x: 0, y: size.height))
            for x in 0...max(1, n) {
                // Max over the samples under this pixel, so short hits stay visible.
                let a = Int(Double(x) / Double(max(1, n)) * Double(levels.count - 1))
                let b = min(levels.count - 1, Int(Double(x + 1) / Double(max(1, n)) * Double(levels.count - 1)))
                let v = CGFloat(levels[a...max(a, b)].max() ?? 0) / peak
                area.addLine(to: CGPoint(x: CGFloat(x), y: size.height - v * (size.height - 2)))
            }
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.closeSubpath()
            ctx.fill(area, with: .linearGradient(Gradient(colors: [StudioStyle.accent.opacity(0.75), StudioStyle.accent.opacity(0.15)]),
                                                 startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            if duration > 0 {
                let x = CGFloat(min(1, max(0, playhead / duration))) * size.width
                ctx.fill(Path(CGRect(x: x - 0.5, y: 0, width: 1, height: size.height)), with: .color(StudioStyle.playhead))
            }
        }
        .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 3))
    }
}
