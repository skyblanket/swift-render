import Foundation
import SwiftRenderKit

// MARK: - Claude Code backend   // S8
//
// To implement (studio-ux §4.8): resolve `claude` via ToolPaths, spawn with
// `-p <prompt> --output-format stream-json --verbose --include-partial-messages
// --permission-mode acceptEdits|plan --allowedTools … --mcp-config <swift-render-mcp>
// --append-system-prompt <house rules> --max-budget-usd N [--model] [--resume]`,
// cwd = project root; decode stream-json leniently (Optionals everywhere, unknown
// types ignored) into `AgentEvent`; cancel = SIGINT, SIGTERM after 2 s.

final class ClaudeCodeBackend: AgentBackend, @unchecked Sendable {
    enum BackendError: Error, CustomStringConvertible {
        case notImplemented
        var description: String { "The Claude Code backend isn't wired up yet (S8)." }
    }

    init() {}

    func run(_ request: AgentRequest) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: BackendError.notImplemented) }
    }

    func cancel() {}
}
