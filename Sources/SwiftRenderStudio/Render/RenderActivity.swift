import AppKit
import SwiftUI
import SwiftRenderKit

// MARK: - Export activity
//
// The toolbar's Export button: `square.and.arrow.up`, or a progress ring while an export
// runs. It opens the Export sheet, or, while exports are running or just finished, a
// popover listing them:
//
//   [▣] NeverHeard · Master 1080p60      ███████████░░░░░  3,112 of 5,580 · 0:27 left   [■]
//   [▣] RepoPromo · Preview  Done in 7.9 s · 4.1 MB     [Show in Finder] [Open] [Attach to Comment ▾]

struct ExportToolbarButton: View {
    @Bindable var model: ProjectModel

    var body: some View {
        Button {
            if model.renders.active != nil || model.ui.showRenderActivity { model.ui.showRenderActivity.toggle() }
            else { model.perform(.renderSheet) }
        } label: {
            Label {
                Text("Export")
            } icon: {
                ExportActivityIcon(job: model.renders.active, outstanding: model.renders.outstanding)
            }
        }
        .help(helpText)
        .popover(isPresented: $model.ui.showRenderActivity, arrowEdge: .bottom) {
            RenderActivityList(model: model)
        }
        .contextMenu {
            Button("Export…") { model.perform(.renderSheet) }
            Button("Export Again") { model.perform(.render) }
            Button("Show Exports") { model.ui.showRenderActivity = true }
        }
    }

    private var helpText: String {
        guard let j = model.renders.active else { return "Export (⌘⇧R)" }
        if let f = j.fraction { return "Exporting \(j.scene): \(Int(f * 100))%" }
        return "Exporting \(j.scene)"
    }
}

/// The export glyph; a progress ring takes its place while a job runs.
struct ExportActivityIcon: View {
    var job: RenderJob?
    var outstanding: Int

    var body: some View {
        ZStack {
            if let job {
                Circle().stroke(StudioStyle.well, lineWidth: 2)
                Circle().trim(from: 0, to: job.fraction ?? 0.25)
                    .stroke(StudioStyle.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            } else {
                Image(systemName: StudioStyle.Symbol.export)
            }
        }
        .frame(width: 18, height: 18)
        .overlay(alignment: .topTrailing) {
            if outstanding > 1 {
                Text("\(outstanding)")
                    .font(StudioStyle.Fonts.footnote.weight(.semibold)).monospacedDigit()
                    .padding(.horizontal, 4)
                    .background(StudioStyle.accent, in: Capsule())
                    .foregroundStyle(StudioStyle.onAccent)
                    .offset(x: 8, y: -6)
            }
        }
    }
}

struct RenderActivityList: View {
    @Bindable var model: ProjectModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Exports").font(StudioStyle.Fonts.headline)
                Spacer()
                if model.renders.jobs.contains(where: \.isDone) {
                    Button("Clear") { model.renders.clearDone() }
                        .buttonStyle(.borderless).controlSize(.small)
                }
                Button("Export…") { model.ui.showRenderActivity = false; model.perform(.renderSheet) }
                    .controlSize(.small)
                    .help("⌘⇧R")
            }
            .padding(.horizontal, StudioStyle.Space.l).padding(.top, StudioStyle.Space.m).padding(.bottom, StudioStyle.Space.s)
            Divider()
            if model.renders.jobs.isEmpty {
                StudioEmptyState(title: "Nothing exported yet", symbol: StudioStyle.Symbol.export,
                                 message: "⌘⇧R picks a size. ⌘R exports another \(model.renders.lastPreset.tileTitle).")
                    .frame(height: 150)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.renders.jobs.reversed()) { job in
                            RenderJobRow(model: model, job: job)
                            Divider().opacity(0.5)
                        }
                    }
                }
                .frame(maxHeight: 380)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: 440)
    }
}

