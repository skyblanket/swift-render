import Foundation
import Observation
import SwiftRenderKit

// MARK: - Agent controller
//
// Run lifecycle (studio-ux §2.4):
//   checkpoint (fix runs) → claim the comments (inProgress, assignee Claude) → prompt →
//   backend run → transcript rows → on finish, any claim the agent didn't resolve goes
//   back to open with a note, and diff stats are computed against the checkpoint.
// While a run is active ProjectModel mutes build failures and raises the watcher
// debounce to 600 ms (`onRunningChanged`). The agent's own review writes arrive through
// the file watcher like any other; ours call `onReviewsChanged` so threads update at once.

/// One row in the agent panel.
struct AgentTranscriptRow: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case text, tool, result, status, notice, error, finished }
    let id = UUID()
    var kind: Kind
    var title: String
    var detail: String = ""
    var files: [String] = []
    /// Tool rows: the backend's call id, and the result once it arrives.
    var toolID: String?
    var ok: Bool?
    var writes = false
}

/// One ask → finish cycle.
struct AgentRun: Identifiable, Equatable, Sendable {
    let id: String
    var scene: String
    var mode: AgentRequest.Mode
    var commentIDs: [String]
    var fixBuild = false
    var startedAt: Date
    var sessionID: String?
    var model: String?
    var finished = false
    var ok: Bool?
    var stopped = false
    var costUSD: Double?
    var seconds: Double?
    var result: String?
    /// Comments Studio claimed for this run.
    var claimed: [String] = []
    /// Absolute paths the agent wrote (Edit/Write calls that succeeded — or whose result never
    /// arrived), first-touch order.
    var touched: [String] = []
    /// Write calls still waiting for their result: tool id → files.
    var pendingWrites: [String: [String]] = [:]
    /// Each touched file as the agent left it (`Checkpoint.fingerprint`), taken at finish:
    /// a file that differs at revert time was edited again since the run.
    var agentLeft: [String: String] = [:]
    /// Files that changed during the run but not through the agent's edit tools (the
    /// user's own edits, or Bash/MCP writes): listed, never reverted.
    var changedOutside: [String] = []
    var stats: [Checkpoint.FileStat] = []
    var checkpoint: Checkpoint?
    var checkpointError: String?
    var reverted = false
    /// What Studio sent, and the raw stream-json the backend saw (debugging, bug reports).
    var prompt: String?
    var logURL: URL?

    var canRevert: Bool { finished && !reverted && checkpoint != nil && !touched.isEmpty }
    func stat(for path: String) -> Checkpoint.FileStat? {
        guard let rel = checkpoint?.relative(path) else { return nil }
        return stats.first { $0.path == rel }
    }
}

@MainActor @Observable
final class AgentController {
    static let agentAuthor = ReviewAuthor.agent("Claude")
    /// Signs the notes Studio itself leaves in threads.
    static let studioAuthor = ReviewAuthor(name: "Studio", kind: .agent)

    let project: Project
    private(set) var runs: [AgentRun] = []
    private(set) var transcript: [AgentTranscriptRow] = []
    private(set) var isRunning = false
    private(set) var isStopping = false
    var lastError: String?

    @ObservationIgnored var backend: AgentBackend
    /// ProjectModel: mute build failures, raise the watcher debounce.
    @ObservationIgnored var onRunningChanged: ((Bool) -> Void)?
    /// ProjectModel: reload the review controller after Studio's own claim/release writes.
    @ObservationIgnored var onReviewsChanged: (() -> Void)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let store: ReviewStore

    init(project: Project, backend: AgentBackend = ClaudeCodeBackend()) {
        self.project = project
        self.backend = backend
        self.store = ReviewStore(project: project)
    }

    var currentRun: AgentRun? { runs.last }
    /// For "Continue last session".
    var lastSessionID: String? { runs.last { $0.sessionID != nil }?.sessionID }

    // MARK: Run

