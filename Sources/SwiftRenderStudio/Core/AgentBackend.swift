import Foundation
import SwiftRenderKit

// MARK: - Agent seam   // S8
//
// Studio drives agents through this protocol: `ClaudeCodeBackend` (headless
// `claude -p … --output-format stream-json`) today; an in-house backend (Claude API
// + specialized tools) later, emitting the same events against the same review files.

protocol AgentBackend: Sendable {
    /// One run. The stream always ends with exactly one `.finished` (also after `cancel`),
    /// or throws when the agent could not be started at all.
    func run(_ request: AgentRequest) -> AsyncThrowingStream<AgentEvent, Error>
    func cancel()
}

struct AgentRequest: Sendable, Equatable {
    enum Mode: String, Sendable, CaseIterable {
        /// Edit, rebuild, verify, resolve.
        case fix
        /// Propose a change in the thread; no edits.
        case plan
        /// Answer in the thread only (questions, acks); no edits, no builds.
        case reply

        var title: String {
            switch self {
            case .fix: return "Fix & resolve"
            case .plan: return "Propose only"
            case .reply: return "Reply only"
            }
        }

        /// Runs that may edit files take a checkpoint and claim their comments.
        var edits: Bool { self == .fix }
    }
    enum Scope: String, Sendable, CaseIterable {
        case sceneFile
        case sources
    }
    var project: Project
    var scene: String
    var commentIDs: [String]
    var mode: Mode = .fix
    var scope: Scope = .sceneFile
    var instructions: String = ""
    var budgetUSD: Double? = 2
    var model: String?
    var resumeSessionID: String?
    /// "Fix the build" runs.
    var buildDiagnostics: [CompilerDiagnostic] = []
    /// Filled by `AgentController` from `AgentPrompt` before the backend sees the request.
    var prompt: String = ""
    var systemPrompt: String = ""
}

/// A tool call as the panel shows it.
struct AgentToolCall: Sendable, Equatable {
    /// The backend's id, used to attach the result (`tool_use.id`).
    var id: String
    /// Short name: `Edit`, `get_comment` (MCP prefixes stripped).
    var name: String
    /// One line: the file, command, comment id or scene + times.
    var summary: String
    /// Absolute paths the call reads or writes.
    var files: [String] = []
    /// Edit/Write: the files are modified (checkpoint diff stats, revert).
    var writes = false
}

enum AgentEvent: Sendable, Equatable {
    /// `mcpStatus`: the swift-render server's status at start ("connected", "pending", "failed"),
    /// nil when the backend doesn't report one.
    case started(sessionID: String, model: String?, mcpStatus: String?)
    case text(String)
    case tool(AgentToolCall)
    case toolResult(id: String, ok: Bool, summary: String)
    /// Non-fatal: a pending MCP server, a permission denial, an API retry.
    case notice(String)
    case finished(ok: Bool, costUSD: Double?, seconds: Double, result: String?)
}

/// Replays recorded `claude` stream-json lines through the real decoder: tests, and
/// `--agent-replay <file.jsonl>` snapshots of the agent panel.
final class ReplayAgentBackend: AgentBackend, @unchecked Sendable {
    let lines: [String]
    let delay: Duration
    private let lock = NSLock()
    private var cancelled = false

    init(lines: [String], delay: Duration = .zero) {
        self.lines = lines
        self.delay = delay
    }

    convenience init(contentsOf url: URL, delay: Duration = .zero) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        self.init(lines: text.split(whereSeparator: \.isNewline).map(String.init), delay: delay)
    }

    func run(_ request: AgentRequest) -> AsyncThrowingStream<AgentEvent, Error> {
        let lines = lines, delay = delay
        lock.lock(); cancelled = false; lock.unlock()
        return AsyncThrowingStream { cont in
            let task = Task {
                var decoder = ClaudeStreamDecoder(root: request.project.root.path)
                for line in lines {
                    if self.isCancelled { break }
                    if delay > .zero { try? await Task.sleep(for: delay) }
                    for e in decoder.decode(line) { cont.yield(e) }
                }
                if !decoder.sawResult {
                    cont.yield(.finished(ok: false, costUSD: nil, seconds: 0,
                                         result: self.isCancelled ? "Stopped" : "no result line"))
                }
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
