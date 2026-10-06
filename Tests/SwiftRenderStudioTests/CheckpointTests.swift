import XCTest
import SwiftRenderKit
@testable import SwiftRenderStudio

/// Revert Run must only ever put files back as they were, or leave them alone: never
/// trash a file that existed before the run, never touch files outside the run, never
/// silently overwrite edits made since the run, and restore bytes exactly.
final class CheckpointTests: XCTestCase {
    private func git(_ args: [String], _ dir: URL) throws -> String { try Checkpoint.git(args, cwd: dir) }

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sr-cp-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return Checkpoint.realpath(url)
    }

    private func makeRepo(commit files: [String: String] = ["Sources/A.swift": "a\nb\nc\n"],
                          gitignore: String? = nil) throws -> URL {
        let root = try tempDir()
        _ = try git(["init", "-q"], root)
        _ = try git(["config", "user.email", "t@example.com"], root)
        _ = try git(["config", "user.name", "t"], root)
        _ = try git(["config", "commit.gpgsign", "false"], root)
        _ = try git(["config", "core.hooksPath", "/dev/null"], root)
        var all = files
        if let gitignore { all[".gitignore"] = gitignore }
        for (path, text) in all { try write(text, root, path) }
        _ = try git(["add", "."], root)
        _ = try git(["commit", "-qm", "init"], root)
        return root
    }

    private func write(_ text: String, _ root: URL, _ path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ root: URL, _ path: String) -> String? {
        try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func revert(_ cp: Checkpoint, _ root: URL, _ paths: [String], keep: Set<String> = [],
                        backup: String? = nil) throws -> (Checkpoint.RevertResult, [String]) {
        var trashed: [String] = []
        let r = try cp.revert(files: paths.map { root.appendingPathComponent($0).path }, keep: keep, backupRef: backup) {
            trashed.append($0.lastPathComponent)
            try FileManager.default.removeItem(at: $0)
        }
        return (r, trashed)
    }

    // MARK: Pre-existing files are never trashed

    func testIgnoredFileEditedByTheAgentIsRestoredNotTrashed() throws {
        let root = try makeRepo(gitignore: ".env\n")
        try write("SECRET=user-original\n", root, ".env")
        let cp = try Checkpoint.create(project: Project.open(root), runID: "ign")
        try write("SECRET=agent-edit\n", root, ".env")
        XCTAssertEqual(try cp.diffStat(files: [root.appendingPathComponent(".env").path]).first?.created, false,
                       "not labelled as created by the agent")
        let (r, trashed) = try revert(cp, root, [".env"])
        XCTAssertEqual(trashed, [])
        XCTAssertEqual(r.restored, [".env"])
        XCTAssertEqual(read(root, ".env"), "SECRET=user-original\n")
    }

    func testFileInsideIgnoredDirectoryIsLeftAloneAndReported() throws {
        let root = try makeRepo(gitignore: "local/\n")
        try write("{\"user\": true}\n", root, "local/props.json")
        let cp = try Checkpoint.create(project: Project.open(root), runID: "igndir")
        XCTAssertTrue(cp.ignored.contains("local/"))
        let (r, trashed) = try revert(cp, root, ["local/props.json"])
        XCTAssertEqual(trashed, [], "the user's file stays")
        XCTAssertEqual(r.skipped.map(\.path), ["local/props.json"])
        XCTAssertEqual(read(root, "local/props.json"), "{\"user\": true}\n")
    }

    func testWrongCasePathToTrackedFileIsRestoredNotTrashed() throws {
        let root = try makeRepo()
        try write("a\nB-user\nc\n", root, "Sources/A.swift")              // uncommitted work at checkpoint time
        let cp = try Checkpoint.create(project: Project.open(root), runID: "case")
        try write("agent\n", root, "Sources/A.swift")
        // The agent named it in the wrong case; the volume is case-insensitive.
        let wrong = root.appendingPathComponent("sources/a.swift").path
        guard FileManager.default.fileExists(atPath: wrong) else { throw XCTSkip("case-sensitive volume") }
        XCTAssertEqual(cp.relative(wrong), "Sources/A.swift")
        var trashed: [String] = []
        let r = try cp.revert(files: [wrong]) { trashed.append($0.path); try FileManager.default.removeItem(at: $0) }
        XCTAssertEqual(trashed, [])
        XCTAssertEqual(r.restored, ["Sources/A.swift"])
        XCTAssertEqual(read(root, "Sources/A.swift"), "a\nB-user\nc\n")
        XCTAssertEqual(try git(["status", "--porcelain"], root), " M Sources/A.swift\n")
    }

    func testFileInsideUntrackedNestedRepositoryIsSkippedAndCheckpointStillWorks() throws {
        let root = try makeRepo()
        let nested = root.appendingPathComponent("vendor/lib")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        _ = try git(["init", "-q"], nested)
        try write("lib v1\n", root, "vendor/lib/L.swift")
        // A dangling symlink must not abort checkpoint creation either.
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("build-link").path,
                                                   withDestinationPath: "/nonexistent/out")
        let cp = try Checkpoint.create(project: Project.open(root), runID: "nested")
        try write("agent\n", root, "vendor/lib/L.swift")
        let (r, trashed) = try revert(cp, root, ["vendor/lib/L.swift"])
        XCTAssertEqual(trashed, [])
        XCTAssertEqual(r.skipped.first?.reason.contains("nested repository"), true, "\(r.skipped)")
    }

    func testCheckpointWithoutHEADOrMidMerge() throws {
        // A fresh `git init` with staged files: `git stash create` can't run.
        let root = try tempDir()
        _ = try git(["init", "-q"], root)
        try write("first\n", root, "Sources/A.swift")
        _ = try git(["add", "."], root)
        let cp = try Checkpoint.create(project: Project.open(root), runID: "unborn")
        XCTAssertTrue(cp.isTracked("Sources/A.swift"))
        try write("agent\n", root, "Sources/A.swift")
        _ = try revert(cp, root, ["Sources/A.swift"])
        XCTAssertEqual(read(root, "Sources/A.swift"), "first\n")

        // A conflicted merge: unmerged paths make `git stash create` fail too.
        _ = try git(["config", "user.email", "t@example.com"], root)
        _ = try git(["config", "user.name", "t"], root)
        _ = try git(["config", "commit.gpgsign", "false"], root)
        _ = try git(["commit", "-qm", "base"], root)
        _ = try git(["checkout", "-q", "-b", "side"], root)
        try write("side\n", root, "Sources/A.swift")
        _ = try git(["commit", "-qam", "side"], root)
        _ = try git(["checkout", "-q", "-"], root)
        try write("main\n", root, "Sources/A.swift")
        _ = try git(["commit", "-qam", "main"], root)
        XCTAssertThrowsError(try git(["merge", "-q", "side"], root))
        let conflicted = try XCTUnwrap(read(root, "Sources/A.swift"))
        let mid = try Checkpoint.create(project: Project.open(root), runID: "merge")
        try write("agent\n", root, "Sources/A.swift")
        _ = try revert(mid, root, ["Sources/A.swift"])
        XCTAssertEqual(read(root, "Sources/A.swift"), conflicted, "back to the conflict markers")
    }

    func testNewFileIsTrashed() throws {
        let root = try makeRepo(gitignore: ".env\n")
        let cp = try Checkpoint.create(project: Project.open(root), runID: "new")
        try write("x\n", root, "Sources/New.swift")
        try write("NEW=1\n", root, ".env")                                  // ignored, but didn't exist before
        let (r, trashed) = try revert(cp, root, ["Sources/New.swift", ".env"])
        XCTAssertEqual(Set(trashed), ["New.swift", ".env"])
        XCTAssertEqual(Set(r.trashed), ["Sources/New.swift", ".env"])
    }

    // MARK: Only the touched files, literally

    func testGlobCharactersInPathsMatchOnlyThatFile() throws {
        let root = try makeRepo(commit: ["Sources/Scene[ab].swift": "glob v1\n", "Sources/Scenea.swift": "a v1\n"])
        try write("a v1\nuser work 1\n", root, "Sources/Scenea.swift")
        let cp = try Checkpoint.create(project: Project.open(root), runID: "glob")
        try write("a v1\nuser work 1\nuser work 2 after checkpoint\n", root, "Sources/Scenea.swift")
        try write("agent\n", root, "Sources/Scene[ab].swift")
        let stats = try cp.diffStat(files: [root.appendingPathComponent("Sources/Scene[ab].swift").path])
        XCTAssertEqual(stats.map(\.path), ["Sources/Scene[ab].swift"])
        _ = try revert(cp, root, ["Sources/Scene[ab].swift"])
        XCTAssertEqual(read(root, "Sources/Scene[ab].swift"), "glob v1\n")
        XCTAssertEqual(read(root, "Sources/Scenea.swift"), "a v1\nuser work 1\nuser work 2 after checkpoint\n",
                       "a file the agent never touched keeps the user's later work")
    }

    // MARK: Edits since the run

    func testEditsMadeAfterTheAgentAreKeptAndEverythingIsBackedUp() throws {
        let root = try makeRepo(commit: ["Sources/A.swift": "a\nb\nc\n", "Sources/B.swift": "b\n"])
        let cp = try Checkpoint.create(project: Project.open(root), runID: "since")
        try write("a\nb-agent\nc\n", root, "Sources/A.swift")
        try write("b-agent\n", root, "Sources/B.swift")
        let files = ["Sources/A.swift", "Sources/B.swift"].map { root.appendingPathComponent($0).path }
        let left = cp.fingerprint(files: files)                         // the run finished here
        try write("a\nb-agent\nc\n// user's 200 lines of new work\n", root, "Sources/A.swift")
        let now = cp.fingerprint(files: files)
        let changed = Set(now.filter { left[$0.key] != $0.value }.keys)
        XCTAssertEqual(changed, ["Sources/A.swift"])

        let (r, _) = try revert(cp, root, ["Sources/A.swift", "Sources/B.swift"], keep: changed,
                                backup: Checkpoint.backupPrefix + "since")
        XCTAssertEqual(read(root, "Sources/A.swift"), "a\nb-agent\nc\n// user's 200 lines of new work\n", "kept")
        XCTAssertEqual(read(root, "Sources/B.swift"), "b\n", "reverted")
        XCTAssertEqual(r.skipped, [.init(path: "Sources/A.swift", reason: "changed since the run")])
        // What the revert overwrote can be brought back.
        XCTAssertEqual(try git(["show", "\(Checkpoint.backupPrefix)since:Sources/B.swift"], root), "b-agent\n")

        // Discarding them too still leaves a copy.
        let (all, _) = try revert(cp, root, ["Sources/A.swift"], backup: Checkpoint.backupPrefix + "since2")
        XCTAssertEqual(all.restored, ["Sources/A.swift"])
        XCTAssertEqual(read(root, "Sources/A.swift"), "a\nb\nc\n")
        XCTAssertTrue(try git(["show", "\(Checkpoint.backupPrefix)since2:Sources/A.swift"], root)
                        .contains("user's 200 lines"))
    }

    // MARK: Byte-faithful untracked restore

    func testUntrackedCRLFAndSymlinkComeBackExactly() throws {
        let root = try makeRepo(commit: ["Sources/A.swift": "a\n", "shared/config.json": "orig"],
                                gitignore: nil)
        try write("* text=auto\n", root, ".gitattributes")
        _ = try git(["add", ".gitattributes"], root)
        _ = try git(["commit", "-qm", "attrs"], root)
        try write("line1\r\nline2\r\n", root, "notes.txt")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link.json").path,
                                                   withDestinationPath: "shared/config.json")
        let cp = try Checkpoint.create(project: Project.open(root), runID: "bytes")
        XCTAssertEqual(cp.links["link.json"], "shared/config.json")

        try write("agent\r\n", root, "notes.txt")
        try Data("agent".utf8).write(to: root.appendingPathComponent("link.json"))   // writes through the link
        let (r, trashed) = try revert(cp, root, ["notes.txt", "link.json"])
        XCTAssertEqual(trashed, [])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("notes.txt")), Data("line1\r\nline2\r\n".utf8))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: root.appendingPathComponent("link.json").path),
                       "shared/config.json", "still a link")
        XCTAssertEqual(read(root, "shared/config.json"), "orig", "the link's target is reverted too")
        XCTAssertTrue(r.restored.contains("shared/config.json"))
        XCTAssertEqual(try git(["status", "--porcelain", "--", "shared"], root), "")
    }
}