struct RenderJobRow: View {
    @Bindable var model: ProjectModel
    var job: RenderJob

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                StudioStyle.rounded(StudioStyle.Radius.medium).fill(StudioStyle.well)
                Image(systemName: job.preset.symbol).foregroundStyle(tint)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Text(job.scene).font(StudioStyle.Fonts.calloutEmphasis).lineLimit(1)
                    Text(job.preset.title).font(StudioStyle.Fonts.callout).foregroundStyle(.secondary).lineLimit(1)
                    if job.range != nil {
                        Text(job.durationLabel).font(StudioStyle.Fonts.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer(minLength: 4)
                    if !job.isDone {
                        Button { model.renders.cancel(job.id) } label: {
                            Image(systemName: "stop.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help(job.state == .queued ? "Take it out of the queue" : "Stop exporting (⌘.)")
                    }
                }
                status
                if case .finished = job.state { actions }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .contentShape(Rectangle())
        .modifier(FinishedExportMenu(model: model, job: job))
    }

    private var tint: AnyShapeStyle {
        switch job.state {
        case .failed: return AnyShapeStyle(StudioStyle.error)
        default: return AnyShapeStyle(.secondary)
        }
    }

    @ViewBuilder private var status: some View {
        switch job.state {
        case .queued:
            caption("Waiting its turn")
        case .building(let line):
            VStack(alignment: .leading, spacing: 4) {
                ProgressBar(fraction: nil)
                caption(job.build == .optimized ? "Getting the Final build ready…" : "Building…").lineLimit(1)
                    .help(line)
            }
        case .rendering(let done, let total, let fps):
            VStack(alignment: .leading, spacing: 4) {
                ProgressBar(fraction: job.fraction)
                HStack(spacing: 0) {
                    caption(total > 0 ? "\(done.formatted()) of \(total.formatted()) frames" : "Starting…")
                    Spacer()
                    if let eta = job.eta { caption(String(format: "%d:%02d left", Int(eta) / 60, Int(eta) % 60)) }
                }
                .monospacedDigit()
            }
        case .finishing(let what):
            VStack(alignment: .leading, spacing: 4) {
                ProgressBar(fraction: nil)
                caption(what)
            }
        case .finished(let secs):
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                caption(String(format: "Done in %@", Self.clock(secs)) + (job.bytes.map { " · " + Self.size($0) } ?? ""))
                    .help(job.output.path)
            }
        case .failed(let why):
            Text(why)
                .font(StudioStyle.Fonts.subheadline).foregroundStyle(StudioStyle.error)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .help(job.log.suffix(12).joined(separator: "\n"))
        case .cancelled:
            caption("Stopped")
        }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Button("Show in Finder") { SourceOpener.reveal(job.output) }
            Button("Open") { NSWorkspace.shared.open(job.output) }
            let comments = model.renders.attachableComments(scene: job.scene)
            Menu("Attach to Comment") {
                if comments.isEmpty {
                    Text("No open comments on \(job.scene) yet")
                }
                ForEach(comments) { c in
                    Button("\(StudioTime.short(c.t))  \(c.body.prefix(48))") { attach(to: c.id) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(comments.isEmpty)
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
    }

    private func attach(to id: String) {
        do {
            try model.renders.attach(job.id, toComment: id, author: model.review.authorName)
            model.review.reload()
            model.review.selection = id
            model.ui.toast = "Added \(job.output.lastPathComponent) to #\(model.review.number(of: id) ?? 0)"
        } catch {
            model.ui.toast = "Couldn't attach: \(error)"
        }
    }

    private func caption(_ s: String) -> some View {
        Text(s).font(StudioStyle.Fonts.subheadline).foregroundStyle(.secondary).monospacedDigit()
    }

    static func clock(_ s: Double) -> String {
        let t = Int(s.rounded())
        return t >= 60 ? String(format: "%d:%02d", t / 60, t % 60) : String(format: "%.1f s", s)
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Thin capsule bar; nil fraction shows the system indeterminate bar.
struct ProgressBar: View {
    var fraction: Double?

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(StudioStyle.well)
                if let fraction {
                    Capsule().fill(StudioStyle.accent).frame(width: max(4, g.size.width * fraction))
                } else {
                    ProgressView().progressViewStyle(.linear).labelsHidden()
                }
            }
        }
        .frame(height: 5)
    }
}

/// A finished export's row: the same right-click menu as its row in the sidebar.
private struct FinishedExportMenu: ViewModifier {
    let model: ProjectModel
    let job: RenderJob

    func body(content: Content) -> some View {
        if case .finished = job.state, FileManager.default.fileExists(atPath: job.output.path) {
            content.studioContextMenu(ContextMenus.export(job.output, model: model))
        } else {
            content
        }
    }
}