    /// Starts a run unless one is active. `info` is the open scene's structure (prompt context).
    func ask(_ request: AgentRequest, info: SceneInfo? = nil) {
        guard !isRunning else { return }
        let runID = ReviewIDs.make("run")
        var run = AgentRun(id: runID, scene: request.scene, mode: request.mode, commentIDs: request.commentIDs,
                           fixBuild: request.buildDiagnostics.contains { $0.severity == .error }, startedAt: Date())
        run.model = request.model
        runs.append(run)
        transcript = []
        isRunning = true
        isStopping = false
        lastError = nil
        onRunningChanged?(true)
        let what = [request.commentIDs.isEmpty ? nil : "\(request.commentIDs.count) comment\(request.commentIDs.count == 1 ? "" : "s")",
                    run.fixBuild ? "the build" : nil].compactMap { $0 }.joined(separator: " + ")
        status("\(request.mode.title) · \(what.isEmpty ? request.scene : what)"
               + (request.resumeSessionID != nil ? " · continuing session" : ""))
        task = Task { [weak self] in await self?.execute(request, runID: runID, info: info) }
    }

    private func execute(_ request: AgentRequest, runID: String, info: SceneInfo?) async {
        var req = request
        let project = self.project

        if req.mode.edits {
            do {
                let cp = try await Task.detached { try Checkpoint.create(project: project, runID: runID) }.value
                update(runID) { $0.checkpoint = cp }
                status("Checkpoint \(cp.sha.prefix(8)) → \(cp.ref)")
            } catch {
                update(runID) { $0.checkpointError = "\(error)" }
                notice("No checkpoint (\(error)) — this run can't be reverted from Studio")
            }
        }

        let entries = req.commentIDs.compactMap { try? store.resolve(id: $0) }
        req.commentIDs = entries.map(\.comment.id)
        update(runID) { $0.commentIDs = req.commentIDs }
        if req.mode.edits {
            var claimed: [String] = []
            for e in entries where e.comment.status == .open
                || (e.comment.status == .inProgress && e.comment.assignee?.kind != .human) {
                if (try? store.setStatus(scene: e.scene, id: e.comment.id, .inProgress, by: Self.agentAuthor)) != nil {
                    claimed.append(e.comment.id)
                }
            }
            update(runID) { $0.claimed = claimed }
            if !claimed.isEmpty { onReviewsChanged?() }
        }

        let made = AgentPrompt.make(req, info: info, comments: entries.map(\.comment))
        req.prompt = made.prompt
        req.systemPrompt = made.system
        req.logURL = project.cacheDir.appendingPathComponent("agent/\(runID).jsonl")
        update(runID) { $0.logURL = req.logURL; $0.prompt = made.prompt }

        do {
            for try await e in backend.run(req) { handle(e, runID: runID) }
        } catch {
            lastError = "\(error)"
            transcript.append(AgentTranscriptRow(kind: .error, title: "\(error)"))
        }
        await finish(runID)
    }

