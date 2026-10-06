import AppKit
import SwiftUI
import SwiftRenderKit

// MARK: - Claude panel
//
// Hidden while idle; slides up when a run starts. Header: Claude's avatar and state
// ("Working… 0:42", "Done in 1:04 · $0.38"), the comments it's on (#1 #2), Undo Claude's
// Changes and Stop, and one … menu. Body: the run as plain steps ("Rebuilt the film ·
// 1.3 s", "Checked 3 frames around 0:07"), Claude's own words, and the files it changed
// with their +/− counts. Show Raw switches to the exact tool calls in monospace.

struct AgentPanel: View {
    @Bindable var model: ProjectModel
    @State private var confirmRevert = false
    @State private var showRaw = false
    /// Touched files edited again since the run (computed when Undo is clicked).
    @State private var changedSinceRun: [String] = []

    var body: some View {
        let agent = model.agent
        let numbers = model.review.comments.isEmpty ? [:] : ReviewController.numbering(model.review.comments)
        VStack(spacing: 0) {
            header(agent, numbers: numbers)
            Divider()
            if agent.transcript.isEmpty {
                empty
            } else {
                HStack(spacing: 0) {
                    transcript(agent, numbers: numbers)
                    if let run = agent.currentRun, !run.touched.isEmpty {
                        Divider()
                        FilesColumn(run: run, root: model.project.root)
                            .frame(width: 240)
                    }
                }
            }
        }
        .background(StudioStyle.chrome)
        .confirmationDialog(revertTitle, isPresented: $confirmRevert) {
            if changedSinceRun.isEmpty {
                Button("Undo Changes", role: .destructive) {
                    if let id = agent.currentRun?.id { Task { await agent.revert(id) } }
                }
            } else {
                Button("Undo Claude's, Keep Mine", role: .destructive) {
                    if let id = agent.currentRun?.id { Task { await agent.revert(id) } }
                }
                Button("Undo Everything", role: .destructive) {
                    if let id = agent.currentRun?.id { Task { await agent.revert(id, includeChanged: true) } }
                }
            }
        } message: {
            Text(revertMessage)
        }
    }

    // MARK: Header

