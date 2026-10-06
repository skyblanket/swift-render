import XCTest
import SwiftRenderKit
@testable import SwiftRenderStudio

/// Stream-json decoding (recorded + documented lines), the claude command line, the
/// prompt, checkpoints in a scratch git repo, and the controller's run lifecycle.
@MainActor
final class AgentTests: XCTestCase {

    // MARK: Fixtures

    /// Recorded from Studio's real run (`RealClaudeRunTests`, Claude Code 2.1.284, CLI not
    /// logged in, swift-render failed because `swift test` held .build's lock). Long lists
    /// trimmed; every key kept is as recorded.
    static let recordedAuthFailure = [
        #"{"type":"system","subtype":"init","cwd":"/Users/sky/swift-render","session_id":"49d75f3f-c403-4ce8-b589-57fa97684ff4","tools":["Read","Glob","Grep"],"mcp_servers":[{"name":"swarmrt-mcp","status":"failed","source":"user"},{"name":"o-v4","status":"connected","source":"user"},{"name":"swift-render","status":"failed","source":"dynamic"}],"model":"claude-fable-5-1","permissionMode":"acceptEdits","apiKeySource":"none","claude_code_version":"2.1.284","output_style":"default","agents":["claude","Explore","general-purpose"],"capabilities":["interrupt_receipt_v1"],"uuid":"c9805f28-aa5f-45cc-a33e-6c96dc1e0d19","fast_mode_state":"off"}"#,
        #"{"type":"assistant","message":{"diagnostics":null,"id":"291fedb5-ff3e-4a46-97a7-6aabb253b984","container":null,"model":"<synthetic>","role":"assistant","stop_reason":"stop_sequence","stop_sequence":"","type":"message","usage":{"input_tokens":0,"output_tokens":0},"content":[{"type":"text","text":"Not logged in · Please run /login"}],"context_management":null},"parent_tool_use_id":null,"session_id":"49d75f3f-c403-4ce8-b589-57fa97684ff4","uuid":"505af1e1-34e1-4fd3-a6fa-3e0587725e9d","timestamp":"2026-10-06T08:03:31.987Z","error":"authentication_failed","is_api_error_message":true}"#,
        #"{"duration_api_ms":0,"stop_reason":"stop_sequence","session_id":"49d75f3f-c403-4ce8-b589-57fa97684ff4","total_cost_usd":0,"usage":{"input_tokens":0,"output_tokens":0},"modelUsage":{},"permission_denials":[],"terminal_reason":"api_error","is_error":true,"num_turns":1,"subtype":"success","api_error_status":null,"result":"Not logged in · Please run /login","type":"result","duration_ms":46,"uuid":"313a7acd-efb3-4c98-8cf8-e457fd929b77"}"#,
    ]

    /// A fix run in the shapes docs/review-loop.md documents for logged-in sessions
    /// (assistant tool_use, user tool_result, result), plus lines a decoder must skip.
    static func fixSession(root: String) -> [String] {
        [
            #"{"type":"system","subtype":"init","session_id":"5f1c9a20-0000-4000-8000-000000000001","model":"claude-sonnet-4-5","permissionMode":"acceptEdits","tools":["Read","Edit","Write","Bash","mcp__swift-render__get_comment"],"mcp_servers":[{"name":"swift-render","status":"connected","source":"dynamic"}]}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Look"}}}"#,
            #"{"type":"assistant","message":{"model":"claude-sonnet-4-5","content":[{"type":"thinking","thinking":"…"},{"type":"text","text":"Looking at the comment first."},{"type":"tool_use","id":"toolu_01","name":"mcp__swift-render__get_comment","input":{"id":"c1a2b3c4"}}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_01","content":[{"type":"text","text":"\n{\"scene\":\"TimelineDemo\"}\nclips at 00:03.00"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"iVBOR"}}]}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_02","name":"Edit","input":{"file_path":"ROOT/Sources/Scene.swift","old_string":"0.20","new_string":"0.10"}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_02","content":"The file ROOT/Sources/Scene.swift has been updated."}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_03","name":"Bash","input":{"command":"swift build --scratch-path .build/studio\necho done","description":"Build"}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_03","is_error":true,"content":"error: compile failed\nmore"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_04","name":"mcp__plugin_swift-render_swift-render__render_frames","input":{"scene":"TimelineDemo","times":[2.7,3,3.3]}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_04","content":[{"type":"image","source":{}},{"type":"image","source":{}}]}]}}"#,
            #"{"type":"future_type","x":1}"#,
            "not json at all",
            #"{"type":"result","subtype":"success","is_error":false,"result":"c1a2b3c4 — resolved: stagger halved","total_cost_usd":0.4213,"duration_ms":73120,"num_turns":9,"session_id":"5f1c9a20-0000-4000-8000-000000000001","permission_denials":[{"tool_name":"mcp__swift-render__set_knobs","tool_use_id":"toolu_09","tool_input":{}}]}"#,
        ].map { $0.replacingOccurrences(of: "ROOT", with: root) }
    }

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sr-agent-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return Checkpoint.realpath(url)
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    // MARK: Decoder

