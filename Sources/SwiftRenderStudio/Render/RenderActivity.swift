import AppKit
import SwiftUI
import SwiftRenderKit

// MARK: - Export activity
//
// The toolbar's Export button: `square.and.arrow.up`, or a progress ring while an export
// runs. It opens the Export sheet, or, while exports are running or just finished, a
// popover listing them:
//
//   [▣] NeverHeard                                              (■)
//       Master 1080p60
//       ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//       Rendering 3,112 of 5,580 · 42 fps · about 1 min left
//   [▣] RepoPromo
//       Preview
//       ✓ Done in 7.9 s · 4.1 MB
//       [Open] [Show in Finder] [Attach to Comment ▾]
//
// One status line per job, in plain words. A native spinner sits beside it while the
// export builds, prepares music or finishes up; a native determinate bar takes over once
// frames flow.

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

    static let width: CGFloat = 400

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: StudioStyle.Space.s) {
                Text("Exports").font(StudioStyle.Fonts.headline)
                Spacer()
                if model.renders.jobs.contains(where: \.isDone) {
                    Button("Clear") { model.renders.clearDone() }
                        .buttonStyle(.borderless).controlSize(.small)
                        .help("Remove finished and stopped exports from this list")
                }
                Button("Export…") { model.ui.showRenderActivity = false; model.perform(.renderSheet) }
                    .controlSize(.small)
                    .help("Export (⌘⇧R)")
            }
            .padding(.horizontal, StudioStyle.Space.l).padding(.vertical, StudioStyle.Space.m)
            Divider()
            if model.renders.jobs.isEmpty {
                StudioEmptyState(title: "Nothing exported yet", symbol: StudioStyle.Symbol.export,
                                 message: "⌘⇧R picks a size. ⌘R exports another \(model.renders.lastPreset.tileTitle).")
                    .frame(height: 150)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(model.renders.jobs.reversed().enumerated()), id: \.element.id) { i, job in
                            if i > 0 { Divider().padding(.leading, StudioStyle.Space.l + RenderJobRow.iconSize + StudioStyle.Space.m) }
                            RenderJobRow(model: model, job: job)
                        }
                    }
                }
                .frame(maxHeight: 400)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: Self.width)
    }
}

struct RenderJobRow: View {
    @Bindable var model: ProjectModel
    var job: RenderJob

    static let iconSize: CGFloat = 28

    var body: some View {
        HStack(alignment: .top, spacing: StudioStyle.Space.m) {
            Image(systemName: job.preset.symbol)
                .font(StudioStyle.Fonts.body)
                .foregroundStyle(iconTint)
                .frame(width: Self.iconSize, height: Self.iconSize)
                .background(StudioStyle.well, in: StudioStyle.rounded(StudioStyle.Radius.medium))

            VStack(alignment: .leading, spacing: StudioStyle.Space.s) {
                HStack(alignment: .firstTextBaseline, spacing: StudioStyle.Space.s) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(job.scene).font(StudioStyle.Fonts.calloutEmphasis).lineLimit(1)
                        Text(subtitle).font(StudioStyle.Fonts.subheadline).foregroundStyle(.secondary)
                            .lineLimit(1).monospacedDigit()
                    }
                    Spacer(minLength: StudioStyle.Space.s)
                    if !job.isDone {
                        Button { model.renders.cancel(job.id) } label: {
                            Image(systemName: "stop.circle").font(StudioStyle.Fonts.body)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help(job.state == .queued ? "Take it out of the queue" : "Stop exporting (⌘.)")
                        .accessibilityLabel(job.state == .queued ? "Remove from queue" : "Stop")
                    }
                }
                status
                if case .finished = job.state { actions }
            }
        }
        .padding(.horizontal, StudioStyle.Space.l).padding(.vertical, StudioStyle.Space.m)
        .contentShape(Rectangle())
        .modifier(FinishedExportMenu(model: model, job: job))
    }

    /// "Master 1080p60", plus the In→Out span when it isn't the whole film.
    private var subtitle: String {
        job.range == nil ? job.preset.title : "\(job.preset.title) · \(job.durationLabel)"
    }

    private var iconTint: AnyShapeStyle {
        if case .failed = job.state { return AnyShapeStyle(StudioStyle.error) }
        return AnyShapeStyle(.secondary)
    }

    @ViewBuilder private var status: some View {
        switch job.state {
        case .queued, .cancelled:
            caption(job.statusLine)
        case .building(let line):
            working(job.statusLine).help(line)
        case .preparing, .finishing:
            working(job.statusLine)
        case .rendering:
            VStack(alignment: .leading, spacing: StudioStyle.Space.xs) {
                ProgressView(value: job.fraction ?? 0)
                    .progressViewStyle(.linear)
                    .tint(StudioStyle.accent)
                    .controlSize(.small)
                caption(job.statusLine)
            }
        case .finished:
            HStack(spacing: StudioStyle.Space.xs) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
                caption(job.statusLine + (job.bytes.map { " · " + Self.size($0) } ?? ""))
            }
            .help(job.output.path)
        case .failed(let why):
            Text(why)
                .font(StudioStyle.Fonts.subheadline).foregroundStyle(StudioStyle.error)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .help(job.log.suffix(12).joined(separator: "\n"))
        }
    }

    /// A step with no frame count yet: the native spinner and what's happening.
    private func working(_ text: String) -> some View {
        HStack(spacing: StudioStyle.Space.s) {
            ProgressView().controlSize(.small).scaleEffect(0.8).frame(width: 14, height: 14)
            caption(text).lineLimit(1)
        }
    }

    private var actions: some View {
        HStack(spacing: StudioStyle.Space.s) {
            Button("Open") { NSWorkspace.shared.open(job.output) }
            Button("Show in Finder") { SourceOpener.reveal(job.output) }
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

    static func clock(_ s: Double) -> String { RenderJob.clock(s) }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
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