    private func header(_ agent: AgentController, numbers: [String: Int]) -> some View {
        HStack(spacing: StudioStyle.Space.s) {
            AuthorAvatar(author: AgentController.agentAuthor, size: 22)
            Text("Claude").font(StudioStyle.Fonts.bodyEmphasis)
            if let run = agent.currentRun {
                RunState(run: run, running: agent.isRunning, stopping: agent.isStopping)
                ForEach(run.commentIDs, id: \.self) { id in commentChip(id, number: numbers[id]) }
                if run.fixBuild { Text("Build errors").font(StudioStyle.Fonts.subheadline).foregroundStyle(.secondary) }
            } else {
                Text("· Ready").foregroundStyle(.secondary)
            }
            Spacer(minLength: StudioStyle.Space.s)
            if let run = agent.currentRun, run.canRevert || agent.isRunning {
                ControlGroup {
                    if run.canRevert {
                        Button("Undo Claude's Changes") {
                            Task {
                                changedSinceRun = await agent.changedSinceRun(run.id)
                                confirmRevert = true
                            }
                        }
                        .help("Put the \(run.touched.count) file\(run.touched.count == 1 ? "" : "s") Claude changed back the way they were")
                    }
                    if agent.isRunning {
                        Button("Stop") { model.perform(.stop) }
                            .disabled(agent.isStopping)
                            .help("Stop Claude (⌘.)")
                    }
                }
                .fixedSize()
            }
            if !agent.isRunning {
                Button("Ask Claude…") { model.perform(.askAgent) }
                    .help("⌘⇧A")
            }
            Menu {
                if let p = agent.currentRun?.prompt {
                    Button("Copy Prompt") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(p, forType: .string)
                    }
                }
                Toggle("Show Raw Stream", isOn: $showRaw)
                if let log = agent.currentRun?.logURL, FileManager.default.fileExists(atPath: log.path) {
                    Button("Show Raw Stream in Finder") { SourceOpener.reveal(log) }
                }
                if let sid = agent.currentRun?.sessionID {
                    Button("Copy Session ID") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(sid, forType: .string)
                    }
                }
                Divider()
                Button("Clear Transcript") { agent.clearTranscript() }
                    .disabled(agent.isRunning || agent.transcript.isEmpty)
            } label: { Image(systemName: StudioStyle.Symbol.more) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("More")
            Button {
                model.ui.showAgentPanel = false
                if agent.isRunning { model.ui.agentPanelClosed = true }
            } label: { Image(systemName: StudioStyle.Symbol.close) }
                .buttonStyle(.borderless)
                .help("Hide the Claude panel (⌘⌥J)")
        }
        .controlSize(.small)
        .font(StudioStyle.Fonts.callout)
        .padding(.horizontal, StudioStyle.Space.m)
        .frame(height: 36)
    }

    private func commentChip(_ id: String, number: Int?) -> some View {
        let c = model.review.comments.first { $0.id == id }
        return Button {
            model.review.open(id)
            model.ui.inspectorTab = .comments
            model.ui.showInspector = true
            if let c { model.playback.seek(c.t, precise: true) }
        } label: {
            CommentDisc(number: number, state: c.map(CommentState.init) ?? .open, size: 18)
        }
        .buttonStyle(.plain)
        .help(c.map { "#\(number ?? 0) · \(StudioTime.short($0.t)) · \(CommentState($0).title): \($0.body)" } ?? "A comment in another scene")
    }

    // MARK: Body

    private var empty: some View {
        StudioEmptyState(title: "Claude's ready when you are", symbol: StudioStyle.Symbol.comments,
                         message: "Pick a comment and press ⌘⇧A.")
    }

    private func transcript(_ agent: AgentController, numbers: [String: Int]) -> some View {
        let run = agent.currentRun
        let rows = showRaw ? agent.transcript : agent.transcript.filter { TranscriptText.isShown($0) }
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(rows) { row in
                        TranscriptRow(row: row, run: run, root: model.project.root, numbers: numbers, raw: showRaw,
                                      pending: agent.isRunning && row.kind == .tool && row.ok == nil)
                            .id(row.id)
                    }
                }
                .padding(.top, StudioStyle.Space.xl)
                .padding(.bottom, StudioStyle.Space.s)
            }
            .defaultScrollAnchor(.bottom)
            // A soft top edge, so a row scrolled under the header fades instead of being cut.
            .mask(VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: StudioStyle.Space.xl)
                Color.black
            })
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
        return "Undo the changes Claude made to \(n) file\(n == 1 ? "" : "s")?"
    }

    private var revertMessage: String {
        guard let run = model.agent.currentRun, run.checkpoint != nil else { return "" }
        let names = run.touched.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")
        var text = "\(names) go back to how they were before Claude started. New files Claude made move to the Trash. Studio keeps a copy of the current versions first, and your comments stay as they are."
        if !changedSinceRun.isEmpty {
            let changed = changedSinceRun.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")
            text += "\n\nYou've edited \(changed) since then. Keep your edits, or undo everything."
        }
        return text
    }
}

// MARK: - Plain-language steps

/// Turns transcript rows into short sentences, and comment IDs into "#1".
enum TranscriptText {
    /// Rows the friendly view shows (session and checkpoint bookkeeping stays in Show Raw).
    static func isShown(_ row: AgentTranscriptRow) -> Bool {
        guard row.kind == .status else { return true }
        return !(row.title.hasPrefix("Session ") || row.title.hasPrefix("Checkpoint "))
    }

    /// Every known comment ID becomes "#n".
    static func numbered(_ s: String, _ numbers: [String: Int]) -> String {
        var out = s
        for (id, n) in numbers.sorted(by: { $0.key.count > $1.key.count }) where out.contains(id) {
            out = out.replacingOccurrences(of: id, with: "#\(n)")
        }
        return out
    }

