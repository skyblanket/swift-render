import Foundation
import SwiftRenderKit

// MARK: - Claude Code backend
//
// Runs the headless command verified in docs/review-loop.md, cwd = project root:
//
//   claude -p "<prompt>" --agent swift-render-director --output-format stream-json --verbose
//     --permission-mode default --allowedTools <tools for the mode> [--disallowedTools …]
//     --mcp-config .mcp.json --max-budget-usd N [--append-system-prompt …] [--model …] [--resume …]
//
// `claude` comes from ToolPaths (Settings override, else the login shell's PATH), and
// the child gets the login-shell environment minus the variables that mark a nested
// Claude Code session, with MCP_CONNECTION_NONBLOCKING=false so the swift-render
// server is connected before the first turn. Stop = SIGINT, SIGTERM after 2 s.

final class ClaudeCodeBackend: AgentBackend, @unchecked Sendable {
    enum BackendError: Error, CustomStringConvertible {
        case claudeNotFound
        case launch(String)
        var description: String {
            switch self {
            case .claudeNotFound:
                return "Claude Code CLI not found. Install it (claude.com/claude-code) or set its path in Settings › General."
            case .launch(let why): return "Couldn't start claude: \(why)"
            }
        }
    }

    /// The director subagent (`.claude/agents/swift-render-director.md`).
    static let agentName = "swift-render-director"
    /// Set by a nested Claude Code session; a child that inherits them thinks it is one.
    static let nestedSessionVariables = [
        "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_CHILD_SESSION",
        "CLAUDE_CODE_HOST_SESSION_ID", "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_CODE_MESSAGING_SOCKET",
        "CLAUDE_CODE_MESSAGING_TOKEN", "CLAUDE_PID", "CLAUDE_AGENT_SDK_VERSION",
    ]

    private let resolveExecutable: @Sendable () async -> URL?
    private let prebuildMCP: Bool
    private let lock = NSLock()
    private var child: ChildProcess?
    private var cancelled = false

    /// `executable`: tests substitute a script that replays recorded stream-json.
    /// `prebuildMCP`: build swift-render-mcp before spawning claude (see `buildMCPServer`).
    init(executable: (@Sendable () async -> URL?)? = nil, prebuildMCP: Bool = true) {
        resolveExecutable = executable ?? { await ToolPaths.resolve("claude") }
        self.prebuildMCP = prebuildMCP
    }

    // MARK: Command line

    static func arguments(for r: AgentRequest) -> [String] {
        var a = ["-p", r.prompt]
        if hasDirector(r.project) { a += ["--agent", agentName] }
        a += ["--output-format", "stream-json", "--verbose"]
        // Under -p in the default mode anything not pre-approved is denied. Not acceptEdits:
        // that also auto-allows Bash rm/mv/cp/mkdir/touch and shell redirections, writes the
        // checkpoint can't see (it tracks Edit/Write) and Revert can't undo.
        a += ["--permission-mode", "default"]
        if r.mode.edits {
            a += ["--allowedTools", "mcp__swift-render"] + editTools + ["Bash(swift build:*)"]
        } else {
            // Plan/reply: read the scene, look at frames, answer in the thread — statuses,
            // knob files and renders stay as they are.
            a += ["--allowedTools"] + readOnlyMCPTools.map { "mcp__swift-render__" + $0 }
            a += ["--disallowedTools"] + editTools + ["Bash"] + writingMCPTools.map { "mcp__swift-render__" + $0 }
        }
        a += ["--mcp-config", mcpConfig(r.project)]
        if !r.systemPrompt.isEmpty { a += ["--append-system-prompt", r.systemPrompt] }
        if let b = r.budgetUSD, b > 0 { a += ["--max-budget-usd", String(format: "%.2f", b)] }
        if let m = r.model, !m.isEmpty { a += ["--model", m] }
        if let s = r.resumeSessionID, !s.isEmpty { a += ["--resume", s] }
        return a
    }

    static let editTools = ["Edit", "Write", "MultiEdit", "NotebookEdit"]
    /// swift-render MCP tools that change nothing the user owns (plan/reply runs).
    static let readOnlyMCPTools = ["list_scenes", "scene_info", "render_frames", "contact_sheet", "check_scene",
                                   "list_comments", "get_comment", "reply_comment", "render_status"]
    /// …and the ones that do: comment statuses, knob files, exports.
    static let writingMCPTools = ["claim_comment", "resolve_comment", "set_knobs", "render_video"]

    /// The project's agent file; without it the house rules travel in the system prompt.
    static func hasDirector(_ p: Project) -> Bool {
        FileManager.default.fileExists(atPath: p.root.appendingPathComponent(".claude/agents/\(agentName).md").path)
    }

    /// `.mcp.json` when it registers `swift-render` (this repo), else an inline config that
    /// builds the server from the project — SwiftPM builds a dependency's executable product.
    static func mcpConfig(_ p: Project) -> String {
        let file = p.root.appendingPathComponent(".mcp.json")
        if let d = try? Data(contentsOf: file),
           let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
           (o["mcpServers"] as? [String: Any])?["swift-render"] != nil {
            return ".mcp.json"
        }
        let launch = "swift build -q --product swift-render-mcp 1>&2 && exec \"$(swift build --show-bin-path)/swift-render-mcp\""
        let config: [String: Any] = ["mcpServers": ["swift-render": [
            "command": "sh", "args": ["-c", launch], "env": ["SWIFT_RENDER_ROOT": p.root.path],
        ]]]
        let d = (try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: d, as: UTF8.self)
    }

