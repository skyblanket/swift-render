import AppKit
import SwiftUI
import SwiftRenderKit

// MARK: - Render activity
//
// Toolbar button (a progress ring while an export runs) + popover:
//
//   [▣] NeverHeard · Master 1080p60      ███████████░░░░░  3,112/5,580 · 92 fps · ETA 0:27   [■]
//   [▣] RepoPromo · Preview  ✓ 7.9 s · 4.1 MB     [Reveal] [Open] [Attach to Comment ▾]

struct RenderActivityButton: View {
    @Bindable var model: ProjectModel

    var body: some View {
        Button { model.ui.showRenderActivity.toggle() } label: {
            Label {
                Text("Renders")
            } icon: {
                RenderActivityIcon(job: model.renders.active, outstanding: model.renders.outstanding)
            }
        }
        .help(helpText)
        .popover(isPresented: $model.ui.showRenderActivity, arrowEdge: .bottom) {
            RenderActivityList(model: model)
        }
    }

    private var helpText: String {
        guard let j = model.renders.active else { return "Render activity" }
        if let f = j.fraction { return "Rendering \(j.scene): \(Int(f * 100))%" }
        return "Rendering \(j.scene)"
    }
}

/// Stack glyph; a progress ring around it while a job runs.
struct RenderActivityIcon: View {
    var job: RenderJob?
    var outstanding: Int

    var body: some View {
        ZStack {
            if let job {
                Circle().stroke(Color.white.opacity(0.15), lineWidth: 2)
                if let f = job.fraction {
                    Circle().trim(from: 0, to: f)
                        .stroke(StudioStyle.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                } else {
                    Circle().trim(from: 0, to: 0.25)
                        .stroke(StudioStyle.accent.opacity(0.7), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                Image(systemName: "square.stack.3d.down.right.fill").font(.system(size: 8, weight: .semibold))
            } else {
                Image(systemName: "square.stack.3d.down.right")
            }
        }
        .frame(width: 18, height: 18)
        .overlay(alignment: .topTrailing) {
            if outstanding > 1 {
                Text("\(outstanding)")
                    .font(.system(size: 8, weight: .bold)).monospacedDigit()
                    .padding(.horizontal, 3).padding(.vertical, 0.5)
                    .background(StudioStyle.accent, in: Capsule())
                    .foregroundStyle(.black)
                    .offset(x: 6, y: -5)
            }
        }
    }
}

struct RenderActivityList: View {
    @Bindable var model: ProjectModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Renders").font(.system(size: 13, weight: .semibold))
                Spacer()
                if model.renders.jobs.contains(where: \.isDone) {
                    Button("Clear") { model.renders.clearDone() }
                        .buttonStyle(.borderless).controlSize(.small)
                }
                Button { model.ui.showRenderActivity = false; model.perform(.renderSheet) } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Render… (⌘⇧R)")
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
            Divider()
            if model.renders.jobs.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "film.stack").font(.system(size: 22, weight: .light)).foregroundStyle(.tertiary)
                    Text("No renders yet").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    Text("⌘⇧R picks a preset · ⌘R renders \(model.renders.lastPreset.title)")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
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
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tint.opacity(0.16))
                Image(systemName: job.preset.symbol).font(.system(size: 13)).foregroundStyle(tint)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Text(job.scene).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text("·").foregroundStyle(.tertiary)
                    Text(job.preset.title).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    if job.range != nil {
                        StudioBadge(text: job.durationLabel, color: .secondary)
                    }
                    Spacer(minLength: 4)
                    if !job.isDone {
                        Button { model.renders.cancel(job.id) } label: {
                            Image(systemName: "stop.circle.fill").font(.system(size: 14))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help(job.state == .queued ? "Remove from queue" : "Stop render (⌘.)")
                    }
                }
                status
                if case .finished = job.state { actions }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var tint: Color {
        switch job.state {
        case .failed: return StudioStyle.bad
        case .cancelled: return .secondary
        case .finished: return StudioStyle.ok
        default: return StudioStyle.accent
        }
    }

    @ViewBuilder private var status: some View {
        switch job.state {
        case .queued:
            caption("Queued")
        case .building(let line):
            VStack(alignment: .leading, spacing: 4) {
                ProgressBar(fraction: nil)
                caption(job.build == .optimized ? "Release build · \(line)" : line).lineLimit(1).truncationMode(.middle)
            }
        case .rendering(let done, let total, let fps):
            VStack(alignment: .leading, spacing: 4) {
                ProgressBar(fraction: job.fraction)
                HStack(spacing: 0) {
                    caption(total > 0 ? "\(done.formatted())/\(total.formatted())" : "Starting…")
                    if fps > 0 { caption(String(format: " · %.0f fps", fps)) }
                    Spacer()
                    if let eta = job.eta { caption(String(format: "ETA %d:%02d", Int(eta) / 60, Int(eta) % 60)) }
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
                Image(systemName: "checkmark.circle.fill").foregroundStyle(StudioStyle.ok).font(.system(size: 10.5))
                caption(String(format: "Done in %@", Self.clock(secs)) + (job.bytes.map { " · " + Self.size($0) } ?? ""))
                caption(" · " + job.output.lastPathComponent).lineLimit(1).truncationMode(.middle)
            }
        case .failed(let why):
            Text(why)
                .font(.system(size: 11)).foregroundStyle(StudioStyle.bad)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .help(job.log.suffix(12).joined(separator: "\n"))
        case .cancelled:
            caption("Cancelled")
        }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Button("Reveal in Finder") { SourceOpener.reveal(job.output) }
            Button("Open") { NSWorkspace.shared.open(job.output) }
            let comments = model.renders.attachableComments(scene: job.scene)
            Menu("Attach to Comment") {
                if comments.isEmpty {
                    Text("No open comments on \(job.scene)")
                }
                ForEach(comments) { c in
                    Button("\(c.timecode)  \(c.body.prefix(48))") { attach(to: c.id) }
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
            model.ui.toast = "Attached \(job.output.lastPathComponent) to \(id)"
        } catch {
            model.ui.toast = "Couldn't attach: \(error)"
        }
    }

    private func caption(_ s: String) -> some View {
        Text(s).font(.system(size: 11)).foregroundStyle(.secondary)
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
                Capsule().fill(Color.white.opacity(0.09))
                if let fraction {
                    Capsule().fill(StudioStyle.accent).frame(width: max(4, g.size.width * fraction))
                } else {
                    ProgressView().progressViewStyle(.linear).tint(StudioStyle.accent).labelsHidden()
                }
            }
        }
        .frame(height: 5)
    }
}