    func testDecodesRecordedAuthFailure() {
        var d = ClaudeStreamDecoder(root: "/Users/sky/swift-render")
        let events = Self.recordedAuthFailure.flatMap { d.decode($0) }
        XCTAssertEqual(events.count, 4)
        XCTAssertEqual(events[0], .started(sessionID: "49d75f3f-c403-4ce8-b589-57fa97684ff4", model: "claude-fable-5-1", mcpStatus: "failed"))
        guard case .notice(let n) = events[1] else { return XCTFail("\(events[1])") }
        XCTAssertTrue(n.contains("failed"))
        XCTAssertEqual(events[2], .text("Not logged in · Please run /login"))
        // subtype "success" but is_error true: a failure.
        XCTAssertEqual(events[3], .finished(ok: false, costUSD: 0, seconds: 0.046, result: "Not logged in · Please run /login"))
        XCTAssertTrue(d.sawResult)
        XCTAssertEqual(d.sessionID, "49d75f3f-c403-4ce8-b589-57fa97684ff4")
    }

    func testDecodesFixSession() {
        let root = "/p"
        var d = ClaudeStreamDecoder(root: root + "/")
        let events = Self.fixSession(root: root).flatMap { d.decode($0) }
        let expected: [AgentEvent] = [
            .started(sessionID: "5f1c9a20-0000-4000-8000-000000000001", model: "claude-sonnet-4-5", mcpStatus: "connected"),
            .text("Looking at the comment first."),
            .tool(AgentToolCall(id: "toolu_01", name: "get_comment", summary: "c1a2b3c4")),
            .toolResult(id: "toolu_01", ok: true, summary: "{\"scene\":\"TimelineDemo\"} · 1 image"),
            .tool(AgentToolCall(id: "toolu_02", name: "Edit", summary: "Sources/Scene.swift", files: ["/p/Sources/Scene.swift"], writes: true)),
            .toolResult(id: "toolu_02", ok: true, summary: "The file /p/Sources/Scene.swift has been updated."),
            .tool(AgentToolCall(id: "toolu_03", name: "Bash", summary: "swift build --scratch-path .build/studio")),
            .toolResult(id: "toolu_03", ok: false, summary: "error: compile failed"),
            .tool(AgentToolCall(id: "toolu_04", name: "render_frames", summary: "TimelineDemo @ 2.7s, 3s, 3.3s")),
            .toolResult(id: "toolu_04", ok: true, summary: "2 images"),
            .notice("Permission denied: set_knobs"),
            .finished(ok: true, costUSD: 0.4213, seconds: 73.12, result: "c1a2b3c4 — resolved: stagger halved"),
        ]
        XCTAssertEqual(events, expected)
    }

