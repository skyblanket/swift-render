import Foundation
import Observation
import SwiftRenderKit

// MARK: - Agent controller   // S8
//
// Run lifecycle: checkpoint → mark comments inProgress (assignee Claude) → backend run
// → transcript rows → on finish, anything still inProgress returns to open with a note.
// While a run is active the build controller mutes failures and the watcher debounce
// rises to 600 ms (wired in ProjectModel via `isRunning`).

/// One row in the agent panel.
struct AgentTranscriptRow: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case text, tool, result, status, error }
    let id = UUID()
    var kind: Kind
    var title: String
    var detail: String = ""
    var files: [String] = []
}

/// One ask → finish cycle.
struct AgentRun: Identifiable, Equatable, Sendable {
    let id: String
    var commentIDs: [String]
    var startedAt: Date
    var sessionID: String?
    var finished = false
    var ok: Bool?
    var costUSD: Double?
    var seconds: Double?
}

@MainActor @Observable
final class AgentController {
    let project: Project
    private(set) var runs: [AgentRun] = []
    private(set) var transcript: [AgentTranscriptRow] = []
    private(set) var isRunning = false
    var lastError: String?

    @ObservationIgnored var backend: AgentBackend
    @ObservationIgnored private var task: Task<Void, Never>?

    init(project: Project, backend: AgentBackend = ClaudeCodeBackend()) {
        self.project = project
        self.backend = backend
    }

    var currentRun: AgentRun? { runs.last }

    // S8: checkpoint, claim comments, prompt, sync statuses, cost/time.
    func ask(_ request: AgentRequest) {
        guard !isRunning else { return }
        let run = AgentRun(id: ReviewIDs.make("run"), commentIDs: request.commentIDs, startedAt: Date())
        runs.append(run)
        transcript = [AgentTranscriptRow(kind: .status, title: "Asking Claude about \(request.commentIDs.count) comment(s)…")]
        isRunning = true
        let backend = backend
        task = Task { [weak self] in
            do {
                for try await e in backend.run(request) { self?.handle(e) }
            } catch {
                self?.transcript.append(AgentTranscriptRow(kind: .error, title: "\(error)"))
                self?.lastError = "\(error)"
            }
            self?.isRunning = false
            if let i = self?.runs.indices.last { self?.runs[i].finished = true }
        }
    }

    func stop() {
        backend.cancel()
        task?.cancel()
        isRunning = false
    }

    private func handle(_ e: AgentEvent) {
        switch e {
        case .started(let sid, let model):
            if let i = runs.indices.last { runs[i].sessionID = sid }
            transcript.append(AgentTranscriptRow(kind: .status, title: "Session \(sid.prefix(8))", detail: model ?? ""))
        case .text(let s):
            transcript.append(AgentTranscriptRow(kind: .text, title: s))
        case .tool(let name, let summary, let files):
            transcript.append(AgentTranscriptRow(kind: .tool, title: name, detail: summary, files: files))
        case .toolResult(let ok, let summary):
            transcript.append(AgentTranscriptRow(kind: .result, title: ok ? "✓" : "✕", detail: summary))
        case .finished(let ok, let cost, let seconds, let result):
            if let i = runs.indices.last {
                runs[i].ok = ok; runs[i].costUSD = cost; runs[i].seconds = seconds; runs[i].finished = true
            }
            transcript.append(AgentTranscriptRow(kind: .status, title: ok ? "Finished" : "Failed", detail: result ?? ""))
        }
    }
}
