import Foundation
import SwiftRenderKit

// MARK: - Agent seam   // S8
//
// Studio drives agents through this protocol: `ClaudeCodeBackend` (headless
// `claude -p … --output-format stream-json`) today; an in-house backend (Claude API
// + specialized tools) later, emitting the same events against the same review files.

protocol AgentBackend: Sendable {
    func run(_ request: AgentRequest) -> AsyncThrowingStream<AgentEvent, Error>
    func cancel()
}

struct AgentRequest: Sendable {
    enum Mode: String, Sendable, CaseIterable {
        /// Edit, rebuild, verify, resolve.
        case fix
        /// Propose only (plan mode).
        case plan
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
}

enum AgentEvent: Sendable, Equatable {
    case started(sessionID: String, model: String?)
    case text(String)
    case tool(name: String, summary: String, files: [String])
    case toolResult(ok: Bool, summary: String)
    case finished(ok: Bool, costUSD: Double?, seconds: Double, result: String?)
}