    /// "#1, #2 and #3".
    static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items.last!
    }

    /// The headline for a tool call.
    static func step(_ row: AgentTranscriptRow, numbers: [String: Int]) -> String {
        let file = row.files.first.map { URL(fileURLWithPath: $0).lastPathComponent }
        let refs = numbers.filter { row.detail.contains($0.key) }.values.sorted().map { "#\($0)" }
        let which = refs.isEmpty ? "a comment" : list(refs)
        switch row.title {
        case "Read": return "Read \(file ?? "a file")"
        case "Edit", "MultiEdit": return "Edited \(file ?? "a file")"
        case "Write": return "Wrote \(file ?? "a file")"
        case "Bash":
            if row.detail.contains("swift build") { return "Rebuilt the film" + seconds(row.detail) }
            return "Ran a command"
        case "build": return "Rebuilt the film" + seconds(row.detail)
        case "Glob", "Grep": return "Searched the code"
        case "render_frames":
            let times = frameTimes(row.detail)
            guard !times.isEmpty else { return "Checked some frames" }
            let mid = times.reduce(0, +) / Double(times.count)
            return "Checked \(times.count) frame\(times.count == 1 ? "" : "s") around \(StudioTime.short(mid.rounded()))"
        case "contact_sheet": return "Made a contact sheet"
        case "check_scene": return "Ran a health check"
        case "list_comments": return "Looked over the comments"
        case "list_scenes": return "Looked at the scenes"
        case "get_comment": return "Read \(which)"
        case "claim_comment": return "Picked up \(which)"
        case "reply_comment": return "Replied on \(which)"
        case "resolve_comment": return "Marked \(which) ready for review"
        case "scene_info": return "Looked at the scene"
        case "set_knobs": return "Adjusted knobs"
        case "render_video": return "Exported a video"
        case "TodoWrite": return "Made a plan"
        case "Result": return "Got a result"
        case "Error": return "Something went wrong"
        default: return row.title
        }
    }

    /// Status and notice lines, in plain words.
    static func line(_ text: String, numbers: [String: Int]) -> String {
        if text.hasPrefix("Back to open: ") {
            let ids = text.dropFirst("Back to open: ".count).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let refs = ids.map { numbers[$0].map { "#\($0)" } ?? $0 }
            return "\(list(refs)) \(refs.count == 1 ? "is" : "are") back on your list"
        }
        return numbered(text, numbers)
    }

    /// "c1 resolved: stagger halved" → "#1 is ready for review: stagger halved".
    static func result(_ text: String, numbers: [String: Int]) -> String {
        var s = numbered(text, numbers)
        if let r = s.range(of: #"(#\d+) resolved:"#, options: .regularExpression) {
            let ref = s[r].split(separator: " ").first.map(String.init) ?? ""
            s.replaceSubrange(r, with: "\(ref) is ready for review:")
        }
        return s
    }

    /// " · 1.3 s" from "… → Build complete! (1.3s)".
    private static func seconds(_ detail: String) -> String {
        guard let r = detail.range(of: #"\((\d+(\.\d+)?)s\)"#, options: .regularExpression) else { return "" }
        let n = detail[r].dropFirst().dropLast(2)
        return " · \(n) s"
    }

    /// "AppleLaunch @ 6.2s, 6.8s, 7.4s" → [6.2, 6.8, 7.4].
    private static func frameTimes(_ detail: String) -> [Double] {
        guard let at = detail.range(of: "@") else { return [] }
        let head = detail[at.upperBound...].components(separatedBy: "→").first ?? ""
        return head.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "s", with: "")) }
    }
}

// MARK: - Rows

private struct RunState: View {
    var run: AgentRun
    var running: Bool
    var stopping: Bool

    var body: some View {
        Group {
            if running {
                SwiftUI.TimelineView(.periodic(from: run.startedAt, by: 1)) { ctx in
                    HStack(spacing: StudioStyle.Space.xs) {
                        ProgressView().controlSize(.mini)
                        Text("\(stopping ? "Stopping…" : "Working…") \(AgentController.duration(ctx.date.timeIntervalSince(run.startedAt)))")
                            .monospacedDigit()
                    }
                }
            } else {
                Text("· " + summary).monospacedDigit()
            }
        }
        .foregroundStyle(.secondary)
        .help("Mode: \(run.mode.title)")
    }

    private var summary: String {
        if run.reverted { return "Changes undone" }
        if run.stopped { return "Stopped" }
        guard run.ok == true else { return "Didn't finish" }
        var s = "Done"
        if let secs = run.seconds { s += " in " + AgentController.duration(secs) }
        if let c = run.costUSD { s += String(format: " · $%.2f", c) }
        return s
    }
}

