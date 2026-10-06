import AppKit
import SwiftUI
import SwiftRenderKit

// MARK: - Build status
//
// The toolbar's activity view ("Up to date", "Building… 30%", "Claude's on it · 0:42",
// "Build Failed · 2 Errors"), the diagnostics popover it opens (rows open the source),
// the build banner over the viewer, and the crash card. Build errors win over a stopped
// preview: a failed build is the reason the preview stopped, so that is what we say.

struct ActivityStatus: Equatable {
    enum Tone: Equatable { case calm, busy, error }
    var text: String
    var tone: Tone
    /// 0…1 when known (builds).
    var fraction: Double?
    var help: String
    /// Claude's run start: the view appends a live elapsed time.
    var since: Date?

    @MainActor
    static func make(_ model: ProjectModel) -> ActivityStatus {
        let b = model.build, h = model.host, a = model.agent
        if a.isRunning, let run = a.currentRun {
            return ActivityStatus(text: a.isStopping ? "Stopping Claude…" : "Claude's on it", tone: .busy,
                                  help: "Claude is working. Click for build details.", since: run.startedAt)
        }
        if case .failed(let diags, _) = b.phase {
            let errs = diags.filter { $0.severity == .error }.count
            if errs > 0 {
                return ActivityStatus(text: "Build Failed · \(errs) Error\(errs == 1 ? "" : "s")", tone: .error,
                                      help: "Click to see what went wrong")
            }
        }
        if case .crashed = h.state { return ActivityStatus(text: "Preview crashed", tone: .error, help: "The film crashed. Studio is restarting it.") }
        switch b.phase {
        case .building:
            let f = b.progress.flatMap { $0.total > 0 ? Double($0.done) / Double($0.total) : nil }
            return ActivityStatus(text: f.map { "Building… \(Int(($0 * 100).rounded()))%" } ?? "Building…", tone: .busy,
                                  fraction: f, help: "Building \(b.product)")
        case .waitingForLock:
            return ActivityStatus(text: "Waiting for another build…", tone: .busy,
                                  help: "Another swift build is using this folder. Studio goes next.")
        default: break
        }
        switch h.state {
        case .swapping: return ActivityStatus(text: "Updating…", tone: .busy, help: "Switching to the new build")
        case .failed: return ActivityStatus(text: "Preview stopped", tone: .error, help: "Click for details")
        case .starting, .idle: return ActivityStatus(text: "Warming up…", tone: .busy, help: "Starting the preview")
        default: break
        }
        if case .succeeded(let s, let at) = b.phase {
            return ActivityStatus(text: "Up to date", tone: .calm,
                                  help: "Built in \(StudioTime.compact(s)) at \(at.formatted(date: .omitted, time: .shortened))")
        }
        return ActivityStatus(text: "Up to date", tone: .calm, help: model.isFake ? "Running a stand-in preview" : "Ready")
    }
}

/// Xcode-style status field in the toolbar's principal slot.
struct ActivityView: View {
    @Bindable var model: ProjectModel