/// Which files a run counts as written, through the controller.
@MainActor
final class AgentTouchedTests: XCTestCase {
    func testFailedWriteIsNotCountedAsTouched() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sr-touch-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = AgentController(project: Project.open(root), backend: ReplayAgentBackend(lines: []))
        agent.ask(AgentRequest(project: Project.open(root), scene: "S", commentIDs: [], mode: .fix))
        let ok = root.appendingPathComponent("Sources/A.swift").path
        let denied = root.appendingPathComponent("local/props.json").path
        let unknown = root.appendingPathComponent("Sources/B.swift").path
        agent.handle(.tool(AgentToolCall(id: "t1", name: "Write", summary: "", files: [denied], writes: true)))
        agent.handle(.toolResult(id: "t1", ok: false, summary: "File has not been read yet"))
        agent.handle(.tool(AgentToolCall(id: "t2", name: "Edit", summary: "", files: [ok], writes: true)))
        agent.handle(.toolResult(id: "t2", ok: true, summary: "updated"))
        agent.handle(.tool(AgentToolCall(id: "t3", name: "Edit", summary: "", files: [unknown], writes: true)))
        XCTAssertEqual(agent.currentRun?.touched, [ok])
        let deadline = Date().addingTimeInterval(5)
        while agent.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        // Stopped before its result: it may have written, so revert covers it.
        XCTAssertEqual(agent.currentRun?.touched, [ok, unknown])
    }
}