private struct TranscriptRow: View {
    var row: AgentTranscriptRow
    var run: AgentRun?
    var root: URL
    var numbers: [String: Int]
    var raw: Bool
    var pending: Bool

    var body: some View {
        Group {
            if raw { rawRow } else { friendlyRow }
        }
        .contentShape(Rectangle())
        .studioContextMenu(ContextMenus.transcript(text: copyText, file: row.files.first))
    }

    /// What Copy puts on the clipboard: the words as shown, plus the raw call underneath.
    private var copyText: String {
        let shown: String
        switch row.kind {
        case .tool, .result: shown = TranscriptText.step(row, numbers: numbers)
        case .finished: shown = row.detail.isEmpty ? (row.ok == true ? "Done." : "Claude didn't finish.") : row.detail
        default: shown = row.title
        }
        let raw = [row.title, row.detail].filter { !$0.isEmpty }.joined(separator: " ")
        return raw.isEmpty || raw == shown ? shown : shown + "\n" + raw
    }

    @ViewBuilder private var friendlyRow: some View {
        switch row.kind {
        case .text:
            HStack(alignment: .top, spacing: StudioStyle.Space.s) {
                AuthorAvatar(author: AgentController.agentAuthor, size: 18)
                Text(TranscriptText.numbered(row.title, numbers))
                    .font(StudioStyle.Fonts.callout)
                    .lineLimit(8)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, StudioStyle.Space.m).padding(.vertical, StudioStyle.Space.xs)
        case .tool, .result:
            HStack(alignment: .firstTextBaseline, spacing: StudioStyle.Space.s) {
                Image(systemName: Self.symbol(row.title)).foregroundStyle(.secondary).frame(width: 18)
                Text(TranscriptText.step(row, numbers: numbers))
                    .font(StudioStyle.Fonts.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if row.writes, let f = row.files.first, let stat = run?.stat(for: f) { DiffStat(stat: stat) }
                Spacer(minLength: StudioStyle.Space.s)
                mark
            }
            .help(([row.title, row.detail].filter { !$0.isEmpty }).joined(separator: " "))
            .padding(.horizontal, StudioStyle.Space.m).padding(.vertical, 2)
        case .status:
            Text(TranscriptText.line(row.title, numbers: numbers))
                .font(StudioStyle.Fonts.footnote).foregroundStyle(.tertiary).lineLimit(1)
                .padding(.horizontal, StudioStyle.Space.m).padding(.vertical, StudioStyle.Space.xs)
                .padding(.leading, 26)
        case .notice:
            HStack(alignment: .firstTextBaseline, spacing: StudioStyle.Space.s) {
                Image(systemName: "info.circle").foregroundStyle(.secondary).frame(width: 18)
                Text(TranscriptText.line(row.title, numbers: numbers))
                    .font(StudioStyle.Fonts.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, StudioStyle.Space.m).padding(.vertical, 2)
        case .error:
            HStack(alignment: .firstTextBaseline, spacing: StudioStyle.Space.s) {
                Image(systemName: StudioStyle.Symbol.error).foregroundStyle(StudioStyle.error).frame(width: 18)
                Text(TranscriptText.numbered(row.title, numbers)).font(StudioStyle.Fonts.callout).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, StudioStyle.Space.m).padding(.vertical, 2)
        case .finished:
            HStack(alignment: .firstTextBaseline, spacing: StudioStyle.Space.s) {
                Image(systemName: row.ok == true ? "checkmark.circle" : StudioStyle.Symbol.error)
                    .foregroundStyle(row.ok == true ? AnyShapeStyle(.secondary) : AnyShapeStyle(StudioStyle.error))
                    .frame(width: 18)
                Text(row.detail.isEmpty ? (row.ok == true ? "Done." : "Claude didn't finish.")
                                        : TranscriptText.result(row.detail, numbers: numbers))
                    .font(StudioStyle.Fonts.calloutEmphasis)
                    .lineLimit(6).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            // The run's summary: a small raised card.
            .padding(.horizontal, StudioStyle.Space.m).padding(.vertical, StudioStyle.Space.s)
            .studioCard(cornerRadius: StudioStyle.Radius.medium, shadow: false)
            .padding(.horizontal, StudioStyle.Space.s).padding(.vertical, StudioStyle.Space.xs)
        }
    }

    /// Show Raw: the exact tool calls and lines, monospace.
    private var rawRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: StudioStyle.Space.s) {
            Text(row.kind.rawValue).foregroundStyle(.tertiary).frame(width: 56, alignment: .leading)
            Text(row.title).fontWeight(.semibold).fixedSize()
            Text(row.detail).foregroundStyle(.secondary).lineLimit(2).truncationMode(.tail)
            Spacer(minLength: StudioStyle.Space.s)
            mark
        }
        .font(StudioStyle.Fonts.codeSmall)
        .textSelection(.enabled)
        .padding(.horizontal, StudioStyle.Space.m).padding(.vertical, 1)
    }

    @ViewBuilder private var mark: some View {
        if pending {
            ProgressView().controlSize(.mini)
        } else if let ok = row.ok {
            Image(systemName: ok ? "checkmark" : StudioStyle.Symbol.close)
                .font(StudioStyle.Fonts.footnote)
                .foregroundStyle(ok ? AnyShapeStyle(.secondary) : AnyShapeStyle(StudioStyle.error))
        }
    }

    static func symbol(_ tool: String) -> String {
        switch tool {
        case "Read": return "doc.text"
        case "Edit", "MultiEdit": return "pencil"
        case "Write": return "doc.badge.plus"
        case "Bash", "build": return "hammer"
        case "Glob", "Grep": return "magnifyingglass"
        case "render_frames", "contact_sheet": return "photo"
        case "check_scene": return "checklist"
        case "list_comments", "list_scenes": return "list.bullet"
        case "get_comment", "reply_comment": return "text.bubble"
        case "claim_comment": return "hand.raised"
        case "resolve_comment": return "checkmark.circle"
        case "scene_info": return "info.circle"
        case "set_knobs": return "slider.horizontal.3"
        case "render_video": return "film"
        case "Error": return "exclamationmark.circle"
        default: return "circle"
        }
    }
}

private struct DiffStat: View {
    var stat: Checkpoint.FileStat
    var body: some View {
        HStack(spacing: 3) {
            if stat.created { Text("New") }
            Text("+\(stat.added)")
            if !stat.created { Text("−\(stat.removed)") }
        }
        .font(StudioStyle.Fonts.footnote.weight(.medium))
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }
}

/// Files the run changed, with real file icons and +/− counts.
private struct FilesColumn: View {
    var run: AgentRun
    var root: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Changed Files")
                .padding(.horizontal, StudioStyle.Space.m).padding(.top, StudioStyle.Space.s).padding(.bottom, StudioStyle.Space.xs)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(run.touched, id: \.self) { f in
                        Button { SourceOpener.open(file: f, line: 1) } label: {
                            HStack(spacing: StudioStyle.Space.s) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: f))
                                    .resizable().frame(width: 18, height: 18)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(URL(fileURLWithPath: f).lastPathComponent).font(StudioStyle.Fonts.callout).lineLimit(1)
                                    Text(folder(f)).font(StudioStyle.Fonts.footnote).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.head)
                                }
                                Spacer(minLength: StudioStyle.Space.xs)
                                if let s = run.stat(for: f) { DiffStat(stat: s) }
                                else if run.reverted { Text("Undone").font(StudioStyle.Fonts.footnote).foregroundStyle(.secondary) }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Open \(f)")
                        .studioContextMenu(ContextMenus.file(f))
                        .padding(.horizontal, StudioStyle.Space.m).padding(.vertical, StudioStyle.Space.xs)
                    }
                }
            }
            if run.checkpointError != nil {
                Text("Studio couldn't save a restore point, so these can't be undone from here.")
                    .font(StudioStyle.Fonts.footnote).foregroundStyle(.secondary)
                    .lineLimit(3).padding(StudioStyle.Space.s)
                    .help(run.checkpointError ?? "")
            }
        }
    }

    private func folder(_ p: String) -> String {
        let dir = URL(fileURLWithPath: p).deletingLastPathComponent().path
        let r = root.path
        return dir.hasPrefix(r) ? String(dir.dropFirst(r.count + (dir.count > r.count ? 1 : 0))) : dir
    }
}