    var body: some View {
        let s = ActivityStatus.make(model)
        Button { model.ui.showBuildPopover.toggle() } label: {
            HStack(spacing: StudioStyle.Space.s) {
                glyph(s)
                Group {
                    if let since = s.since {
                        SwiftUI.TimelineView(.periodic(from: since, by: 1)) { ctx in
                            Text("\(s.text) · \(StudioTime.compact(ctx.date.timeIntervalSince(since)).replacingOccurrences(of: " s", with: "s"))")
                        }
                    } else {
                        Text(s.text)
                    }
                }
                .font(StudioStyle.Fonts.callout)
                .monospacedDigit()
                .foregroundStyle(s.tone == .error ? AnyShapeStyle(StudioStyle.error) : AnyShapeStyle(.secondary))
                .lineLimit(1)
            }
            .padding(.horizontal, StudioStyle.Space.m)
            .frame(minWidth: 200, maxWidth: 320, minHeight: 24)
            .background(StudioStyle.well, in: StudioStyle.rounded(StudioStyle.Radius.medium))
            .overlay(alignment: .bottom) {
                if let f = s.fraction {
                    GeometryReader { g in
                        Capsule().fill(StudioStyle.accent).frame(width: g.size.width * f, height: 2)
                    }
                    .frame(height: 2)
                    .padding(.horizontal, StudioStyle.Space.s)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(s.help)
        .popover(isPresented: $model.ui.showBuildPopover, arrowEdge: .bottom) {
            BuildDiagnosticsPopover(model: model)
        }
    }

    @ViewBuilder private func glyph(_ s: ActivityStatus) -> some View {
        switch s.tone {
        case .busy: ProgressView().controlSize(.mini)
        case .error: Image(systemName: StudioStyle.Symbol.error).foregroundStyle(StudioStyle.error)
        case .calm: Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
        }
    }
}

struct BuildDiagnosticsPopover: View {
    @Bindable var model: ProjectModel

    var body: some View {
        let b = model.build
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(headline).font(StudioStyle.Fonts.headline)
                Spacer()
                Button("Rebuild Now") { model.perform(.build) }
                    .keyboardShortcut("b", modifiers: .command)
                    .disabled(b.isBuilding)
            }
            .padding(StudioStyle.Space.m)
            if model.host.swapError != nil {
                Label("The new build didn't start, so Studio kept the last one that worked.", systemImage: "arrow.uturn.backward.circle")
                    .font(StudioStyle.Fonts.callout).foregroundStyle(.secondary)
                    .help(model.host.swapError ?? "")
                    .padding(.horizontal, StudioStyle.Space.m).padding(.bottom, StudioStyle.Space.s)
            }
            Divider()
            if b.diagnostics.isEmpty {
                StudioEmptyState(title: b.isBuilding ? "Building…" : "All clear", symbol: StudioStyle.Symbol.build,
                                 message: b.isBuilding ? nil : "The last build had no errors or warnings.")
                    .frame(height: 150)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(b.diagnostics, id: \.self) { d in
                            DiagnosticRow(diagnostic: d, root: model.project.root)
                            Divider().opacity(0.5)
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
            Divider()
            HStack {
                Button("Copy Log") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(b.log, forType: .string)
                }
                Spacer()
                Button("Ask Claude to Fix") {
                    model.ui.showBuildPopover = false
                    model.perform(.askAgent)
                }
                .disabled(b.errors.isEmpty)
            }
            .padding(StudioStyle.Space.m)
        }
        .frame(width: 520)
    }

    private var headline: String {
        let b = model.build
        switch b.phase {
        case .failed(let errs, _):
            return "Build failed · " + BuildErrorBanner.counts(errors: errs.filter { $0.severity == .error }.count, warnings: b.warnings.count)
        case .succeeded(let s, _): return "Up to date · built in \(StudioTime.compact(s))"
        case .building: return "Building…"
        case .waitingForLock: return "Waiting for another build…"
        case .idle: return "Build"
        }
    }
}

/// A compiler message: the message in callout, file:line under it in small monospace.
struct DiagnosticRow: View {
    var diagnostic: CompilerDiagnostic
    var root: URL

    var body: some View {
        let d = diagnostic
        Button {
            if !d.file.isEmpty { SourceOpener.open(d) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: StudioStyle.Space.s) {
                Image(systemName: d.severity == .error ? StudioStyle.Symbol.error : StudioStyle.Symbol.warning)
                    .foregroundStyle(d.severity == .error ? StudioStyle.error : StudioStyle.warning)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.message).font(StudioStyle.Fonts.callout).lineLimit(2).multilineTextAlignment(.leading)
                    if !d.file.isEmpty {
                        Text("\(relative(d.file)):\(d.line)")
                            .font(StudioStyle.Fonts.codeSmall).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                }
                Spacer(minLength: StudioStyle.Space.s)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, StudioStyle.Space.m).padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .help(d.file.isEmpty ? "" : "Open in \(SourceOpener.preferred.title)")
    }

    private func relative(_ path: String) -> String {
        let r = root.path + "/"
        return path.hasPrefix(r) ? String(path.dropFirst(r.count)) : path
    }
}

/// Build errors above the viewer, on chrome (no wash): only the glyphs are colored. The
/// viewer below keeps showing the last good build. Quiet while Claude is mid-edit (its
/// in-between states often don't compile).
struct BuildErrorBanner: View {
    @Bindable var model: ProjectModel
    var errors: [CompilerDiagnostic]
    @State private var expanded = true

    var body: some View {
        let b = model.build
        let muted = b.agentEditing
        let rows = Array((errors + b.warnings).prefix(3))
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: StudioStyle.Space.s) {
                Image(systemName: StudioStyle.Symbol.error)
                    .foregroundStyle(muted ? AnyShapeStyle(.secondary) : AnyShapeStyle(StudioStyle.error))
                VStack(alignment: .leading, spacing: 0) {
                    Text(muted ? "Claude's editing" : "Build failed · " + Self.counts(errors: errors.count, warnings: b.warnings.count))
                        .font(StudioStyle.Fonts.calloutEmphasis)
                    Text(detail).font(StudioStyle.Fonts.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: StudioStyle.Space.s)
                Button("Ask Claude to Fix") { model.perform(.askAgent) }
                    .help("⌘⇧A")
                    .disabled(muted)
                Button("Show All Errors") { model.ui.showBuildPopover = true }
                Button { withAnimation(.snappy(duration: 0.2)) { expanded.toggle() } } label: {
                    Image(systemName: "chevron.down").rotationEffect(.degrees(expanded ? 0 : -90))
                }
                .buttonStyle(.borderless)
                .help(expanded ? "Hide the errors" : "Show the errors")
            }
            .controlSize(.small)
            .padding(.horizontal, StudioStyle.Space.m)
            .padding(.vertical, StudioStyle.Space.s)
            if expanded {
                ForEach(rows, id: \.self) { d in DiagnosticRow(diagnostic: d, root: model.project.root) }
                    .padding(.bottom, StudioStyle.Space.xs)
            }
        }
        .background(StudioStyle.chrome)
        .overlay(alignment: .bottom) { StudioStyle.hairline.frame(height: 1) }
        .opacity(muted ? 0.7 : 1)
    }

    /// "2 errors, 1 warning".
    static func counts(errors: Int, warnings: Int) -> String {
        "\(errors) error\(errors == 1 ? "" : "s")" + (warnings > 0 ? ", \(warnings) warning\(warnings == 1 ? "" : "s")" : "")
    }

    private var detail: String {
        if model.build.agentEditing { return "Errors in between edits are normal. Studio rebuilds when Claude's done." }
        return model.host.active == nil ? "Nothing to play until they're fixed." : "Showing the last version that worked."
    }
}

/// Shown over the viewer after the film crashes (or hangs) on a frame.
struct CrashCard: View {
    @Bindable var model: ProjectModel
    var crash: HostCrash

