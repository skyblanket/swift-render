import SwiftUI
import SwiftRenderKit

// MARK: - Agent panel   // S8
//
// Header: run state with live elapsed time (cost and duration once finished), comment
// chips that open their threads, Revert run, Stop. Body: the transcript — the agent's
// text, one row per tool call (icon, name, one-line summary, file chips with +/− since
// the checkpoint, result mark), notices and the final line — and, when the run wrote
// files, a column listing them with their diff stats.

struct AgentPanel: View {
    @Bindable var model: ProjectModel
    @State private var confirmRevert = false

    var body: some View {
        let agent = model.agent
        VStack(spacing: 0) {
            header(agent)
            Divider()
            if agent.transcript.isEmpty {
                empty
            } else {
                HStack(spacing: 0) {
                    transcript(agent)
                    if let run = agent.currentRun, !run.touched.isEmpty {
                        Divider()
                        FilesColumn(run: run, root: model.project.root)
                            .frame(width: 230)
                    }
                }
            }
        }
        .background(StudioStyle.laneBackground)
        .confirmationDialog(revertTitle, isPresented: $confirmRevert) {
            Button("Revert Files", role: .destructive) {
                if let id = agent.currentRun?.id { Task { await agent.revert(id) } }
            }
        } message: {
            Text(revertMessage)
        }
    }

    // MARK: Header