    /// SIGINT to the agent; the backend still ends the stream with `.finished`.
    func stop() {
        guard isRunning, !isStopping else { return }
        isStopping = true
        if let i = runs.indices.last { runs[i].stopped = true }
        status("Stopping…")
        backend.cancel()
        // A backend that never ends its stream must not wedge the panel.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, self.isStopping, self.isRunning else { return }
            self.task?.cancel()
        }
    }

    func clearTranscript() {
        guard !isRunning else { return }
        transcript = []
    }

    // MARK: Events

    /// Exposed for tests: apply one backend event to the current run.
    func handle(_ e: AgentEvent, runID: String? = nil) {
        let id = runID ?? runs.last?.id ?? ""
        switch e {
        case .started(let sid, let model, let mcp):
            update(id) { $0.sessionID = sid; if let model { $0.model = model } }
            let parts = ["Session \(sid.prefix(8))", model, mcp.map { "swift-render \($0)" }].compactMap { $0 }
            status(parts.joined(separator: " · "))
            // init arrives before the first API call: without the review tools a comment run
            // can only burn budget, so stop it here.
            if mcp == "failed", runs.first(where: { $0.id == id })?.commentIDs.isEmpty == false {
                transcript.append(AgentTranscriptRow(kind: .error, title:
                    "The swift-render MCP server failed to start (another swift build holding .build? a compile error in the server?). Stopped before the first turn."))
                stop()
            }
        case .progress(let s):
            status(s)
        case .text(let s):
            transcript.append(AgentTranscriptRow(kind: .text, title: s))
        case .tool(let call):
            transcript.append(AgentTranscriptRow(kind: .tool, title: call.name, detail: call.summary,
                                                 files: call.files, toolID: call.id, writes: call.writes))
            // Counted once the result says it worked: a denied or failed Write changed nothing,
            // and reverting it would act on a file the agent never touched.
            if call.writes, !call.files.isEmpty {
                update(id) { $0.pendingWrites[call.id] = call.files }
            }
        case .toolResult(let toolID, let ok, let summary):
            update(id) { run in
                if let files = run.pendingWrites.removeValue(forKey: toolID), ok { Self.addTouched(files, to: &run) }
            }
            if let i = transcript.lastIndex(where: { $0.toolID == toolID && $0.kind == .tool }) {
                transcript[i].ok = ok
                if !summary.isEmpty, !ok || transcript[i].title != "Read" { transcript[i].detail += "  →  " + summary }
            } else {
                transcript.append(AgentTranscriptRow(kind: .result, title: ok ? "Result" : "Error", detail: summary, ok: ok))
            }
        case .notice(let s):
            notice(s)
        case .finished(let ok, let cost, let seconds, let result):
            update(id) { run in
                run.ok = ok; run.costUSD = cost; run.result = result
                run.seconds = seconds > 0 ? seconds : Date().timeIntervalSince(run.startedAt)
            }
            let run = runs.first { $0.id == id }
            var line = run?.stopped == true ? "Stopped" : ok ? "Finished" : "Failed"
            if let s = run?.seconds { line += " · " + Self.duration(s) }
            if let cost { line += String(format: " · $%.2f", cost) }
            transcript.append(AgentTranscriptRow(kind: .finished, title: line, detail: result ?? "", ok: ok))
        }
    }

    private func finish(_ runID: String) async {
        // A write whose result never came (stopped mid-call) may have happened.
        update(runID) { run in
            for files in run.pendingWrites.values { Self.addTouched(files, to: &run) }
            run.pendingWrites = [:]
        }
        guard let run = runs.first(where: { $0.id == runID }) else { return }
        if run.ok == nil { handle(.finished(ok: false, costUSD: nil, seconds: 0, result: lastError), runID: runID) }

        // Claims the agent didn't close go back to the reviewers.
        var released: [String] = []
        let why = run.stopped ? "the run was stopped" : (run.ok == true ? "it ended" : "the run failed")
        for id in run.claimed {
            guard let e = try? store.resolve(id: id), e.comment.status == .inProgress,
                  e.comment.assignee?.kind == .agent else { continue }
            _ = try? store.reply(scene: e.scene, id: id, ReviewReply(
                author: Self.studioAuthor, body: "Agent run ended without resolving this (\(why)); back to open."))
            if (try? store.setStatus(scene: e.scene, id: id, .open)) != nil { released.append(id) }
        }
        if !released.isEmpty {
            noteReleased(released)
            onReviewsChanged?()
        }

        if let cp = run.checkpoint {
            let files = run.touched
            let (stats, left, outside) = await Task.detached { () -> ([Checkpoint.FileStat]?, [String: String], [String]) in
                let stats = files.isEmpty ? [] : try? cp.diffStat(files: files)
                let mine = Set(cp.resolve(files))
                return (stats, files.isEmpty ? [:] : cp.fingerprint(files: files),
                        cp.changedSince().filter { !mine.contains($0) })
            }.value
            update(runID) { run in
                if let stats { run.stats = stats }
                run.agentLeft = left
                run.changedOutside = outside
            }
            if !outside.isEmpty {
                notice("Also changed during the run, not by the agent's edit tools (Revert leaves these alone): "
                       + outside.prefix(8).joined(separator: ", ") + (outside.count > 8 ? " +\(outside.count - 8) more" : ""))
            }
        }
        update(runID) { $0.finished = true }
        isRunning = false
        isStopping = false
        task = nil
        onRunningChanged?(false)
    }

    /// "Back to open" notice for comments a run held but didn't resolve, above the final line.
    func noteReleased(_ ids: [String]) {
        let row = AgentTranscriptRow(kind: .notice, title: "Back to open: " + ids.joined(separator: ", "))
        if transcript.last?.kind == .finished { transcript.insert(row, at: transcript.count - 1) } else { transcript.append(row) }
    }

    // MARK: Revert

    /// Touched files (repository-relative) whose content differs from what the agent left:
    /// edited again since the run. Revert keeps them unless asked to include them.
    func changedSinceRun(_ runID: String) async -> [String] {
        guard let run = runs.first(where: { $0.id == runID }), let cp = run.checkpoint, run.finished else { return [] }
        let files = run.touched, left = run.agentLeft
        guard !left.isEmpty else { return [] }
        return await Task.detached {
            cp.fingerprint(files: files).filter { rel, now in left[rel].map { $0 != now } ?? false }.keys.sorted()
        }.value
    }

    /// Restores the files the run wrote to its checkpoint (created files go to the Trash).
    /// Files edited again since the run are kept unless `includeChanged`. Whatever is
    /// overwritten is committed to `refs/swift-render/pre-revert/<run>` first.
    func revert(_ runID: String, includeChanged: Bool = false) async {
        guard !isRunning, let run = runs.first(where: { $0.id == runID }), run.canRevert, let cp = run.checkpoint else { return }
        let files = run.touched
        let keep = includeChanged ? [] : Set(await changedSinceRun(runID))
        do {
            let r = try await Task.detached {
                try cp.revert(files: files, keep: keep, backupRef: Checkpoint.backupPrefix + runID)
            }.value
            update(runID) { $0.reverted = true; $0.stats = [] }
            let n = r.restored.count + r.trashed.count
            status("Reverted \(n) file\(n == 1 ? "" : "s") to \(cp.sha.prefix(8))"
                   + (r.trashed.isEmpty ? "" : " (\(r.trashed.count) new → Trash)"))
            if let b = r.backupRef { notice("The files as they were before this revert: \(b)") }
            for (reason, paths) in Dictionary(grouping: r.skipped, by: \.reason).sorted(by: { $0.key < $1.key }) {
                notice("Not restored (\(reason)): " + paths.map(\.path).joined(separator: ", "))
            }
        } catch {
            lastError = "\(error)"
            transcript.append(AgentTranscriptRow(kind: .error, title: "Revert failed: \(error)"))
        }
    }

    // MARK: Helpers

    private static func addTouched(_ files: [String], to run: inout AgentRun) {
        for f in files where !run.touched.contains(f) { run.touched.append(f) }
    }

    private func update(_ runID: String, _ edit: (inout AgentRun) -> Void) {
        guard let i = runs.firstIndex(where: { $0.id == runID }) else { return }
        edit(&runs[i])
    }

    private func status(_ s: String) { transcript.append(AgentTranscriptRow(kind: .status, title: s)) }
    private func notice(_ s: String) { transcript.append(AgentTranscriptRow(kind: .notice, title: s)) }

    /// "42s", "3:07".
    static func duration(_ s: Double) -> String {
        s < 60 ? String(format: "%.0fs", s) : String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
}