    static func environment(_ base: [String: String] = ToolPaths.environment) -> [String: String] {
        var env = base
        nestedSessionVariables.forEach { env[$0] = nil }
        env["MCP_CONNECTION_NONBLOCKING"] = "false"
        return env
    }

    /// Shell-quoted command line, for the ask sheet's preview and the transcript.
    static func commandLine(for r: AgentRequest) -> String {
        (["claude"] + arguments(for: r)).map { a in
            a.range(of: "^[A-Za-z0-9_./:=@%+-]+$", options: .regularExpression) != nil
                ? a : "'" + a.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }

    // MARK: Run

    func run(_ request: AgentRequest) -> AsyncThrowingStream<AgentEvent, Error> {
        lock.withLock { cancelled = false }
        return AsyncThrowingStream { cont in
            let task = Task {
                guard let exe = await self.resolveExecutable() else {
                    cont.finish(throwing: BackendError.claudeNotFound); return
                }
                let root = request.project.root
                if self.prebuildMCP {
                    cont.yield(.progress("Building swift-render-mcp…"))
                    if let why = await self.buildMCPServer(root) { cont.yield(.notice(why)) }
                }
                let child = ChildProcess(exe, Self.arguments(for: request), cwd: root,
                                         env: Self.environment(), qos: .userInitiated)
                if !self.adopt(child) {
                    cont.yield(.finished(ok: false, costUSD: nil, seconds: 0, result: "Stopped"))
                    cont.finish(); return
                }
                do { try child.run() } catch {
                    cont.finish(throwing: BackendError.launch("\(error)")); return
                }
                child.closeStdin()      // -p reads piped stdin as extra input; give it EOF
                let start = Date()
                let log = Self.openLog(request.logURL)
                defer { try? log?.close() }
                var decoder = ClaudeStreamDecoder(root: root.path)
                for await line in child.stdoutLines {
                    log?.write(line + Data("\n".utf8))
                    for e in decoder.decode(line) { cont.yield(e) }
                }
                let term = await child.waitForExit()
                if !decoder.sawResult {
                    let wasCancelled = self.isCancelled
                    let tail = child.stderrTail.split(whereSeparator: \.isNewline).last.map(String.init)
                    let why = wasCancelled ? "Stopped"
                        : tail ?? "claude exited with \(term.uncaughtSignal ? "signal" : "status") \(term.status)"
                    cont.yield(.finished(ok: false, costUSD: nil, seconds: Date().timeIntervalSince(start), result: why))
                }
                self.release(child)
                cont.finish()
            }
            cont.onTermination = { reason in
                if case .cancelled = reason { self.cancel() }
                _ = task
            }
        }
    }

    /// The MCP launcher (`.mcp.json` or the inline config) runs `swift build --product
    /// swift-render-mcp` inside claude's MCP connect timeout, and fails the server when
    /// another SwiftPM holds `.build`'s lock. Building it here first waits out the lock
    /// (Stop still works) and leaves the launcher a no-op. nil on success.
    private func buildMCPServer(_ root: URL) async -> String? {
        guard let swift = await ToolPaths.resolve("swift") else { return nil }
        let build = ChildProcess(swift, ["build", "-q", "--product", "swift-render-mcp"], cwd: root,
                                 env: ToolPaths.environment, qos: .userInitiated)
        guard adopt(build) else { return nil }
        defer { release(build) }
        do { try build.run() } catch { return "Couldn't prebuild swift-render-mcp: \(error)" }
        build.closeStdin()
        for await _ in build.stdoutLines {}
        let t = await build.waitForExit()
        if t.status == 0 || isCancelled { return nil }
        let tail = build.stderrTail.split(whereSeparator: \.isNewline).suffix(2).joined(separator: " ")
        return "swift-render-mcp didn't build (\(tail.isEmpty ? "exit \(t.status)" : tail)) — review tools may be missing"
    }

    private static func openLog(_ url: URL?) -> FileHandle? {
        guard let url else { return nil }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { return nil }
        return try? FileHandle(forWritingTo: url)
    }

    /// Records the running child; false when a cancel already arrived.
    private func adopt(_ c: ChildProcess) -> Bool {
        lock.withLock {
            if cancelled { return false }
            child = c
            return true
        }
    }

    private func release(_ c: ChildProcess) { lock.withLock { if child === c { child = nil } } }

    private var isCancelled: Bool { lock.withLock { cancelled } }

    /// SIGINT (claude stops its tools and MCP children), SIGTERM after 2 s, then SIGKILL.
    func cancel() {
        lock.lock()
        cancelled = true
        let c = child
        lock.unlock()
        guard let c else { return }
        Task.detached { await c.terminate(grace: .seconds(2)) }
    }
}