    private func header(_ agent: AgentController) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(.purple)
            Text("Agent").font(.system(size: 11, weight: .semibold))
            if let run = agent.currentRun {
                RunStateBadge(run: run, running: agent.isRunning, stopping: agent.isStopping)
                Text(run.mode.title).foregroundStyle(.tertiary)
                if run.fixBuild { StudioBadge(text: "build", color: StudioStyle.bad) }
                ForEach(run.commentIDs, id: \.self) { id in commentChip(id) }
            } else {
                Text("idle").foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let run = agent.currentRun, run.canRevert {
                Button { confirmRevert = true } label: { Label("Revert Run", systemImage: "arrow.uturn.backward") }
                    .help("Restore the \(run.touched.count) file\(run.touched.count == 1 ? "" : "s") this run wrote to checkpoint \(run.checkpoint?.sha.prefix(8) ?? "")")
            }
            if agent.isRunning {
                Button { model.perform(.stop) } label: { Label("Stop", systemImage: "stop.fill") }
                    .disabled(agent.isStopping)
                    .help("Stop the agent (⌘.)")
            } else {
                Button { model.perform(.askAgent) } label: { Label("Ask…", systemImage: "sparkles") }
                    .help("Ask Claude (⌘⇧A)")
                if !agent.transcript.isEmpty {
                    Button { agent.clearTranscript() } label: { Image(systemName: "clear") }
                        .buttonStyle(.borderless)
                        .help("Clear transcript")
                }
            }
            Button { model.ui.showAgentPanel = false } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .help("Hide agent panel (⌘⌥J)")
        }
        .controlSize(.small)
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(.bar)
    }

    private func commentChip(_ id: String) -> some View {
        let c = model.review.comments.first { $0.id == id }
        return Button {
            model.review.selection = id
            model.ui.inspectorTab = .comments
            model.ui.showInspector = true
            if let c { model.playback.seek(c.t, precise: true) }
        } label: {
            HStack(spacing: 3) {
                Circle().fill(c.map { StudioStyle.color($0.status) } ?? .gray).frame(width: 6, height: 6)
                Text(String(id.prefix(5))).font(StudioStyle.monoSmall)
            }
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.primary.opacity(0.07), in: Capsule())
        }
        .buttonStyle(.plain)
        .help(c.map { "\($0.timecode) · \($0.status.rawValue) — \($0.body)" } ?? id)
    }

    // MARK: Body

    private var empty: some View {
        HStack(spacing: 6) {
            Text("No agent run yet.").foregroundStyle(.secondary)
            Text("Select comments and press ⌘⇧A to ask Claude to fix them.").foregroundStyle(.tertiary)
            Spacer()
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
    }

    private func transcript(_ agent: AgentController) -> some View {
        let run = agent.currentRun
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(agent.transcript) { row in
                        TranscriptRow(row: row, run: run, root: model.project.root,
                                      pending: agent.isRunning && row.kind == .tool && row.ok == nil)
                            .id(row.id)
                    }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: agent.transcript.count) {
                if let last = agent.transcript.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onAppear {
                if let last = agent.transcript.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private var revertTitle: String {
        let n = model.agent.currentRun?.touched.count ?? 0
        return "Revert \(n) file\(n == 1 ? "" : "s") written by this run?"
    }

    private var revertMessage: String {
        guard let run = model.agent.currentRun, let cp = run.checkpoint else { return "" }
        let names = run.touched.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")
        return "\(names) go back to checkpoint \(cp.sha.prefix(8)) (taken before the run). Files the agent created move to the Trash. Comment threads are not changed."
    }
}

// MARK: - Rows

private struct RunStateBadge: View {
    var run: AgentRun
    var running: Bool
    var stopping: Bool

    var body: some View {
        if running {
            SwiftUI.TimelineView(.periodic(from: run.startedAt, by: 1)) { ctx in
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 10, height: 10)
                    Text(stopping ? "Stopping" : "Running").foregroundStyle(.purple)
                    Text(AgentController.duration(ctx.date.timeIntervalSince(run.startedAt)))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
            }
        } else {
            HStack(spacing: 4) {
                Image(systemName: icon).foregroundStyle(color)
                Text(title).foregroundStyle(color)
                if let s = run.seconds { Text(AgentController.duration(s)).monospacedDigit().foregroundStyle(.secondary) }
                if let c = run.costUSD { Text(String(format: "$%.2f", c)).monospacedDigit().foregroundStyle(.secondary) }
                if run.reverted { StudioBadge(text: "reverted", color: StudioStyle.warn) }
            }
        }
    }

    private var title: String { run.stopped ? "Stopped" : run.ok == true ? "Done" : "Failed" }
    private var icon: String { run.stopped ? "stop.circle.fill" : run.ok == true ? "checkmark.circle.fill" : "xmark.octagon.fill" }
    private var color: Color { run.stopped ? .secondary : run.ok == true ? StudioStyle.ok : StudioStyle.bad }
}

private struct TranscriptRow: View {
    var row: AgentTranscriptRow
    var run: AgentRun?
    var root: URL
    var pending: Bool

    var body: some View {
        switch row.kind {
        case .text:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "text.bubble").foregroundStyle(.purple.opacity(0.8)).frame(width: 16)
                Text(row.title)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.primary.opacity(0.92))
                    .lineLimit(6)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 4)
        case .tool, .result:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: Self.symbol(row.title)).foregroundStyle(row.writes ? StudioStyle.accent : .secondary)
                    .frame(width: 16)
                Text(row.title)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(row.writes ? StudioStyle.accent : .primary)
                    .fixedSize()
                ForEach(row.files, id: \.self) { f in FileChip(path: f, stat: run?.stat(for: f), root: root) }
                Text(detail)
                    .font(StudioStyle.monoSmall).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 6)
                mark
            }
            .padding(.horizontal, 12).padding(.vertical, 2.5)
        case .status:
            HStack(spacing: 8) {
                Rectangle().fill(StudioStyle.hairline).frame(width: 14, height: 1)
                Text(row.title).font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary).lineLimit(1)
                Rectangle().fill(StudioStyle.hairline).frame(height: 1)
            }
            .padding(.horizontal, 12).padding(.vertical, 4)
        case .notice:
            Label(row.title, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11)).foregroundStyle(StudioStyle.warn)
                .padding(.horizontal, 12).padding(.vertical, 2.5)
        case .error:
            Label(row.title, systemImage: "xmark.octagon.fill")
                .font(.system(size: 11)).foregroundStyle(StudioStyle.bad)
                .textSelection(.enabled)
                .padding(.horizontal, 12).padding(.vertical, 2.5)
        case .finished:
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: row.ok == true ? "checkmark.seal.fill" : "xmark.seal.fill")
                    Text(row.title).font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(row.ok == true ? StudioStyle.ok : StudioStyle.bad)
                if !row.detail.isEmpty {
                    Text(row.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(8).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((row.ok == true ? StudioStyle.ok : StudioStyle.bad).opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 10).padding(.vertical, 4)
        }
    }

    private var detail: String {
        // The file is already a chip; keep only what follows it.
        guard !row.files.isEmpty else { return row.detail }
        let rel = row.files.first.map { relative($0) } ?? ""
        return row.detail.hasPrefix(rel) ? String(row.detail.dropFirst(rel.count)).trimmingCharacters(in: .whitespaces) : row.detail
    }

    private func relative(_ p: String) -> String {
        let r = root.path + "/"
        return p.hasPrefix(r) ? String(p.dropFirst(r.count)) : p
    }

    @ViewBuilder private var mark: some View {
        if pending {
            ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 12, height: 12)
        } else if let ok = row.ok {
            Image(systemName: ok ? "checkmark" : "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(ok ? StudioStyle.ok : StudioStyle.bad)
        }
    }

    static func symbol(_ tool: String) -> String {
        switch tool {
        case "Read": return "doc.text"
        case "Edit", "MultiEdit": return "pencil"
        case "Write": return "doc.badge.plus"
        case "Bash": return "terminal"
        case "Glob", "Grep": return "magnifyingglass"
        case "build": return "hammer"
        case "render_frames", "contact_sheet": return "photo"
        case "check_scene": return "stethoscope"
        case "list_comments", "list_scenes": return "list.bullet"
        case "get_comment": return "text.bubble"
        case "claim_comment": return "hand.raised"
        case "reply_comment": return "arrowshape.turn.up.left"
        case "resolve_comment": return "checkmark.circle"
        case "scene_info": return "info.circle"
        case "set_knobs": return "slider.horizontal.3"
        case "render_video": return "film"
        case "Result": return "arrow.turn.down.right"
        case "Error": return "xmark.circle"
        default: return "wrench.and.screwdriver"
        }
    }
}