    var body: some View {
        VStack(alignment: .leading, spacing: StudioStyle.Space.s) {
            HStack(spacing: StudioStyle.Space.s) {
                Image(systemName: StudioStyle.Symbol.error).foregroundStyle(StudioStyle.error)
                Text(crash.t.map { "The film crashed at \(StudioTime.short($0))" } ?? "The film crashed")
                    .font(StudioStyle.Fonts.headline)
                    .help(crash.t.map { StudioTime.frameHelp($0, fps: model.playback.fps) } ?? "")
                Spacer()
                Button { model.host.crash = nil } label: { Image(systemName: StudioStyle.Symbol.close) }
                    .buttonStyle(.borderless)
                    .help("Dismiss")
            }
            Text(crash.message).font(StudioStyle.Fonts.code).foregroundStyle(.secondary).lineLimit(4)
            if let loc = crash.location {
                Button { SourceOpener.open(loc) } label: {
                    HStack(spacing: StudioStyle.Space.xs) {
                        Text(URL(fileURLWithPath: loc.file).lastPathComponent)
                        Image(systemName: StudioStyle.Symbol.reveal).imageScale(.small)
                    }
                    .font(StudioStyle.Fonts.callout)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Line \(loc.line)\(crash.symbol.map { " in \($0)" } ?? "")")
            }
            Text(statusLine).font(StudioStyle.Fonts.subheadline).foregroundStyle(.secondary)
            HStack {
                Button("Ask Claude to Fix") { model.perform(.askAgent) }
                Button("Copy Crash Details") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(crash.report, forType: .string)
                }
                .disabled(crash.report.isEmpty)
            }
            .controlSize(.small)
        }
        .padding(StudioStyle.Space.l)
        .frame(width: 420)
        .studioCard()
    }

    private var statusLine: String {
        switch model.host.state {
        case .ready: return "Studio skipped this frame. It'll try again after your next save."
        case .failed: return "The preview stopped. Save a fix and it starts again."
        default: return "Restarting the preview…"
        }
    }
}
