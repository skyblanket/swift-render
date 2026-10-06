import AppKit
import SwiftUI
import SwiftRenderKit

// MARK: - Build HUD
//
// Toolbar pill (Built 1.3s · Building [12/40] · Waiting for another swift build ·
// N errors · Host starting · Host crashed), a diagnostics popover whose rows open
// the source in the editor, and the crash card shown over the viewer.

struct BuildPill: View {
    @Bindable var model: ProjectModel

    private enum Tone { case ok, busy, bad, neutral }

    private var state: (tone: Tone, symbol: String, text: String) {
        let b = model.build, h = model.host
        if case .crashed = h.state { return (.bad, "xmark.octagon.fill", "Host crashed") }
        if case .failed = h.state, !b.isBuilding { return (.bad, "xmark.octagon.fill", "Host stopped") }
        switch b.phase {
        case .waitingForLock: return (.busy, "hourglass", "Waiting for another swift build")
        case .building:
            if let p = b.progress { return (.busy, "hammer.fill", "Building… [\(p.done)/\(p.total)]") }
            return (.busy, "hammer.fill", "Building…")
        case .failed(let errs, _):
            let muted = b.agentEditing ? " (agent editing)" : ""
            return (.bad, "exclamationmark.triangle.fill", "\(errs.count) error\(errs.count == 1 ? "" : "s")\(muted)")
        case .succeeded(let s, let at):
            if case .swapping = h.state { return (.busy, "arrow.triangle.2.circlepath", "Swapping host…") }
            return (.ok, "checkmark.circle.fill", String(format: "Built %.1fs · ", s) + at.formatted(date: .omitted, time: .shortened))
        case .idle:
            switch h.state {
            case .starting: return (.neutral, "circle.dotted", "Host starting")
            case .ready: return (.ok, "checkmark.circle.fill", model.isFake ? "Fake host ready" : "Ready")
            case .swapping: return (.busy, "arrow.triangle.2.circlepath", "Swapping host…")
            case .idle: return (.neutral, "circle.dotted", "Idle")
            default: return (.neutral, "circle.dotted", "Starting")
            }
        }
    }

    private func color(_ t: Tone) -> Color {
        switch t {
        case .ok: return StudioStyle.ok
        case .busy: return StudioStyle.warn
        case .bad: return StudioStyle.bad
        case .neutral: return .secondary
        }
    }

    var body: some View {
        let s = state
        Button {
            model.ui.showBuildPopover.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: s.symbol)
                    .foregroundStyle(color(s.tone))
                    .symbolEffect(.pulse, isActive: s.tone == .busy)
                Text(s.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 230, alignment: .leading)
                Text("gen \(model.host.generation)")
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
        }
        .help("Build status — click for diagnostics (⌘B to build)")
        .popover(isPresented: $model.ui.showBuildPopover, arrowEdge: .bottom) {
            BuildDiagnosticsPopover(model: model)
        }
    }
}

struct BuildDiagnosticsPopover: View {
    @Bindable var model: ProjectModel

    var body: some View {
        let b = model.build
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(headline).font(.headline)
                Spacer()
                Button { model.perform(.build) } label: { Label("Build", systemImage: "hammer") }
                    .keyboardShortcut("b", modifiers: .command)
                    .disabled(b.isBuilding)
            }
            .padding(12)
            if let swapError = model.host.swapError {
                Label(swapError, systemImage: "arrow.uturn.backward.circle")
                    .font(.callout).foregroundStyle(StudioStyle.warn)
                    .padding(.horizontal, 12).padding(.bottom, 8)
            }
            Divider()
            if b.diagnostics.isEmpty {
                ContentUnavailableView("No diagnostics", systemImage: "checkmark.seal",
                                       description: Text(b.isBuilding ? "Building…" : "The last build was clean."))
                    .frame(height: 140)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(b.diagnostics, id: \.self) { d in
                            DiagnosticRow(diagnostic: d, root: model.project.root)
                            Divider().opacity(0.4)
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
            Divider()
            HStack {
                Button("Copy log") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(b.log, forType: .string)
                }
                Spacer()
                Button {
                    model.ui.showBuildPopover = false
                    model.perform(.askAgent)
                } label: { Label("Ask Claude to fix the build", systemImage: "sparkles") }
                    .disabled(b.errors.isEmpty)
            }
            .padding(10)
        }
        .frame(width: 560)
    }

    private var headline: String {
        let b = model.build
        switch b.phase {
        case .failed(let errs, _):
            let w = b.warnings.count
            return "\(errs.count) error\(errs.count == 1 ? "" : "s") · \(w) warning\(w == 1 ? "" : "s") — showing gen \(model.host.generation)"
        case .succeeded(let s, _): return String(format: "Build %d succeeded (%.1fs)", b.generation, s)
        case .building(let line): return line
        case .waitingForLock: return "Waiting for another swift build"
        case .idle: return "Build"
        }
    }
}

struct DiagnosticRow: View {
    var diagnostic: CompilerDiagnostic
    var root: URL

    var body: some View {
        let d = diagnostic
        Button {
            if !d.file.isEmpty { SourceOpener.open(d) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: d.severity == .error ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(d.severity == .error ? StudioStyle.bad : StudioStyle.warn)
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.message).font(.callout).lineLimit(3).multilineTextAlignment(.leading)
                    if !d.file.isEmpty {
                        Text("\(relative(d.file)):\(d.line):\(d.column)")
                            .font(StudioStyle.monoSmall).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if !d.file.isEmpty {
                    Image(systemName: "arrow.up.forward.square").foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12).padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .help(d.file.isEmpty ? "" : "Open in \(SourceOpener.preferred.title)")
    }

    private func relative(_ path: String) -> String {
        let r = root.path + "/"
        return path.hasPrefix(r) ? String(path.dropFirst(r.count)) : path
    }
}

/// Shown over the viewer after a host crash (or hang).
struct CrashCard: View {
    @Bindable var model: ProjectModel
    var crash: HostCrash

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.trianglebadge.exclamationmark.fill").foregroundStyle(StudioStyle.bad)
                Text(crash.t.map { "Scene crashed at \(StudioStyle.timecode($0)) (f\(frameIndex($0, fps: model.playback.fps)))" }
                     ?? "Scene crashed")
                    .font(.headline)
                Spacer()
                Button { model.host.crash = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
            }
            Text(crash.message).font(.system(.callout, design: .monospaced))
            if let loc = crash.location {
                Button {
                    SourceOpener.open(loc)
                } label: {
                    HStack {
                        Text("\(URL(fileURLWithPath: loc.file).lastPathComponent):\(loc.line)")
                            .font(StudioStyle.mono)
                        if let s = crash.symbol { Text("in \(s)").foregroundStyle(.secondary).lineLimit(1) }
                        Spacer()
                        Text("Open").foregroundStyle(.tint)
                    }
                }
                .buttonStyle(.plain)
            }
            Text(statusLine).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button { model.perform(.askAgent) } label: { Label("Ask Claude to fix", systemImage: "sparkles") }
                Button("Copy backtrace") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(crash.report, forType: .string)
                }
                .disabled(crash.report.isEmpty)
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 440)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(StudioStyle.bad.opacity(0.5)))
        .shadow(radius: 18)
    }

    private var statusLine: String {
        switch model.host.state {
        case .ready: return "Host restarted · this frame is skipped until the next build"
        case .failed(let why): return why
        default: return "Restarting host…"
        }
    }
}
