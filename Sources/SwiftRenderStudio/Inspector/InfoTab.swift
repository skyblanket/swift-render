import AppKit
import SwiftUI
import SwiftRenderKit

// MARK: - Info tab
//
// The scene at a glance (kind, length, canvas, source), Health Check (16 moments across
// the film in a contact sheet whose cells seek on click, plus a checklist), structure,
// sound, and a collapsed Technical section for the preview process.

struct InfoTab: View {
    @Bindable var model: ProjectModel
    @State private var showTechnical = false

    var body: some View {
        if let info = model.info {
            Form {
                sceneSection(info)
                checkSection(info)
                structureSection(info)
                audioSection(info)
                technicalSection()
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        } else {
            StudioEmptyState(title: "Pick a scene", symbol: StudioStyle.Symbol.film,
                             message: "Choose a scene on the left to see its details.")
                .inspectorFill()
        }
    }

    // MARK: Sections

    private func sceneSection(_ info: SceneInfo) -> some View {
        Section("Scene") {
            LabeledContent("Name") { Text(info.name).textSelection(.enabled) }
            LabeledContent("Kind") { Text(Self.kind(info.kind)) }
            LabeledContent("Length") {
                Text(StudioTime.length(info.duration, fps: info.fps)).monospacedDigit()
                    .help("\(StudioTime.precise(info.duration)) · \(StudioTime.spoken(info.duration))")
            }
            LabeledContent("Canvas") { Text(verbatim: "\(info.width) × \(info.height) · \(info.fps) fps").monospacedDigit() }
            if let src = info.sourcePath {
                LabeledContent("Source") {
                    Button { SourceOpener.open(file: src, line: 1) } label: {
                        HStack(spacing: StudioStyle.Space.xs) {
                            Text(URL(fileURLWithPath: src).lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Image(systemName: StudioStyle.Symbol.reveal).imageScale(.small)
                        }
                    }
                    .buttonStyle(.borderless)
                    .help(relative(src))
                    .contextMenu {
                        Button("Open") { SourceOpener.open(file: src, line: 1) }
                        Button("Show in Finder") { SourceOpener.reveal(URL(fileURLWithPath: src)) }
                    }
                }
            }
            let files = clipSourceFiles(info)
            if files.count > 1 {
                LabeledContent("Also In") {
                    VStack(alignment: .trailing, spacing: 2) {
                        ForEach(files.dropFirst(), id: \.self) { f in
                            Button(URL(fileURLWithPath: f).lastPathComponent) { SourceOpener.open(file: f, line: 1) }
                                .buttonStyle(.borderless)
                                .lineLimit(1)
                                .help(relative(f))
                        }
                    }
                }
            }
        }
    }

    static func kind(_ k: SceneKind) -> String {
        switch k {
        case .render: return "Render scene"
        case .audio: return "Moves to the music"
        case .props: return "Has editable content"
        case .propsAudio: return "Editable content, moves to the music"
        }
    }

    private func checkSection(_ info: SceneInfo) -> some View {
        let insp = model.inspector
        let result = insp.currentCheck
        return Section {
            HStack(spacing: StudioStyle.Space.s) {
                Button(insp.checkRunning ? "Checking…" : result == nil ? "Check Film" : "Check Again") {
                    Task { await insp.runCheck() }
                }
                .disabled(insp.checkRunning || model.host.active == nil)
                if insp.checkRunning { ProgressView().controlSize(.small) }
                Spacer()
                if let r = result {
                    let stale = r.generation != model.host.generation
                    Text(stale ? "Out of date" : r.at.formatted(date: .omitted, time: .shortened))
                        .font(StudioStyle.Fonts.subheadline)
                        .foregroundStyle(.secondary)
                        .help(stale ? "You've rebuilt since this check. Check again." : "Checked at \(r.at.formatted())")
                    Button { SourceOpener.reveal(URL(fileURLWithPath: r.sheetPath)) } label: { Image(systemName: "folder") }
                        .buttonStyle(.borderless)
                        .help("Show the contact sheet in Finder")
                }
            }
            if let e = insp.checkError {
                Label(e, systemImage: StudioStyle.Symbol.error).font(StudioStyle.Fonts.subheadline).foregroundStyle(StudioStyle.error)
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
                Text("Looks at 16 moments across the film for blank frames and checks the sound. Click a frame to jump there.")
                    .font(StudioStyle.Fonts.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Health Check")
        }
    }

    private func structureSection(_ info: SceneInfo) -> some View {
        Section("Structure") {
            row("Clips", info.clips.isEmpty ? "One continuous shot" : clipSummary(info.clips))
            if !info.captions.isEmpty { row("Captions", "\(info.captions.count)") }
            row("Music", scoreSummary(info.events))
            row("Knobs", knobSummary(info))
            if let json = model.propsJSON ?? info.propsJSON {
                row("Content", (try? JSONValue.parse(json)).map { "\($0.children.count) fields" } ?? "Not valid JSON")
            }
        }
    }

    @ViewBuilder private func audioSection(_ info: SceneInfo) -> some View {
        // "audio: none …" is already a Health Check line.
        let audioLine = model.inspector.currentCheck?.report.first { $0.hasPrefix("audio:") && !$0.contains("none") }
        if info.audioPath != nil || !info.loudness.isEmpty || audioLine != nil {
            Section("Sound") {
                if let p = info.audioPath {
                    LabeledContent("Track") {
                        Button(URL(fileURLWithPath: p).lastPathComponent) { SourceOpener.reveal(URL(fileURLWithPath: p)) }
                            .buttonStyle(.borderless)
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
                        .help("Loudness over time")
                }
            }
        }
    }

    private func technicalSection() -> some View {
        Section {
            DisclosureGroup("Technical", isExpanded: $showTechnical) {
                row("Process", model.host.pid.map { "pid \($0)" } ?? "Not running")
                row("Build", "\(model.host.generation)")
                row("Render Time", String(format: "%.1f ms per frame (average)", model.playback.stats.msPerFrame))
                if let v = model.host.hostVersion { row("Version", v) }
            }
        }
    }

    // MARK: Helpers

    private func row(_ k: String, _ v: String) -> some View {
        LabeledContent(k) { Text(verbatim: v).monospacedDigit().textSelection(.enabled) }
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
        return depth > 1 ? "\(clips.count), \(depth) levels deep" : "\(clips.count)"
    }

    private func knobSummary(_ info: SceneInfo) -> String {
        let live = model.knobValues.count
        return live == 0 ? "\(info.knobs.count)" : "\(info.knobs.count), \(live) changed"
    }

    private func scoreSummary(_ e: [ScoreEventInfo]) -> String {
        guard !e.isEmpty else { return "None" }
        let counts = Dictionary(grouping: e, by: \.kind).mapValues(\.count).sorted { $0.value > $1.value }
        return "\(e.count) notes and hits"
            + (counts.isEmpty ? "" : ", mostly " + counts.prefix(2).map(\.key).joined(separator: " and "))
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
                            outline(c, scale: s, sheet: sheet, color: StudioStyle.onPicture, width: 1.5)
                        }
                        if let h = hovered {
                            outline(h, scale: s, sheet: sheet, color: StudioStyle.accent, width: 2)
                            let r = ContactSheetGeometry.cellRect(h, sheet: sheet)
                            Text(StudioTime.short(ContactSheetGeometry.time(cell: h, duration: duration)))
                                .font(StudioStyle.Fonts.footnote.weight(.semibold)).monospacedDigit()
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(StudioStyle.pictureScrim, in: StudioStyle.rounded(StudioStyle.Radius.small))
                                .foregroundStyle(StudioStyle.onPicture)
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
            .clipShape(StudioStyle.rounded(StudioStyle.Radius.small))
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

/// One `check` report line as a checklist item; only warnings take a color (orange).
struct ReportLine: View {
    let text: String

    var body: some View {
        // "⚠︎" is U+26A0 + a variation selector: a different Character than "⚠", so match the scalar.
        let warn = text.unicodeScalars.contains("\u{26A0}")
        let (head, rest) = split(warn ? Self.stripWarning(text) : text)
        HStack(alignment: .firstTextBaseline, spacing: StudioStyle.Space.s) {
            Image(systemName: warn ? "exclamationmark.triangle" : StudioStyle.Symbol.ok)
                .foregroundStyle(warn ? AnyShapeStyle(StudioStyle.warning) : AnyShapeStyle(.secondary))
            Text(Self.friendly(head: head, rest: rest))
                .font(StudioStyle.Fonts.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "frames: no blank samples" → "Frames: none blank"; backticks render as code.
    static func friendly(head: String?, rest: String) -> AttributedString {
        var body = rest
        if head == "frames", rest == "no blank samples" { body = "none blank" }
        if head == "audio", rest.hasPrefix("none") {
            body = "none yet. Add `soundtrack(duration:)` to give it a beat."
        }
        let label = head.map { $0.prefix(1).uppercased() + $0.dropFirst() + ": " } ?? ""
        let md = (try? AttributedString(markdown: body)) ?? AttributedString(body)
        var out = AttributedString(label)
        out.font = StudioStyle.Fonts.calloutEmphasis
        return out + md
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
            let width = Double(max(1, n)), last = Double(levels.count - 1)
            for x in 0...max(1, n) {
                // Max over the samples under this pixel, so short hits stay visible.
                let a = Int(Double(x) / width * last)
                let b = min(levels.count - 1, Int(Double(x + 1) / width * last))
                let level: Float = levels[a...max(a, b)].max() ?? 0
                let v = CGFloat(level) / peak
                let y: CGFloat = size.height - v * (size.height - 2)
                area.addLine(to: CGPoint(x: CGFloat(x), y: y))
            }
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.closeSubpath()
            ctx.fill(area, with: .color(StudioStyle.Lane.audio.opacity(0.45)))
            if duration > 0 {
                let x = CGFloat(min(1, max(0, playhead / duration))) * size.width
                ctx.fill(Path(CGRect(x: x - 0.5, y: 0, width: 1, height: size.height)), with: .color(StudioStyle.playhead))
            }
        }
        .background(StudioStyle.well, in: StudioStyle.rounded(StudioStyle.Radius.small))
    }
}