    func testDecoderIsLenient() {
        var d = ClaudeStreamDecoder()
        XCTAssertEqual(d.decode(#"{"type":"assistant"}"#), [])
        XCTAssertEqual(d.decode(#"{"type":"assistant","message":{"content":"plain"}}"#), [.text("plain")])
        XCTAssertEqual(d.decode(#"{"type":"user","message":{"content":"a prompt echo"}}"#), [])
        XCTAssertEqual(d.decode(#"{"type":"system","subtype":"init"}"#), [.started(sessionID: "", model: nil, mcpStatus: nil)])
        XCTAssertEqual(d.decode(#"{"type":"system","subtype":"init","session_id":"s","mcp_servers":[{"name":"plugin:swift-render:swift-render","status":"connected"}]}"#),
                       [.started(sessionID: "s", model: nil, mcpStatus: "connected")])
        // No is_error: fall back to subtype.
        XCTAssertEqual(d.decode(#"{"type":"result","subtype":"error_max_budget_usd"}"#),
                       [.finished(ok: false, costUSD: nil, seconds: 0, result: "Ended: error_max_budget_usd")])
        XCTAssertEqual(d.decode(Data([0xff, 0xfe])), [])
        XCTAssertEqual(ClaudeStreamDecoder.shortName("mcp__plugin_swift-render_swift-render__claim_comment"), "claim_comment")
        XCTAssertEqual(ClaudeStreamDecoder.shortName("Edit"), "Edit")
    }

    // MARK: Command line

    func testCommandLineMatchesTheVerifiedHeadlessRun() {
        let project = Project.open(repoRoot)
        var r = AgentRequest(project: project, scene: "TimelineDemo", commentIDs: ["c1"], mode: .reply, budgetUSD: 1)
        r.prompt = "P"
        let a = ClaudeCodeBackend.arguments(for: r)
        // docs/review-loop.md: claude -p … --agent swift-render-director --output-format stream-json --verbose
        //   --permission-mode acceptEdits --allowedTools "mcp__swift-render" --mcp-config .mcp.json --max-budget-usd 1
        XCTAssertEqual(Array(a.prefix(4)), ["-p", "P", "--agent", "swift-render-director"])
        func value(_ flag: String) -> String? { a.firstIndex(of: flag).map { a[$0 + 1] } }
        XCTAssertEqual(value("--output-format"), "stream-json")
        XCTAssertTrue(a.contains("--verbose"))
        XCTAssertEqual(value("--permission-mode"), "acceptEdits")
        XCTAssertEqual(value("--allowedTools"), "mcp__swift-render")
        XCTAssertFalse(a.contains("Bash(swift build:*)"), "reply runs don't build")
        XCTAssertTrue(a.contains("--disallowedTools"))
        XCTAssertEqual(value("--mcp-config"), ".mcp.json")
        XCTAssertEqual(value("--max-budget-usd"), "1.00")
        XCTAssertNil(value("--resume"))

        r.mode = .fix
        r.model = "sonnet"
        r.resumeSessionID = "abc"
        r.systemPrompt = "rules"
        let f = ClaudeCodeBackend.arguments(for: r)
        let allowed = f.firstIndex(of: "--allowedTools")!
        XCTAssertEqual(Array(f[allowed + 1...allowed + 2]), ["mcp__swift-render", "Bash(swift build:*)"])
        XCTAssertFalse(f.contains("--disallowedTools"))
        XCTAssertEqual(f[f.firstIndex(of: "--model")! + 1], "sonnet")
        XCTAssertEqual(f[f.firstIndex(of: "--resume")! + 1], "abc")
        XCTAssertEqual(f[f.firstIndex(of: "--append-system-prompt")! + 1], "rules")
        XCTAssertTrue(ClaudeCodeBackend.commandLine(for: r).hasPrefix("claude -p P --agent swift-render-director"))
    }

    func testProjectWithoutMCPJsonGetsInlineConfigAndNoAgentFlag() throws {
        let root = try tempDir()
        var r = AgentRequest(project: Project.open(root), scene: "S", commentIDs: [])
        r.prompt = "P"
        let a = ClaudeCodeBackend.arguments(for: r)
        XCTAssertFalse(a.contains("--agent"))
        let config = a[a.firstIndex(of: "--mcp-config")! + 1]
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(config.utf8)) as? [String: Any])
        let server = try XCTUnwrap((o["mcpServers"] as? [String: Any])?["swift-render"] as? [String: Any])
        XCTAssertEqual((server["env"] as? [String: String])?["SWIFT_RENDER_ROOT"], r.project.root.path)
        XCTAssertEqual(server["command"] as? String, "sh")
    }

    func testEnvironmentDropsNestedSessionMarkers() {
        let env = ClaudeCodeBackend.environment(["PATH": "/bin", "CLAUDECODE": "1", "CLAUDE_CODE_ENTRYPOINT": "sdk",
                                                 "ANTHROPIC_API_KEY": "k", "MCP_CONNECTION_NONBLOCKING": "true"])
        XCTAssertNil(env["CLAUDECODE"])
        XCTAssertNil(env["CLAUDE_CODE_ENTRYPOINT"])
        XCTAssertEqual(env["ANTHROPIC_API_KEY"], "k")
        XCTAssertEqual(env["MCP_CONNECTION_NONBLOCKING"], "false")
        XCTAssertEqual(env["PATH"], "/bin")
    }

    // MARK: Prompt

    func testPromptCarriesCommentContextAndHouseRules() {
        let root = URL(fileURLWithPath: "/proj")
        let src = "/proj/Sources/Scenes/Demo.swift"
        let info = SceneInfo(name: "Demo", kind: .render, duration: 12, width: 1920, height: 1080, fps: 60,
                             clips: [ClipInfo(id: "a", label: "Title", start: 2, end: 5, depth: 0, pinned: false,
                                              transitionIn: "cut", transitionDuration: 0,
                                              source: SourceLocation(file: src, line: 41))],
                             sourcePath: src)
        var c = ReviewComment(id: "c1a2b3c4", t: 3, region: ReviewRegion(x: 0.1, y: 0.2, w: 0.3, h: 0.25),
                              body: "logo feels small", author: ReviewAuthor(name: "Sky"))
        c.attachments = [ReviewAttachment(kind: .before, path: ReviewAttachmentPaths.before(c.id), t: 3)]
        c.replies = [ReviewReply(author: ReviewAuthor(name: "Sky"), body: "about 20% bigger")]
        let other = ReviewComment(id: "cffff0000", t: 9, body: "not picked", author: ReviewAuthor(name: "Sky"))
        let r = AgentRequest(project: Project.open(root), scene: "Demo", commentIDs: ["c1a2b3c4"], mode: .fix,
                             instructions: "keep the amber palette",
                             buildDiagnostics: [CompilerDiagnostic(file: src, line: 7, column: 3, severity: .error, message: "boom")])
        let (prompt, system) = AgentPrompt.make(r, info: info, comments: [c, other])
        for needle in ["Scene: Demo — render, 12.00 s, canvas 1920×1080 @ 60 fps", "Source: Sources/Scenes/Demo.swift",
                       "c1a2b3c4 @ 00:03.00 (f180)", "region x 0.10 y 0.20 w 0.30 h 0.25 = 192,216 576×270 pt of 1920×1080",
                       "clip Title (Sources/Scenes/Demo.swift:41)", "“logo feels small” — Sky",
                       "Before frame: .swift-render/attachments/c1a2b3c4-before.png", "Sky: “about 20% bigger”",
                       "Sources/Scenes/Demo.swift:7:3: error: boom", "First make the project build", "resolve_comment",
                       "From the reviewer: keep the amber palette"] {
            XCTAssertTrue(prompt.contains(needle), "missing: \(needle)\n---\n\(prompt)")
        }
        XCTAssertFalse(prompt.contains("cffff0000"))
        XCTAssertTrue(system.contains("no whoosh, riser or swish"))
        XCTAssertTrue(system.contains("pure functions of time"))
        XCTAssertTrue(system.contains("no camera shake, no flash or white frames"), "launch-film grammar reaches the agent")

        let reply = AgentPrompt.make(AgentRequest(project: Project.open(root), scene: "Demo", commentIDs: ["c1a2b3c4"], mode: .reply),
                                     info: info, comments: [c]).prompt
        XCTAssertTrue(reply.contains("Do not edit any files"))
        XCTAssertFalse(reply.contains("Scope:"))
    }

    // MARK: Checkpoints

    private func git(_ args: [String], _ dir: URL) throws -> String { try Checkpoint.git(args, cwd: dir) }

    private func makeRepo() throws -> URL {
        let root = try tempDir()
        _ = try git(["init", "-q"], root)
        _ = try git(["config", "user.email", "t@example.com"], root)
        _ = try git(["config", "user.name", "t"], root)
        _ = try git(["config", "commit.gpgsign", "false"], root)
        _ = try git(["config", "core.hooksPath", "/dev/null"], root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try "a\nb\nc\n".write(to: root.appendingPathComponent("Sources/A.swift"), atomically: true, encoding: .utf8)
        try "keep\n".write(to: root.appendingPathComponent("Sources/B.swift"), atomically: true, encoding: .utf8)
        _ = try git(["add", "."], root)
        _ = try git(["commit", "-qm", "init"], root)
        return root
    }

    func testCheckpointDiffAndRevertLeaveIndexAndStashAlone() throws {
        let root = try makeRepo()
        let a = root.appendingPathComponent("Sources/A.swift")
        let u = root.appendingPathComponent("notes.txt")
        let new = root.appendingPathComponent("Sources/New.swift")
        // The user's own uncommitted state, which a revert must bring back exactly.
        try "a\nB-user\nc\n".write(to: a, atomically: true, encoding: .utf8)
        try "untracked v1\n".write(to: u, atomically: true, encoding: .utf8)
        _ = try git(["add", "Sources/B.swift"], root)       // something staged, to prove the index is untouched
        let indexBefore = try git(["diff", "--cached", "--name-status"], root)
        let stashBefore = try git(["stash", "list"], root)

        let cp = try Checkpoint.create(project: Project.open(root), runID: "runtest1")
        XCTAssertEqual(try git(["rev-parse", cp.ref], root).trimmingCharacters(in: .whitespacesAndNewlines), cp.sha)
        XCTAssertEqual(try git(["stash", "list"], root), stashBefore, "stash create must not push")
        XCTAssertTrue(cp.untracked.contains("notes.txt"))
        XCTAssertNotNil(cp.untrackedBlobs["notes.txt"])

        // The "agent": edits a tracked file, an untracked one, and creates a file.
        try "a\nB-agent\nc\nd\n".write(to: a, atomically: true, encoding: .utf8)
        try "untracked v2\nmore\n".write(to: u, atomically: true, encoding: .utf8)
        try "struct New {}\n".write(to: new, atomically: true, encoding: .utf8)

        let stats = try cp.diffStat(files: [a.path, u.path, new.path])
        XCTAssertEqual(stats, [
            Checkpoint.FileStat(path: "Sources/A.swift", added: 2, removed: 1),
            Checkpoint.FileStat(path: "Sources/New.swift", added: 2, removed: 0, created: true),
            Checkpoint.FileStat(path: "notes.txt", added: 2, removed: 1),
        ])

        var trashed: [String] = []
        let skipped = try cp.revert(files: [a.path, u.path, new.path]) { trashed.append($0.lastPathComponent); try FileManager.default.removeItem(at: $0) }
        XCTAssertEqual(skipped, [])
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "a\nB-user\nc\n")
        XCTAssertEqual(try String(contentsOf: u, encoding: .utf8), "untracked v1\n")
        XCTAssertEqual(trashed, ["New.swift"])
        XCTAssertEqual(try git(["diff", "--cached", "--name-status"], root), indexBefore, "index untouched")
        XCTAssertEqual(try git(["stash", "list"], root), stashBefore)
        XCTAssertEqual(try cp.diffStat(files: [a.path, u.path, new.path]), [])
        cp.delete()
        XCTAssertThrowsError(try git(["rev-parse", "--verify", "-q", cp.ref], root))
    }

    func testCleanTreeCheckpointsHEADAndOutsideGitThrows() throws {
        let root = try makeRepo()
        let cp = try Checkpoint.create(project: Project.open(root), runID: "runclean")
        XCTAssertEqual(cp.sha, try git(["rev-parse", "HEAD"], root).trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertNil(cp.relative("/somewhere/else.swift"))
        XCTAssertThrowsError(try Checkpoint.create(project: Project.open(try tempDir()), runID: "x"))
    }

    // MARK: Controller

    private func waitIdle(_ agent: AgentController, seconds: Double = 10) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while agent.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(agent.isRunning, "run did not finish")
    }

    func testFixRunClaimsTracksFilesAndReleasesUnresolved() async throws {
        let root = try tempDir()       // not a git repo: the run goes ahead without a checkpoint
        let project = Project.open(root)
        let store = ReviewStore(project: project)
        let c = ReviewComment(id: "c1a2b3c4", t: 3, body: "faster", author: ReviewAuthor(name: "Sky"))
        try store.add(scene: "TimelineDemo", c)
        var running: [Bool] = []
        var reloads = 0
        let agent = AgentController(project: project, backend: ReplayAgentBackend(lines: Self.fixSession(root: root.path)))
        agent.onRunningChanged = { running.append($0) }
        agent.onReviewsChanged = { reloads += 1 }

        agent.ask(AgentRequest(project: project, scene: "TimelineDemo", commentIDs: ["c1a2"], mode: .fix))
        XCTAssertTrue(agent.isRunning)
        try await waitIdle(agent)

        let run = try XCTUnwrap(agent.currentRun)
        XCTAssertEqual(run.commentIDs, ["c1a2b3c4"])
        XCTAssertEqual(run.claimed, ["c1a2b3c4"], "prefix resolved and claimed")
        XCTAssertEqual(run.ok, true)
        XCTAssertEqual(run.costUSD, 0.4213)
        XCTAssertEqual(run.seconds, 73.12)
        XCTAssertEqual(run.sessionID, "5f1c9a20-0000-4000-8000-000000000001")
        XCTAssertEqual(run.touched, [root.path + "/Sources/Scene.swift"])
        XCTAssertNil(run.checkpoint)
        XCTAssertNotNil(run.checkpointError)
        XCTAssertTrue(run.finished)
        XCTAssertFalse(run.canRevert)
        XCTAssertEqual(running, [true, false])
        XCTAssertGreaterThanOrEqual(reloads, 2, "claim and release both reload the threads")

        // The agent never resolved it: back to open with a note from Studio.
        let after = try XCTUnwrap(store.load(scene: "TimelineDemo").comments.first)
        XCTAssertEqual(after.status, .open)
        XCTAssertNil(after.assignee)
        XCTAssertEqual(after.replies.last?.author, AgentController.studioAuthor)
        XCTAssertTrue(after.replies.last?.body.contains("without resolving") ?? false)

        // Results land on their tool rows.
        let tools = agent.transcript.filter { $0.kind == .tool }
        XCTAssertEqual(tools.map(\.title), ["get_comment", "Edit", "Bash", "render_frames"])
        XCTAssertEqual(tools.map(\.ok), [true, true, false, true])
        XCTAssertTrue(agent.transcript.contains { $0.kind == .notice && $0.title.contains("Permission denied") })
        XCTAssertEqual(agent.transcript.last?.kind, .finished)
        XCTAssertTrue(run.prompt?.contains("c1a2b3c4 @ 00:03.00") ?? false)
        XCTAssertEqual(run.logURL?.lastPathComponent, "\(run.id).jsonl")
    }

    func testReplyRunNeitherClaimsNorCheckpoints() async throws {
        let root = try makeRepo()
        let project = Project.open(root)
        let store = ReviewStore(project: project)
        try store.add(scene: "S", ReviewComment(id: "cabcdef01", t: 1, body: "?", author: ReviewAuthor(name: "Sky")))
        let agent = AgentController(project: project, backend: ReplayAgentBackend(lines: Self.fixSession(root: root.path)))
        agent.ask(AgentRequest(project: project, scene: "S", commentIDs: ["cabcdef01"], mode: .reply))
        try await waitIdle(agent)
        XCTAssertEqual(agent.currentRun?.claimed, [])
        XCTAssertNil(agent.currentRun?.checkpoint)
        XCTAssertEqual(try store.load(scene: "S").comments.first?.status, .open)
        XCTAssertEqual(try store.load(scene: "S").comments.first?.replies.count, 0)
        XCTAssertEqual(try git(["for-each-ref", Checkpoint.refPrefix], root), "")
    }

    /// Edits a file mid-run (like the agent would), so the checkpoint, diff stats and
    /// Revert run are exercised end to end through the controller.
    private final class EditingBackend: AgentBackend, @unchecked Sendable {
        let file: URL
        init(file: URL) { self.file = file }
        func run(_ request: AgentRequest) -> AsyncThrowingStream<AgentEvent, Error> {
            let file = file
            return AsyncThrowingStream { cont in
                cont.yield(.started(sessionID: "s1", model: "m", mcpStatus: "connected"))
                cont.yield(.tool(AgentToolCall(id: "t1", name: "Edit", summary: "", files: [file.path], writes: true)))
                try? "a\nb\nc\nd\n".write(to: file, atomically: true, encoding: .utf8)
                cont.yield(.toolResult(id: "t1", ok: true, summary: "updated"))
                cont.yield(.finished(ok: true, costUSD: 0.01, seconds: 1, result: "done"))
                cont.finish()
            }
        }
        func cancel() {}
    }

    func testFixRunCheckpointDiffStatsAndRevert() async throws {
        let root = try makeRepo()
        let project = Project.open(root)
        let file = root.appendingPathComponent("Sources/A.swift")
        let agent = AgentController(project: project, backend: EditingBackend(file: file))
        agent.ask(AgentRequest(project: project, scene: "S", commentIDs: [], mode: .fix,
                               buildDiagnostics: [CompilerDiagnostic(file: file.path, line: 1, column: 1, severity: .error, message: "x")]))
        try await waitIdle(agent)
        let run = try XCTUnwrap(agent.currentRun)
        XCTAssertTrue(run.fixBuild)
        let cp = try XCTUnwrap(run.checkpoint)
        XCTAssertEqual(try git(["for-each-ref", "--format=%(refname)", Checkpoint.refPrefix], root)
                        .trimmingCharacters(in: .whitespacesAndNewlines), cp.ref)
        XCTAssertEqual(run.stats, [Checkpoint.FileStat(path: "Sources/A.swift", added: 1, removed: 0)])
        XCTAssertEqual(run.stat(for: file.path)?.label, "+1 −0")
        XCTAssertTrue(run.canRevert)

        await agent.revert(run.id)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "a\nb\nc\n")
        XCTAssertEqual(agent.currentRun?.reverted, true)
        XCTAssertEqual(agent.currentRun?.canRevert, false)
        XCTAssertEqual(try git(["status", "--porcelain"], root), "")
    }

    /// Never ends on its own; `cancel` ends it the way ClaudeCodeBackend does after SIGINT.
    private final class HangingBackend: AgentBackend, @unchecked Sendable {
        private let lock = NSLock()
        private var cont: AsyncThrowingStream<AgentEvent, Error>.Continuation?
        func run(_ request: AgentRequest) -> AsyncThrowingStream<AgentEvent, Error> {
            AsyncThrowingStream { c in
                c.yield(.started(sessionID: "s", model: nil, mcpStatus: "connected"))
                lock.withLock { cont = c }
            }
        }
        func cancel() {
            let c = lock.withLock { cont }
            c?.yield(.finished(ok: false, costUSD: nil, seconds: 0.5, result: "Stopped"))
            c?.finish()
        }
    }

    func testStopEndsTheRunAndReleasesClaims() async throws {
        let root = try tempDir()
        let project = Project.open(root)
        let store = ReviewStore(project: project)
        try store.add(scene: "S", ReviewComment(id: "c00000001", t: 1, body: "x", author: ReviewAuthor(name: "Sky")))
        let agent = AgentController(project: project, backend: HangingBackend())
        agent.ask(AgentRequest(project: project, scene: "S", commentIDs: ["c00000001"], mode: .fix))
        let deadline = Date().addingTimeInterval(5)
        while agent.currentRun?.sessionID == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(try store.load(scene: "S").comments.first?.status, .inProgress)
        XCTAssertEqual(try store.load(scene: "S").comments.first?.assignee, AgentController.agentAuthor)

        agent.stop()
        try await waitIdle(agent)
        XCTAssertEqual(agent.currentRun?.stopped, true)
        XCTAssertEqual(agent.currentRun?.ok, false)
        XCTAssertTrue(agent.transcript.last?.title.hasPrefix("Stopped") ?? false)
        let c = try XCTUnwrap(store.load(scene: "S").comments.first)
        XCTAssertEqual(c.status, .open)
        XCTAssertTrue(c.replies.last?.body.contains("stopped") ?? false)
    }

    func testFailedMCPServerStopsACommentRunAtInit() async throws {
        let root = try tempDir()
        let project = Project.open(root)
        try ReviewStore(project: project).add(scene: "S", ReviewComment(id: "c00000002", t: 1, body: "x", author: ReviewAuthor(name: "Sky")))
        let agent = AgentController(project: project, backend: ReplayAgentBackend(lines: Self.recordedAuthFailure))
        agent.ask(AgentRequest(project: project, scene: "S", commentIDs: ["c00000002"], mode: .reply))
        try await waitIdle(agent)
        XCTAssertEqual(agent.currentRun?.stopped, true)
        XCTAssertEqual(agent.currentRun?.ok, false)
        XCTAssertTrue(agent.transcript.contains { $0.kind == .error && $0.title.contains("MCP server failed") })
    }

    // MARK: Process backend

    /// The real spawn path (ChildProcess, stdout lines, raw log, missing result line,
    /// SIGINT stop) with a script standing in for `claude`.
    func testProcessBackendDecodesStdoutKeepsLogAndStops() async throws {
        let dir = try tempDir()
        let fixture = dir.appendingPathComponent("stream.jsonl")
        try (Self.fixSession(root: dir.path).joined(separator: "\n") + "\n").write(to: fixture, atomically: true, encoding: .utf8)
        let script = dir.appendingPathComponent("fake-claude")
        try "#!/bin/sh\ncat \"\(fixture.path)\"\nif [ -n \"$HANG\" ]; then exec sleep 30; fi\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let backend = ClaudeCodeBackend(executable: { script }, prebuildMCP: false)
        var r = AgentRequest(project: Project.open(dir), scene: "S", commentIDs: [])
        r.logURL = dir.appendingPathComponent("log/run.jsonl")
        var events: [AgentEvent] = []
        for try await e in backend.run(r) { events.append(e) }
        XCTAssertEqual(events.count, 12)
        XCTAssertEqual(events.last, .finished(ok: true, costUSD: 0.4213, seconds: 73.12, result: "c1a2b3c4 — resolved: stagger halved"))
        XCTAssertEqual(try String(contentsOf: r.logURL!, encoding: .utf8).split(separator: "\n").count, 13)

        // No result line: the script is cut off by Stop.
        try "#!/bin/sh\nhead -n 3 \"\(fixture.path)\"\nexec sleep 30\n".write(to: script, atomically: true, encoding: .utf8)
        let started = Date()
        var got: [AgentEvent] = []
        // Stop once the first line has been decoded (a fixed delay raced process start-up
        // when the suite's other tests were spawning hosts).
        for try await e in backend.run(r) {
            if got.isEmpty { backend.cancel() }
            got.append(e)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "SIGINT should end it well before the 2 s SIGTERM + SIGKILL path")
        XCTAssertEqual(got.first, .started(sessionID: "5f1c9a20-0000-4000-8000-000000000001", model: "claude-sonnet-4-5", mcpStatus: "connected"))
        guard case .finished(let ok, _, _, let result) = got.last else { return XCTFail("\(String(describing: got.last))") }
        XCTAssertFalse(ok)
        XCTAssertEqual(result, "Stopped")
    }

    func testMissingClaudeThrows() async {
        let backend = ClaudeCodeBackend(executable: { nil }, prebuildMCP: false)
        do {
            for try await _ in backend.run(AgentRequest(project: Project.open(URL(fileURLWithPath: "/tmp")), scene: "", commentIDs: [])) {}
            XCTFail("expected claudeNotFound")
        } catch {
            XCTAssertTrue("\(error)".contains("not found"))
        }
    }
}
