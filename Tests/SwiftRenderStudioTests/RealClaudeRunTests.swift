import XCTest
import SwiftRenderKit
@testable import SwiftRenderStudio

/// One real headless Claude Code run through Studio's own path (AgentController →
/// AgentPrompt → ClaudeCodeBackend → `claude -p … --agent swift-render-director`), on
/// this repo: a throwaway comment on TimelineDemo asks for a reply only ("ack"), the run
/// is Reply-only mode (no edits, no builds) with a $1 budget, and the comment and its
/// attachments are always deleted afterwards. Spends real money and needs `claude`
/// logged in, so opt-in:
///
///   SR_STUDIO_REAL_CLAUDE=1 swift test --filter RealClaudeRunTests
///
/// The raw stream is kept at .swift-render/cache/agent/<run>.jsonl.
@MainActor
final class RealClaudeRunTests: XCTestCase {
    func testReplyOnlyRunOnTimelineDemo() async throws {
        guard ProcessInfo.processInfo.environment["SR_STUDIO_REAL_CLAUDE"] == "1" else {
            throw XCTSkip("set SR_STUDIO_REAL_CLAUDE=1 to run a real (paid) claude -p turn")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let project = Project.open(root)
        let store = ReviewStore(project: project)
        let comment = ReviewComment(t: 3, body: "Studio agent check: reply to this comment with the word ack. Do not edit any files.",
                                    author: ReviewAuthor(name: "studio-test"))
        try store.add(scene: "TimelineDemo", comment)
        defer { try? store.remove(scene: "TimelineDemo", id: comment.id) }

        let agent = AgentController(project: project, backend: ClaudeCodeBackend())
        agent.ask(AgentRequest(project: project, scene: "TimelineDemo", commentIDs: [comment.id], mode: .reply,
                               instructions: "Reply with the single word ack. Nothing else.", budgetUSD: 1))
        let deadline = Date().addingTimeInterval(600)
        while agent.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(200)) }
        XCTAssertFalse(agent.isRunning, "run did not finish in 10 minutes")

        for row in agent.transcript {
            print("[agent] \(row.kind.rawValue)\(row.ok.map { $0 ? " ✓" : " ✕" } ?? ""): \(row.title) \(row.detail)")
        }
        let run = try XCTUnwrap(agent.currentRun)
        print("[agent] ok=\(run.ok.map(String.init) ?? "nil") cost=\(run.costUSD ?? -1) seconds=\(run.seconds ?? -1) "
              + "session=\(run.sessionID ?? "-") log=\(run.logURL?.path ?? "-")")
        let after = try store.load(scene: "TimelineDemo").comments.first { $0.id == comment.id }
        let replies = after?.replies ?? []
        print("[agent] replies: " + replies.map { "\($0.author.name)(\($0.author.kind.rawValue)): \($0.body)" }.joined(separator: " | "))

        XCTAssertNotNil(run.sessionID, "no system/init line")
        XCTAssertEqual(run.ok, true, "run failed: \(run.result ?? "-")")
        XCTAssertTrue(replies.contains { $0.author.kind == .agent && $0.body.lowercased().contains("ack") },
                      "no agent reply containing ack")
        XCTAssertEqual(after?.status, .open, "reply-only runs leave the status alone")
    }
}