private struct FileChip: View {
    var path: String
    var stat: Checkpoint.FileStat?
    var root: URL

    var body: some View {
        Button { SourceOpener.open(file: path, line: 1) } label: {
            HStack(spacing: 4) {
                Image(systemName: "swift").font(.system(size: 9)).foregroundStyle(.orange)
                Text(URL(fileURLWithPath: path).lastPathComponent).font(.system(size: 10.5, weight: .medium))
                if let stat { DiffStat(stat: stat) }
            }
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help("Open \(path) in \(SourceOpener.preferred.title)")
        .fixedSize()
    }
}

private struct DiffStat: View {
    var stat: Checkpoint.FileStat
    var body: some View {
        HStack(spacing: 3) {
            if stat.created { Text("new").foregroundStyle(StudioStyle.accent) }
            Text("+\(stat.added)").foregroundStyle(StudioStyle.ok)
            if !stat.created { Text("−\(stat.removed)").foregroundStyle(StudioStyle.bad) }
        }
        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
    }
}

/// Files the run wrote, with diff stats once it finishes.
private struct FilesColumn: View {
    var run: AgentRun
    var root: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("FILES").font(StudioStyle.laneLabel).foregroundStyle(.tertiary)
                Spacer()
                if let cp = run.checkpoint {
                    Text("since \(cp.sha.prefix(7))").font(StudioStyle.monoSmall).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(run.touched, id: \.self) { f in
                        Button { SourceOpener.open(file: f, line: 1) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "doc").font(.system(size: 10)).foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(URL(fileURLWithPath: f).lastPathComponent).font(.system(size: 11, weight: .medium))
                                    Text(folder(f)).font(.system(size: 9.5)).foregroundStyle(.tertiary)
                                        .lineLimit(1).truncationMode(.head)
                                }
                                Spacer(minLength: 4)
                                if let s = run.stat(for: f) { DiffStat(stat: s) }
                                else if run.reverted { Text("reverted").font(.system(size: 9.5)).foregroundStyle(.tertiary) }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                    }
                }
            }
            if let why = run.checkpointError {
                Text("No checkpoint: \(why)").font(.system(size: 9.5)).foregroundStyle(StudioStyle.warn)
                    .lineLimit(2).padding(8)
            }
        }
        .background(Color.black.opacity(0.12))
    }

    private func folder(_ p: String) -> String {
        let dir = URL(fileURLWithPath: p).deletingLastPathComponent().path
        let r = root.path
        return dir.hasPrefix(r) ? String(dir.dropFirst(r.count + (dir.count > r.count ? 1 : 0))) : dir
    }
}
